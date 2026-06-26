import Foundation

struct SSEMessage: Equatable {
    let event: String
    let data: String
}

struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func parse(line: String) -> [SSEMessage] {
        let normalizedLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if normalizedLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return flush().map { [$0] } ?? []
        }

        if normalizedLine.hasPrefix(":") {
            return []
        }

        let parts = normalizedLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let field = parts.first else {
            return []
        }

        let rawValue = parts.count > 1 ? String(parts[1]) : ""
        let value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : rawValue

        switch field {
        case "event":
            let pending = flush()
            event = value
            return pending.map { [$0] } ?? []
        case "data":
            dataLines.append(value)
            return []
        default:
            return []
        }
    }

    mutating func flush() -> SSEMessage? {
        guard event != nil || !dataLines.isEmpty else {
            return nil
        }

        let message = SSEMessage(event: event ?? "message", data: dataLines.joined(separator: "\n"))
        event = nil
        dataLines = []
        return message
    }
}
