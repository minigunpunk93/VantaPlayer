# Manual Test Checklist

## Fixed Window Sizing (Normal Mode)
- [ ] Launch the app and confirm the initial window appears at the new normal size target.
- [ ] Try resizing from all window edges/corners and verify the normal window does not resize.
- [ ] Move the window and confirm interactions remain macOS-native.

## Compact Mode Width Match
- [ ] Toggle compact mode (`Control` + `Command` + `C`).
- [ ] Verify compact mode keeps the exact same window width as normal mode.
- [ ] Verify only window height changes when entering compact mode.
- [ ] Toggle back to normal mode and verify top edge remains visually stable (no jittering/multi-step resize).

## Stealth Stoplights and Chrome Insets
- [ ] In normal mode, confirm close/minimize/zoom stoplight buttons are hidden.
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
