import Foundation
import Photos

// MARK: - Action Types

enum SortActionKind {
    /// Uncategorized → album (the original operation)
    case classify(albumNode: AlbumNode)
    /// Album → uncategorized (Delete in sorted view)
    case returnToUncategorized(albumNode: AlbumNode)
    /// Uncategorized or album → pending delete
    case moveToPendingDelete(sourceAlbumNode: AlbumNode?)   // nil = came from uncategorized
    /// Pending delete → uncategorized
    case restoreFromPendingDelete
}

struct SortAction {
    let kind: SortActionKind
    let assets: [PhotoAsset]   // full copies with preview

    // Legacy convenience init used by classify path
    init(albumNode: AlbumNode, originalAssets: [PhotoAsset]) {
        self.kind   = .classify(albumNode: albumNode)
        self.assets = originalAssets
    }

    init(kind: SortActionKind, assets: [PhotoAsset]) {
        self.kind   = kind
        self.assets = assets
    }

    // For display in groupedByAlbum
    var albumNode: AlbumNode? {
        switch kind {
        case .classify(let n):            return n
        case .returnToUncategorized:      return nil
        case .moveToPendingDelete:        return nil
        case .restoreFromPendingDelete:   return nil
        }
    }
}

// MARK: - SortHistory

@Observable
final class SortHistory {

    private(set) var undoStack: [SortAction] = []
    private(set) var redoStack: [SortAction] = []
    // Assets queued for permanent deletion (confirmed on app quit)
    private(set) var pendingDeleteAssets: [PhotoAsset] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasPendingDeletes: Bool { !pendingDeleteAssets.isEmpty }

    func record(_ action: SortAction) {
        undoStack.append(action)
        redoStack = []
    }

    func popUndo() -> SortAction? {
        guard !undoStack.isEmpty else { return nil }
        return undoStack.removeLast()
    }

    func pushRedo(_ action: SortAction) {
        redoStack.append(action)
    }

    func popRedo() -> SortAction? {
        guard !redoStack.isEmpty else { return nil }
        return redoStack.removeLast()
    }

    func addPendingDelete(_ assets: [PhotoAsset]) {
        let existingIDs = Set(pendingDeleteAssets.map(\.id))
        for a in assets where !existingIDs.contains(a.id) {
            pendingDeleteAssets.append(a)
        }
        UserDefaults.standard.set(!pendingDeleteAssets.isEmpty, forKey: Prefs.hasPendingDeletes)
    }

    func clearPendingDeletes() {
        pendingDeleteAssets = []
        UserDefaults.standard.set(false, forKey: Prefs.hasPendingDeletes)
    }

    func clearAll() {
        undoStack = []
        redoStack = []
        pendingDeleteAssets = []
        UserDefaults.standard.set(false, forKey: Prefs.hasPendingDeletes)
    }

    func removeFromPendingDelete(ids: Set<String>) {
        pendingDeleteAssets.removeAll { ids.contains($0.id) }
        UserDefaults.standard.set(!pendingDeleteAssets.isEmpty, forKey: Prefs.hasPendingDeletes)
    }

    // Remove asset IDs from all undo/redo stacks
    func removeAssetsFromHistory(ids: Set<String>) {
        undoStack = undoStack.compactMap { action in
            let filtered = action.assets.filter { !ids.contains($0.id) }
            return filtered.isEmpty ? nil : SortAction(kind: action.kind, assets: filtered)
        }
        redoStack = redoStack.compactMap { action in
            let filtered = action.assets.filter { !ids.contains($0.id) }
            return filtered.isEmpty ? nil : SortAction(kind: action.kind, assets: filtered)
        }
    }

    // Aggregated view: only classify actions, grouped by album
    var groupedByAlbum: [(albumNode: AlbumNode, assets: [PhotoAsset])] {
        var albumOrder: [String] = []
        var map: [String: (AlbumNode, [PhotoAsset])] = [:]

        for action in undoStack {
            guard case .classify(let node) = action.kind else { continue }
            let id = node.id
            if map[id] == nil {
                albumOrder.append(id)
                map[id] = (node, [])
            }
            map[id]!.1.append(contentsOf: action.assets)
        }

        return albumOrder.compactMap { map[$0] }.map { node, assets in
            let sorted = assets.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            return (node, sorted)
        }
    }

    var totalSortedCount: Int {
        undoStack.reduce(0) { sum, action in
            if case .classify = action.kind { return sum + action.assets.count }
            return sum
        }
    }
}
