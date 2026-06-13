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
        let fullScreenItem = NSMenuItem(title: "进入全屏幕",
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        appMenu.addItem(fullScreenItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PhotoSorter",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Library menu
        let libraryItem = NSMenuItem(title: "照片库", action: nil, keyEquivalent: "")
        menu.addItem(libraryItem)
        let libraryMenu = NSMenu(title: "照片库")
        libraryItem.submenu = libraryMenu
        libraryMenu.addItem(withTitle: "刷新照片库",
                            action: #selector(refreshAll),
                            keyEquivalent: "r")
        libraryMenu.addItem(withTitle: "选择照片库…",
                            action: #selector(selectPhotoLibrary),
                            keyEquivalent: "")

        // Strip menu
        let stripItem = NSMenuItem(title: "收藏条", action: nil, keyEquivalent: "")
        menu.addItem(stripItem)
        let stripMenu = NSMenu(title: "收藏条")
        stripItem.submenu = stripMenu
        stripMenu.addItem(withTitle: "删除全部收藏相册",
                          action: #selector(clearFavoriteAlbums),
                          keyEquivalent: "")
        stripMenu.addItem(withTitle: "删除最近使用历史",
                          action: #selector(clearRecentAlbums),
                          keyEquivalent: "")

        // View menu
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let hideStripItem = NSMenuItem(title: "单图模式自动隐藏收藏条",
                                       action: #selector(toggleAutoHideStrip),
                                       keyEquivalent: "")
        hideStripItem.state = UserDefaults.standard.object(forKey: Prefs.autoHideStrip) == nil
            ? .on
            : (UserDefaults.standard.bool(forKey: Prefs.autoHideStrip) ? .on : .off)
        viewMenu.addItem(hideStripItem)

        let videoLoopItem = NSMenuItem(title: "视频循环播放",
                                       action: #selector(toggleVideoLoop),
                                       keyEquivalent: "")
        videoLoopItem.state = UserDefaults.standard.bool(forKey: Prefs.videoLoop) ? .on : .off
        viewMenu.addItem(videoLoopItem)

        let thumbnailFitItem = NSMenuItem(title: "按比例显示缩略图",
                                          action: #selector(toggleThumbnailFit),
                                          keyEquivalent: "")
        thumbnailFitItem.state = UserDefaults.standard.bool(forKey: Prefs.thumbnailFit) ? .on : .off
        viewMenu.addItem(thumbnailFitItem)

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

    @objc func selectPhotoLibrary() {
        let panel = NSOpenPanel()
        panel.title = "选择包含照片库的文件夹"
        panel.message = "请选择 .photoslibrary 所在的文件夹（通常是 Pictures）"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if url.pathExtension == "photoslibrary" {
                // 直接选中了 .photoslibrary 本身
                UserDefaults.standard.set(url.path, forKey: Prefs.photoLibraryPath)
                NotificationCenter.default.post(name: .refreshRequested, object: nil)
            } else {
                // 选的是普通文件夹，扫描里面的 .photoslibrary
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                let libraries = items.filter { $0.pathExtension == "photoslibrary" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !libraries.isEmpty else {
                    let a = NSAlert()
                    a.messageText = "未找到照片库"
                    a.informativeText = "所选文件夹中没有 .photoslibrary 文件。"
                    a.runModal()
                    return
                }
                if libraries.count == 1 {
                    UserDefaults.standard.set(libraries[0].path, forKey: Prefs.photoLibraryPath)
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                } else {
                    self?.showLibraryPicker(libraries: libraries)
                }
            }
        }
    }

    private func showLibraryPicker(libraries: [URL]) {
        let alert = NSAlert()
        alert.messageText = "选择照片库"
        alert.informativeText = "找到多个照片库，请选择："
        for lib in libraries { alert.addButton(withTitle: lib.lastPathComponent) }
        alert.addButton(withTitle: "取消")
        let idx = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard idx >= 0 && idx < libraries.count else { return }
        UserDefaults.standard.set(libraries[idx].path, forKey: Prefs.photoLibraryPath)
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
    }

    @objc func clearFavoriteAlbums() {
        let alert = NSAlert()
        alert.messageText = "删除全部收藏相册？"
        alert.informativeText = "收藏条中的所有相册将被移除，此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NotificationCenter.default.post(name: .clearFavoritesRequested, object: nil)
    }

    @objc func clearRecentAlbums() {
        let alert = NSAlert()
        alert.messageText = "删除最近使用历史？"
        alert.informativeText = "最近使用的相册记录将被清空，此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NotificationCenter.default.post(name: .clearRecentRequested, object: nil)
    }

    @objc func toggleAutoHideStrip(_ sender: NSMenuItem) {
        let newState = sender.state == .on ? false : true
        sender.state = newState ? .on : .off
        UserDefaults.standard.set(newState, forKey: Prefs.autoHideStrip)
        NotificationCenter.default.post(name: .autoHideStripToggled, object: newState)
    }

    @objc func toggleVideoLoop(_ sender: NSMenuItem) {
        let newState = sender.state != .on
        sender.state = newState ? .on : .off
        UserDefaults.standard.set(newState, forKey: Prefs.videoLoop)
        NotificationCenter.default.post(name: .videoLoopToggled, object: newState)
    }

    @objc func toggleThumbnailFit(_ sender: NSMenuItem) {
        let newState = sender.state != .on
        sender.state = newState ? .on : .off
        UserDefaults.standard.set(newState, forKey: Prefs.thumbnailFit)
        NotificationCenter.default.post(name: .thumbnailFitToggled, object: newState)
    }
}
