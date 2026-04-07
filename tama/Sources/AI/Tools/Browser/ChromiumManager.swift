import Foundation
import os

/// Manages downloading and lifecycle of Chrome for Testing (bundled Chromium browser).
/// Stored at ~/Library/Application Support/Tama/Chromium/.
@MainActor
final class ChromiumManager: ObservableObject {
    static let shared = ChromiumManager()

    private let logger = Logger(subsystem: "com.unstablemind.tama", category: "chromium")

    // MARK: - Published State

    @Published var isDownloaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0

    // MARK: - Constants

    private static let versionURL =
        "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
    private static let appName = "Google Chrome for Testing.app"

    // MARK: - Paths

    private var chromiumDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tama/Chromium")
    }

    private var appURL: URL {
        chromiumDir.appendingPathComponent(Self.appName)
    }

    /// Path to the Chrome for Testing executable, or nil if not downloaded.
    var chromiumExecutablePath: String? {
        let path = appURL
            .appendingPathComponent("Contents/MacOS/Google Chrome for Testing")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Init

    private init() {
        checkExisting()
    }

    private func checkExisting() {
        isDownloaded = chromiumExecutablePath != nil
        // swiftformat:disable:next redundantSelf
        logger.info("Chromium check — downloaded: \(self.isDownloaded)")
    }

    // MARK: - Download

    func downloadChromium() {
        guard !isDownloading else {
            logger.warning("Chromium download already in progress")
            return
        }
        isDownloading = true
        downloadProgress = 0

        Task {
            do {
                // 1. Fetch version JSON to get the right download URL.
                let zipURL = try await fetchDownloadURL()
                logger.info("Chromium download URL: \(zipURL.absoluteString)")

                // 2. Download zip to a temp file.
                let tempZip = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chrome-for-testing-\(UUID().uuidString).zip")

                try await downloadFile(from: zipURL, to: tempZip) { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress * 0.9 // Reserve 10% for extraction
                    }
                }

                logger.info("Zip downloaded to \(tempZip.path)")

                // 3. Strip quarantine from the zip BEFORE extracting so the .app
                //    inside never inherits it. Running xattr -cr on an .app bundle
                //    triggers the macOS "App Management" permission prompt.
                let stripQuarantine = Process()
                stripQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                stripQuarantine.arguments = ["-d", "com.apple.quarantine", tempZip.path]
                try? stripQuarantine.run()
                stripQuarantine.waitUntilExit()

                // 4. Extract zip.
                let tempExtractDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chrome-extract-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)

                let dittoProcess = Process()
                dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                dittoProcess.arguments = ["-xk", tempZip.path, tempExtractDir.path]
                try dittoProcess.run()
                dittoProcess.waitUntilExit()

                guard dittoProcess.terminationStatus == 0 else {
                    throw ChromiumManagerError.extractionFailed
                }

                downloadProgress = 0.95

                // 5. Find the .app in the extracted directory.
                let platform: String
                #if arch(arm64)
                platform = "chrome-mac-arm64"
                #else
                platform = "chrome-mac-x64"
                #endif

                let extractedApp = tempExtractDir
                    .appendingPathComponent(platform)
                    .appendingPathComponent(Self.appName)

                guard FileManager.default.fileExists(atPath: extractedApp.path) else {
                    throw ChromiumManagerError.appNotFoundInZip
                }

                // 6. Move .app to final location.
                try FileManager.default.createDirectory(at: chromiumDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: appURL.path) {
                    try FileManager.default.removeItem(at: appURL)
                }
                try FileManager.default.moveItem(at: extractedApp, to: appURL)

                // 7. Clean up temp files.
                try? FileManager.default.removeItem(at: tempZip)
                try? FileManager.default.removeItem(at: tempExtractDir)

                isDownloaded = true
                isDownloading = false
                downloadProgress = 1.0
                logger.info("Chromium installed at \(self.appURL.path)")
            } catch {
                logger.error("Chromium download failed: \(error.localizedDescription)")
                isDownloading = false
                downloadProgress = 0
            }
        }
    }

    // MARK: - Delete

    func deleteChromium() {
        do {
            if FileManager.default.fileExists(atPath: appURL.path) {
                try FileManager.default.removeItem(at: appURL)
            }
            isDownloaded = false
            downloadProgress = 0
            logger.info("Chromium deleted")
        } catch {
            logger.error("Failed to delete Chromium: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func fetchDownloadURL() async throws -> URL {
        guard let url = URL(string: Self.versionURL) else {
            throw ChromiumManagerError.invalidVersionURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channels = json["channels"] as? [String: Any],
              let stable = channels["Stable"] as? [String: Any],
              let downloads = stable["downloads"] as? [String: Any],
              let chromeDownloads = downloads["chrome"] as? [[String: Any]]
        else {
            throw ChromiumManagerError.unexpectedAPIResponse
        }

        let targetPlatform: String
        #if arch(arm64)
        targetPlatform = "mac-arm64"
        #else
        targetPlatform = "mac-x64"
        #endif

        guard let entry = chromeDownloads.first(where: { ($0["platform"] as? String) == targetPlatform }),
              let urlString = entry["url"] as? String,
              let downloadURL = URL(string: urlString)
        else {
            throw ChromiumManagerError.platformNotFound(targetPlatform)
        }

        return downloadURL
    }
}

// MARK: - Errors

enum ChromiumManagerError: LocalizedError {
    case invalidVersionURL
    case unexpectedAPIResponse
    case platformNotFound(String)
    case extractionFailed
    case appNotFoundInZip

    var errorDescription: String? {
        switch self {
        case .invalidVersionURL:
            "Invalid Chrome for Testing version URL"
        case .unexpectedAPIResponse:
            "Unexpected response from Chrome for Testing API"
        case let .platformNotFound(platform):
            "No download found for platform: \(platform)"
        case .extractionFailed:
            "Failed to extract Chrome zip archive"
        case .appNotFoundInZip:
            "Chrome for Testing app not found in extracted archive"
        }
    }
}
