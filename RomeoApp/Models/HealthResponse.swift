import Foundation

struct HealthResponse: Decodable, Equatable {
    let status: String
    let version: String
}
