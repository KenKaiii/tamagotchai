import AppKit

/// Draws a cartoon mascot avatar for the menu bar — a cute robot-like creature
/// with big eyes, small antenna, and a friendly expression.
/// Rendered entirely with vector paths so it looks crisp at any scale.
///
/// The icon is an 18×18 pt template image so macOS handles light/dark tinting.
/// Supports 10 mood variants via `MenuBarMood.Mood`.
enum MenuBarIcon {
    /// Creates the menu bar icon as a template `NSImage` for the given mood.
    static func create(
        mood: MenuBarMood.Mood = .afternoon,
        animationFrame: Bool = false,
        size: CGFloat = 18
    ) -> NSImage {
        let image = NSImage(
            size: NSSize(width: size, height: size),
            flipped: false
        ) { rect in
            Self.draw(in: rect, mood: mood, animationFrame: animationFrame)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Creates a squircle session icon — the mascot face on a rounded-rect background.
    /// Returns a non-template image tinted with `labelColor` for use in session lists.
    static func sessionIcon(mood: MenuBarMood.Mood, size: CGFloat = 28) -> NSImage {
        let image = NSImage(
            size: NSSize(width: size, height: size),
            flipped: false
        ) { rect in
            // Draw squircle background
            let bgPath = NSBezierPath(
                roundedRect: rect,
                xRadius: size * 0.24,
                yRadius: size * 0.24
            )
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bgPath.fill()

            // Draw mascot face inset within the squircle
            let inset = size * 0.16
            let faceRect = rect.insetBy(dx: inset, dy: inset)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.saveGState()
            ctx.translateBy(x: faceRect.origin.x, y: faceRect.origin.y)
            ctx.scaleBy(x: faceRect.width / size, y: faceRect.height / size)
            let drawRect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            Self.draw(in: drawRect, mood: mood, animationFrame: false)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Creates a squircle icon with an SF Symbol centered inside.
    /// Matches the visual style of `sessionIcon` for consistent list row icons.
    static func symbolIcon(name: String, size: CGFloat = 28) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Squircle background — identical to sessionIcon
            let bgPath = NSBezierPath(
                roundedRect: rect,
                xRadius: size * 0.24,
                yRadius: size * 0.24
            )
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bgPath.fill()

            // Draw SF Symbol centered
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .medium)
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                let symbolSize = configured.size
                let x = (size - symbolSize.width) / 2
                let y = (size - symbolSize.height) / 2
                configured.draw(
                    in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Layout Constants

    private struct Layout {
        let w: CGFloat
        let h: CGFloat
        let headCenterX: CGFloat
        let headCenterY: CGFloat
        let headRadiusX: CGFloat
        let headRadiusY: CGFloat
        let eyeSpacing: CGFloat
        let eyeY: CGFloat
        let mouthY: CGFloat

        init(rect: NSRect) {
            w = rect.width
            h = rect.height
            headCenterX = w / 2
            headCenterY = h * 0.46
            headRadiusX = w * 0.38
            headRadiusY = h * 0.33
            eyeSpacing = headRadiusX * 0.52
            eyeY = headCenterY + headRadiusY * 0.08
            mouthY = headCenterY - headRadiusY * 0.38
        }
    }

    // MARK: - Main Draw

    static func draw(
        in rect: NSRect,
        mood: MenuBarMood.Mood,
        animationFrame: Bool,
        color: CGColor = CGColor(gray: 0, alpha: 1)
    ) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let layout = Layout(rect: rect)

        ctx.setFillColor(color)
        ctx.setStrokeColor(color)

        drawAntenna(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)
        drawHead(ctx: ctx, layout: layout)
        drawEars(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)

        // Cut out face features
        ctx.setBlendMode(.clear)
        drawEyes(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)
        drawMouth(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)

        // Restore and add details
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        drawEyeDetails(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)
        drawAccessories(ctx: ctx, layout: layout, mood: mood, animationFrame: animationFrame)
    }

    // MARK: - Antenna

    private static func drawAntenna(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        let antennaBaseY = layout.headCenterY + layout.headRadiusY * 0.85
        var antennaTipY = layout.h - 1.5
        let antennaTipRadius: CGFloat = 1.5

        // Antenna tilt/bounce per mood
        var tipX = layout.headCenterX
        switch mood {
        case .thinking:
            tipX += animationFrame ? 2.0 : -2.0
        case .morning:
            tipX += 1.0
        case .listening:
            tipX += animationFrame ? 1.2 : -1.2
        case .responding:
            // Slight bounce
            antennaTipY += animationFrame ? 0.5 : -0.5
        case .speaking:
            // Bigger bounce
            antennaTipY += animationFrame ? 1.0 : -1.0
            tipX += animationFrame ? 0.5 : -0.5
        default:
            break
        }

        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: layout.headCenterX, y: antennaBaseY))
        ctx.addLine(to: CGPoint(x: tipX, y: antennaTipY - antennaTipRadius))
        ctx.strokePath()

        // Antenna tip ball
        ctx.fillEllipse(in: CGRect(
            x: tipX - antennaTipRadius,
            y: antennaTipY - antennaTipRadius,
            width: antennaTipRadius * 2,
            height: antennaTipRadius * 2
        ))
    }

    // MARK: - Head

    private static func drawHead(ctx: CGContext, layout: Layout) {
        let headRect = CGRect(
            x: layout.headCenterX - layout.headRadiusX,
            y: layout.headCenterY - layout.headRadiusY,
            width: layout.headRadiusX * 2,
            height: layout.headRadiusY * 2
        )
        let headPath = CGPath(
            roundedRect: headRect,
            cornerWidth: layout.headRadiusX * 0.55,
            cornerHeight: layout.headRadiusY * 0.55,
            transform: nil
        )
        ctx.addPath(headPath)
        ctx.fillPath()
    }

    // MARK: - Ears

    private static func drawEars(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        // Listening: ears pulse between big and bigger
        let earRadius: CGFloat
        let earY: CGFloat
        switch mood {
        case .listening:
            earRadius = animationFrame ? 2.5 : 2.0
            earY = layout.headCenterY + layout.headRadiusY * 0.2
        default:
            earRadius = 1.8
            earY = layout.headCenterY + layout.headRadiusY * 0.1
        }

        // Left ear
        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX - layout.headRadiusX - earRadius * 0.6,
            y: earY - earRadius,
            width: earRadius * 2,
            height: earRadius * 2
        ))
        // Right ear
        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX + layout.headRadiusX - earRadius * 1.4,
            y: earY - earRadius,
            width: earRadius * 2,
            height: earRadius * 2
        ))
    }

    // MARK: - Eyes

    private static func drawEyes(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        switch mood {
        case .morning:
            drawEyePair(ctx: ctx, layout: layout, radiusX: 2.2, radiusY: 2.6)

        case .afternoon:
            drawEyePair(ctx: ctx, layout: layout, radiusX: 2.0, radiusY: 2.4)

        case .evening:
            drawEyePair(ctx: ctx, layout: layout, radiusX: 2.0, radiusY: 1.6)

        case .night:
            drawEyePair(ctx: ctx, layout: layout, radiusX: 1.8, radiusY: 1.2)

        case .lateNight:
            drawClosedEyes(ctx: ctx, layout: layout)

        case .listening:
            // Wide attentive eyes
            drawEyePair(ctx: ctx, layout: layout, radiusX: 2.2, radiusY: 2.6)

        case .thinking:
            // Eyes looking up
            let shiftedEyeY = layout.eyeY + layout.headRadiusY * 0.12
            drawEyePair(ctx: ctx, layout: layout, radiusX: 1.8, radiusY: 2.0, eyeY: shiftedEyeY)

        case .responding:
            // Happy squint eyes (^_^ style) — curved arc cutouts
            drawHappyEyes(ctx: ctx, layout: layout)

        case .speaking:
            // Wide animated eyes — size pulses
            let ry: CGFloat = animationFrame ? 2.8 : 2.2
            drawEyePair(ctx: ctx, layout: layout, radiusX: 2.2, radiusY: ry)

        case .error:
            drawXEyes(ctx: ctx, layout: layout)
        }
    }

    private static func drawEyePair(
        ctx: CGContext,
        layout: Layout,
        radiusX: CGFloat,
        radiusY: CGFloat,
        eyeY: CGFloat? = nil
    ) {
        let y = eyeY ?? layout.eyeY

        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX - layout.eyeSpacing - radiusX,
            y: y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        ))
        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX + layout.eyeSpacing - radiusX,
            y: y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        ))
    }

    private static func drawClosedEyes(ctx: CGContext, layout: Layout) {
        let lineWidth: CGFloat = 3.0
        let lineHeight: CGFloat = 1.0

        for xOffset in [-layout.eyeSpacing, layout.eyeSpacing] {
            ctx.fill(CGRect(
                x: layout.headCenterX + xOffset - lineWidth / 2,
                y: layout.eyeY - lineHeight / 2,
                width: lineWidth,
                height: lineHeight
            ))
        }
    }

    private static func drawHappyEyes(ctx: CGContext, layout: Layout) {
        // ^_^ style — upside-down U arcs (happy squint)
        let arcWidth: CGFloat = 2.4
        let arcHeight: CGFloat = 1.8

        ctx.setLineWidth(1.4)
        for xOffset in [-layout.eyeSpacing, layout.eyeSpacing] {
            let cx = layout.headCenterX + xOffset
            let cy = layout.eyeY

            // Draw an upside-down U arc
            ctx.move(to: CGPoint(x: cx - arcWidth, y: cy - arcHeight * 0.3))
            ctx.addQuadCurve(
                to: CGPoint(x: cx + arcWidth, y: cy - arcHeight * 0.3),
                control: CGPoint(x: cx, y: cy + arcHeight)
            )
            ctx.strokePath()
        }
    }

    private static func drawXEyes(ctx: CGContext, layout: Layout) {
        let armLen: CGFloat = 1.8
        ctx.setLineWidth(1.2)

        for xOffset in [-layout.eyeSpacing, layout.eyeSpacing] {
            let cx = layout.headCenterX + xOffset
            let cy = layout.eyeY

            ctx.move(to: CGPoint(x: cx - armLen, y: cy - armLen))
            ctx.addLine(to: CGPoint(x: cx + armLen, y: cy + armLen))
            ctx.move(to: CGPoint(x: cx + armLen, y: cy - armLen))
            ctx.addLine(to: CGPoint(x: cx - armLen, y: cy + armLen))
        }
        ctx.strokePath()
    }

    // MARK: - Mouth

    private static func drawMouth(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        switch mood {
        case .morning, .afternoon:
            drawSmileMouth(ctx: ctx, layout: layout, width: layout.headRadiusX * 0.6, height: 1.4)

        case .evening:
            drawSmileMouth(ctx: ctx, layout: layout, width: layout.headRadiusX * 0.5, height: 1.2)

        case .night:
            drawSmileMouth(ctx: ctx, layout: layout, width: layout.headRadiusX * 0.4, height: 1.0)

        case .lateNight:
            break

        case .listening:
            // Small open mouth — ready to receive
            let mouthW: CGFloat = layout.headRadiusX * 0.35
            let mouthH: CGFloat = animationFrame ? 2.0 : 1.4
            ctx.fillEllipse(in: CGRect(
                x: layout.headCenterX - mouthW / 2,
                y: layout.mouthY - mouthH / 2,
                width: mouthW,
                height: mouthH
            ))

        case .thinking:
            // Small "o" mouth
            let mouthW: CGFloat = layout.headRadiusX * 0.3
            let mouthH: CGFloat = 1.8
            ctx.fillEllipse(in: CGRect(
                x: layout.headCenterX - mouthW / 2,
                y: layout.mouthY - mouthH / 2,
                width: mouthW,
                height: mouthH
            ))

        case .responding:
            // Talking animation — mouth toggles between open and smile
            if animationFrame {
                let mouthW: CGFloat = layout.headRadiusX * 0.5
                let mouthH: CGFloat = 2.6
                ctx.fillEllipse(in: CGRect(
                    x: layout.headCenterX - mouthW / 2,
                    y: layout.mouthY - mouthH / 2,
                    width: mouthW,
                    height: mouthH
                ))
            } else {
                drawSmileMouth(
                    ctx: ctx, layout: layout,
                    width: layout.headRadiusX * 0.6, height: 1.4
                )
            }

        case .speaking:
            // Animated talking — wider mouth, bigger toggle
            let mouthW: CGFloat = animationFrame ? layout.headRadiusX * 0.6 : layout.headRadiusX * 0.4
            let mouthH: CGFloat = animationFrame ? 3.0 : 1.6
            ctx.fillEllipse(in: CGRect(
                x: layout.headCenterX - mouthW / 2,
                y: layout.mouthY - mouthH / 2,
                width: mouthW,
                height: mouthH
            ))

        case .error:
            drawWavyMouth(ctx: ctx, layout: layout)
        }
    }

    private static func drawSmileMouth(
        ctx: CGContext,
        layout: Layout,
        width: CGFloat,
        height: CGFloat
    ) {
        let mouthRect = CGRect(
            x: layout.headCenterX - width / 2,
            y: layout.mouthY - height / 2,
            width: width,
            height: height
        )
        let mouthPath = CGPath(
            roundedRect: mouthRect,
            cornerWidth: height / 2,
            cornerHeight: height / 2,
            transform: nil
        )
        ctx.addPath(mouthPath)
        ctx.fillPath()
    }

    private static func drawWavyMouth(ctx: CGContext, layout: Layout) {
        let segmentW: CGFloat = 1.6
        let amplitude: CGFloat = 1.0
        let startX = layout.headCenterX - segmentW * 1.5

        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: startX, y: layout.mouthY))

        for i in 0 ..< 3 {
            let x1 = startX + CGFloat(i) * segmentW + segmentW / 2
            let y1 = layout.mouthY + (i.isMultiple(of: 2) ? amplitude : -amplitude)
            let x2 = startX + CGFloat(i + 1) * segmentW
            let y2 = layout.mouthY
            ctx.addQuadCurve(to: CGPoint(x: x2, y: y2), control: CGPoint(x: x1, y: y1))
        }
        ctx.strokePath()
    }

    // MARK: - Eye Details (glints)

    private static func drawEyeDetails(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        // No glints for closed, X, or happy-squint eyes
        guard mood != .lateNight, mood != .error, mood != .responding else { return }

        let glintRadius: CGFloat = 0.8
        let glintOffsetX: CGFloat = 0.6
        let glintOffsetY: CGFloat = 0.7
        let eyeY = mood == .thinking ? layout.eyeY + layout.headRadiusY * 0.12 : layout.eyeY

        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX - layout.eyeSpacing + glintOffsetX - glintRadius,
            y: eyeY + glintOffsetY - glintRadius,
            width: glintRadius * 2,
            height: glintRadius * 2
        ))
        ctx.fillEllipse(in: CGRect(
            x: layout.headCenterX + layout.eyeSpacing + glintOffsetX - glintRadius,
            y: eyeY + glintOffsetY - glintRadius,
            width: glintRadius * 2,
            height: glintRadius * 2
        ))
    }

    // MARK: - Accessories

    private static func drawAccessories(
        ctx: CGContext,
        layout: Layout,
        mood: MenuBarMood.Mood,
        animationFrame: Bool
    ) {
        switch mood {
        case .lateNight:
            drawZzz(ctx: ctx, layout: layout, animationFrame: animationFrame)
        default:
            break
        }
    }

    private static func drawZzz(ctx: CGContext, layout: Layout, animationFrame: Bool) {
        let startX = layout.headCenterX + layout.headRadiusX * 0.6
        let startY = layout.headCenterY + layout.headRadiusY * 0.8
        // Animate: z's drift up slightly
        let drift: CGFloat = animationFrame ? 1.0 : 0.0

        ctx.setLineWidth(0.8)

        for (i, scale) in [(0, 1.2), (1, 0.8)] as [(Int, CGFloat)] {
            let ox = startX + CGFloat(i) * 3.0
            let oy = startY + CGFloat(i) * 2.5 + drift
            let zw: CGFloat = 2.0 * scale
            let zh: CGFloat = 2.0 * scale

            ctx.move(to: CGPoint(x: ox, y: oy + zh))
            ctx.addLine(to: CGPoint(x: ox + zw, y: oy + zh))
            ctx.addLine(to: CGPoint(x: ox, y: oy))
            ctx.addLine(to: CGPoint(x: ox + zw, y: oy))
            ctx.strokePath()
        }
    }
}
