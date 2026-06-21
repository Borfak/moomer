mod capture;
mod platform;
mod renderer;

use std::sync::Arc;
use std::time::Instant;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Window, WindowId};

use capture::Screenshot;
use renderer::{Frame, Renderer};

const MIN_SCALE: f32 = 0.2;
const MAX_SCALE: f32 = 20.0;
const ZOOM_SENSITIVITY: f32 = 0.08;
const KEY_ZOOM_STEP: f32 = 3.0; // scroll-units per =/- keypress
const SMOOTH_SPEED: f32 = 10.0;
const SHADOW: f32 = 0.85;
const PAN_STEP: f32 = 140.0; // px per arrow/hjkl keypress
const DRAG_FRICTION: f32 = 6.0; // higher = pan coast stops sooner
const SCALE_FRICTION: f32 = 8.0; // higher = zoom coast stops sooner

/// 2D camera and flashlight state, smoothly interpolated toward target values.
struct View {
    scale: f32,
    center: [f32; 2],
    t_scale: f32,
    t_center: [f32; 2],
    vel: [f32; 2], // center velocity (UV/sec) for pan inertia
    vel_scale: f32, // log-space zoom velocity for zoom inertia
    radius: f32,
    t_radius: f32,
    flashlight: bool,
    mirror: bool,
}

impl View {
    fn new() -> Self {
        Self {
            scale: 1.0,
            center: [0.5, 0.5],
            t_scale: 1.0,
            t_center: [0.5, 0.5],
            vel: [0.0, 0.0],
            vel_scale: 0.0,
            radius: 220.0,
            t_radius: 220.0,
            flashlight: false,
            mirror: false,
        }
    }

    /// Kick the zoom velocity; the actual scaling is integrated in `animate`,
    /// anchored on the live cursor, so it coasts to a stop (zoom inertia).
    fn zoom(&mut self, dy: f32) {
        self.vel_scale += dy * ZOOM_SENSITIVITY * SCALE_FRICTION;
    }

    /// Grow/shrink the flashlight spotlight (Ctrl+scroll).
    fn adjust_radius(&mut self, dy: f32) {
        let factor = (dy * ZOOM_SENSITIVITY).exp();
        self.t_radius = (self.t_radius * factor).clamp(40.0, 4000.0);
    }

    /// Drag the image. `dt` is the time since the last cursor event, used to
    /// estimate the fling velocity that coasts after release.
    fn on_drag(&mut self, delta: [f32; 2], res: [f32; 2], dt: f32) {
        // Mirroring flips screen X, so drag X must flip too to keep "grab" feel.
        let dx = if self.mirror { -delta[0] } else { delta[0] };
        let mv = [
            dx / (res[0] * self.t_scale),
            delta[1] / (res[1] * self.t_scale),
        ];
        self.t_center[0] -= mv[0];
        self.t_center[1] -= mv[1];
        self.vel = [-mv[0] / dt, -mv[1] / dt];
    }

    /// Nudge the view by a pixel step (keyboard panning), no inertia.
    fn pan(&mut self, dx_px: f32, dy_px: f32, res: [f32; 2]) {
        let dx = if self.mirror { -dx_px } else { dx_px };
        self.t_center[0] += dx / (res[0] * self.t_scale);
        self.t_center[1] += dy_px / (res[1] * self.t_scale);
    }

    fn reset(&mut self) {
        self.t_scale = 1.0;
        self.t_center = [0.5, 0.5];
        self.vel = [0.0, 0.0];
        self.vel_scale = 0.0;
    }

    fn animate(&mut self, dt: f32, cursor: [f32; 2], res: [f32; 2], dragging: bool) {
        // Zoom inertia: velocity scales the target (anchored on the cursor) then decays.
        if self.vel_scale != 0.0 {
            let factor = (self.vel_scale * dt).exp();
            let new_scale = (self.t_scale * factor).clamp(MIN_SCALE, MAX_SCALE);
            // Match the shader's X flip when mirrored, so it stays under the cursor.
            let cur_x = if self.mirror {
                1.0 - cursor[0] / res[0]
            } else {
                cursor[0] / res[0]
            };
            let cur_n = [cur_x, cursor[1] / res[1]];
            let anchor = [
                self.t_center[0] + (cur_n[0] - 0.5) / self.t_scale,
                self.t_center[1] + (cur_n[1] - 0.5) / self.t_scale,
            ];
            self.t_center = [
                anchor[0] - (cur_n[0] - 0.5) / new_scale,
                anchor[1] - (cur_n[1] - 0.5) / new_scale,
            ];
            let limited = new_scale <= MIN_SCALE || new_scale >= MAX_SCALE;
            self.t_scale = new_scale;
            self.vel_scale *= (-SCALE_FRICTION * dt).exp();
            if limited || self.vel_scale.abs() < 1e-4 {
                self.vel_scale = 0.0;
            }
        }

        // Pan inertia: once released, the velocity carries the target and decays.
        if !dragging && (self.vel[0] != 0.0 || self.vel[1] != 0.0) {
            self.t_center[0] += self.vel[0] * dt;
            self.t_center[1] += self.vel[1] * dt;
            let decay = (-DRAG_FRICTION * dt).exp();
            self.vel[0] *= decay;
            self.vel[1] *= decay;
            if self.vel[0].hypot(self.vel[1]) < 1e-4 {
                self.vel = [0.0, 0.0];
            }
        }

        let k = 1.0 - (-dt * SMOOTH_SPEED).exp();
        self.scale += (self.t_scale - self.scale) * k;
        self.center[0] += (self.t_center[0] - self.center[0]) * k;
        self.center[1] += (self.t_center[1] - self.center[1]) * k;
        self.radius += (self.t_radius - self.radius) * k;
    }

    /// True once everything has reached its target and inertia has died, so the
    /// redraw loop can stop and the app can idle until the next input.
    fn settled(&mut self) -> bool {
        let done = self.vel == [0.0, 0.0]
            && self.vel_scale == 0.0
            && (self.scale - self.t_scale).abs() < 1e-4
            && (self.center[0] - self.t_center[0]).abs() < 1e-5
            && (self.center[1] - self.t_center[1]).abs() < 1e-5
            && (self.radius - self.t_radius).abs() < 0.25;
        if done {
            self.scale = self.t_scale;
            self.center = self.t_center;
            self.radius = self.t_radius;
        }
        done
    }
}

struct App {
    shot: Option<Screenshot>,
    window: Option<Arc<Window>>,
    renderer: Option<Renderer>,
    view: View,
    cursor: [f32; 2],
    dragging: bool,
    ctrl: bool,
    last_frame: Option<Instant>,
    last_cursor: Option<Instant>,
    revealed: bool,
}

impl App {
    fn new(shot: Screenshot) -> Self {
        Self {
            shot: Some(shot),
            window: None,
            renderer: None,
            view: View::new(),
            cursor: [0.0, 0.0],
            dragging: false,
            ctrl: false,
            last_frame: None,
            last_cursor: None,
            revealed: false,
        }
    }

    fn request_redraw(&self) {
        if let Some(w) = &self.window {
            w.request_redraw();
        }
    }

    fn pan(&mut self, dx: f32, dy: f32, res: [f32; 2]) {
        self.view.pan(dx, dy, res);
        self.request_redraw();
    }

    /// Copy the currently displayed (zoomed/panned) frame to the clipboard.
    fn copy_to_clipboard(&self) {
        let Some(r) = &self.renderer else { return };
        let (width, height, rgba) = r.capture_frame();
        let result = arboard::Clipboard::new().and_then(|mut cb| {
            cb.set_image(arboard::ImageData {
                width: width as usize,
                height: height as usize,
                bytes: rgba.into(),
            })
        });
        if let Err(e) = result {
            eprintln!("clipboard copy failed: {e}");
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let monitor = event_loop
            .primary_monitor()
            .or_else(|| event_loop.available_monitors().next());

        // Cover the monitor without native fullscreen, to stay on the current Space.
        // Hidden until the first frame renders, to avoid a blank flash on launch.
        let mut attrs = Window::default_attributes()
            .with_title("moomer")
            .with_decorations(false)
            .with_resizable(false)
            .with_visible(false);
        if let Some(m) = &monitor {
            attrs = attrs.with_inner_size(m.size()).with_position(m.position());
        }

        let window = Arc::new(event_loop.create_window(attrs).expect("create window"));
        platform::configure_overlay(&window);

        let shot = self.shot.take().expect("screenshot available");
        let renderer = Renderer::new(window.clone(), &shot);

        self.cursor = renderer.size().map(|v| v * 0.5);
        self.window = Some(window);
        self.renderer = Some(renderer);
        self.last_frame = Some(Instant::now());
        self.request_redraw();
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let res = self.renderer.as_ref().map(|r| r.size()).unwrap_or([1.0, 1.0]);

        match event {
            WindowEvent::CloseRequested => event_loop.exit(),

            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                match event.logical_key {
                    Key::Named(NamedKey::Escape) => event_loop.exit(),
                    Key::Character(ref s) if s == "q" => event_loop.exit(),
                    Key::Character(ref s) if s == "f" => {
                        self.view.flashlight = !self.view.flashlight;
                        self.request_redraw();
                    }
                    Key::Character(ref s) if s == "m" => {
                        self.view.mirror = !self.view.mirror;
                        self.request_redraw();
                    }
                    Key::Character(ref s) if s == "0" => {
                        self.view.reset();
                        self.request_redraw();
                    }
                    Key::Character(ref s) if s == "=" || s == "+" => {
                        self.view.zoom(KEY_ZOOM_STEP);
                        self.request_redraw();
                    }
                    Key::Character(ref s) if s == "-" => {
                        self.view.zoom(-KEY_ZOOM_STEP);
                        self.request_redraw();
                    }
                    Key::Character(ref s) if s == "c" => {
                        self.copy_to_clipboard();
                    }
                    // Keyboard panning: arrows or vim-style hjkl.
                    Key::Named(NamedKey::ArrowRight) => self.pan(PAN_STEP, 0.0, res),
                    Key::Named(NamedKey::ArrowLeft) => self.pan(-PAN_STEP, 0.0, res),
                    Key::Named(NamedKey::ArrowDown) => self.pan(0.0, PAN_STEP, res),
                    Key::Named(NamedKey::ArrowUp) => self.pan(0.0, -PAN_STEP, res),
                    Key::Character(ref s) if s == "l" => self.pan(PAN_STEP, 0.0, res),
                    Key::Character(ref s) if s == "h" => self.pan(-PAN_STEP, 0.0, res),
                    Key::Character(ref s) if s == "j" => self.pan(0.0, PAN_STEP, res),
                    Key::Character(ref s) if s == "k" => self.pan(0.0, -PAN_STEP, res),
                    _ => {}
                }
            }

            WindowEvent::ModifiersChanged(mods) => {
                self.ctrl = mods.state().control_key();
            }

            WindowEvent::MouseInput { state, button: MouseButton::Left, .. } => {
                self.dragging = state == ElementState::Pressed;
                if self.dragging {
                    // Start a fresh drag: drop any leftover coast velocity.
                    self.view.vel = [0.0, 0.0];
                    self.last_cursor = None;
                } else {
                    // Released: let the fling velocity coast.
                    self.request_redraw();
                }
            }

            WindowEvent::CursorMoved { position, .. } => {
                let new = [position.x as f32, position.y as f32];
                if self.dragging {
                    let now = Instant::now();
                    let cdt = self
                        .last_cursor
                        .replace(now)
                        .map(|t| (now - t).as_secs_f32())
                        .unwrap_or(1.0 / 60.0)
                        .clamp(1e-4, 0.1);
                    let delta = [new[0] - self.cursor[0], new[1] - self.cursor[1]];
                    self.view.on_drag(delta, res, cdt);
                }
                self.cursor = new;
                // The cursor only changes the image while dragging or when the
                // flashlight spotlight is tracking it.
                if self.dragging || self.view.flashlight {
                    self.request_redraw();
                }
            }

            WindowEvent::MouseWheel { delta, .. } => {
                let dy = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y,
                    MouseScrollDelta::PixelDelta(p) => p.y as f32 / 50.0,
                };
                // Ctrl+scroll resizes the flashlight; plain scroll always zooms.
                if self.ctrl {
                    self.view.adjust_radius(dy);
                } else {
                    self.view.zoom(dy);
                }
                self.request_redraw();
            }

            WindowEvent::Resized(size) => {
                if let Some(r) = &mut self.renderer {
                    r.resize(size.width, size.height);
                }
                self.request_redraw();
            }

            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let dt = self
                    .last_frame
                    .replace(now)
                    .map(|t| (now - t).as_secs_f32())
                    .unwrap_or(1.0 / 60.0)
                    .min(0.1);
                self.view.animate(dt, self.cursor, res, self.dragging);

                if let Some(r) = &mut self.renderer {
                    r.update(&Frame {
                        cursor: self.cursor,
                        center: self.view.center,
                        scale: self.view.scale,
                        radius: self.view.radius,
                        flashlight: self.view.flashlight,
                        mirror: self.view.mirror,
                        shadow: SHADOW,
                    });
                    match r.render() {
                        Ok(()) => {
                            if !self.revealed {
                                if let Some(w) = &self.window {
                                    w.set_visible(true);
                                    w.focus_window();
                                }
                                self.revealed = true;
                            }
                        }
                        Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                            if let Some(w) = &self.window {
                                let s = w.inner_size();
                                r.resize(s.width, s.height);
                            }
                        }
                        Err(wgpu::SurfaceError::OutOfMemory) => event_loop.exit(),
                        Err(e) => eprintln!("render error: {e:?}"),
                    }
                }
            }

            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        // Keep redrawing only while still animating toward the target; once
        // settled, idle until the next input instead of spinning the GPU.
        if !self.view.settled() {
            self.request_redraw();
        }
    }
}

fn main() {
    let shot = match Screenshot::capture_primary() {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "Screen capture failed: {e}\n\
                 Grant Screen Recording: System Settings → Privacy & Security → Screen Recording,\n\
                 then restart your terminal and try again."
            );
            std::process::exit(1);
        }
    };

    let event_loop = EventLoop::new().expect("event loop");
    // Idle between events; the app drives its own redraws while animating.
    event_loop.set_control_flow(ControlFlow::Wait);

    let mut app = App::new(shot);
    event_loop.run_app(&mut app).expect("run app");
}
