# SwiftUI 与 AppKit 边界

## 边界划分原则

SwiftUI 负责声明式布局和状态绑定；AppKit 负责性能关键路径和系统级事件。两者通过 `NSViewRepresentable` / `NSViewControllerRepresentable` 桥接。

## 桥接点清单

### PhotoCollectionView（NSViewControllerRepresentable）

**为什么用 AppKit**：网格需要差分更新（只更新变化的 cell）、精确的动画控制、以及 `NSCollectionView` 的 cell 复用机制。SwiftUI 的 LazyVGrid 在大量 cell 变化时会全量重渲染。

```
PhotoGridView (SwiftUI)
    └── NSViewControllerRepresentable
            → PhotoCollectionViewController (NSViewController)
                    → NSCollectionView
                            → PhotoCell (NSCollectionViewItem)
                                    → ThumbnailView (NSView)
```

**Coordinator 职责**：
- `makeCoordinator()` 返回 `Coordinator` 实例
- `updateNSViewController()` → 比较 old/new assets，调 `updateItems()`
- `Coordinator` 持有 `onOpenPreview`、`onScrollChange` 等回调，从 AppKit 事件回调到 ContentView

**数据向下传递**：`PhotoGridView` 通过 `updateNSViewController` 的 `context.coordinator` 更新数据，不走 SwiftUI 状态。

**事件向上传递**：
- 双击 cell → `coordinator.onOpenPreview()`
- 滚动 → `scrollObserver` 写 `@Binding var topGradientOpacity`
- 选中变化 → `coordinator.selectionDidChange()` → 写 `photosStore.selectedIDs`

### AlbumStripView（NSViewRepresentable，收藏条芯片部分）

**为什么用 AppKit**：芯片列表需要拖拽排序（NSPanGestureRecognizer + CALayer transform 动画），SwiftUI 的 `.onDrag` 不支持自定义排序动画。

```
AlbumStripCombined (SwiftUI)
    ├── rowLabel + emptyHint → 纯 SwiftUI Text
    └── FavoriteStripView (NSViewRepresentable)
            → NSScrollView + NoScrollerScrollView
                    → NSCollectionView（水平布局）
                            → ChipCell (NSCollectionViewItem)
                                    ├── NSTextField (label)
                                    ├── NSTextField (keyLabel，数字快捷键)
                                    ├── NSVisualEffectView (背景毛玻璃)
                                    └── CALayer (highlightLayer，选中态)
```

**拖拽排序机制**（详见 favorite_strip_drag.md）：
- `NSPanGestureRecognizer` 识别拖拽
- `.began`：记录起始 index，开始视觉排序
- `.changed`：根据 translation 计算目标 index，用 CATransaction 更新其他 cell 的 `transform`
- `.ended`：提交排序 → `onReorder(from, to)` → `albumsStore.reorderFavorites`

### SwipeNavigationView（NSViewRepresentable）

包装一个透明 NSView，附加 NSPanGestureRecognizer，捕获触控板滑动：

```
SwipeNavigationView (NSViewRepresentable)
    → GestureHostView (NSView)
            └── NSPanGestureRecognizer
                    → 回调：onHorizontalSwipe / onVerticalSwipe / onSwipeEnded
```

### KeyboardHandler（NSViewRepresentable）

包装一个 0 尺寸 NSView，在 `makeNSView` 时安装 `NSEvent.addLocalMonitorForEvents(.keyDown)`：

```
KeyboardHandler (NSViewRepresentable)
    → KeyListenerView (NSView)
            └── NSEvent.addLocalMonitorForEvents
                    → 过滤 → 调用 Swift 闭包 → 更新 ContentView @State
```

> `removeMonitor` 在 `dismantle` 时调用，避免泄漏。

### PlayerViews（AppKit + AVKit）

**AVPlayerHostingView（NSViewRepresentable）**：
```
AVPlayerHostingView → NSView
    └── AVPlayerLayer (sublayer)
            ← AVPlayer（由 SinglePhotoView 管理生命周期）
```

**GIFPlayerView（NSViewRepresentable）**：
```
GIFPlayerView → NSView
    └── NSImageView (animates: true)
            ← [NSImage] 帧数组（由 PHAssetResource 解码）
```

## SwiftUI 侧的 AppKit 适配技巧

### TrackingAreaView（鼠标悬停检测）
```swift
// NSViewRepresentable，覆盖目标区域，监听 mouseEntered / mouseExited
// 用于收藏条的悬停显示逻辑
TrackingAreaView { hovering in isHovered = hovering }
    .frame(height: hoverTriggerH)
    .allowsHitTesting(false)    // 不拦截点击事件
```

### MovableTitleBarBackground
```swift
// NSViewRepresentable，将标题栏区域设为可拖动窗口区域
// 通过 isMovableByWindowBackground = true 实现
```

### CursorModifier（光标修改）
```swift
// ViewModifier，在 hover 区域切换系统光标（resizeLeftRight 等）
// 通过包装 NSView.addCursorRect 实现
```

## @Bindable 用法

`PhotoGridView` 用 `@Bindable var store: PhotosStore`，允许在 `NSViewControllerRepresentable` 内部写 `$store.selectedIDs`（双向绑定），而不是通过 closure 回调。这是 Swift 5.9 `@Observable` + `@Bindable` 组合的标准用法。
