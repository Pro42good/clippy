import AppKit
import Foundation
import ScreenCaptureKit

struct CaptureDisplay: Identifiable, Codable, Equatable, Hashable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int

    var label: String {
        if width > 0, height > 0 {
            return "\(name) — \(width)×\(height)"
        }
        return name
    }

    static let mainDisplayID: UInt32 = 0
    static let mainDisplay = CaptureDisplay(id: mainDisplayID, name: "Main Display", width: 0, height: 0)
}

enum DisplayManager {
    static func refreshDisplays() async -> [CaptureDisplay] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return [.mainDisplay]
        }

        let mapped = content.displays.map { display in
            CaptureDisplay(
                id: display.displayID,
                name: localizedName(for: display.displayID, fallbackIndex: content.displays.firstIndex(where: { $0.displayID == display.displayID }) ?? 0),
                width: display.width,
                height: display.height
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return [.mainDisplay] + mapped
    }

    static func resolveDisplay(id: UInt32, from displays: [SCDisplay]) -> SCDisplay? {
        if id == CaptureDisplay.mainDisplayID {
            return displays.first
        }
        return displays.first { $0.displayID == id } ?? displays.first
    }

    static func name(for display: SCDisplay, index: Int) -> String {
        localizedName(for: display.displayID, fallbackIndex: index)
    }

    private static func localizedName(for displayID: CGDirectDisplayID, fallbackIndex: Int) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return "Display \(fallbackIndex + 1)"
    }
}

@MainActor
final class DisplayStore: ObservableObject {
    static let shared = DisplayStore()

    @Published private(set) var displays: [CaptureDisplay] = [.mainDisplay]

    private init() {}

    func refreshDisplays() async {
        displays = await DisplayManager.refreshDisplays()
    }
}
