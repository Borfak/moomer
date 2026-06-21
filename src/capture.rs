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
        let monitors = Monitor::all()?;
        let monitor = monitors
            .into_iter()
            .find(|m| m.is_primary().unwrap_or(false))
            .or_else(|| Monitor::all().ok().and_then(|mut v| v.drain(..).next()))
            .ok_or("no monitor found")?;

        let rgba = monitor.capture_image()?;
        let (width, height) = (rgba.width(), rgba.height());

        Ok(Self { width, height, rgba })
    }
}
