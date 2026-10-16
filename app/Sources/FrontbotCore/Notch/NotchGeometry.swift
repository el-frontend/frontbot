import Foundation
import CoreGraphics

/// Dimensiones del notch, midiendo el notch físico cuando la pantalla lo tiene.
/// Adaptado de coucou `IslandScreenGeometry` (MIT, © 2026 Louis Raillé).
public struct NotchGeometry: Equatable, Sendable {
    public static let fallbackNotchWidth: CGFloat = 184
    public static let expandedSize = CGSize(width: 520, height: 400)
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24
    private static let collapsedExtraWidth: CGFloat = 120

    public let hasNotch: Bool
    public let width: CGFloat
    public let height: CGFloat

    public init(screenWidth: CGFloat, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measured = screenWidth - left - right
                width = measured > 0 && measured < screenWidth ? measured : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }

    /// Marco del panel en coordenadas AppKit: centrado arriba de `screenFrame`.
    public func panelFrame(in screenFrame: CGRect, expanded: Bool) -> CGRect {
        let size = expanded
            ? CGSize(width: min(Self.expandedSize.width, screenFrame.width), height: min(Self.expandedSize.height, screenFrame.height))
            : CGSize(width: width + Self.collapsedExtraWidth, height: height)
        return CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}
