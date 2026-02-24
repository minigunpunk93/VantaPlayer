# Manual Test Checklist

## Fixed Window Sizing (Normal Mode)
- [ ] Launch the app and confirm the initial window appears at the new normal size target.
- [ ] Try resizing from all window edges/corners and verify the normal window does not resize.
- [ ] Move the window and confirm interactions remain macOS-native.

## Compact Mode Width Match
- [ ] Toggle compact mode (`Control` + `Command` + `C`).
- [ ] Compact toggle feels instant (no visible delay before resize).
- [ ] Verify compact mode keeps the exact same window width as normal mode.
- [ ] Verify only window height changes when entering compact mode.
- [ ] Toggle back to normal mode and verify top edge remains visually stable (no jittering/multi-step resize).
- [ ] In compact mode, verify there is no duplicate expand/compact button near the volume slider.
- [ ] Verify compact toolbar icon reflects action:
- [ ] Compact ON shows expand-outward icon.
- [ ] Compact OFF shows shrink-inward icon.

## Stealth Stoplights and Chrome Insets
- [ ] In normal mode, confirm the close stoplight button is visible.
- [ ] Confirm minimize and zoom stoplight buttons are hidden.
- [ ] Confirm title remains hidden with transparent title bar and no separator line.
- [ ] Verify content starts near the top-left with minimal leading inset (no large empty stoplight gutter).

## Keyboard/Menu Window Actions
- [ ] Use `Command` + `W` and verify the key window closes.
- [ ] Use `Command` + `M` and verify the key window minimizes.
- [ ] Use `Control` + `Command` + `F` and verify full screen toggles on/off.
- [ ] Confirm the above actions are available from the menu bar window command group.

## Accessibility / Reduced Motion
- [ ] Enable Reduce Motion in macOS Accessibility settings.
- [ ] Toggle compact mode and verify resize transitions occur without animation.

## Micro-polish
- [ ] Verify card visuals are consistent across header, playlist, inspector, queue picker, and transport strip.
- [ ] Verify no clipping in both normal and compact windows at the current fixed sizes.
- [ ] Verify time digits remain visually stable while values change.

## Normal Preset Shrink (A1-S)
- [ ] In normal mode, hide playlist and verify window height shrinks to remove large empty space.
- [ ] In normal mode, hide inspector and verify window height shrinks to remove large empty space.
- [ ] In normal mode, hide both playlist and inspector and verify app auto-switches to compact mode.
