import AppKit

/// Displays 3 animated skeleton bars with a shimmer gradient, used as a loading placeholder.
final class SkeletonView: NSView {
    private let barLayers: [CALayer] = {
        let widthFractions: [CGFloat] = [0.65, 0.85, 0.45]
        return widthFractions.map { _ in
            let layer = CALayer()
            layer.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            layer.cornerRadius = 6
            return layer
        }
    }()

    private let shimmerLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor(white: 1.0, alpha: 0.12).cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [-1, -0.5, 0].map { NSNumber(value: $0) }
        return gradient
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in barLayers {
            layer?.addSublayer(bar)
        }
        layer?.addSublayer(shimmerLayer)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = 12
        let spacing: CGFloat = 10
        let widthFractions: [CGFloat] = [0.65, 0.85, 0.45]

        for (i, bar) in barLayers.enumerated() {
            let y = CGFloat(i) * (barHeight + spacing)
            bar.frame = CGRect(
                x: 0,
                y: y,
                width: bounds.width * widthFractions[i],
                height: barHeight
            )
        }
        shimmerLayer.frame = bounds
    }

    func startAnimating() {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0].map { NSNumber(value: $0) }
        animation.toValue = [1.0, 1.5, 2.0].map { NSNumber(value: $0) }
        animation.duration = 1.2
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "shimmer")
    }

    func stopAnimating() {
        shimmerLayer.removeAnimation(forKey: "shimmer")
    }
}
