import Foundation
import XTBKit

/// Appends a line to ~/Library/Application Support/XTBBar/log.txt. Never pass secrets here.
enum Log {
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XTBBar/log.txt")

    static func write(_ message: String) {
        try? appendLine("\(Date().formatted(date: .numeric, time: .standard)) \(message)", to: url)
    }
}
