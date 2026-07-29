import SwiftUI
import UIKit

struct HealthCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("miniBaseURL") private var miniBaseURL = AppDefaults.miniBaseURL
    @AppStorage("elevenLabsVoiceID") private var elevenLabsVoiceID = ""
    @AppStorage("fullRomeoSTTProvider") private var fullRomeoSTTProviderRaw = FullRomeoSTTProvider.elevenLabsScribe.rawValue
    @AppStorage("romeoDuckingLevel") private var romeoDuckingLevelRaw = RomeoDuckingLevel.max.rawValue
    @State private var isPocketModeEnabled = false
    @State private var viewModel = HealthCheckViewModel()
    @State private var fullRomeoViewModel = FullRomeoViewModel()
    @State private var voiceViewModel = FullRomeoVoiceViewModel()
    @State private var liveViewModel = LiveRomeoViewModel()
    @State private var elevenLabsAPIKey = ""
    @State private var openAIAPIKey = ""
    @State private var secretStorageMessage: String?
    @State private var elevenLabsTestMessage: String?
    @State private var openAIKeyTestMessage: String?
    @State private var elevenLabsSTTTestMessage: String?
    @State private var isTestingElevenLabs = false
    @State private var isTestingElevenLabsSTT = false
    @State private var isTestingOpenAIKey = false
    @State private var fullRomeoText = ""
    @State private var isReadyForShortcutRequests = false
    @State private var shortcutTransitionTask: Task<Void, Never>?
    @State private var pendingAudioCleanupTask: Task<Void, Never>?

    private let elevenLabsAPIKeyAccount = "romeo-elevenlabs-api-key"
    private let openAIAPIKeyAccount = "romeo-openai-api-key"
    private let keychainStore = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Full Romeo") {
                    voiceControls

                    TextField("Type fallback message", text: $fullRomeoText, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)

                    HStack {
                        Button {
                            saveSecrets()
                            fullRomeoViewModel.send(
                                text: fullRomeoText,
                                baseURL: miniBaseURL
                            )
                        } label: {
                            Label("Send", systemImage: "paperplane")
                        }
                        .disabled(!fullRomeoViewModel.canSend)

                        if !fullRomeoViewModel.canSend {
                            Button(role: .cancel) {
                                fullRomeoViewModel.cancel()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                        }
                    }

                    fullRomeoStatusRow
                    LabeledContent("Typed fallback transport", value: fullRomeoViewModel.transportText)
                    fullRomeoReplyRow
                }

                Section("Live Romeo") {
                    liveControls
                }

                Section("Pocket Mode") {
                    Button {
                        isPocketModeEnabled = true
                    } label: {
                        Label("Enter Pocket Mode", systemImage: "lock.fill")
                    }
                }

                Section("Configuration") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tailnet URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://agent-host.your-tailnet.ts.net", text: $miniBaseURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        Text("Include a nonstandard port, such as :8443, if your Tailscale Serve or HTTPS setup uses one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ElevenLabs API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("sk_...", text: $elevenLabsAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveSecrets)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ElevenLabs Voice ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Voice ID", text: $elevenLabsVoiceID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenAI API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("sk-...", text: $openAIAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveSecrets)
                    }

                    Button {
                        testElevenLabsVoice()
                    } label: {
                        Label(
                            isTestingElevenLabs ? "Testing ElevenLabs" : "Test ElevenLabs Voice",
                            systemImage: isTestingElevenLabs ? "speaker.wave.2" : "speaker.wave.2.fill"
                        )
                    }
                    .disabled(isTestingElevenLabs)

                    if let elevenLabsTestMessage {
                        Text(elevenLabsTestMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        testElevenLabsSTT()
                    } label: {
                        Label(
                            isTestingElevenLabsSTT ? "Testing ElevenLabs STT" : "Test ElevenLabs STT",
                            systemImage: isTestingElevenLabsSTT ? "waveform" : "waveform.badge.magnifyingglass"
                        )
                    }
                    .disabled(isTestingElevenLabsSTT)

                    if let elevenLabsSTTTestMessage {
                        Text(elevenLabsSTTTestMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        testOpenAIKey()
                    } label: {
                        Label(
                            isTestingOpenAIKey ? "Testing OpenAI Key" : "Test OpenAI Key",
                            systemImage: isTestingOpenAIKey ? "key.horizontal" : "key.horizontal.fill"
                        )
                    }
                    .disabled(isTestingOpenAIKey)

                    if let openAIKeyTestMessage {
                        Text(openAIKeyTestMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Audio Duck") {
                    Picker("Background duck", selection: $romeoDuckingLevelRaw) {
                        ForEach(RomeoDuckingLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Default background duck", value: "Max")
                }

                Section("Health") {
                    Button {
                        Task {
                            saveSecrets()
                            await viewModel.check(baseURL: miniBaseURL)
                        }
                    } label: {
                        Label(buttonTitle, systemImage: buttonIcon)
                    }
                    .disabled(!viewModel.canCheck)

                    statusRow

                    if let secretStorageMessage {
                        Text(secretStorageMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Romeo")
            .overlay {
                if isPocketModeEnabled {
                    pocketModeOverlay
                }
            }
            .onAppear {
                updateIdleTimer(for: scenePhase)
            }
            .task {
                loadSecrets()
                try? await Task.sleep(for: .milliseconds(700))
                isReadyForShortcutRequests = true
                handleShortcutRequests()
            }
            .onChange(of: scenePhase) { _, newPhase in
                updateIdleTimer(for: newPhase)
                if newPhase == .active {
                    handleShortcutRequests()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: RomeoShortcutRequest.didChangeNotification)) { _ in
                handleShortcutRequests()
            }
            .onReceive(NotificationCenter.default.publisher(for: RomeoAudioSession.didBeginInterruptionNotification)) { _ in
                if let cleanup = voiceViewModel.handleAudioInterruption() {
                    rememberAudioCleanup(cleanup)
                }
            }
        }
    }

    private var pocketModeOverlay: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 34, weight: .semibold))
                Text("Pocket Mode")
                    .font(.headline)
                Text("Long press to unlock")
                    .font(.footnote)
            }
            .padding(56)
            .contentShape(Rectangle())
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 1.6)
                    .onEnded { _ in
                        isPocketModeEnabled = false
                    }
            )
            .foregroundStyle(.white.opacity(0.28))
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pocket Mode. Long press to unlock.")
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase != .background
    }

    private var buttonTitle: String {
        switch viewModel.state {
        case .checking:
            "Checking"
        default:
            "Check Health"
        }
    }

    private var buttonIcon: String {
        switch viewModel.state {
        case .checking:
            "arrow.triangle.2.circlepath"
        case .reachable:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .idle:
            "network"
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.state {
        case .idle:
            LabeledContent("Status", value: "Not checked")
        case .checking:
            HStack {
                ProgressView()
                Text("Checking")
            }
        case .reachable(let response):
            VStack(alignment: .leading, spacing: 8) {
                Label("Reachable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Status", value: response.status)
                LabeledContent("Version", value: response.version)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Unreachable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("STT", selection: $fullRomeoSTTProviderRaw) {
                ForEach(FullRomeoSTTProvider.allCases) { provider in
                    Text(provider.shortName).tag(provider.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    transitionToFullRomeo(source: "tap")
                } label: {
                    Label("Talk", systemImage: "waveform")
                }
                .disabled(!voiceViewModel.canStart)

                if !voiceViewModel.canStart {
                    if voiceViewModel.state == .listening,
                       !voiceViewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            saveSecrets()
                            voiceViewModel.submitCurrentTranscript(
                                baseURL: miniBaseURL,
                                elevenLabsAPIKey: elevenLabsAPIKey,
                                elevenLabsVoiceID: elevenLabsVoiceID,
                                source: "tap",
                                duckingLevel: romeoDuckingLevel
                            )
                        } label: {
                            Label("Submit", systemImage: "paperplane")
                        }
                    }

                    Button(role: .cancel) {
                        rememberAudioCleanup(voiceViewModel.cancel())
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }

            voiceStatusRow
            LabeledContent("Transport", value: voiceViewModel.transportText)
            LabeledContent("STT provider", value: fullRomeoSTTProvider.displayName)
            if !voiceViewModel.transcript.isEmpty {
                LabeledContent("Transcript", value: voiceViewModel.transcript)
            }
            if !voiceViewModel.submittedText.isEmpty {
                LabeledContent("Submitted", value: voiceViewModel.submittedText)
            }
            if !voiceViewModel.replyText.isEmpty {
                LabeledContent("Spoken reply", value: voiceViewModel.replyText)
            }
        }
    }

    @ViewBuilder
    private var voiceStatusRow: some View {
        switch voiceViewModel.state {
        case .idle:
            LabeledContent("Voice", value: "Idle")
        case .starting:
            HStack {
                ProgressView()
                Text("Starting microphone")
            }
        case .listening:
            HStack {
                ProgressView()
                Text("Listening")
            }
        case .thinking:
            HStack {
                ProgressView()
                Text("Thinking...")
            }
        case .speaking:
            HStack {
                ProgressView()
                Text("Speaking")
            }
        case .done:
            Label("Voice turn done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Voice failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fullRomeoStatusRow: some View {
        switch fullRomeoViewModel.state {
        case .idle:
            LabeledContent("Typed fallback", value: "Not sent")
        case .streaming:
            HStack {
                ProgressView()
                Text(fullRomeoViewModel.statusText)
            }
        case .done:
            Label("Typed fallback done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Typed fallback failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fullRomeoReplyRow: some View {
        if !fullRomeoViewModel.replyText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Typed fallback reply")
                    .font(.headline)
                Text(fullRomeoViewModel.replyText)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    transitionToLiveRomeo()
                } label: {
                    Label("Start Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!liveViewModel.canStart)

                if !liveViewModel.canStart {
                    Button {
                        finishLiveRomeo()
                    } label: {
                        Label("End", systemImage: "checkmark.circle")
                    }

                    Button(role: .cancel) {
                        rememberAudioCleanup(liveViewModel.cancel())
                    } label: {
                        Label("Discard", systemImage: "xmark.circle")
                    }
                }
            }

            liveStatusRow
            if !liveViewModel.transcriptPostStatusText.isEmpty {
                Text(liveViewModel.transcriptPostStatusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !liveViewModel.latestUserText.isEmpty {
                LabeledContent("Last user", value: liveViewModel.latestUserText)
            }
            if !liveViewModel.latestRomeoText.isEmpty {
                LabeledContent("Last Romeo", value: liveViewModel.latestRomeoText)
            }
            if !liveViewModel.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Live transcript")
                        .font(.headline)
                    Text(liveViewModel.transcript)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var liveStatusRow: some View {
        switch liveViewModel.state {
        case .idle:
            LabeledContent("Live", value: "Idle")
        case .connecting:
            HStack {
                ProgressView()
                Text("Connecting")
            }
        case .live:
            HStack {
                ProgressView()
                Text("Live")
            }
        case .postingTranscript:
            HStack {
                ProgressView()
                Text("Posting transcript")
            }
        case .done:
            Label("Live session done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Live failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fullRomeoSTTProvider: FullRomeoSTTProvider {
        FullRomeoSTTProvider(rawValue: fullRomeoSTTProviderRaw) ?? .elevenLabsScribe
    }

    private var romeoDuckingLevel: RomeoDuckingLevel {
        RomeoDuckingLevel(rawValue: romeoDuckingLevelRaw) ?? .max
    }

    private func loadSecrets() {
        do {
            elevenLabsAPIKey = try keychainStore.string(for: elevenLabsAPIKeyAccount)
            openAIAPIKey = try keychainStore.string(for: openAIAPIKeyAccount)
            secretStorageMessage = nil
        } catch {
            secretStorageMessage = "Could not load secrets from Keychain."
        }
    }

    private func saveSecrets() {
        do {
            try keychainStore.setString(elevenLabsAPIKey, for: elevenLabsAPIKeyAccount)
            try keychainStore.setString(openAIAPIKey, for: openAIAPIKeyAccount)
            secretStorageMessage = nil
        } catch {
            secretStorageMessage = "Could not save secrets to Keychain."
        }
    }

    private func testElevenLabsVoice() {
        saveSecrets()

        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            elevenLabsTestMessage = ElevenLabsTTSError.missingAPIKey.localizedDescription
            return
        }

        guard !voiceID.isEmpty else {
            elevenLabsTestMessage = ElevenLabsTTSError.missingVoiceID.localizedDescription
            return
        }

        isTestingElevenLabs = true
        elevenLabsTestMessage = "Testing ElevenLabs voice..."

        Task {
            await pendingAudioCleanupTask?.value
            do {
                try await ElevenLabsTTSClient().speak(
                    text: "Romeo voice test.",
                    apiKey: apiKey,
                    voiceID: voiceID
                )
                elevenLabsTestMessage = "ElevenLabs voice test played."
            } catch {
                elevenLabsTestMessage = error.localizedDescription
            }

            try? RomeoAudioSession.deactivateNotifyingOthers()
            isTestingElevenLabs = false
        }
    }

    private func testElevenLabsSTT() {
        saveSecrets()

        let apiKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            elevenLabsSTTTestMessage = ElevenLabsTTSError.missingAPIKey.localizedDescription
            return
        }

        isTestingElevenLabsSTT = true
        elevenLabsSTTTestMessage = "Testing ElevenLabs Scribe..."

        Task {
            do {
                try await ElevenLabsScribeKeyValidator().validate(apiKey: apiKey)
                elevenLabsSTTTestMessage = "ElevenLabs Scribe key is valid."
            } catch {
                elevenLabsSTTTestMessage = error.localizedDescription
            }

            isTestingElevenLabsSTT = false
        }
    }

    private func testOpenAIKey() {
        saveSecrets()

        let apiKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            openAIKeyTestMessage = LiveRealtimeError.missingAPIKey.localizedDescription
            return
        }

        isTestingOpenAIKey = true
        openAIKeyTestMessage = "Testing OpenAI key..."

        Task {
            do {
                try await OpenAIKeyValidator().validate(apiKey: apiKey)
                openAIKeyTestMessage = "OpenAI key is valid."
            } catch {
                openAIKeyTestMessage = error.localizedDescription
            }

            isTestingOpenAIKey = false
        }
    }

    private func rememberAudioCleanup(_ cleanup: Task<Void, Never>) {
        let previousCleanup = pendingAudioCleanupTask
        pendingAudioCleanupTask = Task {
            await previousCleanup?.value
            await cleanup.value
        }
    }

    private func transitionToLiveRomeo() {
        saveSecrets()
        shortcutTransitionTask?.cancel()
        rememberAudioCleanup(voiceViewModel.cancel())
        fullRomeoViewModel.cancel()
        let cleanup = pendingAudioCleanupTask

        shortcutTransitionTask = Task {
            await cleanup?.value
            guard !Task.isCancelled else {
                return
            }
            liveViewModel.restart(
                baseURL: miniBaseURL,
                openAIAPIKey: openAIAPIKey,
                duckingLevel: romeoDuckingLevel
            )
            shortcutTransitionTask = nil
        }
    }

    private func transitionToFullRomeo(source: String) {
        saveSecrets()
        shortcutTransitionTask?.cancel()
        rememberAudioCleanup(liveViewModel.cancel())
        fullRomeoViewModel.cancel()
        let cleanup = pendingAudioCleanupTask

        shortcutTransitionTask = Task {
            await cleanup?.value
            guard !Task.isCancelled else {
                return
            }
            voiceViewModel.restart(
                baseURL: miniBaseURL,
                elevenLabsAPIKey: elevenLabsAPIKey,
                elevenLabsVoiceID: elevenLabsVoiceID,
                source: source,
                sttProvider: fullRomeoSTTProvider,
                duckingLevel: romeoDuckingLevel
            )
            shortcutTransitionTask = nil
        }
    }

    private func finishLiveRomeo() {
        shortcutTransitionTask?.cancel()
        let cleanup = pendingAudioCleanupTask
        shortcutTransitionTask = Task {
            await cleanup?.value
            guard !Task.isCancelled else {
                return
            }
            liveViewModel.stop(baseURL: miniBaseURL)
            shortcutTransitionTask = nil
        }
    }

    private func stopRomeo() {
        shortcutTransitionTask?.cancel()
        rememberAudioCleanup(voiceViewModel.cancel())
        fullRomeoViewModel.cancel()
        let cleanup = pendingAudioCleanupTask

        shortcutTransitionTask = Task {
            await cleanup?.value
            guard !Task.isCancelled else {
                return
            }
            liveViewModel.stop(baseURL: miniBaseURL)
            shortcutTransitionTask = nil
        }
    }

    private func handleShortcutRequests() {
        guard isReadyForShortcutRequests, scenePhase == .active else {
            return
        }

        if RomeoShortcutRequest.consumeFullRomeoStopRequest() {
            stopRomeo()
            return
        }

        if RomeoShortcutRequest.consumeLiveRomeoListeningRequest() {
            transitionToLiveRomeo()
            return
        }

        if RomeoShortcutRequest.consumeFullRomeoListeningRequest() {
            saveSecrets()

            switch voiceViewModel.state {
            case .thinking:
                voiceViewModel.acknowledgeStillThinking(
                    elevenLabsAPIKey: elevenLabsAPIKey,
                    elevenLabsVoiceID: elevenLabsVoiceID
                )
                return
            case .starting, .listening, .speaking:
                return
            case .idle, .done, .failed:
                break
            }

            transitionToFullRomeo(source: "siri")
            return
        }
    }
}

#Preview {
    HealthCheckView()
}
