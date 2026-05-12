#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/OpenClawIsland.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openclaw.island.plist"
LABEL="com.openclaw.island"
UID_VALUE="$(id -u)"

if [ ! -x "$APP_PATH/Contents/MacOS/OpenClawIsland" ]; then
    echo "OpenClawIsland.app 不存在或不可执行，请先运行 ./build.sh"
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH/Contents/MacOS/OpenClawIsland</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.openclaw/logs/openclaw-island.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.openclaw/logs/openclaw-island.err.log</string>
</dict>
</plist>
PLIST

mkdir -p "$HOME/.openclaw/logs"
plutil -lint "$PLIST_PATH"
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST_PATH"
launchctl enable "gui/$UID_VALUE/$LABEL"
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

echo "已安装并启动 LaunchAgent: $PLIST_PATH"
