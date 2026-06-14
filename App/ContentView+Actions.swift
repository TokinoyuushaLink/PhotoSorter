import SwiftUI
import Photos

extension ContentView {

    // MARK: - Assign

    func assignToAlbum(_ node: AlbumNode) {
        guard !node.isFolder, let collection = node.assetCollection else { return }
        let ids = assignIDs
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }
        let isSingleGrid = !isInSingleMode && photosStore.selectedIDs.isEmpty && focusedID != nil
        let preFocusIdx  = focusedID.flatMap { id in photosStore.assets.firstIndex(where: { $0.id == id }) }
        let assignedIDSet = Set(ids)
        photosStore.addIDs(ids, to: collection, albumNode: node, history: sortHistory) {
            albumsStore.recordRecent(node)
            albumsStore.reload()
            if self.isInSingleMode {
                self.singleModeAssets = self.singleModeAssets.filter { !assignedIDSet.contains($0.id) }
            } else {
                guard isSingleGrid else { return }
                let remaining = self.photosStore.assets
                if remaining.isEmpty { self.focusedID = nil }
                else if let idx = preFocusIdx {
                    self.focusedID = remaining[min(idx, remaining.count - 1)].id
                }
            }
        }
    }

    // MARK: - Delete Actions

    /// Cmd+Delete：已分类视图中 pending-delete 组 → 归还未归类；相册组 → 移入 pending-delete；
    ///             未归类视图 → 移入 pending-delete。
    func moveSelectedToPendingDelete() {
        let ids = showClassifiedView ? assignIDsForClassified() : assignIDs
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }

        if showClassifiedView {
            let idSet = Set(ids)
            let pendingIDs = Set(sortHistory.pendingDeleteAssets.map(\.id))

            let toRestore = sortHistory.pendingDeleteAssets.filter { idSet.contains($0.id) }
            if !toRestore.isEmpty {
                let restoreIDs = Set(toRestore.map(\.id))
                sortHistory.removeFromPendingDelete(ids: restoreIDs)
                photosStore.restoreAssets(toRestore)
                sortHistory.record(SortAction(kind: .restoreFromPendingDelete, assets: toRestore))
                showTopHint("已将 \(toRestore.count) 张照片归还未归类")
                postClassifiedCompletionNotification()
                syncSingleModeAssetsIfNeeded()
            }

            let toDelete = sortHistory.groupedByAlbum.flatMap(\.assets)
                .filter { idSet.contains($0.id) && !pendingIDs.contains($0.id) }
            if !toDelete.isEmpty {
                moveAlbumAssetsToPendingDelete(assets: toDelete)
            }

            if toRestore.isEmpty && toDelete.isEmpty { showTopHint("请先选择照片") }
        } else {
            let toDelete = photosStore.assets.filter { ids.contains($0.id) }
            guard !toDelete.isEmpty else { return }
            let isSingleGrid = !isInSingleMode && photosStore.selectedIDs.isEmpty && focusedID != nil
            let preFocusIdx = focusedID.flatMap { id in photosStore.assets.firstIndex(where: { $0.id == id }) }
            sortHistory.addPendingDelete(toDelete)
            photosStore.removeAssetsDirectly(ids: ids)
            photosStore.clearSelection()
            sortHistory.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: nil), assets: toDelete))
            showTopHint("已标记 \(toDelete.count) 张照片为待删除")
            if isSingleGrid {
                let remaining = photosStore.assets
                focusedID = remaining.isEmpty ? nil : remaining[min(preFocusIdx ?? 0, remaining.count - 1)].id
            }
            syncSingleModeAssetsIfNeeded()
        }
    }

    /// Delete（无修饰键），仅在已分类视图有效：相册组 → 归还未归类。
    func returnSelectedToUncategorized() {
        guard showClassifiedView else { return }
        let ids = assignIDsForClassified()
        guard !ids.isEmpty else { showTopHint("请先选择照片"); return }

        let groups = sortHistory.groupedByAlbum
        var allRestored: [PhotoAsset] = []
        for g in groups {
            let matching = g.assets.filter { ids.contains($0.id) }
            if !matching.isEmpty {
                allRestored.append(contentsOf: matching)
                sortHistory.record(SortAction(kind: .returnToUncategorized(albumNode: g.albumNode), assets: matching))
            }
        }
        guard !allRestored.isEmpty else { return }

        sortHistory.removeAssetsFromHistory(ids: Set(ids))
        photosStore.restoreAssets(allRestored)
        showTopHint("已将 \(allRestored.count) 张照片归还未归类")
        postClassifiedCompletionNotification()
        syncSingleModeAssetsIfNeeded()
    }

    /// 将已分类相册组的资产移入 pending-delete。
    func moveAlbumAssetsToPendingDelete(assets: [PhotoAsset]) {
        let groups = sortHistory.groupedByAlbum
        let ids = Set(assets.map(\.id))
        for g in groups {
            let matching = g.assets.filter { ids.contains($0.id) }
            if !matching.isEmpty {
                sortHistory.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: g.albumNode), assets: matching))
            }
        }
        sortHistory.addPendingDelete(assets)
        sortHistory.removeAssetsFromHistory(ids: ids)
        showTopHint("已标记 \(assets.count) 张照片为待删除")
        postClassifiedCompletionNotification()
    }

    func permanentlyDeletePending() {
        let assets = sortHistory.pendingDeleteAssets
        guard !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        var phAssets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            .enumerateObjects { a, _, _ in phAssets.append(a) }
        let history = sortHistory
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(phAssets as NSFastEnumeration)
        }) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                let deletedIDs = Set(assets.map(\.id))
                history.removeAssetsFromHistory(ids: deletedIDs)
                history.clearPendingDeletes()
                ContentView.postClassifiedCompletionNotification(history: history)
            }
        }
    }

    // MARK: - Commit

    /// 批量写入 Photos 框架（不退出）。
    func commitAll() {
        let groups = sortHistory.groupedByAlbum
        let pending = sortHistory.pendingDeleteAssets

        var total = groups.count + (pending.isEmpty ? 0 : 1)
        guard total > 0 else { return }

        func done() {
            total -= 1
            guard total == 0 else { return }
            sortHistory.clearAll()
            showClassifiedView = false
            ContentView.postClassifiedCompletionNotification(history: sortHistory)
            showTopHint("分类完成")
        }

        for g in groups {
            guard let collection = g.albumNode.assetCollection else { done(); continue }
            let phAssets = fetchPHAssets(for: g.assets)
            guard !phAssets.isEmpty else { done(); continue }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }

        if !pending.isEmpty {
            var phAssets: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: pending.map(\.id), options: nil)
                .enumerateObjects { a, _, _ in phAssets.append(a) }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }
    }

    /// 批量写入 Photos 框架后退出。
    func commitAllAndQuit() {
        let groups = sortHistory.groupedByAlbum
        guard !groups.isEmpty else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }

        var total = groups.count
        func done() {
            total -= 1
            if total == 0 { NSApp.reply(toApplicationShouldTerminate: true) }
        }

        for g in groups {
            guard let collection = g.albumNode.assetCollection else { done(); continue }
            let phAssets = fetchPHAssets(for: g.assets)
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest(for: collection)?.addAssets(phAssets as NSFastEnumeration)
            }) { _, _ in DispatchQueue.main.async { done() } }
        }
    }

    // MARK: - Undo / Redo

    func undoLastAction() {
        guard let action = sortHistory.popUndo() else { return }
        let history = sortHistory
        let store = photosStore

        switch action.kind {

        case .classify(let albumNode):
            store.restoreAssets(action.assets)
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片从「\(albumNode.title)」移回")
            ContentView.postClassifiedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .returnToUncategorized(let albumNode):
            let ids = action.assets.map(\.id)
            store.removeAssetsDirectly(ids: ids)
            history.record(SortAction(kind: .classify(albumNode: albumNode), assets: action.assets))
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片移回「\(albumNode.title)」")
            ContentView.postClassifiedCompletionNotification(history: history)

        case .moveToPendingDelete(let sourceAlbumNode):
            let restoreAssets = action.assets
            let restoreIDs = Set(restoreAssets.map(\.id))
            history.removeFromPendingDelete(ids: restoreIDs)
            if let albumNode = sourceAlbumNode {
                history.record(SortAction(kind: .classify(albumNode: albumNode), assets: restoreAssets))
                history.pushRedo(action)
                showTopHint("已撤销：\(restoreAssets.count) 张照片移回「\(albumNode.title)」")
                ContentView.postClassifiedCompletionNotification(history: history)
            } else {
                store.restoreAssets(restoreAssets)
                history.pushRedo(action)
                showTopHint("已撤销：\(restoreAssets.count) 张照片从待删除移回未归类")
                ContentView.postClassifiedCompletionNotification(history: history)
                syncSingleModeAssetsIfNeeded()
            }

        case .restoreFromPendingDelete:
            history.addPendingDelete(action.assets)
            store.removeAssetsDirectly(ids: action.assets.map(\.id))
            history.pushRedo(action)
            showTopHint("已撤销：\(action.assets.count) 张照片移回待删除")
            ContentView.postClassifiedCompletionNotification(history: history)
        }
    }

    func redoLastAction() {
        guard let action = sortHistory.popRedo() else { return }
        let history = sortHistory
        let store = photosStore

        switch action.kind {

        case .classify(let albumNode):
            store.removeAssetsDirectly(ids: action.assets.map(\.id))
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片归入「\(albumNode.title)」")
            ContentView.postClassifiedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .returnToUncategorized(let albumNode):
            let ids = Set(action.assets.map(\.id))
            history.removeAssetsFromHistory(ids: ids)
            store.restoreAssets(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片从「\(albumNode.title)」归还未归类")
            ContentView.postClassifiedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .moveToPendingDelete(let sourceAlbumNode):
            let ids = Set(action.assets.map(\.id))
            if sourceAlbumNode != nil {
                history.removeAssetsFromHistory(ids: ids)
            } else {
                store.removeAssetsDirectly(ids: Array(ids))
            }
            history.addPendingDelete(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片标记为待删除")
            ContentView.postClassifiedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()

        case .restoreFromPendingDelete:
            history.removeFromPendingDelete(ids: Set(action.assets.map(\.id)))
            store.restoreAssets(action.assets)
            history.record(action)
            showTopHint("已重做：\(action.assets.count) 张照片从待删除移回未归类")
            ContentView.postClassifiedCompletionNotification(history: history)
            syncSingleModeAssetsIfNeeded()
        }
    }

    // MARK: - Helpers

    func fetchPHAssets(for assets: [PhotoAsset]) -> [PHAsset] {
        var result: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
            .enumerateObjects { a, _, _ in result.append(a) }
        return result
    }

    /// 已分类视图为空时发 sortedViewShouldDismiss，否则只清除选中。
    func postClassifiedCompletionNotification() {
        ContentView.postClassifiedCompletionNotification(history: sortHistory)
    }

    static func postClassifiedCompletionNotification(history: SortHistory) {
        let isEmpty = history.totalSortedCount == 0 && history.pendingDeleteAssets.isEmpty
        NotificationCenter.default.post(
            name: isEmpty ? .sortedViewShouldDismiss : .sortedSelectionShouldClear,
            object: nil
        )
    }

    /// 已分类视图下的目标 ID（多选优先，否则 focusedID）。
    func assignIDsForClassified() -> [String] {
        if !classifiedSelectedIDs.isEmpty { return Array(classifiedSelectedIDs) }
        if let id = focusedID { return [id] }
        return []
    }
}
