import SwiftUI
import AppKit

extension ContentView {

    // MARK: - 层 1：照片网格

    var gridLayer: some View {
        PhotoGridView(
            store: photosStore,
            focusedID: $focusedID,
            focusedFrame: $focusedFrame,
            gridLayout: gridLayout,
            onOpenPreview: enterSingleMode,
            topGradientOpacity: $topGradientOpacity,
            bottomGradientOpacity: $bottomGradientOpacity,
            topPadding: (!photosStore.assets.isEmpty || totalClassifiedAndDeleteCount > 0) && !photosStore.isLoading ? topGradientH : 0,
            bottomPadding: stripH + stripFadeH,
            useThumbnailFit: thumbnailFit,
            sections: showClassifiedView ? classifiedSections : nil,
            externalSelectedIDs: showClassifiedView ? $classifiedSelectedIDs : nil,
            onSelectAll: showClassifiedView ? {
                self.classifiedSelectedIDs = Set(self.classifiedSections.flatMap { $0.assets.map(\.id) })
            } : nil
        )
        .padding(.trailing, panelTotalWidth)
    }

    // MARK: - 层 2：单图背景遮罩

    var backdropLayer: some View {
        Color(colorScheme == .dark ? NSColor.black : NSColor.windowBackgroundColor)
            .ignoresSafeArea()
            .opacity(previewOpacity)
            .allowsHitTesting(false)
    }

    // MARK: - 层 4：渐变 + 标题文字

    @ViewBuilder var overlayGradientLayer: some View {
        // 顶部渐变
        VStack(spacing: 0) {
            topGradientOverlay.opacity(multiQueueHint ? 1 : smallTitleOpacity)
            Spacer()
        }
        .padding(.trailing, panelTotalWidth)
        .allowsHitTesting(false)
        .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
        .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

        smallTitleOverlay
            .padding(.trailing, panelTotalWidth)
            .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
            .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

        largeTitleOverlay
            .padding(.trailing, panelTotalWidth)
            .opacity(multiQueueHint ? 1 : 1 - previewOpacity)
            .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)

        // 底部渐变
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [gradientBase.opacity(0), gradientBase.opacity(colorScheme == .dark ? 0.65 : 0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: stripFadeH + stripH)
            .opacity(bottomGradientOpacity)
        }
        .padding(.trailing, panelTotalWidth)
        .allowsHitTesting(false)
        .opacity(1 - previewOpacity)
    }

    // MARK: - 层 5：底部收藏条

    var albumStripLayer: some View {
        VStack(spacing: 0) {
            Spacer()
            AlbumStripCombined(
                favoriteNodes: albumsStore.favoriteNodes,
                recentNodes: albumsStore.recentNodes,
                onAssign: assignToAlbum,
                onReorderFavorites: albumsStore.reorderFavorites,
                isInSingleMode: stripHiddenInSingleMode,
                autoHideInSingleMode: autoHideStrip,
                forceLightText: bottomLabelIsWhite,
                pressedIndex: stripPressedIndex,
                forceShow: stripForceShow
            )
        }
        .padding(.trailing, panelTotalWidth)
    }

    // MARK: - 层 6：右侧面板

    var rightPanelLayer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ResizeDivider(width: $rightWidth, minWidth: Layout.columnWidth + 1, maxWidth: 520, side: .right)
            ColumnBrowserView(
                roots: albumsStore.roots,
                albumsStore: albumsStore,
                onAssign: assignToAlbum
            )
            .frame(width: rightWidth)
            .background(.ultraThickMaterial)
            .animation(Anim.enter, value: previewOpacity > 0.5)
        }
        .offset(x: sidebarVisible ? 0 : 1 + rightWidth)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)
    }

    // MARK: - 层 7：标题栏

    var titlebarLayer: some View {
        VStack(spacing: 0) {
            MovableTitleBarBackground()
                .frame(height: Layout.titlebarAreaHeight)
                .overlay(alignment: .trailing) { sidebarToggleButton }

            if !showingPreview && totalClassifiedAndDeleteCount > 0 {
                HStack(alignment: .center, spacing: 4) {
                    Spacer()
                    commitButton
                    modeSwitchControl.padding(.trailing, 0)
                }
                .padding(.trailing, sidebarVisible ? 1 + rightWidth + 10 : 42)
                .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)
                .transition(.opacity)
                .confirmationDialog("确认分类", isPresented: $showCommitConfirm, titleVisibility: .visible) {
                    Button("确认分类") { commitAll() }.keyboardShortcut(.defaultAction)
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将 \(totalClassifiedAndDeleteCount) 张照片写入对应相册，此操作不可撤销。")
                }
            }

            Spacer()
        }
        .animation(.easeInOut(duration: Anim.fadeInOut), value: previewOpacity > 0.5)
        .animation(.easeInOut(duration: Anim.fadeInOut), value: totalClassifiedAndDeleteCount > 0)
    }

    // MARK: - 层 8：Undo/Redo + Delete 监听

    var undoRedoLayer: some View {
        UndoRedoMonitor(
            canUndo: sortHistory.canUndo,
            canRedo: sortHistory.canRedo,
            onUndo: undoLastAction,
            onRedo: redoLastAction,
            onDelete: showClassifiedView && !isInSingleMode ? returnSelectedToUncategorized : nil,
            onCmdDelete: moveSelectedToPendingDelete,
            onToggleSidebar: toggleSidebar
        )
        .allowsHitTesting(false)
    }

    // MARK: - 权限遮罩

    var permissionOverlay: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("需要照片库权限")
                    .font(.title2.weight(.semibold))
                if photosStore.authStatus == .denied || photosStore.authStatus == .restricted {
                    Text("请前往\n系统设置 → 隐私与安全性 → 照片\n开启 PhotoSorter 的访问权限。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text("PhotoSorter 需要访问您的照片\n才能显示和整理未分类的图像。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("授权访问") { photosStore.requestAuthorization() }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(40)
        }
    }

    // MARK: - 顶部渐变 / 标题文字

    var topGradientOverlay: some View {
        LinearGradient(
            colors: [gradientBase.opacity(colorScheme == .dark ? 0.6 : 0.45), gradientBase.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: topGradientH)
    }

    var smallTitleOverlay: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 1) {
                    Text("PhotoSorter")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(displayedStatusText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .opacity(statusTextOpacity)
                        .animation(.easeInOut(duration: Anim.fadeInOut), value: statusTextOpacity)
                }
                .opacity(multiQueueHint || topGradientOpacity > 0.5 ? 1 : 0)
                .animation(.easeInOut(duration: Anim.fastFade), value: topGradientOpacity > 0.5)
                .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Layout.titlebarAreaHeight)
            .allowsHitTesting(false)

            Spacer().allowsHitTesting(false)
        }
    }

    var largeTitleOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(displayedLargeTitleText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .opacity(largeTitleTextOpacity)
                .id(showClassifiedView)
                .transition(.opacity)
            if !showClassifiedView {
                Text(displayedStatusText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .opacity(statusTextOpacity)
                    .animation(.easeInOut(duration: Anim.fadeInOut), value: statusTextOpacity)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 16)
        .padding(.top, titlebarHeight + 10)
        .opacity(largeTitleOpacity)
        .opacity(multiQueueHint ? 0 : 1 - previewOpacity)
        .animation(.easeInOut(duration: Anim.multiHintFade), value: multiQueueHint)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: Anim.fadeInOut), value: showClassifiedView)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in updateTitlebarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in updateTitlebarHeight() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in updateTitlebarHeight() }
        .onAppear { updateTitlebarHeight() }
    }

    // MARK: - Toolbar 子控件

    private var sidebarToggleButton: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    previewOpacity > 0.5
                        ? Color.primary.opacity(0.35)
                        : (!sidebarVisible && !topLabelIsWhite
                            ? Color.accentColor
                            : (topLabelIsWhite ? Color.white : Color.primary))
                )
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("显示/隐藏相册面板 (⌘\\)")
        .padding(.trailing, sidebarVisible ? 1 + rightWidth + 2 : 4)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: sidebarVisible)
        .animation(.easeInOut(duration: Anim.fadeInOut), value: previewOpacity > 0.5)
        .animation(.easeInOut(duration: Anim.fadeInOut), value: topLabelIsWhite)
    }

    private var commitButton: some View {
        Button { showCommitConfirm = true } label: {
            ZStack {
                Circle().fill(Color.green).frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("确认分类（将所有已分类照片写入相册）")
    }

    var modeSwitchControl: some View {
        HStack(spacing: 0) {
            modeButton(title: "未归类", count: photosStore.assets.count, active: !showClassifiedView) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { showClassifiedView = false }
                topGradientOpacity = 0
                bottomGradientOpacity = 0
                classifiedSelectedIDs = []
                focusedID = nil
            }
            modeButton(title: "已分类", count: totalClassifiedAndDeleteCount, active: showClassifiedView) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { showClassifiedView = true }
                topGradientOpacity = 0
                bottomGradientOpacity = 0
                photosStore.clearSelection()
                focusedID = nil
            }
        }
        .background(
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }

    func modeButton(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if active {
                            Capsule().fill(Color.accentColor)
                                .matchedGeometryEffect(id: "modePill", in: modeSwitchNS)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}
