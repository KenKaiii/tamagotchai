import AVFoundation
import os
import SwiftUI

/// Voice settings panel for configuring Kokoro TTS voices.
struct VoiceSettingsView: View {
    @ObservedObject private var manager = KokoroManager.shared
    @State private var previewingVoice: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Voice Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.top, 10)
                .padding(.bottom, 8)

            modelSection

            Divider().opacity(0.3).padding(.horizontal, 14)

            voiceListSection

            Divider().opacity(0.3).padding(.horizontal, 14)

            footerSection
        }
        .frame(width: 380)
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: manager.modelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(manager.modelDownloaded ? .green.opacity(0.9) : .white.opacity(0.6))
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Kokoro TTS Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text(manager.modelDownloaded ? "Ready" : "~350 MB download required")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                if !manager.modelDownloaded {
                    if manager.modelDownloading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        GlassButton("Download", isPrimary: true) {
                            manager.downloadModel()
                        }
                    }
                }
            }

            if manager.modelDownloading {
                ProgressView(value: manager.modelDownloadProgress)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(y: 0.5)
            }

            if !manager.modelDownloaded, !manager.modelDownloading {
                Text("Voice disabled until model is downloaded")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.8))
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Voice List

    private var voiceListSection: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(KokoroManager.availableVoices) { voice in
                    voiceRow(voice)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 320)
        .scrollClipDisabled()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func voiceRow(_ voice: VoiceInfo) -> some View {
        let isDownloaded = manager.downloadedVoices.contains(voice.id)
        let isSelected = manager.selectedVoice == voice.id
        let isDownloading = manager.voiceDownloading[voice.id] == true
        let isPreviewing = previewingVoice == voice.id

        return HStack(spacing: 8) {
            // Play/preview button
            playButton(for: voice, isDownloaded: isDownloaded, isPreviewing: isPreviewing)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(voice.name)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(.white.opacity(0.9))

                    Text(voice.grade)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(gradeColor(voice.grade).opacity(0.3))
                        )
                }
                Text("\(voice.gender == .female ? "♀" : "♂") \(voice.accent)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            if isDownloading {
                ProgressView(value: manager.voiceDownloadProgress[voice.id] ?? 0)
                    .frame(width: 40)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(y: 0.5)
            } else if isDownloaded {
                if !isSelected {
                    GlassButton("Select", isPrimary: true) {
                        manager.selectedVoice = voice.id
                    }
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green.opacity(0.9))
                        .padding(.horizontal, 6)
                }
            } else if manager.modelDownloaded {
                GlassButton("Download") {
                    manager.downloadVoice(voice.id)
                }
            } else {
                Text("Need model")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
        )
    }

    // MARK: - Play Button

    @ViewBuilder
    private func playButton(for voice: VoiceInfo, isDownloaded: Bool, isPreviewing: Bool) -> some View {
        if isPreviewing {
            // Animated bars while previewing
            HStack(spacing: 1.5) {
                ForEach(0 ..< 3, id: \.self) { i in
                    SoundBar(index: i)
                }
            }
            .frame(width: 16, height: 14)
            .onTapGesture {
                stopPreview()
            }
        } else if isDownloaded, manager.modelDownloaded {
            Button {
                previewVoice(voice.id)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 16, height: 14)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        } else {
            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 14, height: 14)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 7))
                        .foregroundColor(.white.opacity(0.2))
                )
                .frame(width: 16)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 8) {
            if !manager.downloadedVoices.isEmpty, manager.modelDownloaded {
                Text("Active: \(voiceName(manager.selectedVoice))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            GlassButton("Done", isPrimary: true) {
                VoiceSettingsController.dismiss()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": .green
        case "A-": .green
        case "B", "B-": .blue
        case "C+", "C": .orange
        default: .gray
        }
    }

    private func voiceName(_ id: String) -> String {
        KokoroManager.availableVoices.first(where: { $0.id == id })?.name ?? id
    }

    private func previewVoice(_ voiceId: String) {
        stopPreview()
        previewingVoice = voiceId

        Task {
            let previousVoice = manager.selectedVoice
            manager.selectedVoice = voiceId
            if let buffer = manager.generateAudioBuffer(text: "Hello! I'm your new voice assistant.") {
                AudioPreviewPlayer.play(buffer) {
                    Task { @MainActor in
                        if previewingVoice == voiceId {
                            previewingVoice = nil
                        }
                    }
                }
            } else {
                previewingVoice = nil
            }
            manager.selectedVoice = previousVoice
        }
    }

    private func stopPreview() {
        previewingVoice = nil
        AudioPreviewPlayer.stop()
    }
}

// MARK: - Sound Bar Animation

private struct SoundBar: View {
    let index: Int
    @State private var height: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.blue.opacity(0.9))
            .frame(width: 3, height: height)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15)
                ) {
                    height = 12
                }
            }
    }
}

// MARK: - Audio Preview Player

/// Plays audio buffers for voice preview, isolated from the main actor.
final class AudioPreviewPlayer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.unstablemind.tamagotchai", category: "voice")

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var completion: (() -> Void)?

    private static let instance = AudioPreviewPlayer()

    static func play(_ buffer: AVAudioPCMBuffer, onComplete: @escaping () -> Void) {
        let inst = instance
        inst.stopInternal()

        inst.completion = onComplete

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        do {
            try engine.start()
        } catch {
            logger.error("Failed to start audio engine for voice preview: \(error.localizedDescription)")
            onComplete()
            return
        }

        node.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            let cb = inst.completion
            inst.completion = nil
            cb?()
        }
        node.play()

        inst.engine = engine
        inst.player = node
    }

    static func stop() {
        instance.stopInternal()
    }

    private func stopInternal() {
        completion = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }
}
