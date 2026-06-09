# PhotoSorterSUI 项目架构

macOS SwiftUI 应用，用于将照片库中的未分类照片整理到相册。SwiftUI + AppKit 混合架构，分为 App、Core、Grid、Preview、Panels 五个模块。

---

## 目录结构

```
PhotoSorterSUI/
├── App/
│   ├── main.swift                  # 入口，手动初始化 NSApplication
│   ├── AppDelegate.swift           # 窗口创建、菜单配置、退出确认
│   └── ContentView.swift           # 主容器，协调所有子视图和业务逻辑
├── Core/
│   ├── Constants.swift             # 全局常量、通知名、工具函数、GridLayout
│   ├── PhotosStore.swift           # 照片库数据，与 Photos 框架交互
│   ├── AlbumsStore.swift           # 相册树结构，收藏夹和最近使用列表
│   └── SortHistory.swift           # 撤销/重做栈，待删除列表
├── Grid/
│   ├── PhotoGridView.swift         # SwiftUI 包装层，计算布局参数
│   ├── PhotoCollectionView.swift   # NSCollectionView 宿主和协调器
│   └── ThumbnailView.swift         # 单格缩略图视图
│   └── ThumbnailCache.swift        # Actor 型 LRU 缩略图缓存（上限 400 项）
├── Preview/
│   ├── SinglePhotoView.swift       # 单图查看器，滑动导航，视频/GIF 播放
│   ├── SwipeNavigationView.swift   # 触控板滑动手势（NSEvent 监听）
│   ├── KeyboardViews.swift         # 键盘监听（KeyEventView、KeyMonitorView、UndoRedoMonitor）
│   └── PlayerViews.swift           # 视频播放器和控制条
└── Panels/
    ├── ColumnBrowserView.swift     # 右侧面板，树状相册浏览
    └── AlbumStripView.swift        # 底部收藏条，拖拽重排，数字快捷键
```

---

## 渲染层次（ContentView ZStack，从下到上）

| 层 | 视图 | 说明 |
|---|---|---|
| 1 | PhotoGridView | 照片网格，padding 右边让出面板空间 |
| 2 | Color（遮罩） | 单图背景，进入单图时淡入 |
| 3 | SinglePhotoView | 单图查看器，仅在 isInSingleMode 时存在 |
| 4 | 渐变 + 标题 | 顶部/底部渐变，大标题/小标题 |
| 5 | AlbumStripCombined | 底部收藏条浮层 |
| 6 | ColumnBrowserView | 右侧面板，弹簧动画显隐 |
| 7 | 标题栏 + 权限 | 侧边栏按钮、模式切换、权限提示覆盖层 |

非交互全局监听（allowsHitTesting = false）：
- `NumberShortcutMonitor`：1–0 快速分配到收藏夹
- `UndoRedoMonitor`：Cmd+Z/Shift+Z、Delete、Cmd+Delete、Cmd+\

---

## 核心数据模型

### PhotosStore
- `assets: [PhotoAsset]` — 未分类照片（按创建日期降序）
- `selectedIDs: Set<String>` — 网格多选集合
- `loadUncategorized()` — 后台遍历所有相册，剩余即为未分类；分批加载 960×960 预览
- `restoreAssets()` — 撤销时按日期重新插入到正确位置

### AlbumsStore
- `roots: [AlbumNode]` — 相册树根节点
- `favoriteNodes` — 收藏夹（有序，位置对应快捷键 1–0）
- `recentNodes` — 最近使用（LRU，最多 20 项）
- `AlbumNode` — 树节点（folder 或 album，含 PHAssetCollection）

### SortHistory
四种操作类型：
```
classify(albumNode)               未分类 → 相册
returnToUncategorized(albumNode)  相册 → 未分类（Delete）
moveToPendingDelete(sourceAlbum)  来源 → 待删除（Cmd+Delete）
restoreFromPendingDelete          待删除 → 未分类
```
- `groupedByAlbum` — 聚合所有 classify 操作，供已分类视图使用
- `pendingDeleteAssets` — 退出时写入 Photos 框架永久删除

---

## 关键数据流

### 分类流程
```
用户点击相册
→ assignToAlbum()
→ PhotosStore.addIDs()         从 assets 移除（纯内存）
→ SortHistory.record()         压入撤销栈
→ .assetsDidSort 通知          如果未分类清空，自动切到已分类视图
→ syncSingleModeAssetsIfNeeded() 单图队列同步，自动跳下一张
```

### 撤销流程（以 classify 为例）
```
Cmd+Z
→ undoLastAction()
→ sortHistory.popUndo()         取出 classify 操作
→ PhotosStore.restoreAssets()   恢复到未分类（按日期插回）
→ sortHistory.pushRedo()        压入重做栈
→ syncSingleModeAssetsIfNeeded() 单图队列穿插恢复
```

### 单图模式
```
Space / 双击
→ enterSingleMode()             构建队列（多选子集 or 全部）
→ SinglePhotoView 进入动画      分三阶段：加载 → 动画 → 媒体可见
→ 滑动触发 handleDrag()         积累偏移，超 5% 阈值则导航
→ 归类/删除后自动跳下一张       handleAssetsChange() 检测队列变化
→ 队列清空 → dismiss()          退出单图模式
```

---

## 标题栏动画（iOS 大标题模拟）

由 `topGradientOpacity`（0→1）统一驱动：

| 阶段 | 效果 |
|---|---|
| 0 → 0.5 | 大标题淡出（largeTitleOpacity） |
| 0.5 → 1 | 小标题淡入 + 顶部渐变显现（smallTitleOpacity） |

- **大标题位置**：用 `NSWindow.contentLayoutRect` 计算真实 titlebar 高度，全屏/窗口化自动适配
- **已分类模式**：大标题显示状态文字（"已分类 24 张"），副标题隐藏

---

## SwiftUI / AppKit 互操作

| 场景 | 方案 |
|---|---|
| 照片网格 | NSViewRepresentable 包装 NSCollectionView（动画批更新） |
| 键盘监听 | NSEvent.addLocalMonitorForEvents（全局）+ 第一响应者（局部） |
| 视频播放 | AVPlayerLayer 包装为 NSViewRepresentable |
| 鼠标悬停 | NSTrackingArea |
| 触控板滑动 | NSEvent .scrollWheel 阶段检测 |
| 窗口事件 | NotificationCenter（didResize、willEnterFullScreen 等） |

---

## 性能要点

- **缩略图缓存**：actor 型 LRU，上限 400 项，防重复请求
- **预览分批加载**：`loadPreviewsBatched()` 分散 PHImageManager 请求
- **网格增量更新**：同结构节变化用动画批更新，结构变化才全量 reloadData
- **渐变驱动**：`NSScrollView.didLiveScrollNotification` + `NSView.frameDidChangeNotification`，无定时器
- **全屏前更新**：监听 `willEnterFullScreen` 提前触发 reportScroll
