import SwiftUI

struct UpdateView: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Software Update")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.top, 10)
                .padding(.bottom, 8)

            stateContent
                .frame(minHeight: 80)
                .padding(.horizontal, 14)

            Divider().opacity(0.3)
                .padding(.top, 8)

            bottomBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
        .task {
            await updater.checkForUpdate()
        }
    }

    // MARK: - State Content

    @ViewBuilder
    private var stateContent: some View {
        switch updater.state {
        case .idle, .checking:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                Text("Checking for updates…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

        case let .upToDate(currentVersion):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.green.opacity(0.9))
                Text("You're up to date")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text("Version \(currentVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)

        case let .available(currentVersion, newVersion):
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue.opacity(0.9))
                Text("Update Available")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text("\(currentVersion) → \(newVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)

        case let .downloading(progress):
            VStack(spacing: 10) {
                ProgressView(value: progress)
                    .tint(.white.opacity(0.7))
                    .frame(maxWidth: 200)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

        case .installing:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                Text("Installing update…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)

        case let .failed(message):
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("Update failed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if case .failed = updater.state {
                GlassButton("Retry") {
                    Task { await updater.checkForUpdate() }
                }
            }

            Spacer()

            if case .available = updater.state {
                GlassButton("Update Now", isPrimary: true) {
                    Task { await updater.performUpdate() }
                }
            }

            GlassButton("Done", isPrimary: isTerminalState) {
                UpdateWindowController.dismiss()
            }
        }
    }

    private var isTerminalState: Bool {
        switch updater.state {
        case .available:
            false
        default:
            true
        }
    }
}
