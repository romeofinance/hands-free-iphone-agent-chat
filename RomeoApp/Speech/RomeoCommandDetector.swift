import Foundation

enum RomeoCommandDetector {
    static func isDonePhraseOnly(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        guard let commandRange = trailingCommandRange(in: trimmed) else {
            return false
        }

        let prefix = trimmed[..<commandRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty
    }

    static func textByStrippingDonePhrase(from transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard let commandRange = trailingCommandRange(in: trimmed) else {
            return nil
        }

        let utterance = String(trimmed[..<commandRange.lowerBound])
            .trimmingCharacters(in: donePhraseTrimCharacters)

        return utterance.isEmpty ? nil : utterance
    }

    private static func trailingCommandRange(in text: String) -> Range<String.Index>? {
        let tokens = commandTokens(in: text)
        guard !tokens.isEmpty else {
            return nil
        }

        var commandStartTokenIndex: Int?
        var endTokenIndex = tokens.count

        while let startTokenIndex = doneCommandStartTokenIndex(
            in: tokens,
            endingBefore: endTokenIndex
        ) {
            commandStartTokenIndex = startTokenIndex
            endTokenIndex = startTokenIndex
        }

        guard let commandStartTokenIndex else {
            return nil
        }

        let lowerBound = text[..<tokens[commandStartTokenIndex].range.lowerBound]
            .lastIndex(where: { !donePhraseTrimCharacters.contains($0.unicodeScalars.first!) })
            .map { text.index(after: $0) }
            ?? text.startIndex

        return lowerBound..<text.endIndex
    }

    private static func doneCommandStartTokenIndex(
        in tokens: [CommandToken],
        endingBefore endTokenIndex: Int
    ) -> Int? {
        guard endTokenIndex >= 2 else {
            return nil
        }

        if tokens[endTokenIndex - 2].normalized == "romeo",
           tokens[endTokenIndex - 1].normalized == "over" {
            return endTokenIndex - 2
        }

        guard endTokenIndex >= 3 else {
            return nil
        }

        if tokens[endTokenIndex - 3].normalized == "romeo",
           tokens[endTokenIndex - 2].normalized == "comma",
           tokens[endTokenIndex - 1].normalized == "over" {
            return endTokenIndex - 3
        }

        return nil
    }

    private static func commandTokens(in text: String) -> [CommandToken] {
        var tokens: [CommandToken] = []
        var currentStart: String.Index?
        var currentEnd: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(after: index)
            let character = text[index]
            if character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                if currentStart == nil {
                    currentStart = index
                }
                currentEnd = nextIndex
            } else if let start = currentStart, let end = currentEnd {
                tokens.append(CommandToken(text[start..<end], range: start..<end))
                currentStart = nil
                currentEnd = nil
            }
            index = nextIndex
        }

        if let start = currentStart, let end = currentEnd {
            tokens.append(CommandToken(text[start..<end], range: start..<end))
        }

        return tokens
    }

    private static let donePhraseTrimCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
}

private struct CommandToken {
    let normalized: String
    let range: Range<String.Index>

    init(_ text: Substring, range: Range<String.Index>) {
        normalized = text.lowercased()
        self.range = range
    }
}
