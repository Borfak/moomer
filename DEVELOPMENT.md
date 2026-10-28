# Development

```sh
swift build
swift test
```

These commands build/run development code. Capture integration tests are opt-in
and require Screen Recording permission for the process launching them.

## Layout

- `Sources/MoomerCore/`: camera, display geometry, frame-rate policy, and CLI parser.
- `Sources/Moomer/`: AppKit overlay, ScreenCaptureKit session, and Metal renderer.
- `Tests/`: unit tests, Metal tests, and opt-in capture/performance checks.
- `Tools/CaptureLoad/`: a separate animated window for capture benchmarks.
- `Tools/AuditHost/`: an AppKit event-loop host for onscreen performance tests.
- `Packaging/`: application metadata used when building the bundle.
- `scripts/`: application packaging.

The diagnostic tools are development executables. The packaging script builds
only `moomer`; neither diagnostic tool is included in `Moomer.app`.

## Rendering and capture

AppKit owns input and the camera. A per-screen CADisplayLink advances animation;
a dedicated serial render queue acquires Metal drawables and submits GPU work.
Only one pending camera snapshot is kept, with newer input replacing it while
the worker waits. The AppKit thread does not wait for drawable availability.

ScreenCaptureKit delivers frames through a bounded mailbox. CVPixelBuffers map
to Metal textures without a CPU pixel copy and remain retained until GPU work
using them completes. Freezing copies the current image into a private texture
before stopping capture. The overlay is excluded from capture.

Both modes pause the display link when animation settles and no new frame is
pending. Live capture wakes it when a frame arrives; camera input wakes it
independently. The cursor monitor check remains active at 20 Hz.

Zoom smoothing interpolates the image point under the cursor and logarithmic
scale together. Reversing the wheel cancels the previous zoom's coast.

The overlay does not enter a separate fullscreen Space. Space/display changes
refresh capture; no private API enumerates virtual desktops.

## Tests

Unit tests cover camera anchoring, mirroring, inertia, scale limits, monitor
layouts, frame-rate selection, and CLI validation. Metal tests cover orientation,
color channels, zoom/pan, mirror, and Retina flashlight scaling. They require a
Metal-capable Mac but do not request screen capture access.

With Screen Recording permission already allowed, capture integration tests
receive frames from connected displays, map them to Metal, and freeze them:

```sh
MOOMER_CAPTURE_TESTS=1 swift test --filter ScreenCaptureIntegrationTests
```

To also measure offscreen rendering during animated zoom:

```sh
MOOMER_CAPTURE_TESTS=1 MOOMER_BENCHMARK=1 swift test --filter ScreenCaptureIntegrationTests
```

These offscreen timings do not measure actual onscreen presentation FPS.
Onscreen audit tests and the animated load tool are opt-in development tools;
they can create substantial CPU/GPU load. Audit JSON output defaults to `/tmp`,
outside the repository.

Before a release, manually check monitors with different scaling factors,
monitor crossing while dragging, display removal, Spaces/fullscreen apps,
permission denial, live/freeze toggling during playback, and clipboard output.

## Packaging

```sh
./scripts/build-app.sh
./scripts/build-app.sh --arch arm64 --arch x86_64
```

Output: `dist/Moomer.app`. The bare SwiftPM executable needs its generated
`Moomer_Moomer.bundle` beside it; the script embeds the resource bundle in the app.

The default signature is ad-hoc. For distribution, set `CODE_SIGN_IDENTITY` to
your Developer ID and notarize separately. Changing a local ad-hoc signature can
require granting Screen Recording permission again.

Commit source, tests, tools, metadata, and documentation. Generated apps,
archives, profiling recordings, and build caches are excluded by `.gitignore`.
Distributable app archives belong in GitHub Release assets.
