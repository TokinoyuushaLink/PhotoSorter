# 待确认 Bug

由自动化逻辑测试（`Tests_logic.swift`）发现，尚未在真实应用中复现确认。

---

## Bug 1：从已分类相册移入待删除后，Cmd+Z 无效

**触发路径**
1. 将照片归类到某相册（如"工作"）
2. 切到「已分类」视图
3. 选中该照片，按 Cmd+Delete → 照片移入「待删除」分组
4. 立即按 Cmd+Z 尝试撤销

**预期行为**
照片从「待删除」移回「工作」相册，undoStack 弹出 `moveToPendingDelete` 动作。

**实际行为**
Cmd+Z 无响应（`canUndo == false`），照片停留在待删除，无法通过撤销恢复。

**根本原因**
`moveAlbumAssetsToPendingDelete` 的执行顺序：
```swift
history.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: g.albumNode), assets: matching))
history.addPendingDelete(assets)
history.removeAssetsFromHistory(ids: ids)   // ← 把上一行刚写入的动作也删掉了
```
`removeAssetsFromHistory` 按 asset id 过滤所有 action，不区分 kind，导致刚记录的 `moveToPendingDelete` 动作被自身清除。

**所在文件**
[ContentView+Actions.swift](../App/ContentView+Actions.swift) — `moveAlbumAssetsToPendingDelete`

**修复方向**
调换顺序：先 `removeAssetsFromHistory`（清除旧的 classify 记录），再 `record(moveToPendingDelete)`：
```swift
history.removeAssetsFromHistory(ids: ids)
history.addPendingDelete(assets)
for g in groups {
    let matching = ...
    history.record(SortAction(kind: .moveToPendingDelete(sourceAlbumNode: g.albumNode), assets: matching))
}
```

---

## Bug 2：从已分类视图归还照片后，Cmd+Z 无效

**触发路径**
1. 将照片归类到某相册
2. 切到「已分类」视图
3. 选中照片，按 Delete → 照片归还到「未归类」
4. 立即按 Cmd+Z 尝试撤销

**预期行为**
照片从「未归类」重新移回相册，undoStack 弹出 `returnToUncategorized` 动作。

**实际行为**
Cmd+Z 无响应（`canUndo == false`），undoStack 被完全清空，之前的归类记录也消失。

**根本原因**
`returnSelectedToUncategorized` 的执行顺序：
```swift
history.record(SortAction(kind: .returnToUncategorized(albumNode: g.albumNode), assets: matching))
// ...
history.removeAssetsFromHistory(ids: Set(ids))   // ← 把 classify + returnToUncategorized 都删了
```
同 Bug 1，`removeAssetsFromHistory` 把同 id 的所有 action（包括刚记录的 `returnToUncategorized`）一并清除。

**所在文件**
[ContentView+Actions.swift](../App/ContentView+Actions.swift) — `returnSelectedToUncategorized`

**修复方向**
先 `removeAssetsFromHistory`，再 `record(returnToUncategorized)`：
```swift
sortHistory.removeAssetsFromHistory(ids: Set(ids))
photosStore.restoreAssets(allRestored)
sortHistory.record(SortAction(kind: .returnToUncategorized(albumNode: g.albumNode), assets: matching))
```

---

## 共同根因

`removeAssetsFromHistory(ids:)` 的语义是"把这些 id 从历史中抹除"，但它不区分 action 的 kind，会无差别删除包含这些 id 的所有 action entry。

任何在 `record(新动作)` **之后** 调用 `removeAssetsFromHistory(同 ids)` 的地方都会触发此问题。修复原则：**先清理历史，再写入新动作**。
