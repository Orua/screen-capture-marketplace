---
name: screen-capture
description: Capture a selected Windows screen region, the active window, or the full desktop and return it to Codex or the clipboard. Use when the user asks to take, grab, attach, inspect, or analyze a screenshot without using an external screenshot app.
---

# Screen Capture

Use the `screen-capture` MCP tools when the user asks for a Windows screenshot.

- For a selected region, tell the user to press `Ctrl+Shift+2` while Codex is idle, drag the rectangle, annotate if needed, then click `Copy` and paste the image into the conversation.
- Use `capture_screenshot` with `window` for the currently active top-level window.
- Use `capture_screenshot` with `screen` for the complete virtual desktop across all monitors.
- After capture, inspect the returned image and continue the user's task.
- The background hotkey helper starts with the MCP server. It uses `%TEMP%\codex-screen-capture` for scratch files and copies the final region image to the Windows clipboard.
