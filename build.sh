#!/bin/bash
# OpenClawIsland 构建与运行脚本
# 前提：需要 macOS Command Line Tools 或 Xcode 安装

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/OpenClawIsland"
APP_NAME="OpenClawIsland.app"
OUTPUT_DIR="$SCRIPT_DIR/Build"
INSTALL_APP_PATH="$SCRIPT_DIR/$APP_NAME"

echo "🦞 OpenClawIsland 构建工具"
echo "========================="

# 检查 swiftc
if ! command -v xcrun &> /dev/null; then
    echo "❌ xcrun 未找到，请安装 Command Line Tools 或 Xcode"
    exit 1
fi

if ! xcrun --find swiftc &> /dev/null; then
    echo "❌ swiftc 未找到，请安装 Command Line Tools 或 Xcode"
    exit 1
fi

SWIFTC="$(xcrun --find swiftc)"
echo "✅ 找到 swiftc: $SWIFTC"
echo ""

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 编译
echo "🔨 正在编译..."
rm -rf "$OUTPUT_DIR/$APP_NAME"
xcrun swiftc \
    -o "$OUTPUT_DIR/OpenClawIsland" \
    -module-name OpenClawIsland \
    -emit-executable \
    "$PROJECT_DIR/Models.swift" \
    "$PROJECT_DIR/ViewModel.swift" \
    "$PROJECT_DIR/DynamicIslandView.swift" \
    "$PROJECT_DIR/AppDelegate.swift" \
    2>&1

echo ""
echo "📦 正在创建 App Bundle..."

# 创建 .app bundle 结构
APP_PATH="$OUTPUT_DIR/$APP_NAME"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# 复制可执行文件
cp "$OUTPUT_DIR/OpenClawIsland" "$APP_PATH/Contents/MacOS/OpenClawIsland"

# 复制 Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

# 复制 entitlements
cp "$PROJECT_DIR/OpenClawIsland.entitlements" "$APP_PATH/Contents/OpenClawIsland.entitlements"

# 设置权限
chmod +x "$APP_PATH/Contents/MacOS/OpenClawIsland"

# 同步根目录 app，确保 openclaw:// URL Scheme 不会被旧 bundle 截获
echo ""
echo "🔁 正在同步当前 App 到项目根目录..."
rm -rf "$INSTALL_APP_PATH"
cp -R "$APP_PATH" "$INSTALL_APP_PATH"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP_PATH" 2>/dev/null || true

echo ""
echo "🎉 构建完成！"
echo "📍 应用位置: $APP_PATH"
echo "📍 已同步位置: $INSTALL_APP_PATH"
echo ""
echo "运行方式 1: open \"$APP_PATH\""
echo "运行方式 2: \"$APP_PATH/Contents/MacOS/OpenClawIsland\""
echo ""
echo "💡 提示: 应用会在屏幕顶部显示灵动岛！"
echo "   - 鼠标悬停 → 展开详情"
echo "   - 横向滚动/滑动 → 切换 Agent"
echo "   - 长按岛 → 模拟通用任务流"
echo "   - URL 更新 → openclaw://update?agent=main&state=callingAPI&msg=正在调用工具"
