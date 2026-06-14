import SwiftUI

extension ContentView {

    // MARK: - Single Photo View（ZStack 层）

    @ViewBuilder var singlePhotoView: some View {
        SinglePhotoView(
            assets: singleModeAssets,
            initialIndex: singleModeInitialIndex,
            enterTrigger: singleEnterTrigger,
            sourceFrame: $focusedFrame,
            backdropOpacity: $previewOpacity,
            getGridFrame: { [self] localIdx in
                let id = localIdx < singleModeAssets.count ? singleModeAssets[localIdx].id : nil
                guard let eid = id else { return gridLayout.frameFor(index: localIdx) }
                return gridLayout.frameFor(index: flatIndexOf(id: eid) ?? localIdx)
            },
            onIndexChange: { singleModeCurrentIndex = $0 },
            onBeforeDismiss: { [self] localIdx in
                let id = localIdx < singleModeAssets.count ? singleModeAssets[localIdx].id : nil
                guard let eid = id, let idx = flatIndexOf(id: eid) else { return }
                gridLayout.scrollToVisible?(idx)
            },
            onDismissBegin: { dismissBegun = true },
            onDismiss: { [self] finalIndex in
                let work = DispatchWorkItem {
                    self.isInSingleMode = false
                    self.showingPreview = false
                    self.dismissBegun = false
                    let dismissedID = self.singleModeAssets.indices.contains(finalIndex)
                        ? self.singleModeAssets[finalIndex].id : nil
                    if let id = dismissedID { self.focusedID = id }
                }
                pendingDismissWork = work
                DispatchQueue.main.async(execute: work)
            },
            spaceEnterSessionID: spaceEnterSessionID,
            panelWidth: panelTotalWidth,
            swipeExcludeBottom: stripH,
            swipeExcludeRight: panelTotalWidth,
            useThumbnailFit: thumbnailFit
        )
        .transition(.identity)
    }

    // MARK: - Enter / Exit

    func enterSingleMode() {
        if isInSingleMode {
            // 退场动画进行中：取消回调，重触进场动画
            pendingDismissWork?.cancel()
            pendingDismissWork = nil
            showingPreview = true
            dismissBegun = false
            singleEnterTrigger += 1
            return
        }
        guard let id = focusedID else { return }

        // 进入前刷新 focusedFrame（由布局计算得出，不依赖滚动状态）
        if let idx = flatIndexOf(id: id) {
            let frame = gridLayout.frameFor(index: idx)
            if frame != .zero { focusedFrame = frame }
        }

        if showClassifiedView {
            buildSingleQueue_classified(startID: id)
        } else {
            buildSingleQueue_uncategorized(startID: id)
        }

        showingPreview = true
        isInSingleMode = true
        singleEnterTrigger += 1
    }

    // MARK: - Queue Sync

    /// 单图模式下，重建队列使其与 photosStore.assets 保持同步。
    func syncSingleModeAssetsIfNeeded() {
        guard isInSingleMode else { return }
        let newQueue = photosStore.assets
        guard newQueue.map(\.id) != singleModeAssets.map(\.id) else { return }

        let currentID = singleModeAssets.indices.contains(singleModeCurrentIndex)
            ? singleModeAssets[singleModeCurrentIndex].id : nil

        singleModeAssets = newQueue

        if let id = currentID, let idx = newQueue.firstIndex(where: { $0.id == id }) {
            singleModeCurrentIndex = idx
        } else {
            singleModeCurrentIndex = min(singleModeCurrentIndex, max(0, newQueue.count - 1))
        }
    }

    // MARK: - Private helpers

    /// 根据 id 计算在当前展示数据中的扁平索引。
    private func flatIndexOf(id: String) -> Int? {
        if showClassifiedView {
            let secs = classifiedSections
            var off = 0
            for sec in secs {
                if let i = sec.assets.firstIndex(where: { $0.id == id }) { return off + i }
                off += sec.assets.count
            }
            return nil
        } else {
            return photosStore.assets.firstIndex(where: { $0.id == id })
        }
    }

    private func buildSingleQueue_classified(startID: String) {
        let secs = classifiedSections
        if classifiedSelectedIDs.count > 1 {
            let allAssets = secs.flatMap(\.assets)
            let queue = allAssets.filter { classifiedSelectedIDs.contains($0.id) }
            guard !queue.isEmpty else { return }
            let startIdx = queue.firstIndex(where: { $0.id == startID }) ?? 0
            singleModeAssets = queue
            singleModeInitialIndex = startIdx
            singleModeCurrentIndex = startIdx
            triggerMultiQueueHint()
        } else {
            let queue = secs.first(where: { $0.assets.contains(where: { $0.id == startID }) })?.assets
                ?? secs.flatMap(\.assets)
            guard let startIdx = queue.firstIndex(where: { $0.id == startID }) else { return }
            singleModeAssets = queue
            singleModeInitialIndex = startIdx
            singleModeCurrentIndex = startIdx
        }
    }

    private func buildSingleQueue_uncategorized(startID: String) {
        let sel = photosStore.selectedIDs
        if sel.count > 1 {
            let queue = photosStore.assets.filter { sel.contains($0.id) }
            guard !queue.isEmpty else { return }
            let startIdx = queue.firstIndex(where: { $0.id == startID }) ?? 0
            singleModeAssets = queue
            singleModeInitialIndex = startIdx
            singleModeCurrentIndex = startIdx
            triggerMultiQueueHint()
        } else {
            guard let idx = photosStore.assets.firstIndex(where: { $0.id == startID }) else { return }
            singleModeAssets = photosStore.assets
            singleModeInitialIndex = idx
            singleModeCurrentIndex = idx
        }
    }

    private func triggerMultiQueueHint() {
        multiQueueHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Anim.hintDuration) {
            withAnimation(.easeInOut(duration: Anim.multiHintFade)) { self.multiQueueHint = false }
        }
    }
}
