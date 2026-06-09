// CLI 编译不支持 @main，顶层表达式只能在 main.swift 里
import AppKit

NSApplication.shared.setActivationPolicy(.regular)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
