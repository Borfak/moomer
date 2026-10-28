# Moomer

A screen zoomer for macOS. Your code is too small.

Moomer makes it bigger. Code quality remains your problem.

Useful for presentations, screencasts, and explaining a bug to six people who
have all decided to sit as far from the screen as possible.

Inspired by [Boomer](https://github.com/tsoding/boomer).

## It used to be Rust

The first version was written in **Rust**. **v2 is a complete rewrite in Swift**.

AppKit handles windows and input. Metal handles rendering. ScreenCaptureKit
handles capture. Apple appears to have named the things after what they do.
Dangerous precedent.

The entire program was rewritten to make a rectangle larger.

The Rust version is still in Git history. Deleting code and actually getting
rid of it are apparently separate features.

![Original Rust version — frozen-screen demo](demo.gif)

*Rust-era footage. The documentation has not yet caught up with the rectangle.*

## What's new in v2

- **Live capture.** Videos and animations keep moving while you zoom.
  Time has been implemented.
- **Freeze / unfreeze.** Press Space. Keep your zoom and position.
- **Multiple monitors.** Starts under the cursor and follows it between screens.
  Tab tells it to stay put.
- **Native refresh-rate target.** Or set an FPS cap yourself.
- **Pinch, zoom, pan, inertia.** Even the camera has trouble letting go.

Flashlight, mirroring, and copying the current view survived the rewrite.

## Build and run

Requires **macOS 14+** and a **Swift 6 toolchain** (Xcode 16+).

```sh
git clone https://github.com/Borfak/moomer.git
cd moomer
./scripts/build-app.sh
open dist/Moomer.app
```

To start in live mode:

```sh
open dist/Moomer.app --args --live
```

Copy `dist/Moomer.app` to `/Applications` if you want to launch it from Finder,
Spotlight, or a hotkey. The build script signs the app locally; rebuilding can
require granting Screen Recording permission again.

Allow Moomer in **System Settings → Privacy & Security → Screen Recording**
(or **Screen & System Audio Recording**), then relaunch. Moomer captures no audio.
Monitor selection itself needs no Accessibility or Input Monitoring permission.

Or run it from the terminal:

```sh
swift run -c release moomer
swift run -c release moomer --live --fps auto
```

**Homebrew:** the tap currently ships the Rust version, `v0.1.0`. It needs an
update for v2. Until then, use the build instructions above. A package manager
cannot install code that has only been released emotionally.

## What happens when you run it

An overlay opens on the physical monitor under your cursor. Move to another
monitor and it follows. Press **Tab** to pin it to the current monitor.

The default is a frozen screenshot. `--live` starts with a moving desktop.
**Space** switches between the two. Input goes to Moomer while the overlay is
open; close it to interact with the applications underneath.

**Esc** or **q** stops capture and exits the process.
We have successfully implemented leaving.

Your hotkey launcher stays around to launch it again.

## Controls

| Control | Action |
| --- | --- |
| Scroll / `+` / `-` | Zoom toward the cursor |
| Trackpad pinch | Zoom |
| Left-drag | Pan; release to coast |
| Arrows / `h` `j` `k` `l` | Pan |
| **Space** | Toggle live / freeze |
| **Tab** | Toggle following the monitor under the cursor |
| `f` | Toggle flashlight. For the line everyone is pretending to read. |
| Ctrl + Scroll | Resize flashlight |
| `m` | Mirror. The bug is on the other side now. |
| `c` | Copy the current view, including effects |
| `0` | Reset zoom and position |
| Esc / `q` | Quit |

## Cmd + Shift + Z

With [skhd](https://github.com/koekeishiya/skhd) installed, add this to
`~/.config/skhd/skhdrc` after copying the app to `/Applications`:

```sh
cmd + shift - z : /usr/bin/open -a /Applications/Moomer.app --args --live --fps auto
```

Start skhd with `skhd --start-service`, or reload its configuration if it is
already running. Allow skhd Accessibility access when prompted.
Remove `--live` if you prefer to start with a frozen frame.

## Options

```sh
moomer --live                  # Start live
moomer --fps auto              # Target the monitor's refresh rate (default)
moomer --fps 60                # Cap at 60 FPS
moomer --no-follow-cursor      # Stay on the initial monitor
moomer --list-displays         # List monitor IDs and refresh rates
moomer --display ID            # Use one monitor and disable following
moomer --help
```

`auto` targets the monitor's refresh rate. Actual FPS depends on capture load,
rendering load, and macOS scheduling. Writing “144 FPS” here would be much easier
than getting all three to agree.

Quit the running overlay before launching with different arguments.

## Development

Build, tests, rendering details, and packaging:
[DEVELOPMENT.md](DEVELOPMENT.md).

Generated apps and build output stay out of Git. Put application archives in
release assets. `target/` is still ignored. Some of us have moved on.

## License

MIT. The license is more permissive than macOS.
