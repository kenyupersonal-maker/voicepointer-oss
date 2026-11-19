import Foundation

/// Numeric timing already owned by the send operation. Querying the input
/// source/window list was optional telemetry and could trap inside HIToolbox
/// on a background task. Unknown window/composition timings remain unknown.
enum DoubaoDoneSignalObservation {
    static func summary(clock: ComposerReleaseTiming, lastChangeMilliseconds: Int) -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "none" }
        let lastChange = lastChangeMilliseconds >= 0 ? lastChangeMilliseconds : nil
        return "doubao done-signal windowOffMs=none markedClearMs=none " +
            "lastChangeMs=\(number(lastChange)) returnMs=\(number(clock.firstReturnMilliseconds))"
    }
}
