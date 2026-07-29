import Foundation

enum AppDefaults {
    static var miniBaseURL: String {
        Bundle.main.object(forInfoDictionaryKey: "ROMEO_DEFAULT_MINI_BASE_URL") as? String
            ?? ""
    }
}
