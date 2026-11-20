import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var model: AppModel!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        AppModel.shared = model
        self.model = model

        buildMainMenu()
        setupStatusItem()
        buildWindow()
        model.bootstrap()

        if ProcessInfo.processInfo.arguments.contains("--background") == false {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    // MARK: 主窗口

    private func buildWindow() {
        let hosting = NSHostingView(rootView: RootView(model: model))
        let frame = NSRect(x: 0, y: 0, width: 980, height: 760)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WebDAV 服务器"
        window.contentView = hosting
        window.minSize = NSSize(width: 940, height: 700)
        window.setFrameAutosaveName("WebDAVServerMainWindow")
        if window.frame.width < 940 {
            window.setContentSize(NSSize(width: 980, height: 760))
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        self.window = window
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "WebDAV 服务器")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "WebDAV 服务器"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button, let model else { return }
        let active = model.server.state.isActive
        let image = NSImage(systemSymbolName: active ? "server.rack" : "server.rack", accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !active
        button.toolTip = "WebDAV 服务器：\(model.server.state.label)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }

        let status = NSMenuItem(title: "状态：\(model.server.state.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let lan = model.lanAddress {
            let item = NSMenuItem(title: "局域网：\(lan)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let remote = model.remoteAddress {
            let item = NSMenuItem(title: "外网：\(remote)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开主窗口", action: #selector(showWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let toggleTitle = model.server.state.isActive ? "停止共享" : "开始共享"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleServer), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)

        if model.lanAddress != nil {
            let copyItem = NSMenuItem(title: "复制局域网地址", action: #selector(copyLanAddress), keyEquivalent: "c")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 WebDAV 服务器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleServer() {
        model?.toggleServer()
        refreshStatusItem()
    }

    @objc private func copyLanAddress() {
        guard let lan = model?.lanAddress else { return }
        model?.copy(lan)
    }

    // MARK: 应用菜单

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appName = "WebDAV 服务器"

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开主窗口", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "服务", action: nil, keyEquivalent: "").isEnabled = false
        let start = NSMenuItem(title: "开始共享", action: #selector(menuStartServer), keyEquivalent: "")
        start.target = self
        appMenu.addItem(start)
        let stop = NSMenuItem(title: "停止共享", action: #selector(menuStopServer), keyEquivalent: "")
        stop.target = self
        appMenu.addItem(stop)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuStartServer() {
        model?.startAll()
        refreshStatusItem()
    }

    @objc private func menuStopServer() {
        model?.stopAll()
        refreshStatusItem()
    }
}
