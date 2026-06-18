# claude 工作指南
该文件只需读取一次。
项目文档`./文档`在必要时读取。

## 构建与运行
如需查看是否编译通过，则执行指令：
```bash
./build.sh 2>&1 | grep -E "error:|构建成功" 
```
目前，还存在swift6的warning，但除非用户提及，否则自动忽略
用户没有XCode，编译使用的是command-Line-Tool

## 日志调试
如需打印调试日志，请使用NSLog输出调试日志。

## 项目基本结构

```
App/          ContentView.swift、AppDelegate.swift（主视图、退出逻辑）
Core/         PhotosStore、AlbumsStore、SortHistory（数据层）
Grid/         PhotoGridView、PhotoCollectionView、ThumbnailView/Cache（网格）
Panels/       AlbumStripView（底部收藏条）、ColumnBrowserView（右侧面板）
Preview/      SwipeNavigationView、PlayerViews（单图预览）
```
