import Foundation
@_spi(Testing) import VoicePointerCore

enum PermissionFeedbackChecks {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }

        expect(
            PermissionFeedback.missing(accessibility: true, inputMonitoring: false, eventPosting: true) == [.inputMonitoring],
            "feedback must identify only missing Input Monitoring"
        )
        expect(
            PermissionFeedback.missing(accessibility: false, inputMonitoring: true, eventPosting: true) == [.accessibility],
            "feedback must identify only missing Accessibility"
        )
        expect(
            PermissionFeedback.missing(accessibility: true, inputMonitoring: true, eventPosting: true).isEmpty,
            "feedback must be empty when all permissions are granted"
        )
        expect(
            PermissionFeedback.missing(accessibility: false, inputMonitoring: false, eventPosting: false) == [.accessibility, .inputMonitoring],
            "feedback must not duplicate the Accessibility settings destination"
        )
        expect(
            PermissionFeedback.missing(accessibility: true, inputMonitoring: true, eventPosting: false) == [.eventPosting],
            "failed posting must remain visible when AX itself is trusted"
        )
        expect(
            PermissionFeedbackKind.inputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"),
            "Input Monitoring feedback must open the Input Monitoring pane"
        )
        expect(
            PermissionFeedbackKind.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"),
            "Accessibility feedback must open the Accessibility pane"
        )
        return failures
    }
}
