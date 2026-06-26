import XCTest
@testable import Romeo

final class SSEParserTests: XCTestCase {
    func testParsesContractStyleEvents() {
        var parser = SSEParser()

        XCTAssertEqual(parser.parse(line: "event: status"), [])
        XCTAssertEqual(parser.parse(line: #"data: {"value":"thinking"}"#), [])

        let status = parser.parse(line: "")

        XCTAssertEqual(status, [SSEMessage(event: "status", data: #"{"value":"thinking"}"#)])

        XCTAssertEqual(parser.parse(line: "event: text"), [])
        XCTAssertEqual(parser.parse(line: #"data: {"delta":"Hello"}"#), [])

        let text = parser.parse(line: "")

        XCTAssertEqual(text, [SSEMessage(event: "text", data: #"{"delta":"Hello"}"#)])
    }

    func testFlushesFinalMessageWithoutTrailingBlankLine() {
        var parser = SSEParser()

        XCTAssertEqual(parser.parse(line: "event: status"), [])
        XCTAssertEqual(parser.parse(line: #"data: {"value":"done"}"#), [])

        XCTAssertEqual(parser.flush(), SSEMessage(event: "status", data: #"{"value":"done"}"#))
    }

    func testParsesDataLineWithoutDecodingIt() {
        var parser = SSEParser()

        XCTAssertEqual(parser.parse(line: "event: text"), [])
        XCTAssertEqual(parser.parse(line: "data: four"), [])

        XCTAssertEqual(parser.parse(line: ""), [SSEMessage(event: "text", data: "four")])
    }

    func testWhitespaceOnlyLineSeparatesEvents() {
        var parser = SSEParser()

        XCTAssertEqual(parser.parse(line: "event: status"), [])
        XCTAssertEqual(parser.parse(line: #"data: {"value":"thinking"}"#), [])

        let messages = parser.parse(line: "   \r")

        XCTAssertEqual(messages, [
            SSEMessage(event: "status", data: #"{"value":"thinking"}"#)
        ])
    }

    func testNewEventFlushesBufferedEvent() {
        var parser = SSEParser()

        XCTAssertEqual(parser.parse(line: "event: status"), [])
        XCTAssertEqual(parser.parse(line: #"data: {"value":"thinking"}"#), [])

        let flushed = parser.parse(line: "event: text")

        XCTAssertEqual(flushed, [
            SSEMessage(event: "status", data: #"{"value":"thinking"}"#)
        ])

        XCTAssertEqual(parser.parse(line: #"data: {"delta":"6"}"#), [])
        XCTAssertEqual(parser.parse(line: "event: status"), [
            SSEMessage(event: "text", data: #"{"delta":"6"}"#)
        ])

        XCTAssertEqual(parser.parse(line: #"data: {"value":"done"}"#), [])
        XCTAssertEqual(parser.flush(), SSEMessage(event: "status", data: #"{"value":"done"}"#))
    }

    func testParsesMiniObservedSequence() {
        var parser = SSEParser()
        var messages: [SSEMessage] = []

        for line in [
            "event: status",
            #"data: {"value":"thinking"}"#,
            "",
            "event: text",
            #"data: {"delta":"6"}"#,
            "",
            "event: status",
            #"data: {"value":"done"}"#,
            ""
        ] {
            messages.append(contentsOf: parser.parse(line: line))
        }

        XCTAssertEqual(messages, [
            SSEMessage(event: "status", data: #"{"value":"thinking"}"#),
            SSEMessage(event: "text", data: #"{"delta":"6"}"#),
            SSEMessage(event: "status", data: #"{"value":"done"}"#)
        ])
    }
}
