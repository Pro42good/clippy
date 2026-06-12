import Foundation

enum ClipDuration: Int, CaseIterable, Identifiable, Codable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fifteen: return "15 seconds"
        case .thirty: return "30 seconds"
        case .sixty: return "1 minute"
        }
    }

    var shortLabel: String {
        switch self {
        case .fifteen: return "15s"
        case .thirty: return "30s"
        case .sixty: return "1m"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue) }
}

struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let fileName: String
    var title: String

    var fileURL: URL {
        ClipStorage.libraryDirectory.appendingPathComponent(fileName)
    }

    init(id: UUID = UUID(), createdAt: Date = Date(), duration: TimeInterval, fileName: String, title: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.title = title ?? Self.defaultTitle(for: createdAt)
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Clip · \(formatter.string(from: date))"
    }
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt

    static let `default` = HotkeyBinding(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue)

    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt16) -> String {
        switch Int(code) {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 53: return "Esc"
        default:
            if let scalar = UnicodeScalar(code) {
                return String(Character(scalar)).uppercased()
            }
            return "Key \(code)"
        }
    }
}

import AppKit
