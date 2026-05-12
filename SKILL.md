---
name: openclaw-dynamic-island
description: macOS Dynamic Island companion for OpenClaw multi-agent status display. Use when users want a background desktop island that reflects OpenClaw agent work state across any OpenClaw-supported message platform.
metadata: {"openclaw": {"emoji": "🏝️", "platforms": ["macOS"], "capabilities": ["agent-status", "desktop-ui", "launch-agent", "url-scheme"]}}
---

# OpenClaw Dynamic Island

This skill package provides a macOS desktop companion for OpenClaw. It shows a small Dynamic Island style status UI for local OpenClaw agents.

## Use When

- The user wants a desktop status island for OpenClaw agents.
- The user wants multi-agent switching from one compact UI.
- The user wants OpenClaw work states to be visible without opening the web control panel.
- The user wants status across Telegram, WeChat, Feishu/Lark, QQ, Discord, Slack, or any other platform routed through OpenClaw.

## Runtime Component

The actual runtime is the native app in this repository:

```bash
./build.sh
./install-launch-agent.sh
```

The LaunchAgent keeps the app available in the background. The island remains hidden until an agent has active or recent status.

## Status Protocol

The app observes OpenClaw local session files:

```text
~/.openclaw/agents/<agent-id>/sessions/*.jsonl
```

It also accepts explicit local status updates:

```bash
open 'openclaw://update?agent=main&state=thinking&msg=Planning'
```

Supported states:

- `idle`
- `receiving`
- `thinking`
- `callingAPI`
- `done`
- `failed`
- `playingMusic`

## Privacy Rule

Never include user `~/.openclaw/openclaw.json`, bot tokens, gateway tokens, account IDs, private logs, or session transcripts when packaging or publishing this skill.

Use only public examples.
