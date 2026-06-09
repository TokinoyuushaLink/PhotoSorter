#!/bin/bash
set -e

# ---------- 参数 ----------

DEBUG_MODE=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG_MODE=true ;;
    esac
done

# ---------- 路径 ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PhotoSorter"
APP="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$MACOS/$APP_NAME"
ICON_SRC="$SCRIPT_DIR/icon.png"
ICON_DST="$RESOURCES/AppIcon.icns"
CLIP_SCRIPT="$SCRIPT_DIR/clip_icon.swift"
TMP_ICONSET="$SCRIPT_DIR/Generated_AppIcon.iconset"

# ---------- 编译目标 ----------

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos15.0"

# ---------- 开始 ----------

if [ "$DEBUG_MODE" = true ]; then
    echo "[$APP_NAME] 开始构建 (DEBUG, arch: $ARCH)"
else
    echo "[$APP_NAME] 开始构建 (arch: $ARCH)"
fi

# 1. 检查编译环境
if ! command -v swiftc &>/dev/null; then
    echo "[错误] 找不到 swiftc，请安装 Command Line Tools："
    echo "       xcode-select --install"
    exit 1
fi

# 2. 清理并重建目录结构
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# 3. 图标生成（icon.png → AppIcon.icns）
if [ -f "$ICON_SRC" ]; then
    echo "[图标] 正在生成 macOS 图标..."
    mkdir -p "$TMP_ICONSET"

    cat > "$CLIP_SCRIPT" << 'SWIFTSCRIPT'
    import AppKit
    guard CommandLine.arguments.count == 3 else { exit(1) }
    let inputPath  = CommandLine.arguments[1]
    let outputPath = CommandLine.arguments[2]
    guard let sizeStr = outputPath.components(separatedBy: "icon_").last?
                           .components(separatedBy: "x").first,
          let size  = Double(sizeStr),
          let image = NSImage(contentsOfFile: inputPath) else { exit(1) }
    let isRetina  = outputPath.contains("@2x")
    let pixelSize = isRetina ? size * 2 : size
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize), pixelsHigh: Int(pixelSize),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let padding      = pixelSize * 0.09
    let contentSize  = pixelSize - (padding * 2)
    let cornerRadius = contentSize * 0.225
    let rect = NSRect(x: padding, y: padding, width: contentSize, height: contentSize)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: outputPath))
    }
SWIFTSCRIPT

    for sz in 16 32 128 256 512; do
        swift "$CLIP_SCRIPT" "$ICON_SRC" "$TMP_ICONSET/icon_${sz}x${sz}.png"
        swift "$CLIP_SCRIPT" "$ICON_SRC" "$TMP_ICONSET/icon_${sz}x${sz}@2x.png"
    done

    rm -f "$CLIP_SCRIPT"
    iconutil -c icns "$TMP_ICONSET" -o "$ICON_DST"
    rm -rf "$TMP_ICONSET"
    echo "[图标] 完成"
else
    echo "[警告] 未找到 icon.png，将使用系统空白图标"
fi

# 4. 收集源文件并编译
echo "[编译] 正在收集源文件..."
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$SCRIPT_DIR" -name "*.swift" ! -name "clip_icon.swift" | sort)

echo "[编译] 共 ${#SWIFT_FILES[@]} 个文件，目标 $TARGET"
swiftc \
    -O \
    -sdk "$SDK" \
    -target "$TARGET" \
    -framework SwiftUI \
    -framework Photos \
    -framework AppKit \
    -framework AVKit \
    "${SWIFT_FILES[@]}" \
    -o "$BIN"

# 5. 生成 Info.plist
ICON_KEY=""
[ -f "$ICON_DST" ] && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>          <string>com.linkapps.PhotoSorter</string>
  <key>CFBundleVersion</key>             <string>1.0.0</string>
  <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>NSPrincipalClass</key>            <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>     <true/>
  <key>LSMinimumSystemVersion</key>      <string>15.0</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>PhotoSorter 需要访问您的照片以显示和整理未分类的图像。</string>
  $ICON_KEY
</dict>
</plist>
PLIST

# ---------- 完成 ----------

echo ""
echo "[完成] $APP"
echo ""
echo "按 Enter 打开应用，按 ESC 取消..."

_open_app=false
while IFS= read -rsn1 key; do
    if [[ "$key" == "" ]]; then
        _open_app=true
        break
    elif [[ "$key" == $'\x1b' ]]; then
        break
    fi
done

if [ "$_open_app" = true ]; then
    open "$APP"
fi
