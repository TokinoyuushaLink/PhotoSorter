import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()

        // App menu
        let appItem = NSMenuItem(title: "PhotoSorter", action: nil, keyEquivalent: "")
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 PhotoSorter",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // View menu
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "刷新照片库",
                         action: #selector(refreshAll),
                         keyEquivalent: "r")
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: "进入全屏幕",
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(.separator())
        let hideStripItem = NSMenuItem(title: "单图模式自动隐藏收藏条",
                                       action: #selector(toggleAutoHideStrip),
                                       keyEquivalent: "")
        hideStripItem.state = UserDefaults.standard.object(forKey: Prefs.autoHideStrip) == nil
            ? .on  // 默认开启
            : (UserDefaults.standard.bool(forKey: Prefs.autoHideStrip) ? .on : .off)
        viewMenu.addItem(hideStripItem)

        NSApp.mainMenu = menu

        let hostingView = NSHostingView(rootView: ContentView().ignoresSafeArea())
        hostingView.sizingOptions = []   // 禁止 hosting view 把内容 intrinsic size 上报给窗口
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowInitialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "PhotoSorter"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.contentView = hostingView
        win.center()
        win.minSize = Layout.windowMinSize
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false   // let terminate flow handle actual closing
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always show quit confirmation (pending deletes or uncategorized count)
        NotificationCenter.default.post(name: .appShouldTerminateWithConfirm, object: nil)
        return .terminateLater
    }

    @objc func refreshAll() {
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
    }

    @objc func toggleAutoHideStrip(_ sender: NSMenuItem) {
        let newState = sender.state == .on ? false : true
        sender.state = newState ? .on : .off
        UserDefaults.standard.set(newState, forKey: Prefs.autoHideStrip)
        NotificationCenter.default.post(name: .autoHideStripToggled, object: newState)
    }
}
