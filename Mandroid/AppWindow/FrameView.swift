import AppKit
import MandroidKit

/// Displays frames on a layer and forwards pointer, scroll and key input.
final class FrameView: NSView {
    var displayWidth = 1
    var displayHeight = 1
    var displayDpi = 320 { didSet { scrollConverter = ScrollConverter(dpi: displayDpi) } }
    var onTouch: ((_ x: Int, _ y: Int, _ identifier: Int, _ pressure: Int) -> Void)?
    var onScroll: ((_ x: Int, _ y: Int, _ axes: ScrollConverter.Axes) -> Void)?
    var onKey: ((KeyAction) -> Void)?
    var onFirstTouch: (() -> Void)?

    private var scrollConverter = ScrollConverter(dpi: 320)
    private var lastFrameSequence: UInt32 = 0
    private(set) var hasFrame = false
    private(set) var renderedPixelSize = NSSize.zero
    private var mouseIsDown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: Frames

    static func cgImage(_ frame: Frame) -> CGImage? {
        guard frame.isComplete, frame.width > 0, frame.height > 0,
              let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    static func pngData(_ frame: Frame) -> Data? {
        guard let cg = cgImage(frame) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func display(_ frame: Frame) {
        guard let image = Self.cgImage(frame) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        renderedPixelSize = NSSize(width: frame.width, height: frame.height)
        hasFrame = true
        lastFrameSequence = frame.sequence
    }

    // MARK: Pointer

    private var mapper: CoordinateMapper {
        CoordinateMapper(viewWidth: bounds.width, viewHeight: bounds.height,
                         displayWidth: displayWidth, displayHeight: displayHeight)
    }

    private func point(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        return mapper.toDisplay(x: p.x, y: p.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseIsDown = true
        onFirstTouch?()
        let (x, y) = point(event)
        onTouch?(x, y, 0, 1000)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        let (x, y) = point(event)
        onTouch?(x, y, 0, 1000)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        let (x, y) = point(event)
        onTouch?(x, y, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right click = Back, a common desktop-Android convention.
        onKey?(.key("GoBack"))
    }

    // MARK: Scroll → Android mouse wheel

    override func scrollWheel(with event: NSEvent) {
        var dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        guard dx != 0 || dy != 0 else { return }
        let m = mapper
        let precise = event.hasPreciseScrollingDeltas
        // Trackpad deltas are view points; content should follow the fingers.
        if precise { (dx, dy) = m.deltaToDisplay(dx: dx, dy: dy) }
        guard let axes = scrollConverter.convert(dx: dx, dy: dy, precise: precise) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let (x, y) = m.toDisplay(x: p.x, y: p.y)
        onScroll?(x, y, axes)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let action = KeyMap.action(for: keyInput(event))
        if case .ignore = action { super.keyDown(with: event); return }
        onKey?(action)
    }

    override func keyUp(with event: NSEvent) {}

    /// ⌘ shortcuts that should reach Android instead of the menu bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        let action = KeyMap.action(for: keyInput(event))
        switch action {
        case .chord, .key:
            onKey?(action)
            return true
        default:
            return false
        }
    }

    private func keyInput(_ e: NSEvent) -> KeyInput {
        let f = e.modifierFlags
        return KeyInput(keyCode: e.keyCode, characters: e.characters ?? "",
                        charactersIgnoringModifiers: e.charactersIgnoringModifiers ?? "",
                        command: f.contains(.command), control: f.contains(.control),
                        option: f.contains(.option), shift: f.contains(.shift), isRepeat: e.isARepeat)
    }
}
