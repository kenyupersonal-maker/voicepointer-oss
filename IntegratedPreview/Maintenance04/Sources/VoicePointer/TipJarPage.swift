import AppKit
import SwiftUI

// 打赏页（2026-11-07，Claude）：照 ChatHand 的打赏弹窗（runtime/ui/tip-jar.js）移植成设置里的一页。
// 收款方式不写在源码里：打开这页时从 ChatHand 官网仓库的 tip.json 读一次（和 ChatHand 用同一份），
// 读到的内容逐项核过，只当文字和图片用；链接只收 https，图标只收 data: 的 PNG/SVG。读不到就在原地说一句，给「再试一次」。
// 不带 Cookie、不带来源页；这一页之外咻不联网读它。

private enum TipCopy {
    static let headline = "觉得好用，欢迎打赏"
    static let lede = "咻 免费使用，之后会开源。如果它帮你省了时间，欢迎请作者喝杯咖啡，支持它继续更新。"
    static let crypto = "加密货币"
    static let paypalGo = "用 PayPal 打赏"
    static let link = "链接"
    static let address = "地址"
    static let copy = "复制"
    static let copied = "已复制"
    static let loading = "正在加载打赏方式…"
    static let failed = "无法加载打赏方式，请检查网络后重试。"
    static let retry = "再试一次"
    static let alipayNote = "打开支付宝扫一扫，金额随意。"
    static func cryptoNote(min: String, network: String) -> String { "最少 \(min)，转账网络请选 \(network)。" }
    static let btcOnly = "仅接收 BTC，铭文和 NFT 不会到账，也无法退回。"
    static func qrLabel(_ name: String) -> String { "\(name) 收款二维码" }
}

struct TipMethod: Identifiable {
    enum Note { case none, paypal, alipay, crypto, custom([String: String]) }
    let id: String
    let names: [String: String]
    let qrSize: Int
    let qrBits: [Bool]
    let logo: NSImage?
    let link: URL?
    let address: String?
    let show: String?
    let tag: String?
    let network: String?
    let minimum: String?
    let isCrypto: Bool
    let note: Note
    let btcOnly: Bool

    var name: String { TipMethod.pick(names) }

    var noteText: String {
        var parts: [String] = []
        switch note {
        case .none, .paypal: break
        case .alipay: parts.append(TipCopy.alipayNote)
        case .crypto:
            if let minimum, let network { parts.append(TipCopy.cryptoNote(min: minimum, network: network)) }
        case .custom(let words): parts.append(TipMethod.pick(words))
        }
        if btcOnly { parts.append(TipCopy.btcOnly) }
        return parts.joined()
    }

    /// The person's language first, then its base language, then English, then whatever there is.
    static func pick(_ words: [String: String]) -> String {
        if let plain = words[""] { return plain }
        for language in Locale.preferredLanguages {
            if let exact = words[language] { return exact }
            let base = String(language.split(separator: "-").first ?? "")
            if let found = words[base] { return found }
            if let found = words.first(where: { $0.key.hasPrefix(base + "-") })?.value { return found }
        }
        return words["en"] ?? words.sorted { $0.key < $1.key }.first?.value ?? ""
    }
}

/// Reads and checks tip.json. Anything that does not pass every check throws the whole file away, as ChatHand does.
enum TipJarSource {
    static let url = URL(string: "https://kenyupersonal-maker.github.io/chathand-site/tip.json")!
    static let maximumBytes = 600_000

    static func parse(_ data: Data) -> [TipMethod]? {
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? NSNumber)?.intValue == 1,
              let list = root["methods"] as? [Any], !list.isEmpty, list.count <= 12 else { return nil }
        var seen = Set<String>()
        var methods: [TipMethod] = []
        for entry in list {
            guard let m = entry as? [String: Any], let id = m["id"] as? String,
                  id.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil, !seen.contains(id) else { return nil }
            seen.insert(id)
            guard let names = words(m["name"]), let qr = m["qr"] as? [String: Any],
                  let n = (qr["n"] as? NSNumber)?.intValue, (21...57).contains(n),
                  let hex = qr["hex"] as? String, hex.count == (n * n + 3) / 4,
                  hex.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil,
                  let logoString = m["logo"] as? String, logoString.count <= 65_536 else { return nil }
            guard let logoData = imageData(logoString) else { return nil }
            let link: URL?
            if let raw = m["link"], !(raw is NSNull) {
                guard let value = https(raw) else { return nil }
                link = value
            } else { link = nil }
            func optional(_ key: String, _ maximum: Int) -> (ok: Bool, value: String?) {
                guard let raw = m[key], !(raw is NSNull) else { return (true, nil) }
                guard let value = plain(raw, maximum) else { return (false, nil) }
                return (true, value)
            }
            let address = optional("address", 128), show = optional("show", 160), tag = optional("tag", 24)
            let network = optional("network", 60), minimum = optional("min", 40)
            guard address.ok, show.ok, tag.ok, network.ok, minimum.ok else { return nil }
            let note: TipMethod.Note
            let rawNote = m["note"]
            if rawNote == nil || rawNote is NSNull {
                note = .none
            } else if let kind = rawNote as? String, kind == "paypal" {
                note = .paypal
            } else if let kind = rawNote as? String, kind == "alipay" {
                note = .alipay
            } else if let kind = rawNote as? String, kind == "crypto" {
                note = .crypto
            } else {
                guard let custom = words(rawNote) else { return nil }
                note = .custom(custom)
            }
            var bits: [Bool] = []
            bits.reserveCapacity(hex.count * 4)
            for character in hex {
                guard let nibble = character.hexDigitValue else { return nil }
                for shift in stride(from: 3, through: 0, by: -1) { bits.append((nibble >> shift) & 1 == 1) }
            }
            methods.append(TipMethod(
                id: id, names: names, qrSize: n, qrBits: Array(bits.prefix(n * n)),
                logo: NSImage(data: logoData), link: link, address: address.value, show: show.value, tag: tag.value,
                network: network.value, minimum: minimum.value, isCrypto: (m["group"] as? String) == "crypto",
                note: note, btcOnly: (m["extra"] as? String) == "btcOnly"))
        }
        return methods
    }

    private static func plain(_ value: Any, _ maximum: Int = 160) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= maximum,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return text
    }

    private static func words(_ value: Any?) -> [String: String]? {
        if let value, let text = plain(value) { return ["": text] }
        guard let map = value as? [String: Any], !map.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (key, raw) in map {
            guard key.range(of: "^[a-z]{2}(-[A-Za-z]{2,4})?$", options: .regularExpression) != nil,
                  let text = plain(raw, 200) else { return nil }
            out[key] = text
        }
        return out
    }

    private static func https(_ value: Any) -> URL? {
        guard let text = value as? String, text.count <= 300, let url = URL(string: text),
              url.scheme == "https", url.user == nil, url.password == nil, url.host != nil else { return nil }
        return url
    }

    private static func imageData(_ value: String) -> Data? {
        for prefix in ["data:image/png;base64,", "data:image/svg+xml;base64,"] where value.hasPrefix(prefix) {
            let body = String(value.dropFirst(prefix.count))
            guard body.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil else { return nil }
            return Data(base64Encoded: body)
        }
        return nil
    }
}

@MainActor
final class TipJarModel: ObservableObject {
    enum Phase { case idle, loading, ready, failed }
    static let shared = TipJarModel()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var methods: [TipMethod] = []
    @Published var current = ""

    func loadIfNeeded() {
        guard phase == .idle || phase == .failed else { return }
        phase = .loading
        Task { @MainActor in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration)
            var request = URLRequest(url: TipJarSource.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpShouldHandleCookies = false
            let list: [TipMethod]?
            do {
                let (data, response) = try await session.data(for: request)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                list = ok ? TipJarSource.parse(data) : nil
            } catch {
                list = nil
            }
            session.finishTasksAndInvalidate()
            if let list, !list.isEmpty {
                methods = list
                if !list.contains(where: { $0.id == current }) { current = list[0].id }
                phase = .ready
            } else {
                phase = .failed
            }
        }
    }
}

@MainActor
struct TipJarPage: View {
    @ObservedObject private var model = TipJarModel.shared
    @State private var copiedValue: String?
    @Namespace private var highlight

    var body: some View {
        SettingsPageBody(SettingsPage.tip.title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TipCopy.headline).font(.system(size: 15, weight: .semibold))
                Text(TipCopy.lede)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
            content
        }
        .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(TipCopy.loading).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .settingsCard()
        case .failed:
            HStack(spacing: 12) {
                Text(TipCopy.failed).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(TipCopy.retry) { model.loadIfNeeded() }
            }
            .settingsCard()
        case .ready:
            HStack(alignment: .top, spacing: 18) {
                methodList.frame(width: 184)
                if let method = model.methods.first(where: { $0.id == model.current }) ?? model.methods.first {
                    detail(method).frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 10) // 24 pt above and below in all, more air than an ordinary card
            .settingsCard()
            // As in ChatHand: scrolling over the card walks through the methods, one per wheel notch or per
            // short trackpad swipe. At the first and last method the page scrolls as usual.
            .background(SettingsWheelStepper(distance: 64, canStep: canStep, step: step))
        }
    }

    private var methodList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.methods.enumerated()), id: \.element.id) { index, method in
                if method.isCrypto && !model.methods.prefix(index).contains(where: { $0.isCrypto }) {
                    Text(TipCopy.crypto)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .padding(.leading, 10)
                }
                TipMethodRow(method: method, selected: method.id == model.current, highlight: highlight) {
                    select(method.id)
                }
            }
        }
    }

    /// The white QR card stays put while the method changes; only the code inside it crossfades, on white, so
    /// two half-transparent cards never overlap into a grey square (Ken, 2026-11-07). The lines under it fade
    /// as one block.
    private func detail(_ method: TipMethod) -> some View {
        VStack(spacing: 12) {
            ZStack {
                TipQRCode(size: method.qrSize, bits: method.qrBits, logo: method.logo)
                    .id(method.id)
                    .transition(SettingsMotion.swap)
            }
            .frame(width: 196, height: 196)
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SettingsPalette.hairline, lineWidth: 1)
            }
            .accessibilityElement()
            .accessibilityLabel(Text(TipCopy.qrLabel(method.name)))
            // Every method's lines laid out invisibly underneath: the card is as tall as the tallest method and
            // does not grow or shrink while the wheel walks through them (Ken, 2026-11-07).
            ZStack(alignment: .top) {
                ForEach(model.methods, id: \.id) { other in info(other).hidden() }
                info(method)
                    .id(method.id)
                    .transition(SettingsMotion.swap)
            }
        }
    }

    private func info(_ method: TipMethod) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(method.name).font(.system(size: 14, weight: .semibold))
                if let network = method.network {
                    Text(network).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if let link = method.link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Label(TipCopy.paypalGo, systemImage: "arrow.up.right")
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
            }
            if let value = method.link?.absoluteString ?? method.address {
                HStack(spacing: 8) {
                    Text(method.link == nil ? TipCopy.address : TipCopy.link)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(method.show ?? value)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copiedValue == value ? TipCopy.copied : TipCopy.copy) { copy(value) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            let note = method.noteText
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func select(_ id: String) {
        guard id != model.current else { return }
        withAnimation(SettingsMotion.slide) { model.current = id }
    }

    private var currentIndex: Int { model.methods.firstIndex { $0.id == model.current } ?? 0 }

    private func canStep(_ direction: Int) -> Bool {
        model.methods.indices.contains(currentIndex + direction)
    }

    private func step(_ direction: Int) {
        let next = currentIndex + direction
        guard model.methods.indices.contains(next) else { return }
        select(model.methods[next].id)
    }

    private func copy(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        copiedValue = value
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedValue == value { copiedValue = nil }
        }
    }
}

private struct TipMethodRow: View {
    let method: TipMethod
    let selected: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let logo = method.logo {
                        Image(nsImage: logo).resizable().scaledToFit()
                    } else {
                        Text(String(method.name.prefix(1))).font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(SettingsPalette.tile, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .frame(width: 20, height: 20)
                Text(method.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let tag = method.tag {
                    Text(tag).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                // The chosen row's fill is one shape that slides to the new row (ChatHand's tip highlight).
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SettingsPalette.tileHover)
                        .matchedGeometryEffect(id: "tip-highlight", in: highlight)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SettingsPalette.tile)
                }
            }
            .animation(SettingsMotion.quick, value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The QR code drawn as ChatHand draws it: one dot per module, the three finder corners as rings, and a hole in
/// the middle (about 27 % of the side) for the payment logo.
private struct TipQRCode: View {
    let size: Int
    let bits: [Bool]
    let logo: NSImage?

    private var hole: Int { size >= 41 ? 11 : 9 }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Canvas { context, canvasSize in
                    let n = size
                    let module = min(canvasSize.width, canvasSize.height) / CGFloat(n)
                    context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(.white))
                    let lo = (n - hole) / 2, hi = lo + hole
                    func finder(_ r: Int, _ c: Int) -> Bool {
                        (r < 7 || r >= n - 7) && (c < 7 || c >= n - 7) && !(r >= n - 7 && c >= n - 7)
                    }
                    var dots = Path()
                    for r in 0..<n {
                        for c in 0..<n where r * n + c < bits.count && bits[r * n + c] {
                            if finder(r, c) || (r >= lo && r < hi && c >= lo && c < hi) { continue }
                            dots.addEllipse(in: CGRect(x: (CGFloat(c) + 0.07) * module, y: (CGFloat(r) + 0.07) * module,
                                                       width: 0.86 * module, height: 0.86 * module))
                        }
                    }
                    context.fill(dots, with: .color(.black))
                    for (x, y) in [(0, 0), (n - 7, 0), (0, n - 7)] {
                        let center = CGPoint(x: (CGFloat(x) + 3.5) * module, y: (CGFloat(y) + 3.5) * module)
                        let ring = Path(ellipseIn: CGRect(x: center.x - 3 * module, y: center.y - 3 * module,
                                                         width: 6 * module, height: 6 * module))
                        context.stroke(ring, with: .color(.black), lineWidth: module)
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.5 * module, y: center.y - 1.5 * module,
                                                            width: 3 * module, height: 3 * module)), with: .color(.black))
                    }
                }
                if let logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * CGFloat(hole) / CGFloat(size) * 0.82,
                               height: side * CGFloat(hole) / CGFloat(size) * 0.82)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

