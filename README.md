# Moomer

Screen zoomer for macOS, inspired by [Boomer](https://github.com/tsoding/boomer).

Freezes the screen in a fullscreen overlay and lets you zoom and pan around it -
handy for presentations, screencasts, and inspecting detail.

## Quick Start

```console
$ cargo run --release
```

Needs **Screen Recording** permission the first time: *System Settings → Privacy &
Security → Screen Recording* → enable your terminal → restart it → run again.

## Controls

| Control | Description |
| --- | --- |
| Scroll | Zoom in/out toward the cursor |
| Left-drag | Pan |
| <kbd>f</kbd> | Toggle flashlight (scroll resizes it) |
| <kbd>0</kbd> | Reset |
| <kbd>Esc</kbd> / <kbd>q</kbd> | Quit |

## Hotkey

Moomer is launch-and-go, like Boomer. To trigger it with a keypress, bind the
built binary (`target/release/moomer`) to a shortcut with
[skhd](https://github.com/koekeishiya/skhd) or an Automator Quick Action.

## Tuning

Constants at the top of `src/main.rs`: `MAX_SCALE`, `ZOOM_SENSITIVITY`,
`SMOOTH_SPEED`, `SHADOW`.

## License

MIT
