import Foundation

/// Turns mouse-wheel and trackpad deltas into Android mouse-wheel axis
/// values. Scroll containers move `axis × scrollFactor` pixels per
/// ACTION_SCROLL, and RecyclerView truncates that to whole pixels, so only
/// whole pixels are sent and the remainder carries to the next event.
public struct ScrollConverter: Sendable {
    public struct Axes: Sendable, Equatable {
        /// Positive moves content down (AXIS_VSCROLL).
        public var vertical: Double
        /// Positive moves content left (AXIS_HSCROLL).
        public var horizontal: Double
    }

    /// Stock `config_verticalScrollFactor` and `config_horizontalScrollFactor`.
    public static let scrollFactorDp = 64.0
    /// Display pixels per wheel unit, as ViewConfiguration rounds it.
    public let factor: Double
    private var pendingX = 0.0, pendingY = 0.0

    public init(dpi: Int) {
        factor = max((Self.scrollFactorDp * Double(dpi) / 160).rounded(), 1)
    }

    /// `dx/dy` are display pixels for precise (trackpad) input, otherwise
    /// wheel lines. AppKit signs: +dy moves content down, +dx moves it right.
    public mutating func convert(dx: Double, dy: Double, precise: Bool) -> Axes? {
        let scale = precise ? 1 : factor
        pendingX += dx * scale
        pendingY += dy * scale
        let px = pendingX.rounded(.towardZero), py = pendingY.rounded(.towardZero)
        guard px != 0 || py != 0 else { return nil }
        pendingX -= px
        pendingY -= py
        return Axes(vertical: axis(py), horizontal: -axis(px))
    }

    /// A 0.01 px bias keeps float error from truncating a pixel away.
    private func axis(_ pixels: Double) -> Double {
        pixels == 0 ? 0 : (pixels + (pixels > 0 ? 0.01 : -0.01)) / factor
    }
}
