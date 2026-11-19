import Foundation
import VoicePointerCore

/// A preview may animate only while a person can look at it; every way of not looking must stop it.
enum PreviewRenderingPolicyChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func viewable(
            onScreen: Bool = true, occluded: Bool = false, miniaturized: Bool = false,
            active: Bool = true, hidden: Bool = false
        ) -> Bool {
            PreviewRenderingPolicy.isViewable(
                windowIsOnScreen: onScreen, windowIsOccluded: occluded, windowIsMiniaturized: miniaturized,
                applicationIsActive: active, applicationIsHidden: hidden
            )
        }
        if !viewable() { failures.append("an on-screen, uncovered window of the front app must animate its previews") }
        if viewable(onScreen: false) { failures.append("a closed or ordered-out window must not animate previews") }
        if viewable(occluded: true) { failures.append("a covered window or one on another Space must not animate previews") }
        if viewable(miniaturized: true) { failures.append("a minimized window must not animate previews") }
        if viewable(active: false) { failures.append("previews must pause while the app is in the background") }
        if viewable(hidden: true) { failures.append("previews must pause while the app is hidden") }
        return failures
    }
}
