import Foundation
import CoreGraphics
@_spi(Testing) import VoicePointerCore

/// L1G checks: editing-intent clock ordering and the gesture wrapper's
/// advance condition. Pure logic; no CGEvent construction, no event taps,
/// no key values recorded.
enum EditingIntentClockChecks {
    static func run() -> [String] {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        // MARK: Clock unit behavior

        let fresh = EditingIntentClock()
        expect(fresh.snapshot() == 0, "fresh clock generation must be 0")
        fresh.advance()
        expect(fresh.snapshot() == 1, "advance must move generation to 1")

        let acted = EditingIntentClock()
        var ran = false
        let returned = acted.performIfUnchanged(0) {
            ran = true
            return "ok"
        }
        expect(ran && returned == "ok", "matched generation must run the action once and return its value")

        acted.advance()
        var staleRan = false
        let stale: String? = acted.performIfUnchanged(0) {
            staleRan = true
            return "never"
        }
        expect(!staleRan && stale == nil, "mismatched generation must not execute the action")

        // MARK: Wrapper advance condition (no real events needed)

        expect(
            EditingIntentClock.shouldAdvance(type: .keyDown, passedThrough: true, syntheticMarker: 0) &&
                EditingIntentClock.shouldAdvance(type: .leftMouseDown, passedThrough: true, syntheticMarker: 0) &&
                EditingIntentClock.shouldAdvance(type: .rightMouseDown, passedThrough: true, syntheticMarker: 0) &&
                EditingIntentClock.shouldAdvance(type: .otherMouseDown, passedThrough: true, syntheticMarker: 0),
            "every passed-through human key/button press type must advance"
        )
        expect(
            !EditingIntentClock.shouldAdvance(type: .keyUp, passedThrough: true, syntheticMarker: 0) &&
                !EditingIntentClock.shouldAdvance(type: .leftMouseUp, passedThrough: true, syntheticMarker: 0) &&
                !EditingIntentClock.shouldAdvance(type: .mouseMoved, passedThrough: true, syntheticMarker: 0) &&
                !EditingIntentClock.shouldAdvance(type: .scrollWheel, passedThrough: true, syntheticMarker: 0) &&
                !EditingIntentClock.shouldAdvance(type: .keyDown, passedThrough: true, syntheticMarker: voicePointerSyntheticEventUserData) &&
                !EditingIntentClock.shouldAdvance(type: .keyDown, passedThrough: false, syntheticMarker: 0) &&
                !EditingIntentClock.shouldAdvance(type: .leftMouseDown, passedThrough: false, syntheticMarker: 0),
            "releases, moves, scrolls, synthetic events, and swallowed events must never advance"
        )

        return failures
    }
}
