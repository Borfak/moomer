//! macOS overlay window setup: always-on-top, covering the menu bar and Dock,
//! on the current Space.

#[cfg(target_os = "macos")]
mod imp {
    use objc2_app_kit::{NSView, NSWindowAnimationBehavior, NSWindowCollectionBehavior};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use winit::window::Window;

    /// NSScreenSaverWindowLevel: above the menu bar and Dock.
    const SCREEN_SAVER_WINDOW_LEVEL: isize = 1000;

    pub fn configure_overlay(window: &Window) {
        let Some(ns_window) = ns_window(window) else { return };
        unsafe {
            ns_window.setLevel(SCREEN_SAVER_WINDOW_LEVEL);
            ns_window.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::FullScreenAuxiliary,
            );
            // Appear instantly instead of fading in.
            ns_window.setAnimationBehavior(NSWindowAnimationBehavior::None);
        }
    }

    fn ns_window(window: &Window) -> Option<objc2::rc::Retained<objc2_app_kit::NSWindow>> {
        let handle = window.window_handle().ok()?.as_raw();
        let RawWindowHandle::AppKit(h) = handle else { return None };
        let view = h.ns_view.as_ptr() as *const NSView;
        unsafe { (*view).window() }
    }
}

#[cfg(target_os = "macos")]
pub use imp::configure_overlay;

#[cfg(not(target_os = "macos"))]
pub fn configure_overlay(_window: &winit::window::Window) {}
