import SwiftUI
import Photos
import AppKit

// MARK: - ContentView

struct ContentView: View {

    // MARK: - 数据层

    @State var photosStore: PhotosStore
    @State var albumsStore = AlbumsStore()
    @State var sortHistory = SortHistory()

    // MARK: - 视图模式

    @State var showClassifiedView = false
    @State var classifiedSelectedIDs: Set<String> = []

    // MARK: - 弹窗开关

    @State var showCommitConfirm = false
    @State var showQuitConfirm = false
    @State var showQuitUncategorized = false
    @State var showRefreshConfirm = false

    // MARK: - 右侧面板

    @State var rightWidth: CGFloat = Layout.columnWidth + 1
    @State var sidebarVisible: Bool = UserDefaults.standard.object(forKey: Prefs.sidebarVisible) == nil
        ? true
        : UserDefaults.standard.bool(forKey: Prefs.sidebarVisible)

    // MARK: - 网格聚焦 / 选中

    @State var focusedID: String?
    @State var focusedFrame: CGRect = .zero
    @State var gridLayout = GridLayout()

    // MARK: - 单图模式

    @State var isInSingleMode = false
    @State var showingPreview = false
    @State var previewOpacity: CGFloat = 0
    @State var dismissBegun = false
    @State var singleModeInitialIndex: Int = 0
    @State var singleModeCurrentIndex: Int = 0
    @State var singleModeAssets: [PhotoAsset] = []
    @State var pendingDismissWork: DispatchWorkItem?
    @State var singleEnterTrigger: Int = 0
    @State var multiQueueHint = false
    /// Space 键按下时记录的 sessionID，用于 SinglePhotoView 忽略同次 keyUp。
    @State var spaceEnterSessionID: Int? = nil

    // MARK: - 标题栏文字动画

    @State var statusTextOpacity: Double = 1
    @State var displayedStatusText: String = ""
    @State var displayedLargeTitleText: String = ""
    @State var largeTitleTextOpacity: Double = 1
    @State var topHintText: String? = nil
    @State var topHintTask: Task<Void, Never>? = nil
    @State var titlebarHeight: CGFloat = 28

    // MARK: - 渐变

    @State var topGradientOpacity: CGFloat = 0
    @State var bottomGradientOpacity: CGFloat = 1

    // MARK: - 收藏条

    @State var autoHideStrip: Bool = UserDefaults.standard.object(forKey: Prefs.autoHideStrip) == nil
        ? true
        : UserDefaults.standard.bool(forKey: Prefs.autoHideStrip)
    /// 数字键高亮的收藏条索引（长按时显示）。
    @State var stripPressedIndex: Int? = nil
    /// 数字键长按时强制显示收藏条（否则自动隐藏）。
    @State var stripForceShow: Bool = false

    // MARK: - 缩略图

    @State var thumbnailFit: Bool = UserDefaults.standard.bool(forKey: Prefs.thumbnailFit)

    // MARK: - 常量

    let topGradientH  = Layout.topGradientHeight
    let stripH        = Layout.stripHeight
    let stripFadeH    = Layout.stripFadeHeight

    @Environment(\.colorScheme) var colorScheme
    let gradientBase: Color = .black
    @Namespace var modeSwitchNS

    // MARK: - Init

    init() {
        _photosStore = State(initialValue: PhotosStore())
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            gridLayer
            backdropLayer
            if isInSingleMode { singlePhotoView.transition(.identity) }
            if (!photosStore.assets.isEmpty || totalClassifiedAndDeleteCount > 0) && !photosStore.isLoading {
                overlayGradientLayer
            }
            albumStripLayer
            rightPanelLayer
            titlebarLayer
            if needsPermission { permissionOverlay }
            GlobalKeyMonitor().allowsHitTesting(false)
            undoRedoLayer
        }
        .onAppear {
            photosStore.checkCurrentAuthorization()
            albumsStore.reload()
            displayedStatusText = statusText
            displayedLargeTitleText = largeTitleSource
        }
        .onChange(of: statusText, animateStatusText)
        .onChange(of: largeTitleSource, animateLargeTitleText)
        .onChange(of: photosStore.authStatus) { _, status in
            guard status == .authorized || status == .limited else { return }
            photosStore.loadUncategorized()
            albumsStore.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
            if totalClassifiedAndDeleteCount > 0 {
                showRefreshConfirm = true
            } else {
                photosStore.loadUncategorized()
                albumsStore.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoHideStripToggled)) { note in
            if let val = note.object as? Bool { autoHideStrip = val }
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailFitToggled)) { note in
            if let val = note.object as? Bool { thumbnailFit = val }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceDown)) { note in
            guard let ev = note.object as? SpaceKeyEvent else { return }
            guard !isInSingleMode else { return }
            spaceEnterSessionID = ev.sessionID
            enterSingleMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyUp)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            let nodes = albumsStore.favoriteNodes
            guard nodes.indices.contains(key) else { return }
            assignToAlbum(nodes[key])
            stripPressedIndex = key
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnHighlightDelay + Anim.columnClearDelay) {
                if self.stripPressedIndex == key { self.stripPressedIndex = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyLongPress)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            stripPressedIndex = key
            if autoHideStrip { stripForceShow = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyLongPressEnd)) { note in
            guard let key = (note.object as? NSNumber)?.intValue, key >= 0 else { return }
            stripForceShow = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.columnClearDelay) {
                if self.stripPressedIndex == key { self.stripPressedIndex = nil }
            }
        }
        .alert("还有待删除的照片", isPresented: $showQuitConfirm) {
            Button("返回") { NSApp.reply(toApplicationShouldTerminate: false) }
        } message: {
            Text("有 \(sortHistory.pendingDeleteAssets.count) 张照片在「待删除」分组中尚未删除。\n请先点击垃圾桶图标完成删除，再退出。")
        }
        .alert("确认归类", isPresented: $showQuitUncategorized) {
            Button("确认归类并退出") { commitAllAndQuit() }
            Button("取消", role: .cancel) { NSApp.reply(toApplicationShouldTerminate: false) }
        } message: {
            let sorted = sortHistory.totalSortedCount
            let uncategorized = photosStore.assets.count
            if uncategorized > 0 {
                Text("将把 \(sorted) 张照片写入相册，还有 \(uncategorized) 张未归类照片将保留。")
            } else {
                Text("将把 \(sorted) 张照片写入相册。")
            }
        }
        .alert("确认刷新", isPresented: $showRefreshConfirm) {
            Button("确定", role: .destructive) {
                sortHistory.clearAll()
                showClassifiedView = false
                classifiedSelectedIDs = []
                photosStore.loadUncategorized()
                albumsStore.reload()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("刷新将清除所有已分类操作（共 \(totalClassifiedAndDeleteCount) 张），此操作不可撤销。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldTerminateWithConfirm)) { _ in
            if sortHistory.hasPendingDeletes {
                showQuitConfirm = true
            } else if sortHistory.totalSortedCount > 0 {
                showQuitUncategorized = true
            } else {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmDeletePending)) { _ in
            permanentlyDeletePending()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sortedSelectionShouldClear)) { _ in
            classifiedSelectedIDs = []
            focusedID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .sortedViewShouldDismiss)) { _ in
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { showClassifiedView = false }
            classifiedSelectedIDs = []
            focusedID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetsDidSort)) { note in
            if let msg = note.object as? String { showTopHint(msg) }
            guard !showClassifiedView, photosStore.assets.isEmpty, totalClassifiedAndDeleteCount > 0 else { return }
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { showClassifiedView = true }
            photosStore.clearSelection()
            focusedID = nil
        }
    }

    // MARK: - Computed

    var totalClassifiedAndDeleteCount: Int {
        sortHistory.totalSortedCount + sortHistory.pendingDeleteAssets.count
    }

    var classifiedSections: [SectionData] {
        var secs = sortHistory.groupedByAlbum.map {
            SectionData(header: $0.albumNode.title, assets: $0.assets)
        }
        if !sortHistory.pendingDeleteAssets.isEmpty {
            let sorted = sortHistory.pendingDeleteAssets.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            secs.append(SectionData(header: "待删除", assets: sorted, isDeleteGroup: true))
        }
        return secs
    }

    var needsPermission: Bool {
        photosStore.authStatus == .notDetermined
        || photosStore.authStatus == .denied
        || photosStore.authStatus == .restricted
    }

    /// 收藏条：单图模式进行中（非退场阶段）时隐藏。
    var stripHiddenInSingleMode: Bool { showingPreview && !dismissBegun }

    /// 面板总宽度 = 分割线(1pt) + 列浏览器；隐藏时为 0。
    var panelTotalWidth: CGFloat { sidebarVisible ? 1 + rightWidth : 0 }

    var statusText: String {
        if let hint = topHintText { return hint }
        if multiQueueHint { return "已进入多选队列（\(singleModeAssets.count) 张）" }
        if showClassifiedView {
            let sel = classifiedSelectedIDs.count
            let total = totalClassifiedAndDeleteCount
            if sel > 0 { return "已选 \(sel) / \(total) 张（已分类）" }
            return "已分类 \(total) 张"
        }
        let sel   = photosStore.selectedIDs.count
        let total = photosStore.assets.count
        if sel > 0 { return "已选 \(sel) / \(total) 张" }
        return "共 \(total) 张未归类"
    }

    var largeTitleSource: String { showClassifiedView ? statusText : "PhotoSorter" }

    /// 大标题：顶部渐变 0→0.5 段淡出；multiQueueHint 时强制隐藏。
    var largeTitleOpacity: Double {
        multiQueueHint ? 0 : max(0, 1 - Double(topGradientOpacity) * 2)
    }

    /// 小标题：顶部渐变 0.5→1 段淡入；multiQueueHint 时强制显示。
    var smallTitleOpacity: Double {
        multiQueueHint ? 1 : max(0, Double(topGradientOpacity) * 2 - 1)
    }

    /// 顶部渐变过半时，浅色模式下文字切白色。
    var topLabelIsWhite: Bool {
        colorScheme == .dark || topGradientOpacity > 0.5
    }

    /// 底部渐变过半时收藏条文字切白色；单图浅色模式保持深色。
    var bottomLabelIsWhite: Bool {
        let hasPhotos = !photosStore.assets.isEmpty || totalClassifiedAndDeleteCount > 0
        let inSingle = showingPreview && !dismissBegun
        if inSingle && colorScheme == .light { return false }
        return hasPhotos && (colorScheme == .dark || bottomGradientOpacity > 0.5)
    }

    /// 当前归类操作的目标 ID 列表（单图 > 多选 > 聚焦）。
    var assignIDs: [String] {
        if showClassifiedView {
            if !classifiedSelectedIDs.isEmpty { return Array(classifiedSelectedIDs) }
            if isInSingleMode, singleModeAssets.indices.contains(singleModeCurrentIndex) {
                return [singleModeAssets[singleModeCurrentIndex].id]
            }
            if let id = focusedID { return [id] }
            return []
        }
        if !photosStore.selectedIDs.isEmpty { return Array(photosStore.selectedIDs) }
        if isInSingleMode, singleModeAssets.indices.contains(singleModeCurrentIndex) {
            return [singleModeAssets[singleModeCurrentIndex].id]
        }
        if let id = focusedID { return [id] }
        return []
    }

    // MARK: - Misc Actions

    func toggleSidebar() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            sidebarVisible.toggle()
        }
        UserDefaults.standard.set(sidebarVisible, forKey: Prefs.sidebarVisible)
    }

    func showTopHint(_ text: String, duration: Double = Anim.hintDuration) {
        topHintTask?.cancel()
        topHintText = text
        topHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            topHintText = nil
        }
    }

    func updateTitlebarHeight() {
        guard let win = NSApp.mainWindow else { return }
        let h = win.frame.height - win.contentLayoutRect.maxY
        if abs(h - titlebarHeight) > 0.5 { titlebarHeight = h }
    }

    // MARK: - Private: 标题文字淡入淡出

    private func animateStatusText(oldText: String, newText: String) {
        func prefix(_ s: String) -> String { s.components(separatedBy: CharacterSet.decimalDigits).first ?? s }
        if prefix(oldText) == prefix(newText) {
            displayedStatusText = newText
        } else {
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { statusTextOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.fadeInOut) {
                self.displayedStatusText = newText
                withAnimation(.easeInOut(duration: Anim.fadeInOut)) { self.statusTextOpacity = 1 }
            }
        }
    }

    private func animateLargeTitleText(oldText: String, newText: String) {
        func prefix(_ s: String) -> String { s.components(separatedBy: CharacterSet.decimalDigits).first ?? s }
        if prefix(oldText) == prefix(newText) {
            displayedLargeTitleText = newText
        } else {
            withAnimation(.easeInOut(duration: Anim.fadeInOut)) { largeTitleTextOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Anim.fadeInOut) {
                self.displayedLargeTitleText = newText
                withAnimation(.easeInOut(duration: Anim.fadeInOut)) { self.largeTitleTextOpacity = 1 }
            }
        }
    }
}
