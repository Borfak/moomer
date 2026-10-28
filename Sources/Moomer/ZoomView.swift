import AppKit
import MetalKit
import QuartzCore
import MoomerCore

enum ViewAction {
    case quit, copy, toggleLive, toggleFollow
}

@MainActor
final class ZoomView: NSView {
    var camera = Camera()
    var cursor = SIMD2<Float>.zero
    var dragging = false
    var onChange: (() -> Void)?
    var onAction: ((ViewAction) -> Void)?
    private var lastDragTime: TimeInterval = 0
    private var tracking: NSTrackingArea?
    private var placeholder: NSImageView?
    private(set) var placeholderGeneration = 0
    private var pixelSize = CGSize(width: 1, height: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        updateDrawableSize()
    }

    required init?(coder: NSCoder) { fatalError("ZoomView is created programmatically") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var drawableSize: CGSize {
        get { pixelSize }
        set { pixelSize = newValue; metalLayer.drawableSize = newValue }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if layer != nil { updateDrawableSize() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    func showPlaceholder(_ image: CGImage) {
        placeholderGeneration &+= 1
        hidePlaceholder()
        let preview = NSImageView(frame: bounds)
        preview.image = NSImage(cgImage: image, size: bounds.size)
        preview.imageScaling = .scaleAxesIndependently
        preview.autoresizingMask = [.width, .height]
        addSubview(preview)
        placeholder = preview
    }

    func hidePlaceholder(ifGeneration generation: Int? = nil) {
        if let generation, generation != placeholderGeneration { return }
        placeholder?.image = nil
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    var pointSize: SIMD2<Float> { SIMD2(max(1, Float(bounds.width)), max(1, Float(bounds.height))) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func updateCursorFromScreen() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        cursor = SIMD2(Float(point.x), Float(point.y))
    }

    private func updateCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = SIMD2(Float(point.x), Float(point.y))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
        if camera.flashlight || camera.zoomVelocity != 0 { onChange?() }
    }

    override func mouseDown(with event: NSEvent) {
        updateCursor(event)
        dragging = true
        camera.velocity = .zero
        lastDragTime = event.timestamp
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { updateCursor(event); return }
        let previous = cursor
        updateCursor(event)
        camera.drag(cursor - previous, size: pointSize, dt: Float(event.timestamp - lastDragTime))
        lastDragTime = event.timestamp
        onChange?()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        // A pause before release shouldn't fling an old velocity.
        if event.timestamp - lastDragTime > 0.08 { camera.velocity = .zero }
        onChange?()
    }

    func cancelDrag() {
        dragging = false
        camera.velocity = .zero
    }

    override func scrollWheel(with event: NSEvent) {
        updateCursor(event)
        let delta = Float(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 50 : 1)
        if event.modifierFlags.contains(.control) { camera.adjustRadius(delta) }
        else { camera.zoom(delta) }
        onChange?()
    }

    override func magnify(with event: NSEvent) {
        updateCursor(event)
        camera.zoom(Float(event.magnification) * 12)
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onAction?(.quit); return
        case 49: if !event.isARepeat { onAction?(.toggleLive) }; return
        case 48: if !event.isARepeat { onAction?(.toggleFollow) }; return
        case 123: camera.pan(SIMD2(-140, 0), size: pointSize)
        case 124: camera.pan(SIMD2(140, 0), size: pointSize)
        case 125: camera.pan(SIMD2(0, 140), size: pointSize)
        case 126: camera.pan(SIMD2(0, -140), size: pointSize)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": onAction?(.quit); return
            case "c": onAction?(.copy); return
            case "f": camera.flashlight.toggle()
            case "m": camera.mirror.toggle()
            case "0": camera.reset()
            case "=", "+": camera.zoom(3)
            case "-", "_": camera.zoom(-3)
            case "h": camera.pan(SIMD2(-140, 0), size: pointSize)
            case "l": camera.pan(SIMD2(140, 0), size: pointSize)
            case "j": camera.pan(SIMD2(0, 140), size: pointSize)
            case "k": camera.pan(SIMD2(0, -140), size: pointSize)
            default: return
            }
        }
        onChange?()
    }
}

@MainActor
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        title = "moomer"
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        animationBehavior = .none
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
    }
}
