use image::RgbaImage;
use xcap::Monitor;

/// A captured screen frame in physical pixels.
pub struct Screenshot {
    pub width: u32,
    pub height: u32,
    pub rgba: RgbaImage,
}

impl Screenshot {
    /// Capture the primary monitor. Requires Screen Recording permission on macOS.
    pub fn capture_primary() -> Result<Self, Box<dyn std::error::Error>> {
        let mut monitors = Monitor::all()?;
        if monitors.is_empty() {
            return Err("no monitor found".into());
        }
        let idx = monitors
            .iter()
            .position(|m| m.is_primary().unwrap_or(false))
            .unwrap_or(0);
        let monitor = monitors.swap_remove(idx);

        let rgba = monitor.capture_image()?;
        let (width, height) = (rgba.width(), rgba.height());

        Ok(Self { width, height, rgba })
    }
}
