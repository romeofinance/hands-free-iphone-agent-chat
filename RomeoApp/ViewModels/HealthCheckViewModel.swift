import Foundation
import Observation

@MainActor
@Observable
final class HealthCheckViewModel {
    enum State: Equatable {
        case idle
        case checking
        case reachable(HealthResponse)
        case failed(String)
    }

    var state: State = .idle

    private let client: HealthClient

    init(client: HealthClient = HealthClient()) {
        self.client = client
    }

    var canCheck: Bool {
        state != .checking
    }

    func check(baseURL: String) async {
        state = .checking

        do {
            let response = try await client.checkHealth(baseURL: baseURL)
            state = .reachable(response)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
