import Foundation

public struct TitleMenuLayout: Equatable, Sendable {
    public let primaryButtonOriginsY: [Double]
    public let secondaryButtonOriginY: Double
    public let heroProtectedBottomY: Double
    public let heroClearanceIsSatisfiable: Bool

    public static func resolve(viewportWidth: Double, viewportHeight: Double) -> TitleMenuLayout {
        guard viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0 else {
            return .init(primaryButtonOriginsY: [0, 0, 0], secondaryButtonOriginY: 0,
                         heroProtectedBottomY: 0, heroClearanceIsSatisfiable: false)
        }
        let imageWidth = 1_672.0, imageHeight = 941.0, protectedSourceY = 416.0
        let imageAspect = imageWidth / imageHeight
        let viewportAspect = viewportWidth / viewportHeight
        let visibleProtectedBottom: Double
        if imageAspect > viewportAspect {
            visibleProtectedBottom = protectedSourceY / imageHeight * viewportHeight
        } else {
            let visibleFraction = imageAspect / viewportAspect
            let cropOffset = (1 - visibleFraction) / 2
            visibleProtectedBottom = ((protectedSourceY / imageHeight - cropOffset) /
                                      visibleFraction) * viewportHeight
        }
        let protectedBottom = min(viewportHeight, max(0, visibleProtectedBottom))
        let legacyOrigin = floor(viewportHeight / 4) + 48
        let heroSafeOrigin = ceil(protectedBottom + 6)
        let footerTop = viewportHeight - 20
        let maximumPrimaryOrigin = footerTop - 4 - 20 - 72
        let primaryOrigin = min(max(legacyOrigin, heroSafeOrigin), maximumPrimaryOrigin)
        let secondaryOrigin = min(primaryOrigin + 84, footerTop - 4 - 20)
        let values = [primaryOrigin, primaryOrigin + 24, primaryOrigin + 48]
        guard (values + [secondaryOrigin, protectedBottom]).allSatisfy(\.isFinite) else {
            return .init(primaryButtonOriginsY: [0, 0, 0], secondaryButtonOriginY: 0,
                         heroProtectedBottomY: 0, heroClearanceIsSatisfiable: false)
        }
        return .init(primaryButtonOriginsY: values, secondaryButtonOriginY: secondaryOrigin,
                     heroProtectedBottomY: protectedBottom,
                     heroClearanceIsSatisfiable: maximumPrimaryOrigin >= heroSafeOrigin)
    }
}
