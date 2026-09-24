import AppKit
import Testing

@MainActor @Suite(.serialized) struct FrameViewInputTests {
    private struct Touch: Equatable {
        let x: Int, y: Int, identifier: Int, pressure: Int
    }

    private struct Scroll {
        let x: Int, y: Int, vertical: Double, horizontal: Double
    }

    private final class Recorder {
        var touches: [Touch] = []
        var scrolls: [Scroll] = []
        var focusChanges = 0
    }

    private func view(width: Double = 400, height: Double = 800, dpi: Int = 320) -> (FrameView, Recorder) {
        let view = FrameView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.displayWidth = 800
        view.displayHeight = 1600
        view.displayDpi = dpi
        let r = Recorder()
        view.onTouch = { r.touches.append(Touch(x: $0, y: $1, identifier: $2, pressure: $3)) }
        view.onScroll = { r.scrolls.append(Scroll(x: $0, y: $1, vertical: $2.vertical, horizontal: $2.horizontal)) }
        view.onFirstTouch = { r.focusChanges += 1 }
        return (view, r)
    }

    private func scroll(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                        momentum: CGMomentumScrollPhase = .none, precise: Bool = true) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                     wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        // CGEvent uses screen coordinates with a top-left origin; a windowless
        // NSEvent exposes the same location with a bottom-left origin.
        cg.location = CGPoint(x: 200, y: (NSScreen.screens.first?.frame.height ?? 0) - 400)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func scrollNeverTouchesOrMovesFocus() throws {
        let (view, r) = view()
        view.scrollWheel(with: try scroll(phase: .mayBegin))
        view.scrollWheel(with: try scroll(dy: -30, phase: .began))
        view.scrollWheel(with: try scroll(dy: -2, phase: .changed))
        view.scrollWheel(with: try scroll(phase: .ended))
        view.scrollWheel(with: try scroll(dy: -1, momentum: .begin))
        view.scrollWheel(with: try scroll(momentum: .end))
        view.scrollWheel(with: try scroll(dy: -1, precise: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(r.touches.isEmpty)
        #expect(r.focusChanges == 0)
        #expect(r.scrolls.count == 4)
    }

    @Test func zeroDeltaSendsNothing() throws {
        let (view, r) = view()
        view.scrollWheel(with: try scroll(phase: .began))
        view.scrollWheel(with: try scroll(momentum: .end))
        #expect(r.scrolls.isEmpty)
    }

    @Test func trackpadFollowsFingersInDisplayPixels() throws {
        // 400 pt view showing 800 px: 30 pt of finger travel is 60 px.
        let (view, r) = view()
        view.scrollWheel(with: try scroll(dy: -30, phase: .began))
        let s = try #require(r.scrolls.first)
        #expect(Int(Float(s.vertical) * 128) == -60)
        #expect(s.horizontal == 0)
        #expect(s.x == 400 && s.y == 800)
    }

    @Test func horizontalTrackpadScroll() throws {
        let (view, r) = view()
        view.scrollWheel(with: try scroll(dx: 10, phase: .began))
        let s = try #require(r.scrolls.first)
        #expect(Int(Float(s.horizontal) * 128) == -20)
        #expect(s.vertical == 0)
    }

    /// One notch must scroll Android's own 64 dp at any window scale and
    /// density; the touch-drag version sent nothing here.
    @Test(arguments: [(400.0, 800.0, 320), (800.0, 1600.0, 320), (800.0, 1600.0, 480), (200.0, 400.0, 160)])
    func wheelNotchIsOneAndroidNotch(size: (Double, Double, Int)) throws {
        let (view, r) = view(width: size.0, height: size.1, dpi: size.2)
        view.scrollWheel(with: try scroll(dy: -1, precise: false))
        let s = try #require(r.scrolls.first)
        #expect(abs(s.vertical + 1) < 0.001)
    }

    @Test func mouseClickStillClicks() throws {
        let (view, r) = view()
        view.scrollWheel(with: try scroll(dy: -1))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 400),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow,
            modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        #expect(r.touches.map(\.pressure) == [1000, 0])
        #expect(r.touches.allSatisfy { $0.identifier == 0 })
    }
}
