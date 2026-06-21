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

const MIN_SCALE: f32 = 1.0;
const MAX_SCALE: f32 = 20.0;
const ZOOM_SENSITIVITY: f32 = 0.1;
const SMOOTH_SPEED: f32 = 16.0;
const SHADOW: f32 = 0.85;

/// 2D camera and flashlight state, smoothly interpolated toward target values.
struct View {
    scale: f32,
    center: [f32; 2],
    t_scale: f32,
    t_center: [f32; 2],
    radius: f32,
    t_radius: f32,
    flashlight: bool,
}

impl View {
    fn new() -> Self {
        Self {
            scale: 1.0,
            center: [0.5, 0.5],
            t_scale: 1.0,
            t_center: [0.5, 0.5],
            radius: 220.0,
            t_radius: 220.0,
            flashlight: false,
        }
    }

    fn clamp_axis(c: f32, scale: f32) -> f32 {
        let m = 0.5 / scale;
        if m >= 0.5 {
            0.5
        } else {
            c.clamp(m, 1.0 - m)
        }
    }

    fn clamp_center(&mut self) {
        self.t_center[0] = Self::clamp_axis(self.t_center[0], self.t_scale);
        self.t_center[1] = Self::clamp_axis(self.t_center[1], self.t_scale);
    }

    fn on_scroll(&mut self, dy: f32, cursor: [f32; 2], res: [f32; 2]) {
        let factor = (dy * ZOOM_SENSITIVITY).exp();
        if self.flashlight {
            self.t_radius = (self.t_radius * factor).clamp(40.0, 4000.0);
            return;
        }
        // Keep the image point under the cursor fixed across the zoom.
        let cur_n = [cursor[0] / res[0], cursor[1] / res[1]];
        let anchor = [
            self.t_center[0] + (cur_n[0] - 0.5) / self.t_scale,
            self.t_center[1] + (cur_n[1] - 0.5) / self.t_scale,
        ];
        let new_scale = (self.t_scale * factor).clamp(MIN_SCALE, MAX_SCALE);
        self.t_center = [
            anchor[0] - (cur_n[0] - 0.5) / new_scale,
            anchor[1] - (cur_n[1] - 0.5) / new_scale,
        ];
        self.t_scale = new_scale;
        self.clamp_center();
    }

    fn on_drag(&mut self, delta: [f32; 2], res: [f32; 2]) {
        self.t_center[0] -= delta[0] / (res[0] * self.t_scale);
        self.t_center[1] -= delta[1] / (res[1] * self.t_scale);
        self.clamp_center();
    }

    fn reset(&mut self) {
        self.t_scale = 1.0;
        self.t_center = [0.5, 0.5];
    }

    fn animate(&mut self, dt: f32) {
        let k = 1.0 - (-dt * SMOOTH_SPEED).exp();
        self.scale += (self.t_scale - self.scale) * k;
        self.center[0] += (self.t_center[0] - self.center[0]) * k;
        self.center[1] += (self.t_center[1] - self.center[1]) * k;
        self.radius += (self.t_radius - self.radius) * k;
    }

    /// True once the current values have reached their targets, snapping them so
    /// the redraw loop can stop and the app can idle until the next input.
    fn settled(&mut self) -> bool {
        let done = (self.scale - self.t_scale).abs() < 1e-4
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
    last_frame: Option<Instant>,
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
            last_frame: None,
            revealed: false,
        }
    }

    fn request_redraw(&self) {
        if let Some(w) = &self.window {
            w.request_redraw();
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
                    Key::Character(ref s) if s == "0" => {
                        self.view.reset();
                        self.request_redraw();
                    }
                    _ => {}
                }
            }

            WindowEvent::MouseInput { state, button: MouseButton::Left, .. } => {
                self.dragging = state == ElementState::Pressed;
            }

            WindowEvent::CursorMoved { position, .. } => {
                let new = [position.x as f32, position.y as f32];
                if self.dragging {
                    let delta = [new[0] - self.cursor[0], new[1] - self.cursor[1]];
                    self.view.on_drag(delta, res);
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
                self.view.on_scroll(dy, self.cursor, res);
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
                self.view.animate(dt);

                if let Some(r) = &mut self.renderer {
                    r.update(&Frame {
                        cursor: self.cursor,
                        center: self.view.center,
                        scale: self.view.scale,
                        radius: self.view.radius,
                        flashlight: self.view.flashlight,
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
