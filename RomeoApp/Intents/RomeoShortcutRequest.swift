import Foundation

enum RomeoShortcutRequest {
    static let didChangeNotification = Notification.Name("romeo.shortcut.request.changed")
    static let freshnessWindow: TimeInterval = 20

    static let fullRomeoListenKey = "romeo.shortcut.fullRomeoListenRequestedAt"
    static let liveRomeoListenKey = "romeo.shortcut.liveRomeoListenRequestedAt"
    static let fullRomeoStopKey = "romeo.shortcut.fullRomeoStopRequestedAt"

    static func requestFullRomeoListening() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fullRomeoListenKey)
        notifyChanged()
    }

    static func requestLiveRomeoListening() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: liveRomeoListenKey)
        notifyChanged()
    }

    static func requestFullRomeoStop() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fullRomeoStopKey)
        notifyChanged()
    }

    static func consumeFullRomeoListeningRequest() -> Bool {
        consumeRequest(forKey: fullRomeoListenKey)
    }

    static func consumeLiveRomeoListeningRequest() -> Bool {
        consumeRequest(forKey: liveRomeoListenKey)
    }

    static func consumeFullRomeoStopRequest() -> Bool {
        consumeRequest(forKey: fullRomeoStopKey)
    }

    private static func consumeRequest(forKey key: String) -> Bool {
        let value = UserDefaults.standard.double(forKey: key)
        guard value > 0 else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: key)
        return Date().timeIntervalSince1970 - value <= freshnessWindow
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
