import AppKit

/// An animated audio level visualizer with vertical bars, styled to match the HUD panel aesthetic.
final class AudioWaveformView: NSView {
    private let barCount = 12
    private let barSpacing: CGFloat = 3
    private let barCornerRadius: CGFloat = 1.5
    private let barMinHeight: CGFloat = 3
    private let barColor = NSColor.white.withAlphaComponent(0.7)

    /// Current audio level (0.0–1.0).
    private var audioLevel: Double = 0

    /// Per-bar heights for smooth animated transitions.
    private var barHeights: [CGFloat] = []

    /// Display link for smooth animation.
    private var displayLink: CVDisplayLink?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        barHeights = Array(repeating: barMinHeight, count: barCount)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the current audio level (0.0–1.0). Call from main thread.
    func setAudioLevel(_ level: Double) {
        audioLevel = level
    }

    func startAnimating() {
        stopAnimating()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async { self?.updateBars() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    func stopAnimating() {
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
        barHeights = Array(repeating: barMinHeight, count: barCount)
        needsDisplay = true
    }

    private func updateBars() {
        let maxBarHeight = bounds.height - 2
        for i in 0 ..< barCount {
            let randomFactor = CGFloat.random(in: 0.4 ... 1.0)
            let targetHeight = max(barMinHeight, CGFloat(audioLevel) * maxBarHeight * randomFactor)
            barHeights[i] += (targetHeight - barHeights[i]) * 0.3
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)

        let totalBarsWidth = CGFloat(barCount) * barSpacing * 2
        let startX = (bounds.width - totalBarsWidth) / 2

        barColor.setFill()

        for i in 0 ..< barCount {
            let barWidth = barSpacing * 1.5
            let barHeight = min(barHeights[i], bounds.height - 2)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (bounds.height - barHeight) / 2

            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: barCornerRadius, yRadius: barCornerRadius)
            path.fill()
        }
    }
}
