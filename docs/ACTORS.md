# Bad Fur Day's actors, and how Conker Maker places them

How the real game spawns its characters and things, worked out from the game code
(conkers-bfd-decomp, US) for the obd_core runtime mod. Function names are the decomp's.

## The actor table

When a scene loads, `func_150169A0(scene)` (called with the scene in play, `D_800BE9F0`)
builds the scene's **actor table** at `D_800D20FC`:

1. A built-in prefix of players' records, copied from ROM (which prefix depends on the scene).
   `D_800D2101` is how many.
2. The scene's own records, from asset **bank 0E, entry = the scene number**, appended.
   `D_800D2100` is the total.
3. `func_15017114(scene)` gives each scene actor its path (bank 10), into `D_800D2104`
   (pointers) and `D_800D2108` (kinds), both sized by the count.
4. The players' records get their character and Conker's position.
5. `func_15016850()` loads each actor number's data (bank 0x12, entry = actor number;
   numbers below 0xBB) into `D_800BE5A8`, numbers in `D_800BE598`, count `D_800BE590`.
6. Records with no id (byte 0x28) are given one by `func_15083DA0`.
7. `func_1508295C(scene, 1, 1)` spawns the players; `func_1508295C(scene, 1, 0)` the rest.

`func_150825C0(index)` decides whether a record spawns now: not if it's already spawned
(`D_800D210C[index]`), not if byte 2 is 1 (it waits for a trigger to wake it, as
`func_15072420` does), not if x is 0x7FFF, not while its respawn timer (`D_800D2110`) runs,
only near a player if byte 1 bits 1-2 ask for that, and only off screen if byte 1 bit 3 asks.
Then `func_15082A44(record, index, 0, 0, 0)` creates the actor in a free `gObjects` slot
(`func_1505ED34`, 25 at most) and returns its index + 1. The actor keeps a pointer to its
record at +0x144 and its table index at +0x13F; its actor number is byte +4 (Conker is 0x96).

So the scene number the game uses everywhere is the same as the asset banks' index, which is
the `scene-NN` number Conker Maker shows: `scene-12` is scene in play 0x0C.

## The 48-byte record (known parts)

| Offset | Size | Meaning |
|---|---|---|
| 0x01 | u8 | spawn rules: bits 1-2 only near a player (3 radii), bit 3 only off screen |
| 0x02 | u8 | 1 = waits until a trigger wakes it; 0 = spawns with the scene |
| 0x03 | u8 | ? (usually 2) |
| 0x04 | u8 | actor number (what it is) |
| 0x06 | s16 ×3 | x, y, z in game units (0x7FFF x = never) |
| 0x0C | u8 | facing, 0x100 a full turn (the actor's u16 angle >> 8) |
| 0x0D–0x10 | u8 | ? (per actor kind) |
| 0x18 | u32 | flags (per actor kind) |
| 0x20, 0x24 | f32 | ? (two equal values, 0.4–1.4: probably size) |
| 0x28 | u8 | id (0 = assigned at load) |

## What the runtime mod does (v0.3)

A **Game Actor** object in a level built on a game scene becomes one more record: the mod hooks
the return of `func_15017114`, copies the table (and the two path tables) into bigger ones from
the game's own allocator, and appends a record per Game Actor: a copy of one of the scene's own
records with the same actor number if there is one (so it keeps that kind's settings),
otherwise a plain template, with byte 2 set to 0, the position, facing and id filled in. The
game then loads that actor number's data and spawns it like any other.

Not known yet: what each actor number *is*. The table below says where each one is placed in
the game, which is how to find out: put one in a level, play, and name it. Numbers whose data
isn't loaded in a scene (they're only in other scenes) may need more than a record to work
(their models), which is the next thing to check.

## Actor numbers by scene

Generated from bank 0E (the number of records of each actor number, and the scenes that place
them). Fill in names as they're found.

| Actor | Placed | Scenes (count) | Name |
|---|---|---|---|
| 0 (0x00) | 7 | 29 ×4, 58, 60, 64 | |
| 5 (0x05) | 23 | 6, 12 ×3, 39 ×19 | |
| 6 (0x06) | 1 | 33 | |
| 7 (0x07) | 2 | 6, 39 | |
| 8 (0x08) | 18 | 3 ×2, 7 ×2, 15 ×10, 17 ×4 | |
| 9 (0x09) | 1 | 7 | |
| 10 (0x0A) | 12 | 3 ×3, 7 ×6, 65 ×3 | |
| 12 (0x0C) | 3 | 1, 16, 24 | |
| 13 (0x0D) | 8 | 1 ×8 | |
| 15 (0x0F) | 2 | 11, 24 | |
| 16 (0x10) | 12 | 2 ×5, 29, 49 ×6 | |
| 17 (0x11) | 4 | 24 ×3, 55 | |
| 18 (0x12) | 2 | 14 ×2 | |
| 19 (0x13) | 2 | 6, 39 | |
| 20 (0x14) | 2 | 24, 55 | |
| 21 (0x15) | 1 | 12 | |
| 22 (0x16) | 51 | 2 ×18, 20 ×15, 36 ×2, 42 ×8, 63, 67 ×7 | |
| 23 (0x17) | 1 | 11 | |
| 24 (0x18) | 4 | 12 ×4 | |
| 25 (0x19) | 1 | 34 | |
| 26 (0x1A) | 1 | 7 | |
| 27 (0x1B) | 4 | 45, 48, 52, 62 | |
| 28 (0x1C) | 1 | 7 | |
| 30 (0x1E) | 1 | 12 | |
| 31 (0x1F) | 2 | 7 ×2 | |
| 32 (0x20) | 18 | 12 ×16, 13, 24 | |
| 33 (0x21) | 2 | 0, 44 | |
| 34 (0x22) | 1 | 12 | |
| 35 (0x23) | 2 | 6, 39 | |
| 36 (0x24) | 2 | 6, 59 | |
| 37 (0x25) | 25 | 0 ×3, 6 ×2, 53 ×10, 55 ×9, 60 | |
| 38 (0x26) | 1 | 12 | |
| 39 (0x27) | 1 | 12 | |
| 40 (0x28) | 5 | 14, 22, 35, 48 ×2 | |
| 41 (0x29) | 14 | 6 ×3, 7 ×2, 10, 11 ×5, 12, 18 ×2 | |
| 43 (0x2B) | 1 | 10 | |
| 44 (0x2C) | 2 | 1, 24 | |
| 45 (0x2D) | 2 | 1, 24 | |
| 46 (0x2E) | 1 | 15 | |
| 49 (0x31) | 4 | 1, 2, 29, 67 | |
| 50 (0x32) | 1 | 2 | |
| 51 (0x33) | 9 | 2 ×8, 10 | |
| 52 (0x34) | 3 | 3, 19 ×2 | |
| 53 (0x35) | 1 | 37 | |
| 54 (0x36) | 2 | 2, 67 | |
| 55 (0x37) | 1 | 1 | |
| 56 (0x38) | 3 | 2, 49, 56 | |
| 57 (0x39) | 2 | 14 ×2 | |
| 58 (0x3A) | 8 | 10 ×7, 29 | |
| 59 (0x3B) | 8 | 26 ×4, 56 ×4 | |
| 60 (0x3C) | 49 | 1, 2 ×2, 6 ×6, 7 ×4, 11, 12 ×4, 14, 17, 18, 20, 25, 30, 41, 44, 49, 50, 53, 55 ×2, 59 ×3, 64 ×15 | |
| 62 (0x3E) | 5 | 6 ×5 | |
| 63 (0x3F) | 5 | 2, 66 ×4 | |
| 64 (0x40) | 7 | 6, 7, 18, 49, 50, 55, 64 | |
| 65 (0x41) | 1 | 12 | |
| 66 (0x42) | 6 | 30 ×6 | |
| 67 (0x43) | 1 | 64 | |
| 68 (0x44) | 18 | 6 ×11, 44, 53 ×6 | |
| 69 (0x45) | 1 | 1 | |
| 70 (0x46) | 1 | 11 | |
| 71 (0x47) | 23 | 19 ×8, 26, 27 ×6, 28 ×3, 35 ×2, 40 ×3 | |
| 72 (0x48) | 11 | 20, 29 ×2, 34, 50 ×5, 60 ×2 | |
| 73 (0x49) | 5 | 4 ×2, 19 ×2, 43 | |
| 74 (0x4A) | 4 | 19, 35 ×3 | |
| 75 (0x4B) | 2 | 16, 24 | |
| 76 (0x4C) | 1 | 11 | |
| 77 (0x4D) | 2 | 4, 28 | |
| 78 (0x4E) | 3 | 19 ×3 | |
| 79 (0x4F) | 3 | 16 ×2, 35 | |
| 80 (0x50) | 9 | 1 ×5, 11 ×3, 24 | |
| 81 (0x51) | 1 | 16 | |
| 82 (0x52) | 1 | 11 | |
| 83 (0x53) | 6 | 15 ×2, 20, 63 ×3 | |
| 84 (0x54) | 2 | 15, 20 | |
| 86 (0x56) | 1 | 33 | |
| 87 (0x57) | 1 | 26 | |
| 88 (0x58) | 32 | 4 ×9, 6, 19 ×3, 28 ×2, 29 ×10, 36 ×2, 47 ×2, 48 ×3 | |
| 89 (0x59) | 1 | 20 | |
| 90 (0x5A) | 129 | 4 ×19, 6 ×2, 14 ×13, 27 ×22, 28 ×20, 30 ×21, 38 ×16, 43 ×4, 45 ×5, 48 ×7 | |
| 91 (0x5B) | 7 | 4, 14, 19, 24, 28, 35, 59 | |
| 92 (0x5C) | 8 | 4 ×4, 28 ×4 | |
| 93 (0x5D) | 1 | 19 | |
| 94 (0x5E) | 2 | 24, 64 | |
| 95 (0x5F) | 4 | 14 ×3, 38 | |
| 96 (0x60) | 2 | 19 ×2 | |
| 97 (0x61) | 1 | 19 | |
| 98 (0x62) | 2 | 51 ×2 | |
| 99 (0x63) | 1 | 24 | |
| 100 (0x64) | 1 | 20 | |
| 101 (0x65) | 1 | 20 | |
| 102 (0x66) | 4 | 19 ×4 | |
| 103 (0x67) | 1 | 19 | |
| 105 (0x69) | 2 | 20 ×2 | |
| 106 (0x6A) | 1 | 20 | |
| 107 (0x6B) | 1 | 19 | |
| 108 (0x6C) | 1 | 12 | |
| 109 (0x6D) | 2 | 1, 12 | |
| 111 (0x6F) | 3 | 33 ×3 | |
| 112 (0x70) | 3 | 29, 34, 65 | |
| 113 (0x71) | 1 | 24 | |
| 114 (0x72) | 5 | 24, 29, 49 ×2, 56 | |
| 115 (0x73) | 4 | 4 ×4 | |
| 117 (0x75) | 5 | 36, 48 ×4 | |
| 118 (0x76) | 2 | 24, 64 | |
| 119 (0x77) | 1 | 36 | |
| 120 (0x78) | 1 | 6 | |
| 121 (0x79) | 3 | 0 ×3 | |
| 123 (0x7B) | 1 | 35 | |
| 124 (0x7C) | 2 | 35 ×2 | |
| 125 (0x7D) | 1 | 16 | |
| 126 (0x7E) | 11 | 14, 28, 35 ×4, 41, 45, 48, 52, 62 | |
| 127 (0x7F) | 5 | 6 ×2, 60, 61, 65 | |
| 128 (0x80) | 7 | 45 ×4, 48 ×3 | |
| 129 (0x81) | 1 | 35 | |
| 130 (0x82) | 1 | 64 | |
| 131 (0x83) | 1 | 35 | |
| 132 (0x84) | 1 | 35 | |
| 133 (0x85) | 1 | 10 | |
| 134 (0x86) | 4 | 26, 56, 57, 64 | |
| 135 (0x87) | 7 | 4, 6, 19, 36, 43, 45, 48 | |
| 136 (0x88) | 3 | 63 ×3 | |
| 137 (0x89) | 5 | 2, 56, 66, 67 ×2 | |
| 138 (0x8A) | 5 | 38, 43, 48 ×2, 52 | |
| 139 (0x8B) | 3 | 6, 29, 41 | |
| 140 (0x8C) | 4 | 46, 60 ×3 | |
| 141 (0x8D) | 15 | 38, 47 ×14 | |
| 142 (0x8E) | 2 | 41 ×2 | |
| 143 (0x8F) | 2 | 50 ×2 | |
| 144 (0x90) | 11 | 49 ×3, 50 ×8 | |
| 145 (0x91) | 8 | 49 ×8 | |
| 146 (0x92) | 1 | 53 | |
| 147 (0x93) | 8 | 53 ×8 | |
| 148 (0x94) | 7 | 16 ×7 | |
| 149 (0x95) | 6 | 53 ×6 | |
| 150 (0x96) | 1 | 57 | |
| 151 (0x97) | 4 | 54, 57, 58, 64 | |
| 152 (0x98) | 12 | 54 ×12 | |
| 153 (0x99) | 2 | 24, 64 | |
| 154 (0x9A) | 1 | 60 | |
| 155 (0x9B) | 7 | 60 ×7 | |
| 156 (0x9C) | 12 | 6, 43 ×2, 60 ×9 | |
| 157 (0x9D) | 11 | 43 ×3, 60 ×8 | |
| 158 (0x9E) | 7 | 23 ×7 | |
| 159 (0x9F) | 23 | 60 ×15, 65 ×8 | |
| 160 (0xA0) | 23 | 60 ×15, 65 ×8 | |
| 162 (0xA2) | 1 | 60 | |
| 163 (0xA3) | 1 | 60 | |
| 164 (0xA4) | 1 | 60 | |
| 165 (0xA5) | 6 | 25 ×4, 63 ×2 | |
| 166 (0xA6) | 8 | 60, 61 ×7 | |
| 167 (0xA7) | 1 | 24 | |
| 168 (0xA8) | 1 | 48 | |
| 169 (0xA9) | 1 | 48 | |
| 170 (0xAA) | 1 | 56 | |
| 171 (0xAB) | 3 | 63 ×3 | |
| 172 (0xAC) | 2 | 10 ×2 | |
| 173 (0xAD) | 2 | 6, 39 | |
| 174 (0xAE) | 2 | 6, 39 | |
| 175 (0xAF) | 2 | 6, 39 | |
| 179 (0xB3) | 1 | 24 | |
| 181 (0xB5) | 1 | 29 | |
| 182 (0xB6) | 1 | 0 | |
| 183 (0xB7) | 1 | 29 | |
| 184 (0xB8) | 1 | 29 | |
| 185 (0xB9) | 1 | 29 | |

## Decomp notes

`func_15016850` (load actor data), written from this study, compiles with the decomp's IDO 5.3
flags to the game's exact instructions except for the stack slot of `data` (0x58 instead of
0x50), an improvement on the repo's current candidate. Unmatched, so it isn't in the decomp yet:

```c
void func_15016850(void) {
    s32 data[2];
    s32 i;
    s32 j;
    s32 found;
    s32 id;

    D_800BE590 = 0;
    data[0] = 0;
    for (i = 0; i < D_800D2100; i++) {
        id = *(u8 *)((s32)D_800D20FC + i * 0x30 + 4);
        found = 0;
        for (j = 0; j < D_800BE590; j++) {
            if (id == D_800BE598[j]) {
                found = 1;
                break;
            }
        }
        if (found) {
            continue;
        }
        if (id < 0xBB) {
            func_1502B7F0(data, 2, 0x12, id);
        }
        if (data[0] != 0) {
            D_800BE5A8[D_800BE590] = data[0];
            D_800BE598[D_800BE590] = id;
            D_800BE590++;
        }
    }
}
```
