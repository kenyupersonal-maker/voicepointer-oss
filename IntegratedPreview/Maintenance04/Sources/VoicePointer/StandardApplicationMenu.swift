import AppKit

// AppKit routes these informal responder actions; UndoManager.undo/redo have no sender.
@objc private protocol ApplicationUndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@MainActor
enum StandardApplicationMenu {
    /// Accessory apps still need a main menu for text-field key equivalents.
    /// Nil targets let AppKit route each command to the current responder.
    static func install(in application: NSApplication) {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "VoicePointer")
        appMenu.addItem(command("退出 VoicePointer", #selector(NSApplication.terminate(_:)), "q"))
        append(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(command("撤销", #selector(ApplicationUndoActions.undo(_:)), "z"))
        editMenu.addItem(command("重做", #selector(ApplicationUndoActions.redo(_:)), "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(command("剪切", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(command("拷贝", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(command("粘贴", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(command("全选", #selector(NSText.selectAll(_:)), "a"))
        append(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(command("关闭", #selector(NSWindow.performClose(_:)), "w"))
        append(windowMenu, to: mainMenu)
        application.mainMenu = mainMenu
        application.windowsMenu = windowMenu
    }

    private static func command(_ title: String, _ action: Selector, _ key: String,
                                modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private static func append(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let root = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        root.submenu = submenu
        mainMenu.addItem(root)
    }

    /// Uses only menu metadata and an injected responder; no key events or pasteboard access.
    static func selfCheck(in application: NSApplication) -> String {
        let oldMainMenu = application.mainMenu
        let oldWindowMenu = application.windowsMenu
        let oldNextResponder = application.nextResponder
        defer {
            application.mainMenu = oldMainMenu
            application.windowsMenu = oldWindowMenu
            application.nextResponder = oldNextResponder
        }
        install(in: application)
        let responder = ApplicationMenuProbeResponder()
        application.nextResponder = responder
        var failures: [String] = []
        let expected: [(String, String, String, String, NSEvent.ModifierFlags)] = [
            ("编辑", "撤销", "undo:", "z", [.command]),
            ("编辑", "重做", "redo:", "z", [.command, .shift]),
            ("编辑", "剪切", "cut:", "x", [.command]),
            ("编辑", "拷贝", "copy:", "c", [.command]),
            ("编辑", "粘贴", "paste:", "v", [.command]),
            ("编辑", "全选", "selectAll:", "a", [.command]),
            ("窗口", "关闭", "performClose:", "w", [.command])
        ]
        for (menuTitle, title, selectorName, key, modifiers) in expected {
            guard let submenu = application.mainMenu?.items.first(where: { $0.title == menuTitle })?.submenu,
                  let item = submenu.items.first(where: { $0.title == title }) else {
                failures.append("missing=\(selectorName)")
                continue
            }
            let action = Selector(selectorName)
            if item.action != action || item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers
                || item.target != nil || !submenu.autoenablesItems {
                failures.append("metadata=\(selectorName)")
            }
            if application.target(forAction: action, to: item.target, from: item) as AnyObject? !== responder {
                failures.append("target=\(selectorName)")
            }
            let baseline = responder.actions.count
            if !application.sendAction(action, to: item.target, from: item)
                || responder.actions.count != baseline + 1 || responder.actions.last != selectorName {
                failures.append("routing=\(selectorName)")
            }
        }
        if application.windowsMenu !== application.mainMenu?.items.first(where: { $0.title == "窗口" })?.submenu {
            failures.append("windowMenu")
        }
        return "ApplicationMenuProbe: \(failures.isEmpty ? "PASS" : "FAIL") commands=\(expected.count) "
            + "syntheticRoutes=\(responder.actions.count)" + (failures.isEmpty ? "" : " " + failures.joined(separator: " "))
    }
}

@MainActor
private final class ApplicationMenuProbeResponder: NSResponder {
    private(set) var actions: [String] = []
    @objc func undo(_ sender: Any?) { actions.append("undo:") }
    @objc func redo(_ sender: Any?) { actions.append("redo:") }
    @objc func cut(_ sender: Any?) { actions.append("cut:") }
    @objc func copy(_ sender: Any?) { actions.append("copy:") }
    @objc func paste(_ sender: Any?) { actions.append("paste:") }
    override func selectAll(_ sender: Any?) { actions.append("selectAll:") }
    @objc func performClose(_ sender: Any?) { actions.append("performClose:") }
}
