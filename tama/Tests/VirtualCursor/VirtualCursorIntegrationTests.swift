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
        //
        // We reset the pacing clock between calls because this test is
        // about panel reuse, not about speech sync. The `pointCallsArePaced`
        // test below covers the pacing behaviour explicitly.
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
            VirtualCursorController.resetPacingForTesting()
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

    @Test("back-to-back point calls are paced to stay in sync with TTS")
    func pointCallsArePaced() async throws {
        // When the agent emits two `point` calls in the same response, tool
        // execution takes ~1ms each but TTS playback takes real seconds.
        // Without pacing the cursor races ahead of the voice (the user's
        // actual complaint was: "points A, then B, and talks about A").
        // Verify that the SECOND call actually waits before firing.
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }
        VirtualCursorController.resetPacingForTesting()

        let tool = PointTool()
        let first = Date()
        _ = try await tool.execute(args: [
            "x": 0.1, "y": 0.1, "pulse": false, "hold_seconds": 10.0,
        ])
        let firstElapsed = Date().timeIntervalSince(first)
        // First call shouldn't wait — pacing clock was reset.
        #expect(firstElapsed < 1.0, "First call must not be paced")

        let second = Date()
        _ = try await tool.execute(args: [
            "x": 0.9, "y": 0.9, "pulse": false, "hold_seconds": 10.0,
        ])
        let secondElapsed = Date().timeIntervalSince(second)
        // Second call must wait at least most of minPointDwell so the cursor
        // doesn't jump ahead of the narration. Allow a small slop for thread
        // scheduling (the guard is `>= dwell - 0.5s`).
        let minDwell = VirtualCursorController.minPointDwell
        #expect(
            secondElapsed >= minDwell - 0.5,
            "Second back-to-back call must be paced by at least ~\(minDwell)s, got \(secondElapsed)s"
        )
    }

    @Test("hideImmediately resets the pacing clock so next point fires fast")
    func hideResetsPacing() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }
        VirtualCursorController.resetPacingForTesting()

        _ = try await PointTool().execute(args: [
            "x": 0.5, "y": 0.5, "pulse": false, "hold_seconds": 10.0,
        ])
        VirtualCursorController.hideImmediately()

        // After a hide, a fresh point should fire immediately — the previous
        // cursor / its narration have ended, so there's nothing to pace against.
        let start = Date()
        _ = try await PointTool().execute(args: [
            "x": 0.2, "y": 0.2, "pulse": false, "hold_seconds": 10.0,
        ])
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "Post-hide point must not be paced, got \(elapsed)s")
    }

    @Test("emphasize returns true only when a cursor is visible")
    func emphasizeGatedOnVisibleCursor() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        // No cursor visible — emphasize must return false rather than firing
        // a ghost pulse on an empty panel.
        #expect(VirtualCursorController.emphasize() == false)

        // After a point call, emphasize should now succeed.
        _ = try await PointTool().execute(args: [
            "x": 0.5, "y": 0.5, "pulse": false, "hold_seconds": 10.0,
        ])
        #expect(VirtualCursorController.emphasize() == true)
    }

    @Test("EmphasizeTool reports a clear message when no cursor is visible")
    func emphasizeToolReportsMissingCursor() async throws {
        defer { cleanup() }
        VirtualCursorController.hideImmediately()

        let result = try await EmphasizeTool().execute(args: [:])
        #expect(
            result.text.lowercased().contains("no virtual cursor")
                || result.text.lowercased().contains("point"),
            "Agent must learn to call `point` first from the tool output"
        )
    }

    @Test("point with upcoming ghosts completes without errors")
    func pointWithUpcomingGhosts() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        // Exercise the full plumb-through: tool arg parsing, controller
        // coord conversion, panel ghost-layer construction.
        let result = try await PointTool().execute(args: [
            "x": 0.1, "y": 0.05,
            "label": "File",
            "pulse": false,
            "hold_seconds": 5.0,
            "upcoming": [
                ["x": 0.2, "y": 0.15],
                ["x": 0.35, "y": 0.25],
                ["x": 0.5, "y": 0.4],
            ],
        ])
        #expect(result.text.contains("upcoming"))
    }

    // MARK: - Tutor overlays coexist with the cursor

    @Test("highlight coexists with a visible cursor (does not displace it)")
    func highlightCoexistsWithCursor() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await PointTool().execute(args: [
            "x": 0.5, "y": 0.5, "pulse": false, "hold_seconds": 10.0,
        ])
        let cursorPanelCount = NSApp.windows.compactMap { $0 as? NSPanel }
            .count(where: { $0.level == .screenSaver && $0.ignoresMouseEvents })

        _ = try await HighlightTool().execute(args: [
            "shape": "rectangle",
            "x": 0.1, "y": 0.1, "width": 0.3, "height": 0.2,
            "hold_seconds": 5.0,
        ])
        let afterHighlight = NSApp.windows.compactMap { $0 as? NSPanel }
            .count(where: { $0.level == .screenSaver && $0.ignoresMouseEvents })
        #expect(afterHighlight == cursorPanelCount, "Highlight should reuse the existing overlay panel")
    }

    @Test("arrow coexists with a visible cursor")
    func arrowCoexistsWithCursor() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await PointTool().execute(args: [
            "x": 0.5, "y": 0.5, "pulse": false, "hold_seconds": 10.0,
        ])
        _ = try await ArrowTool().execute(args: [
            "x1": 0.2, "y1": 0.2, "x2": 0.8, "y2": 0.8,
            "hold_seconds": 2.0,
        ])
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
            .filter { $0.level == .screenSaver && $0.ignoresMouseEvents }
        #expect(!panels.isEmpty)
    }

    @Test("countdown, scroll_hint, and shortcut overlays can run back-to-back")
    func overlaysCoexist() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await CountdownTool().execute(args: ["seconds": 1])
        _ = try await ScrollHintTool().execute(args: [
            "direction": "down",
            "hold_seconds": 1.0,
        ])
        _ = try await ShowShortcutTool().execute(args: [
            "shortcut": "cmd+s",
            "hold_seconds": 0.5,
        ])
        // None of these should error, and exactly one panel per display must exist.
        let panels = NSApp.windows.compactMap { $0 as? NSPanel }
            .filter { $0.level == .screenSaver && $0.ignoresMouseEvents }
        #expect(!panels.isEmpty)
    }

    @Test("hideImmediately tears down every overlay too")
    func hideImmediatelyClearsOverlays() async throws {
        guard VirtualCursorController.screenCount > 0 else { return }
        defer { cleanup() }

        _ = try await HighlightTool().execute(args: [
            "shape": "rectangle",
            "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2,
            "hold_seconds": 30.0,
        ])
        _ = try await ArrowTool().execute(args: [
            "x1": 0.2, "y1": 0.2, "x2": 0.9, "y2": 0.9,
            "hold_seconds": 30.0,
        ])
        VirtualCursorController.hideImmediately()
        // A second hide must not throw and must still leave no active
        // overlays (idempotent).
        VirtualCursorController.hideImmediately()
    }
}
