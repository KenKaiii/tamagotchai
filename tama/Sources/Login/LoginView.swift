import SwiftUI

struct LoginView: View {
    @State private var apiKeyInputs: [AIProvider: String] = [:]
    @State private var validatingProvider: AIProvider?
    @State private var isAuthenticating = false
    @State private var errorMessage: String?
    @State private var selectedModelId: String

    let onLoginStateChanged: (Bool) -> Void

    init(onLoginStateChanged: @escaping (Bool) -> Void) {
        self.onLoginStateChanged = onLoginStateChanged
        _selectedModelId = State(initialValue: ProviderStore.shared.selectedModel.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("AI Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.top, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 12) {
                    modelSelector
                    providerSections
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)

            if let errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }

            Divider().opacity(0.3)
                .padding(.top, 8)

            HStack {
                Spacer()
                GlassButton("Done", isPrimary: true) {
                    LoginWindowController.dismiss()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        VStack(spacing: 6) {
            Text("Active Model")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.45))

            let available = ModelRegistry.availableModels()

            if available.isEmpty {
                Text("Add an API key below to get started")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 4)
            } else {
                modelDropdown(models: available)
            }
        }
    }

    private func modelDropdown(models: [ModelInfo]) -> some View {
        Menu {
            ForEach(models) { model in
                Button {
                    selectedModelId = model.id
                    ProviderStore.shared.setSelectedModel(model)
                } label: {
                    HStack {
                        Text(model.name)
                        Text("(\(model.provider.displayName))")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } label: {
            HStack {
                if let current = models.first(where: { $0.id == selectedModelId }) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Text(current.provider.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                } else {
                    Text("Select a model")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Provider Sections

    private var providerSections: some View {
        ForEach(AIProvider.allCases) { provider in
            providerRow(provider)
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
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
                    connectedBadge
                }
            }

            if ProviderStore.shared.hasCredentials(for: provider) {
                connectedRow(provider)
            } else if provider.usesOAuth {
                oauthRow(provider)
            } else {
                addKeyRow(provider)
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

    private var connectedBadge: some View {
        Text("Connected")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.green.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15))
            .cornerRadius(4)
    }

    private func connectedRow(_ provider: AIProvider) -> some View {
        HStack {
            Text(provider.usesOAuth ? "Signed in" : "API key configured")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
            GlassButton(provider.usesOAuth ? "Sign Out" : "Remove") {
                ProviderStore.shared.removeCredential(for: provider)
                onLoginStateChanged(ProviderStore.shared.hasAnyCredentials)
                selectedModelId = ProviderStore.shared.selectedModel.id
            }
        }
    }

    private func oauthRow(_ provider: AIProvider) -> some View {
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
    }

    private func addKeyRow(_ provider: AIProvider) -> some View {
        HStack(spacing: 8) {
            TextField("Paste API key", text: binding(for: provider))
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
                    addApiKey(key, for: provider)
                }
                .disabled(key.isEmpty)
                .opacity(key.isEmpty ? 0.5 : 1)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.25))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func binding(for provider: AIProvider) -> Binding<String> {
        Binding(
            get: { apiKeyInputs[provider] ?? "" },
            set: { apiKeyInputs[provider] = $0 }
        )
    }

    private func startOAuth(for provider: AIProvider) {
        errorMessage = nil
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

                let available = ModelRegistry.availableModels()
                if !available.contains(where: { $0.id == selectedModelId }) {
                    let defaultModel = ModelRegistry.defaultModel(for: provider)
                    selectedModelId = defaultModel.id
                    ProviderStore.shared.setSelectedModel(defaultModel)
                }

                onLoginStateChanged(true)
            } catch {
                errorMessage = error.localizedDescription
            }
            isAuthenticating = false
        }
    }

    private func addApiKey(_ key: String, for provider: AIProvider) {
        errorMessage = nil
        validatingProvider = provider

        Task {
            let error = await ProviderStore.shared.validateApiKey(key, for: provider)
            validatingProvider = nil

            if let error {
                errorMessage = error
                return
            }

            ProviderStore.shared.setCredential(.apiKey(key), for: provider)
            apiKeyInputs[provider] = nil

            let available = ModelRegistry.availableModels()
            if !available.contains(where: { $0.id == selectedModelId }) {
                let defaultModel = ModelRegistry.defaultModel(for: provider)
                selectedModelId = defaultModel.id
                ProviderStore.shared.setSelectedModel(defaultModel)
            }

            onLoginStateChanged(true)
        }
    }
}
