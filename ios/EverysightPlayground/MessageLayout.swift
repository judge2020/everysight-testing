import Foundation

struct DiscordMessage {
    let id: String
    let userID: String
    let author: String
    let conversation: String
    let content: String
    let timestamp: Double
    let edited: Bool
    let disclosure: Bool

    init?(_ value: [AnyHashable: Any]) {
        guard let id = value["id"] as? String, let userID = value["userID"] as? String,
              let author = value["author"] as? String, let content = value["content"] as? String else { return nil }
        self.id = id; self.userID = userID; self.author = author; self.content = content
        conversation = value["conversation"] as? String ?? userID
        timestamp = (value["timestamp"] as? NSNumber)?.doubleValue ?? 0
        edited = (value["edited"] as? NSNumber)?.boolValue ?? false
        disclosure = (value["disclosure"] as? NSNumber)?.boolValue ?? false
    }
}

enum MessageLayout {
    // Conservative line width for the pinned SDK's default font at 0.65 scale.
    // Iterate Characters so emoji and composed characters are never split.
    static func pages(_ content: String, columns: Int = 38, rows: Int = 5) -> [[String]] {
        precondition(columns > 0 && rows > 0)
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        var lines: [String] = []
        for paragraph in normalized.components(separatedBy: "\n") {
            var remaining = Array(paragraph)
            if remaining.isEmpty { lines.append(""); continue }
            while !remaining.isEmpty {
                var count = min(columns, remaining.count)
                if count < remaining.count, remaining[count] != " ", let space = remaining[..<count].lastIndex(of: " "), space > 0 {
                    count = space
                }
                lines.append(String(remaining.prefix(count)))
                remaining.removeFirst(count)
                if remaining.first == " " { remaining.removeFirst() }
            }
        }
        if lines.isEmpty { lines = ["[Empty message]"] }
        return stride(from: 0, to: lines.count, by: rows).map { Array(lines[$0..<min($0 + rows, lines.count)]) }
    }
}
