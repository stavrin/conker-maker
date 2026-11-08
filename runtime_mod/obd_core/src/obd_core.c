// Conker Maker runtime (obd_core) v0.3: the level loader, growing.
//
// What it does:
//   1. Once the game is running, reads the Conker Maker package from the ROM's free space
//      (0x3F8C000, see cmtools/package.py) with the game's own ROM loader, then the runtime
//      block it points to (cmtools/runtime.py): levels, events, conditions, actions, strings.
//   2. When a scene a level is built on comes into play, waits a moment for it to settle, puts
//      Conker at the level's Conker Start (position and facing) and runs its "Level starts"
//      events whose conditions hold: Give/Take cash change the real wallet, story flags are kept
//      here, waits wait. Lines ("say") go to the console for now: the real game's speech
//      bubbles aren't worked out yet. Actions it can't do yet are named in the console.
//   3. Game Actors: as a level's scene loads, appends its Game Actor objects to the scene's actor
//      table (the 48-byte placement records func_150169A0 reads from asset bank 0E; see
//      conker_maker/docs/ACTORS.md), so the game itself spawns them, with their own looks and
//      behaviour. Each is copied from a record of the same actor number in that scene if there
//      is one, else from a plain template, and set to spawn straight away.
//   4. Logs scene changes and (if switched on) Conker's position and facing every two seconds,
//      which is how the scene numbers and the editor -> game conversion get checked.
//
// Hooked on func_1501BBB8, which reads the controllers once per game frame (the hook the
// Cheats mod uses).

#include "modding.h"
#include "PR/ultratypes.h"
#include "recompconfig.h"
#include "recomputils.h"

#define PACKAGE_ROM_OFFSET 0x03F8C000
#define PACKAGE_HEADER_SIZE 0x40
#define scene_in_play (*(volatile s32*)0x800BE9F0)
#define cash (*(volatile s32*)0x800D2148)

// Conker is gObjects[0] (0x32C bytes each): his position is three floats at +0x14, his
// facing three angles at +0x76 / +0x78 / +0x7A (0x10000 a full turn; +0x7A the one he moves by).
#define CONKER 0x800CC2D0
#define conker_x (*(volatile f32*)(CONKER + 0x14))
#define conker_y (*(volatile f32*)(CONKER + 0x18))
#define conker_z (*(volatile f32*)(CONKER + 0x1C))
#define conker_angle_76 (*(volatile u16*)(CONKER + 0x76))
#define conker_angle_78 (*(volatile u16*)(CONKER + 0x78))
#define conker_angle_7A (*(volatile u16*)(CONKER + 0x7A))

#define FRAMES_PER_SECOND 30   // game frames (the hook's rate)
#define SETTLE_FRAMES 20       // after a scene comes into play, before placing Conker
#define MAX_FLAGS 64
#define NONE 0xFFFF

// The game's ROM -> RDRAM loader (conkers-bfd-decomp src/game/game_57FA0.c).
void func_10004514(s32 rom_offset, s32 dram, s32 size, s32 wait);
// The game's allocator and memset-to-zero (as func_15017114 uses them for the actor tables).
void* allocate_memory(s32 size, s32 a1, s32 a2, s32 a3);   // func_10003C40 in the decomp
void bzero(void* p, s32 size);                                // func_100226F0

// The scene's actor table, built by func_150169A0 as the scene loads: the players' records,
// then the scene's own (bank 0E), 0x30 bytes each; then func_15017114 gives each a path.
#define ACTOR_RECORD 0x30
#define actor_table (*(u8**)0x800D20FC)
#define scene_actor_count (*(u8*)0x800D2100)
#define actor_paths (*(u32**)0x800D2104)
#define actor_path_kinds (*(u8**)0x800D2108)

// A record that spawns at once (byte 2 is 0; 1 would wait to be woken by a trigger), copied
// from one in Windy's table, for actor numbers the scene doesn't have a record of its own for.
static const u8 actor_template[ACTOR_RECORD] = {
    0x00, 0x20, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x81, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x20, 0x00, 0x63, 0x32, 0x32, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00,
    0x3F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x00, 0x00, 0x00, 0x00,
};

enum { TRIGGER_LEVEL_START = 1 };
enum { COND_FLAG_SET = 1, COND_FLAG_NOT_SET = 2, COND_CASH_AT_LEAST = 3 };
enum { ACT_OTHER = 0, ACT_SAY, ACT_GIVE_CASH, ACT_TAKE_CASH, ACT_SET_FLAG, ACT_WAIT, ACT_GOTO_LEVEL };

// Everything below is big-endian in the ROM, which is how the recompiled game reads memory
// too, so the structs are read as they are. (Packed by hand: every field is aligned.)
typedef struct {
    char magic[4];       // 'CMKR'
    u16 version;
    u16 flags;
    u32 size;            // compressed payload bytes
    u32 crc32;
    u32 raw_size;        // JSON bytes
    char title[36];
    u32 runtime_offset;  // v2: the runtime block, from the start of the header
    u32 runtime_size;
} PackageHeader;

typedef struct {
    char magic[4];       // 'CMRT'
    u16 version, level_count, event_count, condition_count, action_count, start_level;
    u32 levels, events, conditions, strings;
    u32 actors;          // v2
    u16 actor_total, pad;
} RuntimeHeader;

typedef struct {
    s16 scene;
    u16 flags;           // 1: has a Conker Start
    f32 x, y, z;
    u16 angle;
    u16 first_event, event_count;
    u16 name;
    u16 first_actor, actor_count;
} Level;

typedef struct {
    u8 actor, angle;
    s16 x, y, z;
    u16 pad, pad2;
} GameActor;

typedef struct {
    u8 trigger, flags;
    u16 subject;
    u16 first_condition, condition_count;
    u16 first_action, action_count;
} Event;

typedef struct {
    u8 type, pad;
    u16 text;
    s32 value;
} Condition;

typedef struct {
    u8 type, pad;
    u16 a, b, pad2;
    s32 value;
} Action;

static int frames = 0;
static int checked = 0;
static s32 last_scene = -1;
static PackageHeader header;

static u8* block = 0;            // the runtime block, once read
static RuntimeHeader* rt = 0;
static Level* levels;
static Event* events;
static Condition* conditions;
static Action* actions;
static const char* strings;
static GameActor* game_actors;

static u16 flags_set[MAX_FLAGS];
static int flag_count = 0;

static int pending_level = -1;   // a level whose scene just came into play
static int settle = 0;
static int queue_event = -1;     // the level_start events still to look at: [queue_event, queue_end)
static int queue_end = 0;
static int running_action = -1;  // the event being played: [running_action, running_end)
static int running_end = 0;
static int wait_frames = 0;

static const char* text(u16 offset) {
    return offset == NONE ? "" : strings + offset;
}

// Copies from the ROM with the game's loader, which works in 16-byte units into 16-byte aligned
// memory. Returns a recomp_alloc'd buffer (free with recomp_free on the 'raw' pointer).
static u8* read_rom(u32 rom_offset, u32 size, u8** raw) {
    u32 rounded = (size + 15) & ~15u;
    *raw = (u8*)recomp_alloc(rounded + 16);
    u8* buffer = (u8*)(((u32)*raw + 15) & ~15u);
    func_10004514(rom_offset, (s32)buffer, rounded, 1);
    return buffer;
}

static int same(const char* a, const char* b, int n) {
    int i;
    for (i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

static void read_package(void) {
    u8* raw;
    u8* buffer = read_rom(PACKAGE_ROM_OFFSET, PACKAGE_HEADER_SIZE, &raw);
    u8* dst = (u8*)&header;
    unsigned i;
    for (i = 0; i < sizeof(header); i++) {
        dst[i] = buffer[i];
    }
    recomp_free(raw);
    header.title[sizeof(header.title) - 1] = '\0';
    if (!same(header.magic, "CMKR", 4)) {
        recomp_printf("[Conker Maker] No Conker Maker game in this ROM: playing Bad Fur Day as normal.\n");
        return;
    }
    recomp_printf("[Conker Maker] Game found: \"%s\" (package v%d)\n", header.title, header.version);
    if (header.version < 2 || header.runtime_size < sizeof(RuntimeHeader)) {
        recomp_printf("[Conker Maker] This game was built with an older Conker Maker: rebuild it to play it here.\n");
        return;
    }
    {
        u8* keep;
        u8* data = read_rom(PACKAGE_ROM_OFFSET + header.runtime_offset, header.runtime_size, &keep);
        RuntimeHeader* h = (RuntimeHeader*)data;
        if (!same(h->magic, "CMRT", 4) || h->version < 2) {
            recomp_printf("[Conker Maker] The game's runtime data is missing or damaged.\n");
            recomp_free(keep);
            return;
        }
        block = data;
        rt = h;
        levels = (Level*)(block + rt->levels);
        events = (Event*)(block + rt->events);
        conditions = (Condition*)(block + rt->conditions);
        actions = (Action*)(block + rt->conditions + rt->condition_count * sizeof(Condition));
        strings = (const char*)(block + rt->strings);
        game_actors = (GameActor*)(block + rt->actors);
    }
    recomp_printf("[Conker Maker] %d levels, %d events, %d actions.\n", rt->level_count, rt->event_count,
                  rt->action_count);
    {
        int i;
        for (i = 0; i < rt->level_count; i++) {
            if (levels[i].scene >= 0) {
                recomp_printf("[Conker Maker]   \"%s\" plays in scene 0x%02X\n", text(levels[i].name), levels[i].scene);
            } else {
                recomp_printf("[Conker Maker]   \"%s\" is built on a blank ground: it plays only in the editor for now\n",
                              text(levels[i].name));
            }
        }
    }
}

// --- game actors --------------------------------------------------------------------------

// After func_15017114 has given the scene's actors their paths, and before func_150169A0 sizes
// the spawn tables by the count and spawns them: make room for this level's Game Actors.
RECOMP_HOOK_RETURN("func_15017114") void obd_core_add_actors(void) {
    int i, j, level = -1;
    int old, total, n;
    u8* table;
    u32* paths;
    u8* kinds;
    if (rt == 0 || !recomp_get_config_u32("place_actors")) {
        return;
    }
    for (i = 0; i < rt->level_count; i++) {
        if (levels[i].scene == scene_in_play && levels[i].actor_count > 0) {
            level = i;
            break;
        }
    }
    if (level < 0) {
        return;
    }
    old = scene_actor_count;
    n = levels[level].actor_count;
    if (old + n > 255) {
        n = 255 - old;
    }
    total = old + n;
    table = (u8*)allocate_memory(total * ACTOR_RECORD, 1, 2, 0);
    paths = (u32*)allocate_memory(total * 4, 1, 0, 0);
    kinds = (u8*)allocate_memory(total, 1, 0, 0);
    if (table == 0 || paths == 0 || kinds == 0) {
        recomp_printf("[Conker Maker] No room for the level's game actors.\n");
        return;
    }
    bzero(paths, total * 4);
    bzero(kinds, total);
    for (i = 0; i < old * ACTOR_RECORD; i++) {
        table[i] = actor_table[i];
    }
    for (i = 0; i < old; i++) {
        paths[i] = actor_paths[i];
        kinds[i] = actor_path_kinds[i];
    }
    for (i = 0; i < n; i++) {
        const GameActor* a = &game_actors[levels[level].first_actor + i];
        u8* r = table + (old + i) * ACTOR_RECORD;
        const u8* from = actor_template;
        for (j = *(u8*)0x800D2101; j < old; j++) {   // one of the scene's own (not a player's) of the same kind
            if (actor_table[j * ACTOR_RECORD + 4] == a->actor) {
                from = actor_table + j * ACTOR_RECORD;
                break;
            }
        }
        for (j = 0; j < ACTOR_RECORD; j++) {
            r[j] = from[j];
        }
        r[2] = 0;                     // spawn now, not when a trigger wakes it
        r[4] = a->actor;
        r[6] = (u8)(a->x >> 8); r[7] = (u8)a->x;
        r[8] = (u8)(a->y >> 8); r[9] = (u8)a->y;
        r[10] = (u8)(a->z >> 8); r[11] = (u8)a->z;
        r[12] = a->angle;
        r[0x28] = 0;                  // func_150169A0 hands out a fresh id
        recomp_printf("[Conker Maker] Game actor %d (0x%02X) at %d, %d, %d%s\n", a->actor, a->actor, a->x, a->y,
                      a->z, from == actor_template ? " (template)" : "");
    }
    actor_table = table;
    actor_paths = paths;
    actor_path_kinds = kinds;
    scene_actor_count = (u8)total;
}

// --- story flags ---------------------------------------------------------------------------

static int same_string(u16 a, u16 b) {
    const char* x = text(a);
    const char* y = text(b);
    while (*x && *x == *y) {
        x++;
        y++;
    }
    return *x == *y;
}

static int flag_is_set(u16 name) {
    int i;
    for (i = 0; i < flag_count; i++) {
        if (same_string(flags_set[i], name)) {
            return 1;
        }
    }
    return 0;
}

static void set_flag(u16 name) {
    if (name == NONE || flag_is_set(name) || flag_count >= MAX_FLAGS) {
        return;
    }
    flags_set[flag_count++] = name;
}

// --- events --------------------------------------------------------------------------------

static int conditions_hold(const Event* e) {
    int i;
    for (i = 0; i < e->condition_count; i++) {
        const Condition* c = &conditions[e->first_condition + i];
        switch (c->type) {
            case COND_FLAG_SET:
                if (!flag_is_set(c->text)) return 0;
                break;
            case COND_FLAG_NOT_SET:
                if (flag_is_set(c->text)) return 0;
                break;
            case COND_CASH_AT_LEAST:
                if (cash < c->value) return 0;
                break;
            default:
                break;
        }
    }
    return 1;
}

// Runs actions until one has to wait (or the event ends).
static void run_actions(void) {
    while (running_action >= 0 && running_action < running_end) {
        const Action* a = &actions[running_action++];
        switch (a->type) {
            case ACT_SAY:
                recomp_printf("[Conker Maker] %s: \"%s\"\n", text(a->a), text(a->b));
                break;
            case ACT_GIVE_CASH:
                cash += a->value;
                recomp_printf("[Conker Maker] +$%d (wallet $%d)\n", a->value, cash);
                break;
            case ACT_TAKE_CASH:
                cash = cash > a->value ? cash - a->value : 0;
                recomp_printf("[Conker Maker] -$%d (wallet $%d)\n", a->value, cash);
                break;
            case ACT_SET_FLAG:
                set_flag(a->a);
                recomp_printf("[Conker Maker] Story flag set: %s\n", text(a->a));
                break;
            case ACT_WAIT:
                wait_frames = (a->value * FRAMES_PER_SECOND + 999) / 1000;
                if (wait_frames > 0) {
                    return;
                }
                break;
            case ACT_GOTO_LEVEL:
                recomp_printf("[Conker Maker] (Go to level \"%s\": not in the real game yet)\n", text(a->a));
                break;
            default:
                recomp_printf("[Conker Maker] (Skipped \"%s\": not in the real game yet)\n", text(a->a));
                break;
        }
    }
    running_action = -1;
}

// Starts the next level_start event whose conditions hold, if nothing is playing.
static void next_event(void) {
    while (running_action < 0 && queue_event >= 0 && queue_event < queue_end) {
        const Event* e = &events[queue_event++];
        if (e->trigger != TRIGGER_LEVEL_START || !conditions_hold(e)) {
            continue;
        }
        running_action = e->first_action;
        running_end = e->first_action + e->action_count;
        run_actions();
    }
    if (queue_event >= queue_end) {
        queue_event = -1;
    }
}

// --- levels --------------------------------------------------------------------------------

static void start_level(int index) {
    const Level* l = &levels[index];
    recomp_printf("[Conker Maker] Level \"%s\" starts\n", text(l->name));
    if ((l->flags & 1) && recomp_get_config_u32("place_conker")) {
        conker_x = l->x;
        conker_y = l->y;
        conker_z = l->z;
        conker_angle_76 = l->angle;
        conker_angle_78 = l->angle;
        conker_angle_7A = l->angle;
        recomp_printf("[Conker Maker] Conker placed at %d, %d, %d facing 0x%04X\n", (int)l->x, (int)l->y,
                      (int)l->z, l->angle);
    }
    queue_event = l->first_event;
    queue_end = l->first_event + l->event_count;
    running_action = -1;
    wait_frames = 0;
}

static void on_scene(s32 scene) {
    int i;
    pending_level = -1;
    queue_event = -1;
    running_action = -1;
    if (rt == 0) {
        return;
    }
    for (i = 0; i < rt->level_count; i++) {
        if (levels[i].scene == scene) {
            pending_level = i;
            settle = SETTLE_FRAMES;
            return;
        }
    }
}

RECOMP_HOOK_RETURN("func_1501BBB8") void obd_core_on_frame(void) {
    s32 scene;
    frames++;
    // Wait a moment after boot, so the game's own loader is set up before we borrow it.
    if (!checked && frames > 30) {
        checked = 1;
        read_package();
        last_scene = -1;   // look at the scene in play again, now there are levels to match
    }
    scene = scene_in_play;
    if (scene != last_scene) {
        if (recomp_get_config_u32("log_scenes")) {
            recomp_printf("[Conker Maker] Scene 0x%02X (%d) (frame %d)\n", scene, scene, frames);
        }
        last_scene = scene;
        if (checked) {
            on_scene(scene);
        }
    }
    if (pending_level >= 0 && --settle <= 0) {
        start_level(pending_level);
        pending_level = -1;
    }
    if (wait_frames > 0 && --wait_frames == 0) {
        run_actions();
    }
    if (wait_frames == 0) {
        next_event();
    }
    if (recomp_get_config_u32("log_position") && frames % (FRAMES_PER_SECOND * 2) == 0) {
        recomp_printf("[Conker Maker] Scene 0x%02X: Conker at %d, %d, %d facing 0x%04X\n", scene, (int)conker_x,
                      (int)conker_y, (int)conker_z, conker_angle_7A);
    }
}
