import Foundation
import os.log

enum Logger {
    private static let subsystem = "ai.orange.desktop"
    private static let core = OSLog(subsystem: subsystem, category: "core")
    private static let lock = NSLock()
    private static var recentEntries: [String] = []
    private static let maxEntries = 200

    static func info(_ message: String) {
        record("INFO", message: message)
        os_log("%{public}@", log: core, type: .info, message)
    }

    static func error(_ message: String) {
        record("ERROR", message: message)
        os_log("%{public}@", log: core, type: .error, message)
    }

    static func recentMessages(limit: Int = 40) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentEntries.suffix(max(1, limit)))
    }

    private static func record(_ level: String, message: String) {
        let formatter = ISO8601DateFormatter()
        let entry = "\(formatter.string(from: Date())) [\(level)] \(message)"
        lock.lock()
        recentEntries.append(entry)
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
        }
        lock.unlock()
    }
}
