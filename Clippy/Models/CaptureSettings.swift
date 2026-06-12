import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureResolution: Int, CaseIterable, Identifiable, Codable {
    case p360 = 360
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440

    var id: Int { rawValue }

    var label: String { "\(rawValue)p" }

    var targetHeight: Int { rawValue }

    func dimensions(for display: SCDisplay) -> (width: Int, height: Int) {
        let scale = min(1.0, Double(targetHeight) / Double(display.height))
        let width = max(2, Int(Double(display.width) * scale) & ~1)
        let height = max(2, Int(Double(display.height) * scale) & ~1)
        return (width, height)
    }

    var videoBitrate: Int {
        switch self {
        case .p360: return 800_000
        case .p720: return 2_000_000
        case .p1080: return 4_000_000
        case .p1440: return 6_000_000
        }
    }
}

enum CaptureFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120

    var id: Int { rawValue }

    var label: String { "\(rawValue) fps" }

    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: Int32(rawValue))
    }
}
