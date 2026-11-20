import Foundation
import Combine

/// 运行日志环形缓冲
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let limit = 2500
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func append(_ message: String, source: String) {
        let stamp = timeFormatter.string(from: Date())
        let prefix = "[\(stamp)] [\(source)] "
        for raw in message.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let line = prefix + trimmed
            appendLine(line)
        }
    }

    private func appendLine(_ line: String) {
        if Thread.isMainThread {
            insert(line)
        } else {
            DispatchQueue.main.async { [weak self] in self?.insert(line) }
        }
    }

    private func insert(_ line: String) {
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func clear() {
        lines.removeAll()
    }

    func exportText() -> String {
        lines.joined(separator: "\n") + "\n"
    }
}
