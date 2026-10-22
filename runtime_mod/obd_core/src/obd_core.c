// Conker Maker runtime (obd_core) v0.1: the skeleton the level loader grows from.
//
// What it does now:
//   1. Once the game is running, reads the Conker Maker package header from the ROM's free
//      space (0x3F8C000, see cmtools/package.py) with the game's own ROM loader,
//      func_10004514(rom_offset, dram, size rounded to 16, 1), and prints what it found.
//   2. Prints each scene change (the scene in play is at 0x800BE9F0, as Skip Intro uses),
//      so the scene IDs Conker Maker levels will be built on can be mapped by playing.
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

// The game's ROM -> RDRAM loader (conkers-bfd-decomp src/game/game_57FA0.c).
void func_10004514(s32 rom_offset, s32 dram, s32 size, s32 wait);

typedef struct {
    char magic[4];       // 'CMKR'
    u16 version;
    u16 flags;
    u32 size;            // compressed payload bytes
    u32 crc32;
    u32 raw_size;        // JSON bytes
    char title[44];
} PackageHeader;

static int frames = 0;
static int checked = 0;
static int found = 0;
static s32 last_scene = -1;
static PackageHeader header;

static void read_package_header(void) {
    // The loader writes in 16-byte units to a 16-byte aligned address.
    u8* raw = (u8*)recomp_alloc(PACKAGE_HEADER_SIZE + 16);
    u8* buffer = (u8*)(((u32)raw + 15) & ~15u);
    const u8* src;
    u8* dst = (u8*)&header;
    unsigned i;
    func_10004514(PACKAGE_ROM_OFFSET, (s32)buffer, PACKAGE_HEADER_SIZE, 1);
    src = buffer;
    for (i = 0; i < sizeof(header); i++) {
        dst[i] = src[i];
    }
    recomp_free(raw);
    header.title[sizeof(header.title) - 1] = '\0';
    found = header.magic[0] == 'C' && header.magic[1] == 'M' && header.magic[2] == 'K' && header.magic[3] == 'R';
    if (found) {
        recomp_printf("[Conker Maker] Game found: \"%s\" (package v%d, %d bytes, %d bytes unpacked)\n",
                      header.title, header.version, header.size, header.raw_size);
    } else {
        recomp_printf("[Conker Maker] No Conker Maker game in this ROM: playing Bad Fur Day as normal.\n");
    }
}

RECOMP_HOOK_RETURN("func_1501BBB8") void obd_core_on_frame(void) {
    s32 scene;
    frames++;
    // Wait a moment after boot, so the game's own loader is set up before we borrow it.
    if (!checked && frames > 30) {
        checked = 1;
        read_package_header();
    }
    scene = scene_in_play;
    if (scene != last_scene) {
        if (recomp_get_config_u32("log_scenes")) {
            recomp_printf("[Conker Maker] Scene 0x%02X (frame %d)\n", scene, frames);
        }
        last_scene = scene;
    }
}
