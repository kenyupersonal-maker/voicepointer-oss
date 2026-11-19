import Foundation

/// When a skin preview (the settings gallery, the skin editor's live view) may animate.
///
/// A preview draws into a Metal layer. When nobody can see it (the settings window was closed, minimized,
/// covered or left on another Space, or the app went to the background) the compositor stops handing the
/// layer's drawables back, `CAMetalLayer.nextDrawable()` waits for one (up to a second) and whichever thread
/// called it stalls. SwiftUI's `onDisappear` says nothing about any of that, so previews follow the window.
public enum PreviewRenderingPolicy {
    public static func isViewable(
        windowIsOnScreen: Bool,
        windowIsOccluded: Bool,
        windowIsMiniaturized: Bool,
        applicationIsActive: Bool,
        applicationIsHidden: Bool
    ) -> Bool {
        windowIsOnScreen && !windowIsOccluded && !windowIsMiniaturized && applicationIsActive && !applicationIsHidden
    }
}
