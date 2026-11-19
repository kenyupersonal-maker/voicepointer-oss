import Foundation
import VoicePointerCore

enum TerminalPeriodChecks {
    static func run() -> [String] {
        let examples = [("好的。", "好的"), ("好吗？", "好吗？"), ("真的！", "真的！"),
                        ("第一句。第二句。", "第一句。第二句"), ("U.S.", "U.S."), ("e.g.", "e.g."),
                        ("……", "……"), ("...", "..."), ("Hello.  \n", "Hello"), ("Really?!", "Really?!")]
        let valid = examples.allSatisfy { TerminalPeriodPolicy.format($0.0).text == $0.1 }
            && TerminalPeriodPolicy.format("好的。", enabled: false).text == "好的。"
            && VoicePointerSettings().omitTerminalPeriod
        return valid ? [] : ["terminal period rules: supplied examples or default failed"]
    }
}
