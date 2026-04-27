import AVFoundation
import os
import RiveRuntime
import Speech
import SwiftUI

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "onboarding"
)

// MARK: - Onboarding Step

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case login
    case voice
    case howToUse
    case ready
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var direction: Int = 1

    // Permissions
    @State private var accessibilityGranted = false
    @State private var fullDiskGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false
    @State private var appManagementGranted = false
    @State private var notificationsGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionPollTimer: Timer?
    @State private var axObserver: NSObjectProtocol?

    // Login
    @State private var isLoggedIn = ClaudeService.shared.isLoggedIn
    @State private var apiKeyInputs: [AIProvider: String] = [:]
    @State private var validatingProvider: AIProvider?
    @State private var isAuthenticating = false
    @State private var loginError: String?

    // How to Use
    @State private var howToChecks: Set<Int> = []

    // Voice
    @ObservedObject private var kokoro = KokoroManager.shared

    // Browser
    @ObservedObject private var chromium = ChromiumManager.shared

    // Rive - avatar mascot for onboarding
    @State private var riveViewModel = RiveViewModel(
        fileName: "avatar_pack",
        stateMachineName: "avatar",
        autoPlay: true,
        artboardName: "Avatar 1"
    )

    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button {
                    ButtonSound.shared.play()
                    onComplete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 12)

            // Mascot
            riveViewModel.view()
                .frame(width: 64, height: 64)
                .padding(.bottom, 4)

            // Step indicator
            stepIndicator
                .padding(.bottom, 12)

            // Content area
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .login:
                    loginStep
                case .voice:
                    voiceStep
                case .howToUse:
                    howToUseStep
                case .ready:
                    readyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: step)

            Spacer(minLength: 8)

            Divider().opacity(0.3)

            // Navigation
            navigationBar
        }
        .frame(width: 420, height: 700)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.white.opacity(0.9) : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Text("Welcome to Tama")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))

            Text("Your AI companion that lives in the menu bar.\nLet's get everything set up.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Text("Permissions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .padding(.bottom, 8)

            Text("Grant access so Tama can work properly.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .padding(.bottom, 12)

            VStack(spacing: 1) {
                permissionRow(
                    title: "Accessibility",
                    description: "Global hotkey (Option+Space)",
                    granted: accessibilityGranted
                ) {
                    OnboardingController.yieldToSystemUI()
                    if accessibilityGranted {
                        PermissionsChecker.shared.openAccessibilitySettings()
                    } else {
                        PermissionsChecker.shared.requestAccessibility()
                        // macOS 15+ no longer shows a visible prompt dialog,
                        // so also open System Settings directly.
                        PermissionsChecker.shared.openAccessibilitySettings()
                    }
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Full Disk Access",
                    description: fullDiskGranted
                        ? "Read, write, and edit files"
                        : "Open Settings, press '+', add Tama from Applications",
                    granted: fullDiskGranted
                ) {
                    OnboardingController.yieldToSystemUI()
                    PermissionsChecker.shared.openFullDiskAccessSettings()
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Microphone",
                    description: "Voice input (hold Option+Space)",
                    granted: microphoneGranted
                ) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        PermissionsChecker.shared.requestMicrophone { granted in
                            microphoneGranted = granted
                        }
                    } else {
                        OnboardingController.yieldToSystemUI()
                        PermissionsChecker.shared.openMicrophoneSettings()
                    }
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Speech Recognition",
                    description: "Voice-to-text transcription",
                    granted: speechGranted
                ) {
                    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                        PermissionsChecker.shared.requestSpeechRecognition { status in
                            speechGranted = status == .authorized
                        }
                    } else {
                        OnboardingController.yieldToSystemUI()
                        PermissionsChecker.shared.openMicrophoneSettings()
                    }
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "App Management",
                    description: appManagementGranted
                        ? "Allows managing the bundled browser"
                        : "Open Settings, toggle Tama on",
                    granted: appManagementGranted
                ) {
                    OnboardingController.yieldToSystemUI()
                    PermissionsChecker.shared.openAppManagementSettings()
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Screen Recording",
                    description: screenRecordingGranted
                        ? "Screenshot tool during chats and voice calls"
                        : "Click Grant, then toggle Tama on in System Settings",
                    granted: screenRecordingGranted
                ) {
                    OnboardingController.yieldToSystemUI()
                    if screenRecordingGranted {
                        PermissionsChecker.shared.openScreenRecordingSettings()
                    } else {
                        // First call may trigger the system TCC dialog; if it
                        // returns false we also open Settings so the user can
                        // toggle the switch manually.
                        _ = PermissionsChecker.shared.requestScreenRecording()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            screenRecordingGranted = PermissionsChecker.shared.isScreenRecordingGranted()
                            if !screenRecordingGranted {
                                PermissionsChecker.shared.openScreenRecordingSettings()
                            }
                        }
                    }
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                permissionRow(
                    title: "Notifications",
                    description: "Reminders and routine alerts",
                    granted: notificationsGranted
                ) {
                    let status = PermissionsChecker.shared.notificationsStatus()
                    if status == .notDetermined {
                        // First time - request authorization (shows system dialog)
                        PermissionsChecker.shared.requestNotifications { newStatus in
                            notificationsGranted = newStatus == .authorized
                        }
                    } else {
                        // Already decided - open system settings
                        OnboardingController.yieldToSystemUI()
                        PermissionsChecker.shared.openNotificationsSettings()
                    }
                }

                Divider().opacity(0.3).padding(.horizontal, 14)

                browserRow
            }

            HStack(spacing: 8) {
                Spacer()
                GlassButton("Refresh") {
                    refreshPermissions()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            } else {
                GlassButton("Grant") { action() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var hasBrowser: Bool {
        BrowserManager.installedSystemBrowser != nil || chromium.isDownloaded
    }

    private var browserDescription: String {
        if chromium.isDownloaded {
            return "Chrome for Testing is ready"
        }
        if let name = BrowserManager.installedSystemBrowser {
            return "\(name) detected"
        }
        return "~400 MB download for web browsing"
    }

    private var browserRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browser (Optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(browserDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if hasBrowser {
                Text("Ready")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            } else if chromium.isDownloading {
                ProgressView(value: chromium.downloadProgress)
                    .frame(width: 60)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(y: 0.5)
            } else {
                GlassButton("Download") { chromium.downloadChromium() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func refreshPermissions() {
        let checker = PermissionsChecker.shared
        accessibilityGranted = checker.isAccessibilityGranted()
        fullDiskGranted = checker.isFullDiskAccessGranted()
        microphoneGranted = checker.isMicrophoneGranted()
        speechGranted = checker.isSpeechRecognitionGranted()
        appManagementGranted = checker.isAppManagementGranted()
        notificationsGranted = checker.isNotificationsGranted()
        screenRecordingGranted = checker.isScreenRecordingGranted()
    }

    private func startPermissionPolling() {
        // Initial check with delay to ensure system returns correct status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshPermissions()
        }

        // Listen for accessibility changes via system notification (instant detection).
        // This is an undocumented but widely-used notification from HIServices.framework.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            // The notification fires before AXIsProcessTrusted updates; delay briefly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                refreshPermissions()
            }
        }

        // Poll for other permissions (FDA, mic, speech) which lack a notification.
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                refreshPermissions()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        if let axObserver {
            DistributedNotificationCenter.default().removeObserver(axObserver)
        }
        axObserver = nil
    }

    // MARK: - Login

    private var loginStep: some View {
        VStack(spacing: 0) {
            Text("Connect a Model")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .padding(.bottom, 8)

            Text("Add an API key for at least one provider.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)

            Text("Your credentials are encrypted and stored securely. " +
                "You may see a system prompt asking for keychain access — this is normal.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AIProvider.allCases) { provider in
                        providerLoginRow(provider)
                    }
                }
                .padding(.horizontal, 14)
            }

            if let loginError {
                Text(loginError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    )
                    .cornerRadius(8)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
    }

    private func providerLoginRow(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text(provider.description)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                if ProviderStore.shared.hasCredentials(for: provider) {
                    Text("Connected")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.green.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            if !ProviderStore.shared.hasCredentials(for: provider) {
                if provider.usesOAuth {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Waiting for browser…")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        } else {
                            GlassButton("Sign in with \(provider.displayName)", isPrimary: true) {
                                startOAuth(for: provider)
                            }
                        }
                        Spacer()
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("Paste API key", text: apiKeyBinding(for: provider))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .disabled(validatingProvider == provider)

                        let key = apiKeyInputs[provider] ?? ""
                        let isValidating = validatingProvider == provider

                        if isValidating {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 40)
                        } else {
                            GlassButton("Add", isPrimary: true) {
                                submitApiKey(key, for: provider)
                            }
                            .disabled(key.isEmpty)
                            .opacity(key.isEmpty ? 0.5 : 1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func apiKeyBinding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { apiKeyInputs[provider] ?? "" },
            set: { apiKeyInputs[provider] = $0 }
        )
    }

    private func startOAuth(for provider: AIProvider) {
        loginError = nil
        isAuthenticating = true

        Task {
            do {
                let credential: ProviderCredential
                switch provider {
                case .openai:
                    let result = try await OpenAIOAuth.shared.authenticate()
                    credential = ProviderCredential.oauth(
                        accessToken: result.accessToken,
                        refreshToken: result.refreshToken,
                        expiresAt: result.expiresAt,
                        accountId: result.accountId
                    )
                case .gemini:
                    let result = try await GeminiOAuth.shared.authenticate()
                    credential = ProviderCredential.oauth(
                        accessToken: result.accessToken,
                        refreshToken: result.refreshToken,
                        expiresAt: result.expiresAt,
                        accountId: result.projectId
                    )
                case .anthropic:
                    let result = try await AnthropicOAuth.shared.authenticate()
                    credential = ProviderCredential.oauth(
                        accessToken: result.accessToken,
                        refreshToken: result.refreshToken,
                        expiresAt: result.expiresAt,
                        accountId: ""
                    )
                default:
                    isAuthenticating = false
                    return
                }
                ProviderStore.shared.setCredential(credential, for: provider)
                let defaultModel = ModelRegistry.defaultModel(for: provider)
                ProviderStore.shared.setSelectedModel(defaultModel)
                isLoggedIn = true
                logger.info("Onboarding OAuth login completed for \(provider.displayName)")
            } catch {
                loginError = error.localizedDescription
            }
            isAuthenticating = false
        }
    }

    private func submitApiKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loginError = nil
        validatingProvider = provider

        Task {
            let error = await ProviderStore.shared.validateApiKey(trimmed, for: provider)
            validatingProvider = nil

            if let error {
                loginError = error
                return
            }

            ProviderStore.shared.setCredential(.apiKey(trimmed), for: provider)
            let defaultModel = ModelRegistry.defaultModel(for: provider)
            ProviderStore.shared.setSelectedModel(defaultModel)
            apiKeyInputs[provider] = nil
            isLoggedIn = true
            logger.info("Onboarding API key added for \(provider.displayName)")
        }
    }

    // MARK: - Voice

    private var voiceStep: some View {
        VStack(spacing: 0) {
            Text("Voice Model")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .padding(.bottom, 8)

            Text("Download the on-device TTS model for voice responses.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            // Model download
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: kokoro.modelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundColor(kokoro.modelDownloaded ? .green.opacity(0.9) : .white.opacity(0.6))
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kokoro TTS Model")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Text(kokoro.modelDownloaded ? "Ready" : "~350 MB download")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }

                    Spacer()

                    if !kokoro.modelDownloaded {
                        if kokoro.modelDownloading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            GlassButton("Download", isPrimary: true) {
                                kokoro.downloadModel()
                            }
                        }
                    }
                }

                if kokoro.modelDownloading {
                    ProgressView(value: kokoro.modelDownloadProgress)
                        .tint(.white.opacity(0.6))
                        .scaleEffect(y: 0.5)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider().opacity(0.3).padding(.horizontal, 24)

            // Default voice download
            if kokoro.modelDownloaded {
                let defaultVoice = KokoroManager.availableVoices[0]
                let voiceDownloaded = kokoro.downloadedVoices.contains(defaultVoice.id)
                let voiceDownloading = kokoro.voiceDownloading[defaultVoice.id] == true

                HStack(spacing: 8) {
                    Image(systemName: voiceDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundColor(voiceDownloaded ? .green.opacity(0.9) : .white.opacity(0.6))
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default Voice: \(defaultVoice.name)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Text(voiceDownloaded ? "Ready" : "\(defaultVoice.accent)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }

                    Spacer()

                    if voiceDownloading {
                        ProgressView(value: kokoro.voiceDownloadProgress[defaultVoice.id] ?? 0)
                            .frame(width: 50)
                            .tint(.white.opacity(0.6))
                            .scaleEffect(y: 0.5)
                    } else if !voiceDownloaded {
                        GlassButton("Download", isPrimary: true) {
                            kokoro.downloadVoice(defaultVoice.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            Text("You can download more voices later in Voice Settings.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 8)

            Divider().opacity(0.3).padding(.horizontal, 10).padding(.top, 12)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - How to Use

    private var howToUseStep: some View {
        VStack(spacing: 0) {
            Text("How to Use Tama")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
                .padding(.bottom, 8)

            Text("A few things to know before you start.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .padding(.bottom, 16)

            VStack(spacing: 1) {
                howToRow(
                    index: 0,
                    icon: "⌥",
                    title: "Option + Space",
                    description: "Opens the prompt panel from anywhere on your Mac."
                )
                Divider().opacity(0.3).padding(.horizontal, 14)
                howToRow(
                    index: 1,
                    icon: "⌨",
                    title: "Type or talk",
                    description: "Just start typing, or speak — Tama picks up whichever you use."
                )
                Divider().opacity(0.3).padding(.horizontal, 14)
                howToRow(
                    index: 2,
                    icon: "⎋",
                    title: "Escape key",
                    description: "Stops the agent, goes back, or dismisses the panel."
                )
                Divider().opacity(0.3).padding(.horizontal, 14)
                howToRow(
                    index: 3,
                    icon: "🔔",
                    title: "Reminders & routines",
                    description: "Tama can remind you of things or run tasks on a schedule."
                )
                Divider().opacity(0.3).padding(.horizontal, 14)
                howToRow(
                    index: 4,
                    icon: "🌐",
                    title: "Files, web & more",
                    description: "Tama can read/write files, search the web, and automate browsers."
                )
                Divider().opacity(0.3).padding(.horizontal, 14)
                howToRow(
                    index: 5,
                    icon: "📑",
                    title: "Tabs at the top",
                    description: "Chats, Reminders, Routines, Tasks, Skills, and Tools — all in one panel."
                )
            }
        }
        .padding(.horizontal, 14)
    }

    private func howToRow(index: Int, icon: String, title: String, description: String) -> some View {
        let checked = howToChecks.contains(index)
        return HStack(spacing: 10) {
            Text(icon)
                .font(.system(size: 14))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(checked ? 0.5 : 0.9))
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(checked ? 0.3 : 0.45))
            }

            Spacer()

            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundColor(checked ? .green.opacity(0.9) : .white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            ButtonSound.shared.play()
            withAnimation(.easeInOut(duration: 0.2)) {
                if checked {
                    howToChecks.remove(index)
                } else {
                    howToChecks.insert(index)
                }
            }
        }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Ready

    private var readyStep: some View {
        VStack(spacing: 12) {
            Text("You're all set")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))

            Text("Press Option+Space to open the prompt panel.\nHold Option+Space for voice input.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: 6) {
                setupSummaryRow("AI Model", done: isLoggedIn)
                setupSummaryRow("Accessibility", done: accessibilityGranted)
                setupSummaryRow("Voice Model", done: kokoro.modelDownloaded && !kokoro.downloadedVoices.isEmpty)
                setupSummaryRow("Browser", done: hasBrowser)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .onAppear { refreshPermissions() }
    }

    private func setupSummaryRow(_ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundColor(done ? .green.opacity(0.9) : .white.opacity(0.3))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(done ? 0.9 : 0.45))
            Spacer()
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 8) {
            if step != .welcome {
                GlassButton("Back") {
                    direction = -1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
            }

            Spacer()

            if step == .ready {
                GlassButton("Get Started", isPrimary: true) {
                    logger.info("Onboarding completed")
                    onComplete()
                }
            } else if step == .login, !isLoggedIn {
                GlassButton("Skip") {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
                GlassButton("Next", isPrimary: true) {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
                .opacity(0.5)
            } else if step == .voice, !kokoro.modelDownloaded {
                GlassButton("Skip") {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
                GlassButton("Next", isPrimary: true) {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
                .opacity(0.5)
            } else if step == .howToUse {
                GlassButton("Next", isPrimary: true) {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
                .opacity(howToChecks.count == 6 ? 1.0 : 0.5)
            } else {
                GlassButton("Next", isPrimary: true) {
                    direction = 1
                    withAnimation {
                        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
