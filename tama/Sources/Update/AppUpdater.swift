import AppKit
import Foundation
import os

private let logger = Logger(
    subsystem: "com.unstablemind.tama",
    category: "updater"
)

// MARK: - Update State

enum UpdateState {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(currentVersion: String, newVersion: String)
    case downloading(progress: Double)
    case installing
    case failed(String)
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case noCurrentVersion
    case networkError(String)
    case noReleaseFound
    case noDMGAsset
    case mountFailed(String)
    case appNotFoundInDMG
    case installFailed(String)
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCurrentVersion:
            "Could not determine the current app version."
        case let .networkError(detail):
            "Network error: \(detail)"
        case .noReleaseFound:
            "No release found on GitHub."
        case .noDMGAsset:
            "No DMG file found in the latest release."
        case let .mountFailed(detail):
            "Failed to mount the update DMG: \(detail)"
        case .appNotFoundInDMG:
            "Could not find Tama.app in the mounted DMG."
        case let .installFailed(detail):
            "Failed to install the update: \(detail)"
        case let .relaunchFailed(detail):
            "Failed to relaunch the app: \(detail)"
        }
    }
}

// MARK: - GitHub Release Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - App Updater

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private(set) var state: UpdateState = .idle

    private let releasesURL = URL(
        string: "https://api.github.com/repos/KenKaiii/tamagotchai/releases/latest"
    )!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var dmgDownloadURL: URL?

    // MARK: - Check for Update

    func checkForUpdate() async {
        let version = currentVersion
        state = .checking
        logger.info("Checking for updates — current version: \(version)")

        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Tama/\(version)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateError.networkError("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                throw UpdateError.networkError("HTTP \(httpResponse.statusCode)")
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^v", with: "", options: .regularExpression)

            guard let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                throw UpdateError.noDMGAsset
            }

            dmgDownloadURL = URL(string: dmgAsset.browserDownloadURL)

            logger.info("Latest release: \(remoteVersion), DMG: \(dmgAsset.name)")

            if isVersionNewer(remote: remoteVersion, current: version) {
                state = .available(currentVersion: version, newVersion: remoteVersion)
                logger.info("Update available: \(version) → \(remoteVersion)")
            } else {
                state = .upToDate(currentVersion: version)
                logger.info("App is up to date")
            }
        } catch let error as UpdateError {
            state = .failed(error.localizedDescription)
            logger.error("Update check failed: \(error.localizedDescription)")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Update check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Perform Update

    func performUpdate() async {
        guard let downloadURL = dmgDownloadURL else {
            state = .failed(UpdateError.noDMGAsset.localizedDescription)
            return
        }

        state = .downloading(progress: 0)
        logger.info("Downloading update from \(downloadURL.absoluteString)")

        let tempDir = FileManager.default.temporaryDirectory
        let dmgPath = tempDir.appendingPathComponent("TamaUpdate.dmg")

        do {
            // Download DMG with progress
            try await downloadFile(from: downloadURL, to: dmgPath) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress)
                }
            }

            logger.info("Download complete, installing…")
            state = .installing

            // Mount, copy, unmount, relaunch
            try await installFromDMG(at: dmgPath)
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("Update failed: \(error.localizedDescription)")
            // Clean up DMG on failure
            try? FileManager.default.removeItem(at: dmgPath)
        }
    }

    // MARK: - Install from DMG

    private func installFromDMG(at dmgPath: URL) async throws {
        let mountPoint = "/tmp/TamaUpdate"

        // Remove stale mount point if it exists
        if FileManager.default.fileExists(atPath: mountPoint) {
            _ = try? runShell("/usr/bin/hdiutil", "detach", mountPoint, "-force")
        }

        // Mount DMG
        let mountResult = try runShell(
            "/usr/bin/hdiutil", "attach", dmgPath.path,
            "-mountpoint", mountPoint,
            "-noverify", "-nobrowse", "-noautoopen"
        )
        logger.info("Mount result: \(mountResult)")

        defer {
            // Always unmount and clean up
            _ = try? runShell("/usr/bin/hdiutil", "detach", mountPoint, "-force")
            try? FileManager.default.removeItem(at: dmgPath)
            logger.info("Cleaned up mount point and DMG")
        }

        // Find the .app in the mounted DMG
        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil
        )
        guard let appSource = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFoundInDMG
        }

        // Determine current app location
        let currentAppURL = Bundle.main.bundleURL
        let parentDir = currentAppURL.deletingLastPathComponent()
        let appName = currentAppURL.lastPathComponent
        let destinationURL = parentDir.appendingPathComponent(appName)

        logger.info("Replacing \(destinationURL.path) with \(appSource.path)")

        // Remove old app and copy new one
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: appSource, to: destinationURL)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }

        logger.info("Update installed successfully, relaunching…")

        // Relaunch via background shell
        relaunch(appPath: destinationURL.path)
    }

    // MARK: - Shell Helper

    @discardableResult
    private func runShell(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed("Exit code \(process.terminationStatus): \(output)")
        }

        return output
    }

    // MARK: - Relaunch

    private func relaunch(appPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Shell script waits for this process to exit, then opens the new app
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; \
        open "\(appPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        do {
            try process.run()
            logger.info("Relaunch script spawned, terminating current process")
            NSApplication.shared.terminate(nil)
        } catch {
            logger.error("Failed to spawn relaunch script: \(error.localizedDescription)")
            state = .failed(UpdateError.relaunchFailed(error.localizedDescription).localizedDescription)
        }
    }

    // MARK: - Version Comparison

    /// Returns true if `remote` is newer than `current` using semver comparison.
    private func isVersionNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0 ..< max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }

        return false
    }
}
