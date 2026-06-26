import XCTest
@testable import Romeo

final class RomeoShortcutRequestTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: RomeoShortcutRequest.fullRomeoListenKey)
        UserDefaults.standard.removeObject(forKey: RomeoShortcutRequest.liveRomeoListenKey)
        UserDefaults.standard.removeObject(forKey: RomeoShortcutRequest.fullRomeoStopKey)
        super.tearDown()
    }

    func testFullRomeoStopRequestIsConsumedOnce() {
        XCTAssertFalse(RomeoShortcutRequest.consumeFullRomeoStopRequest())

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: RomeoShortcutRequest.fullRomeoStopKey)

        XCTAssertTrue(RomeoShortcutRequest.consumeFullRomeoStopRequest())
        XCTAssertFalse(RomeoShortcutRequest.consumeFullRomeoStopRequest())
    }

    func testStaleRequestIsClearedWithoutBeingConsumed() {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 - RomeoShortcutRequest.freshnessWindow - 1,
            forKey: RomeoShortcutRequest.fullRomeoListenKey
        )

        XCTAssertFalse(RomeoShortcutRequest.consumeFullRomeoListeningRequest())
        XCTAssertFalse(RomeoShortcutRequest.consumeFullRomeoListeningRequest())
    }

    func testRequestPostsChangeNotification() {
        let expectation = expectation(forNotification: RomeoShortcutRequest.didChangeNotification, object: nil)

        RomeoShortcutRequest.requestFullRomeoListening()

        wait(for: [expectation], timeout: 1)
    }
}
