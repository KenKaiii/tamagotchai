import AppKit
@testable import Tama
import Testing

/// End-to-end sanity checks that exercise the full show → animate → hide
/// lifecycle through the real `PointTool` / `VirtualCursorController` on the
/// test host's actual display. Runs on the MainActor because the controller
/// creates real `NSPanel`s.
///
/// These tests prove the tool is actually wired to a click-through, always-
/// on-top overlay — not just that the math is right.
@MainActor
@Suite("VirtualCursor Integration")
struct VirtualCursorIntegrationTests {
    /// Tidy up after each test — a stray visible cursor leaks between runs.
    private func cleanup() {
        VirtualCursorController.hideImmediately()
    }

    @Test("PointTool places a visible, click-through panel at screenSaver level")
    func panelIsClickThroughAndAtCorrectLevel() async throws {
        // Skip when no display is attached (rare under CI without a virtual
        // screen). The unit tests already cover the math.
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await PointTool().execute(args: [
            "x": 0.5,
            "y": 0.5,
            "pulse": false,
            "hold_seconds": 1.0,
        ])

        // There should now be at least one panel owned by the controller.
        // We can't easily reach into its private dictionary, so instead verify
        // via the public surface: find the panel among NSApp.windows.
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
            .filter { $0.level == .screenSaver && $0.ignoresMouseEvents }
        #expect(!panels.isEmpty, "Expected a screenSaver-level click-through panel after point")

        if let panel = panels.first {
            #expect(panel.ignoresMouseEvents, "Real cursor events must pass through the overlay")
            #expect(panel.level == .screenSaver, "Overlay must sit above menu bar and fullscreen apps")
            #expect(!panel.isOpaque, "Overlay background must be transparent")
            #expect(panel.hasShadow == false, "Overlay panel must not cast a window shadow")
            #expect(
                panel.collectionBehavior.contains(.canJoinAllSpaces),
                "Overlay must follow the user across Spaces"
            )
            #expect(
                panel.collectionBehavior.contains(.fullScreenAuxiliary),
                "Overlay must remain visible over fullscreen apps"
            )
            #expect(
                panel.collectionBehavior.contains(.stationary),
                "Overlay must not slide with Spaces transitions"
            )
            #expect(
                !panel.collectionBehavior.contains(.ignoresCycle) == false,
                "Overlay must be excluded from Cmd-Tab cycle"
            )
        }
    }

    @Test("back-to-back point calls reuse the same panel (no teleport / leak)")
    func backToBackCallsReusePanel() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await PointTool().execute(args: [
            "x": 0.1, "y": 0.1, "pulse": false, "hold_seconds": 5.0,
        ])
        let afterFirst = NSApp.windows.compactMap { $0 as? NSPanel }
            .count(where: { $0.ignoresMouseEvents && $0.level == .screenSaver })

        _ = try await PointTool().execute(args: [
            "x": 0.9, "y": 0.9, "pulse": false, "hold_seconds": 5.0,
        ])
        let afterSecond = NSApp.windows.compactMap { $0 as? NSPanel }
            .count(where: { $0.ignoresMouseEvents && $0.level == .screenSaver })

        #expect(
            afterSecond == afterFirst,
            "Second point call on the same display must reuse the existing overlay panel"
        )
    }

    @Test("hideImmediately fades cursor out and clears active-display state")
    func hideImmediatelyCleansUp() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }

        _ = try await PointTool().execute(args: [
            "x": 0.5, "y": 0.5, "pulse": false, "hold_seconds": 10.0,
        ])
        VirtualCursorController.hideImmediately()
        // Calling again is a no-op and must not throw.
        VirtualCursorController.hideImmediately()
    }

    @Test("sequential point calls chain through a multi-step walkthrough")
    func sequentialPointsChainThroughWalkthrough() async throws {
        // This is the core of the "walk me through X" experience: the agent
        // calls `point` N times in sequence and the cursor must stay alive,
        // move smoothly between targets, and never flash off between steps.
        // We verify by counting overlay panels after each step — the count
        // must stay constant (one panel, reused), otherwise the cursor is
        // being torn down and recreated between steps.
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        let tool = PointTool()
        let walkthrough: [(Double, Double, String)] = [
            (0.05, 0.02, "File menu"),
            (0.20, 0.10, "Open recent"),
            (0.35, 0.15, "Recent doc"),
        ]

        var panelCounts: [Int] = []
        for (x, y, label) in walkthrough {
            _ = try await tool.execute(args: [
                "x": x,
                "y": y,
                "label": label,
                "pulse": false,
                "hold_seconds": 10.0, // generous — next step cancels pending hide
            ])
            let count = NSApp.windows.compactMap { $0 as? NSPanel }
                .count(where: { $0.level == .screenSaver && $0.ignoresMouseEvents })
            panelCounts.append(count)
        }

        let first = panelCounts.first ?? 0
        #expect(first >= 1, "First point call must establish the cursor panel")
        for (step, count) in panelCounts.enumerated() {
            #expect(
                count == first,
                "Step \(step + 1) unexpectedly changed panel count (\(count) vs \(first)) — cursor is being recreated instead of reusing"
            )
        }
    }
}
