import AVFoundation
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import os

/// Manages Kokoro TTS model and voice downloads, loading, and audio generation.
/// All files are stored in ~/Library/Application Support/Tama/KokoroTTS/.
@MainActor
final class KokoroManager: ObservableObject {
    static let shared = KokoroManager()

    private let logger = Logger(subsystem: "com.unstablemind.tama", category: "kokoro")

    // MARK: - Published State

    @Published var modelDownloaded = false
    @Published var modelDownloading = false
    @Published var modelDownloadProgress: Double = 0

    @Published var downloadedVoices: Set<String> = []
    @Published var voiceDownloading: [String: Bool] = [:]
    @Published var voiceDownloadProgress: [String: Double] = [:]

    @Published var voiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "kokoroVoiceEnabled")
            // swiftformat:disable:next redundantSelf
            logger.info("Voice enabled changed to: \(self.voiceEnabled)")
        }
    }

    @Published var selectedVoice: String {
        didSet {
            UserDefaults.standard.set(selectedVoice, forKey: "kokoroSelectedVoice")
            // swiftformat:disable:next redundantSelf
            logger.info("Selected voice changed to: \(self.selectedVoice)")
        }
    }

    // MARK: - TTS Engine

    private var ttsEngine: KokoroTTS?
    private var loadedVoices: [String: MLXArray] = [:]

    // MARK: - Constants

    // swiftlint:disable:next modifier_order
    private nonisolated static let hfBaseURL = "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main"
    // swiftlint:disable:next modifier_order
    private nonisolated static let modelFileName = "kokoro-v1_0.safetensors"
    nonisolated static let sampleRate = KokoroTTS.Constants.samplingRate

    static let availableVoices: [VoiceInfo] = [
        VoiceInfo(id: "af_heart", name: "Heart", gender: .female, accent: "US English", grade: "A"),
        VoiceInfo(id: "af_bella", name: "Bella", gender: .female, accent: "US English", grade: "A-"),
        VoiceInfo(id: "af_sarah", name: "Sarah", gender: .female, accent: "US English", grade: "B"),
        VoiceInfo(id: "af_aoede", name: "Aoede", gender: .female, accent: "US English", grade: "B"),
        VoiceInfo(id: "bf_emma", name: "Emma", gender: .female, accent: "British English", grade: "B"),
        VoiceInfo(id: "af_nicole", name: "Nicole", gender: .female, accent: "US English", grade: "B"),
    ]

    // MARK: - Paths

    private var basePath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tama/KokoroTTS")
    }

    private var modelDir: URL { basePath.appendingPathComponent("model") }
    private var voicesDir: URL { basePath.appendingPathComponent("voices") }
    private var modelFile: URL { modelDir.appendingPathComponent(Self.modelFileName) }

    // MARK: - Init

    private init() {
        voiceEnabled = UserDefaults.standard.object(forKey: "kokoroVoiceEnabled") as? Bool ?? true
        selectedVoice = UserDefaults.standard.string(forKey: "kokoroSelectedVoice") ?? "af_heart"
        // swiftformat:disable:next redundantSelf
        logger.info("KokoroManager initializing, voice enabled: \(self.voiceEnabled), voice: \(self.selectedVoice)")
        checkExistingFiles()
    }

    /// Whether Kokoro is ready to generate speech (model loaded + voice selected + loaded).
    var isReady: Bool { ttsEngine != nil && loadedVoices[selectedVoice] != nil }

    /// Whether model and at least the selected voice are downloaded on disk (no memory load).
    var isDownloaded: Bool { modelDownloaded && downloadedVoices.contains(selectedVoice) }

    // MARK: - File Checks

    private func checkExistingFiles() {
        // Migrate from old "Tamagotchai" path if needed
        migrateFromOldPath()

        let modelPath = modelFile.path
        modelDownloaded = FileManager.default.fileExists(atPath: modelPath)
        // swiftformat:disable:next redundantSelf
        logger.info("Model file check at \(modelPath): \(self.modelDownloaded)")

        if FileManager.default.fileExists(atPath: voicesDir.path) {
            let enumerator = FileManager.default.enumerator(atPath: voicesDir.path)
            while let file = enumerator?.nextObject() as? String {
                if file.hasSuffix(".safetensors") {
                    let voiceId = file.replacingOccurrences(of: ".safetensors", with: "")
                    downloadedVoices.insert(voiceId)
                    logger.info("Found existing voice: \(voiceId)")
                }
            }
        }

        let ready = isReady
        let voiceCount = downloadedVoices.count
        let hasModel = modelDownloaded
        logger.info("Startup complete — model: \(hasModel), voices: \(voiceCount), ready: \(ready)")
    }

    /// Migrates Kokoro files from the old "Tamagotchai" directory to the new "Tama" directory.
    private func migrateFromOldPath() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldPath = appSupport.appendingPathComponent("Tamagotchai/KokoroTTS")
        let newPath = basePath

        guard FileManager.default.fileExists(atPath: oldPath.path) else {
            return
        }

        logger.info("Migrating Kokoro files from \(oldPath.path) to \(newPath.path)")

        do {
            // Create directories if needed
            try FileManager.default.createDirectory(at: newPath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)

            // Migrate model directory
            let oldModelDir = oldPath.appendingPathComponent("model")
            if FileManager.default.fileExists(atPath: oldModelDir.path) {
                let modelFiles = try FileManager.default.contentsOfDirectory(
                    at: oldModelDir,
                    includingPropertiesForKeys: nil
                )
                for file in modelFiles {
                    let dest = modelDir.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: dest)
                    logger.info("Migrated model file: \(file.lastPathComponent)")
                }
            }

            // Migrate voices directory
            let oldVoicesDir = oldPath.appendingPathComponent("voices")
            if FileManager.default.fileExists(atPath: oldVoicesDir.path) {
                let voiceFiles = try FileManager.default.contentsOfDirectory(
                    at: oldVoicesDir,
                    includingPropertiesForKeys: nil
                )
                for file in voiceFiles {
                    let dest = voicesDir.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: dest)
                    logger.info("Migrated voice file: \(file.lastPathComponent)")
                }
            }

            // Remove old directory if empty
            try? FileManager.default.removeItem(at: oldPath)
            logger.info("Migration complete")
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Lazy Loading

    /// Loads the TTS engine and all downloaded voice embeddings into memory on demand.
    /// No-op if everything is already loaded.
    func ensureLoaded() {
        // swiftformat:disable:next redundantSelf
        logger.info("ensureLoaded called — engine loaded: \(self.ttsEngine != nil)")
        loadEngine()
        for voiceId in downloadedVoices {
            loadVoiceEmbedding(voiceId)
        }
    }

    /// Frees the TTS engine, voice embeddings, and GPU memory.
    func unload() {
        let hadEngine = ttsEngine != nil
        let voiceCount = loadedVoices.count
        ttsEngine = nil
        loadedVoices.removeAll()
        // MLX caches Metal GPU buffers aggressively — must flush explicitly
        MLX.Memory.cacheLimit = 0
        MLX.Memory.clearCache()
        logger.info("Unloaded TTS engine (was loaded: \(hadEngine)), \(voiceCount) voice(s), GPU cache cleared")
    }

    // MARK: - Model Download

    func downloadModel() {
        guard !modelDownloading else {
            logger.warning("Model download already in progress")
            return
        }
        modelDownloading = true
        modelDownloadProgress = 0

        let url = URL(string: "\(Self.hfBaseURL)/\(Self.modelFileName)")!
        let destDir = modelDir
        let destFile = modelFile

        logger.info("Starting model download from \(url.absoluteString)")

        Task {
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                try await downloadFile(from: url, to: destFile) { [weak self] progress in
                    Task { @MainActor in
                        self?.modelDownloadProgress = progress
                    }
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: destFile.path))?[
                    .size
                ] as? Int64 ?? 0
                logger.info("Model saved: \(destFile.path) (\(fileSize) bytes)")

                modelDownloaded = true
                modelDownloading = false
                modelDownloadProgress = 1.0
                loadEngine()
            } catch {
                logger.error("Model download failed: \(error.localizedDescription)")
                modelDownloading = false
            }
        }
    }

    // MARK: - Voice Download

    func downloadVoice(_ voiceId: String) {
        guard voiceDownloading[voiceId] != true else {
            logger.warning("Voice \(voiceId) download already in progress")
            return
        }
        voiceDownloading[voiceId] = true
        voiceDownloadProgress[voiceId] = 0

        let url = URL(string: "\(Self.hfBaseURL)/voices/\(voiceId).safetensors")!
        let destDir = voicesDir
        let destFile = destDir.appendingPathComponent("\(voiceId).safetensors")

        logger.info("Starting voice download: \(voiceId) from \(url.absoluteString)")

        Task {
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

                try await downloadFile(from: url, to: destFile) { [weak self] progress in
                    Task { @MainActor in
                        self?.voiceDownloadProgress[voiceId] = progress
                    }
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: destFile.path))?[
                    .size
                ] as? Int64 ?? 0
                logger.info("Voice \(voiceId) saved: \(destFile.path) (\(fileSize) bytes)")

                downloadedVoices.insert(voiceId)
                voiceDownloading[voiceId] = false
                voiceDownloadProgress[voiceId] = 1.0
                loadVoiceEmbedding(voiceId)
            } catch {
                logger.error("Voice \(voiceId) download failed: \(error.localizedDescription)")
                voiceDownloading[voiceId] = false
            }
        }
    }

    // MARK: - Engine Loading

    private func loadEngine() {
        guard ttsEngine == nil, modelDownloaded else {
            let loaded = ttsEngine != nil
            let downloaded = modelDownloaded
            logger.debug("loadEngine skipped — already loaded: \(loaded), downloaded: \(downloaded)")
            return
        }
        let path = modelFile
        logger.info("Loading Kokoro TTS engine from \(path.path)…")
        let startTime = CFAbsoluteTimeGetCurrent()
        ttsEngine = KokoroTTS(modelPath: path)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Kokoro TTS engine loaded in \(String(format: "%.2f", elapsed))s")
    }

    private func loadVoiceEmbedding(_ voiceId: String) {
        guard loadedVoices[voiceId] == nil else {
            logger.debug("loadVoiceEmbedding skipped — \(voiceId) already loaded")
            return
        }
        let file = voicesDir.appendingPathComponent("\(voiceId).safetensors")
        guard FileManager.default.fileExists(atPath: file.path) else {
            logger.warning("Voice file missing: \(file.path)")
            return
        }

        do {
            let arrays = try MLX.loadArrays(url: file)
            logger.debug("Voice \(voiceId) safetensors keys: \(arrays.keys.joined(separator: ", "))")
            // Voice safetensors files use "voice" as the key (per mlx-swift-audio VoiceLoader)
            if let embedding = arrays["voice"] ?? arrays.values.first {
                loadedVoices[voiceId] = embedding
                logger.info("Loaded voice embedding: \(voiceId) shape=\(embedding.shape)")
            } else {
                logger.error("Voice \(voiceId) safetensors has no arrays")
            }
        } catch {
            logger.error("Failed to load voice \(voiceId): \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Generation

    /// Snapshot of state needed for off-main-thread audio generation.
    struct GenerationContext: @unchecked Sendable {
        let engine: KokoroTTS
        let voice: MLXArray
        let voiceId: String
        let language: Language
    }

    /// Captures engine + voice state for off-main-thread generation. Returns nil if not ready.
    /// Automatically calls `ensureLoaded()` if the engine or voice isn't loaded yet.
    func captureGenerationContext() -> GenerationContext? {
        if ttsEngine == nil || loadedVoices[selectedVoice] == nil {
            logger.info("captureGenerationContext triggering ensureLoaded()")
            ensureLoaded()
        }
        guard let engine = ttsEngine, let voice = loadedVoices[selectedVoice] else { return nil }
        let language: Language = selectedVoice.hasPrefix("b") ? .enGB : .enUS
        return GenerationContext(engine: engine, voice: voice, voiceId: selectedVoice, language: language)
    }

    /// Generates audio off the main thread using a captured context. Thread-safe.
    nonisolated static func generateAudioBufferOffMain(text: String, context: GenerationContext) -> AVAudioPCMBuffer? {
        let logger = Logger(subsystem: "com.unstablemind.tama", category: "kokoro")
        logger.debug("Generating audio — voice: \(context.voiceId), text: \(text.prefix(80))…")

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let (audio, _) = try context.engine.generateAudio(
                voice: context.voice,
                language: context.language,
                text: text
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let duration = Double(audio.count) / Double(sampleRate)
            let rtf = elapsed > 0 ? duration / elapsed : 0
            let durStr = String(format: "%.2f", duration)
            let elapStr = String(format: "%.2f", elapsed)
            let rtfStr = String(format: "%.1f", rtf)
            logger.info(
                "Audio generated — \(audio.count) samples, \(durStr)s audio in \(elapStr)s (\(rtfStr)x realtime)"
            )
            return createBuffer(from: audio)
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.error(
                "Audio generation failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Generates audio on the main actor (used for previews in VoiceSettingsView).
    func generateAudioBuffer(text: String) -> AVAudioPCMBuffer? {
        guard let ctx = captureGenerationContext() else { return nil }
        return Self.generateAudioBufferOffMain(text: text, context: ctx)
    }

    // Creates an AVAudioPCMBuffer from a float audio array.
    // swiftlint:disable:next modifier_order
    private nonisolated static func createBuffer(from audio: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(audio.count)
        let dst = buffer.floatChannelData![0]
        audio.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: audio.count)
        }

        return buffer
    }
}

// MARK: - Voice Info

struct VoiceInfo: Identifiable {
    enum Gender: String { case female, male }

    let id: String
    let name: String
    let gender: Gender
    let accent: String
    let grade: String
}
