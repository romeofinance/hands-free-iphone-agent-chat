import XCTest
@testable import Romeo

final class RomeoCommandDetectorTests: XCTestCase {
    func testDetectsAndStripsEndAnchoredDonePhrase() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What is five plus one, Romeo, over"),
            "What is five plus one"
        )
    }

    func testDetectsDonePhraseAcrossPunctuationAndCase() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "Tell me a story. ROMEO... over!!!"),
            "Tell me a story"
        )
    }

    func testDetectsSpokenCommaInDonePhrase() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What's my name Romeo comma over"),
            "What's my name"
        )
    }

    func testDetectsSpokenCommaWithPunctuationAroundCommaToken() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What's my name? Romeo, comma, over."),
            "What's my name"
        )
    }

    func testDetectsDonePhraseAcrossSentenceBreak() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What's my name? Romeo. Over."),
            "What's my name"
        )
    }

    func testStripsRepeatedTrailingDonePhrases() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What's my name Romeo over Romeo over"),
            "What's my name"
        )
    }

    func testStripsRepeatedTrailingSpokenCommaDonePhrases() {
        XCTAssertEqual(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "What's my name Romeo comma over. Romeo, over."),
            "What's my name"
        )
    }

    func testDoesNotDetectMidSentenceDonePhrase() {
        XCTAssertNil(
            RomeoCommandDetector.textByStrippingDonePhrase(from: "Romeo, over, what is five plus one?")
        )
    }

    func testReturnsNilWhenOnlyDonePhraseWasSpoken() {
        XCTAssertNil(RomeoCommandDetector.textByStrippingDonePhrase(from: "Romeo, over"))
    }

    func testDetectsDonePhraseOnlyForLiveMode() {
        XCTAssertTrue(RomeoCommandDetector.isDonePhraseOnly("Romeo, over"))
        XCTAssertTrue(RomeoCommandDetector.isDonePhraseOnly("ROMEO comma over!!!"))
        XCTAssertTrue(RomeoCommandDetector.isDonePhraseOnly("Romeo, comma, over."))
        XCTAssertFalse(RomeoCommandDetector.isDonePhraseOnly("What is my name, Romeo over"))
        XCTAssertFalse(RomeoCommandDetector.isDonePhraseOnly("Romeo, over, what is five plus one?"))
    }
}
