import AppKit
import CoreGraphics
@testable import Tama
import Testing

@Suite("VirtualCursorController")
struct VirtualCursorControllerTests {
    // MARK: - appKitPoint(forNormalizedX:y:inFrame:)

    @Test("centre of a 1920x1080 screen at origin maps to (960, 540)")
    func centreOfOriginScreen() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.5,
            y: 0.5,
            inFrame: frame
        )
        #expect(point.x == 960)
        #expect(point.y == 540)
    }

    @Test("top-left of a 1920x1080 screen maps to (0, 1080)")
    func topLeftCorner() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.0,
            y: 0.0,
            inFrame: frame
        )
        #expect(point.x == 0)
        #expect(point.y == 1080, "y=0 is top; AppKit y at top = frame.maxY")
    }

    @Test("bottom-right of a 1920x1080 screen maps to (1920, 0)")
    func bottomRightCorner() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let point = VirtualCursorController.appKitPoint(
            forNormalizedX: 1.0,
            y: 1.0,
            inFrame: frame
        )
        #expect(point.x == 1920)
        #expect(point.y == 0, "y=1 is bottom; AppKit y at bottom = frame.minY")
    }

    @Test("centre of a screen at horizontal offset (1920, 0) maps to (2880, 540)")
    func offsetScreenCentre() {
        let frame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let point = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.5,
            y: 0.5,
            inFrame: frame
        )
        #expect(point.x == 2880)
        #expect(point.y == 540)
    }

    @Test("screen with negative minX (placed left of main) still maps correctly")
    func negativeOffsetScreen() {
        // A secondary screen to the left of the main one has negative minX.
        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let centre = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.5,
            y: 0.5,
            inFrame: frame
        )
        #expect(centre.x == -720)
        #expect(centre.y == 450)

        let topLeft = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.0,
            y: 0.0,
            inFrame: frame
        )
        #expect(topLeft.x == -1440)
        #expect(topLeft.y == 900)
    }

    @Test("screen with negative minY (placed below main) still maps correctly")
    func negativeYScreen() {
        let frame = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let point = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.5,
            y: 0.5,
            inFrame: frame
        )
        #expect(point.x == 960)
        #expect(point.y == -540)
    }

    @Test("y axis is flipped (top → frame.maxY, bottom → frame.minY)")
    func yAxisFlipped() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = VirtualCursorController.appKitPoint(forNormalizedX: 0.5, y: 0.0, inFrame: frame)
        let bottom = VirtualCursorController.appKitPoint(forNormalizedX: 0.5, y: 1.0, inFrame: frame)
        #expect(top.y > bottom.y, "AppKit y increases upward, so y=0 (top) > y=1 (bottom)")
    }

    @Test("NSScreen convenience matches the rect-based overload")
    @MainActor
    func screenOverloadMatchesFrameOverload() {
        guard let screen = NSScreen.screens.first else { return }
        let viaScreen = VirtualCursorController.appKitPoint(forNormalizedX: 0.3, y: 0.4, on: screen)
        let viaFrame = VirtualCursorController.appKitPoint(
            forNormalizedX: 0.3,
            y: 0.4,
            inFrame: screen.frame
        )
        #expect(viaScreen == viaFrame)
    }

    // MARK: - screen(forIndex:)

    @Test("screen(forIndex: 0) returns a screen when at least one is attached")
    @MainActor
    func screenForIndexZero() {
        guard VirtualCursorController.screenCount > 0 else {
            // No displays available (rare in CI without a virtual screen). Skip.
            return
        }
        #expect(VirtualCursorController.screen(forIndex: 0) != nil)
    }

    @Test("screen(forIndex:) returns nil for negative index")
    @MainActor
    func screenForNegativeIndex() {
        #expect(VirtualCursorController.screen(forIndex: -1) == nil)
    }

    @Test("screen(forIndex:) returns nil for out-of-range index")
    @MainActor
    func screenForOutOfRangeIndex() {
        let count = VirtualCursorController.screenCount
        #expect(VirtualCursorController.screen(forIndex: count + 10) == nil)
    }

    // MARK: - displayID(for:)

    @Test("displayID is stable across calls for the same screen")
    @MainActor
    func displayIDStable() {
        guard let screen = NSScreen.screens.first else { return }
        let first = VirtualCursorController.displayID(for: screen)
        let second = VirtualCursorController.displayID(for: screen)
        #expect(first == second)
    }

    // MARK: - Constants

    @Test("hold-seconds bounds are sensible")
    func holdBounds() {
        #expect(VirtualCursorController.minHoldSeconds > 0)
        #expect(VirtualCursorController.maxHoldSeconds > VirtualCursorController.minHoldSeconds)
        #expect(VirtualCursorController.defaultHoldSeconds >= VirtualCursorController.minHoldSeconds)
        #expect(VirtualCursorController.defaultHoldSeconds <= VirtualCursorController.maxHoldSeconds)
    }
}
