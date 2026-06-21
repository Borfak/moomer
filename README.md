# Moomer

Screen zoomer for macOS, inspired by [Boomer](https://github.com/tsoding/boomer).

Freezes the screen in a fullscreen overlay and lets you zoom and pan around it -
handy for presentations, screencasts, and inspecting detail.

![demo](demo.gif)

## Install

```sh
brew tap Borfak/moomer
brew trust borfak/moomer
brew install moomer
```

Or build from source: `cargo build --release`.

## Usage

Run `moomer` to freeze the screen, then zoom/pan around it (see Controls); press
<kbd>Esc</kbd> to quit. Needs **Screen Recording** permission the first time:
*System Settings → Privacy & Security → Screen Recording*.

To launch it with a global hotkey, bind `moomer` to a shortcut with
[skhd](https://github.com/koekeishiya/skhd) (e.g. `cmd + shift - z : moomer`) or
an Automator Quick Action.

## Controls

| Control | Description |
| --- | --- |
| Scroll / <kbd>=</kbd> <kbd>-</kbd> | Zoom in/out toward the cursor |
| Left-drag | Pan (flick to coast) |
| Arrows / <kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd> | Pan |
| <kbd>f</kbd> | Toggle flashlight |
| <kbd>Ctrl</kbd> + Scroll | Resize flashlight |
| <kbd>m</kbd> | Mirror image |
| <kbd>c</kbd> | Copy current view to clipboard |
| <kbd>0</kbd> | Reset |
| <kbd>Esc</kbd> / <kbd>q</kbd> | Quit |

## Tuning

Constants at the top of `src/main.rs`: `MAX_SCALE`, `ZOOM_SENSITIVITY`,
`SMOOTH_SPEED`, `SHADOW`.

## License

MIT
