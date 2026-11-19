import Foundation
import CMultitouchSupport

public enum MagicMouseFeel: String, CaseIterable, Sendable {
    case safe, balanced, sensitive
    public var title: String { switch self { case .safe: "稳妥"; case .balanced: "均衡"; case .sensitive: "灵敏" } }
    public var density: Float { switch self { case .safe: 1.0; case .balanced: 0.9; case .sensitive: 0.8 } }
    public func applying(to configuration: GestureConfiguration) -> GestureConfiguration {
        var next = configuration
        next.magicMouseMinDensity = density; next.magicMouseSlowMinDensity = 1.1
        next.magicMouseFastLandingMilliseconds = 100; next.magicMouseMaxLandingSkewMilliseconds = 600
        return next
    }
    public static func selected(in configuration: GestureConfiguration) -> Self? {
        allCases.first { $0.density == configuration.magicMouseMinDensity && configuration.magicMouseSlowMinDensity == 1.1 &&
            configuration.magicMouseFastLandingMilliseconds == 100 && configuration.magicMouseMaxLandingSkewMilliseconds == 600 }
    }
}
public enum MagicMouseChordRule {
    public static func isEdge(_ point: TouchSamplePoint, configuration: GestureConfiguration) -> Bool {
        VPMagicMouseIsEdge(point.x, point.minor, configuration.magicMouseEdgeMargin, configuration.magicMouseEdgeMaxMinor)
    }
    public static func requiredDensity(configuration: GestureConfiguration, skewMilliseconds: Double) -> Float {
        VPMagicMouseRequiredDensity(configuration.magicMouseMinDensity, configuration.magicMouseSlowMinDensity,
            Double(configuration.magicMouseFastLandingMilliseconds) / 1000, skewMilliseconds / 1000)
    }
}
