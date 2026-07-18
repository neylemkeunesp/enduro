# Memory optimization: fitting Night Highway in a 4K ROM

## Summary
`src/night_highway.asm` targets an unbanked 4 KB Atari 2600 cartridge
(`$F000`–`$FFFF`). The 6502 interrupt/reset vectors must occupy the last six
bytes (`$FFFA`–`$FFFF`), so usable program space is `$F000`–`$FFF9` (4090
bytes). The build had grown one byte too large, and the fix reclaimed wasted
alignment padding by relocating a small data table.

## Symptom
`dasm` failed to assemble:

```
segment: code fffa                    vs current org: fffb
 ROM usada: 4091 de 4096 bytes
 Livre: -1 bytes
src/night_highway.asm (2386): error: Origin Reverse-indexed.
```

`CODE_END` had reached `$FFFB`, one byte into the vector area. The subsequent
`ORG $FFFA` for the vector table therefore moved the origin *backwards*, which
DASM reports as `Origin Reverse-indexed`.

## Root cause
The cartridge image is laid out as:

- Program code from `$F000`.
- `ALIGN 256` → `SpriteData` at `$FC00` (sprites need a private page so they can
  be addressed with one-byte pointers).
- Kernel mask/helper tables immediately after, ending at `$FCB7`.
- `ALIGN 256` → `FontL0` at `$FD00` (the 4x5 font relies on page alignment:
  `FontL0..L3` share a page and `FontL4` starts the next one).
- All remaining data tables (font, logo, road/curve, colour, stage, audio and
  message tables) follow the font and run up to `CODE_END`.

Because every data table was placed *after* the page-aligned font block, their
combined size pushed `CODE_END` to `$FFFB`. Meanwhile the two `ALIGN 256`
directives left dead padding earlier in the image — in particular a ~73-byte
zero-filled gap between the kernel tables (`$FCB7`) and `FontL0` (`$FD00`).
Shrinking code before those `ALIGN` boundaries does not help: the freed bytes
are simply absorbed back into the alignment padding and `CODE_END` does not
move.

## Fix
Relocate the 18-byte **stage tables** (section 29: `StageGoal`, `StageTime`,
`StageCarBase`, `StageSpawn`, `StageCurveMax`, `StageCurveFreq`) out of the
trailing data region and into the dead padding gap that sits between the kernel
tables and the `FontL0` alignment (section 24).

- The tables now assemble at `$FCB7` onward (well below `$FD00`), so `FontL0`
  stays page-aligned and the font is byte-for-byte unchanged.
- Removing those 18 bytes from the tail drops `CODE_END` by 18 bytes, from
  `$FFFB` to `$FFE9`.

Result:

```
 ROM usada: 4073 de 4096 bytes
 Livre: 17 bytes
Complete. (0)
```

## Why this is safe
- The stage tables are **position-independent**: they are read only through
  absolute-indexed loads (`StageGoal,x`, `StageCurveFreq,x`, …), so their
  physical address does not matter.
- They are consumed by `InitStage`, `UpdateCurve` and `SpawnLogic`, all of which
  run during VBLANK/overscan — **never inside the cycle-counted visible
  kernel** — so kernel scanline timing is untouched.
- No page-aligned block (`SpriteData`, the kernel mask tables, the font) was
  moved or resized; the existing `CHECK_PAGE` guards still pass.

## Rejected alternative
`SetupTitleText` still contains two inline copies of the `textPtr` setup that
could call the existing `SetTextPtrA` helper (saving ~6 bytes of code). This was
**not** used to fix the overflow for two reasons:

1. That code lives before an `ALIGN 256`, so the savings would be absorbed by
   padding and would not lower `CODE_END`.
2. The identical inline setups inside the text kernels sit in a tight
   two-scanline (152-cycle) window before `DrawTextLine6`'s first `WSYNC`;
   converting them to `jsr`/`rts` risks breaking kernel timing.

## Build and verify
```sh
dasm src/night_highway.asm -f3 -onight_highway.bin -lnight_highway.lst -Iinclude/
stella night_highway.bin
```

Confirm the assembler prints `Livre: 17 bytes` / `Complete. (0)` and that the
output binary is exactly 4096 bytes with reset vectors pointing at `$F000`.
