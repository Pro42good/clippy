import Foundation

@MainActor
final class ClippyDebugLog: ObservableObject {
    static let shared = ClippyDebugLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String

        var formatted: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return "[\(formatter.string(from: timestamp))] [\(category)] \(message)"
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 250

    private init() {}

    func log(_ category: String, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        print(entry.formatted)
    }

    func logError(_ category: String, _ error: Error, context: String = "") {
        let ns = error as NSError
        var parts = [String]()
        if !context.isEmpty { parts.append(context) }
        parts.append("\(ns.domain) code=\(ns.code)")
        parts.append(ns.localizedDescription)
        if !ns.userInfo.isEmpty {
            parts.append("userInfo=\(ns.userInfo)")
        }
        log(category, parts.joined(separator: " | "))
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        entries.reversed().map(\.formatted).joined(separator: "\n")
    }
}
