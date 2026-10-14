---
name: screen-capture
description: Capture a selected Windows screen region, the active window, or the full desktop and return it to Codex or the clipboard. Use when the user asks to take, grab, attach, inspect, or analyze a screenshot without using an external screenshot app.
---

# Screen Capture

Use the `screen-capture` MCP tools when the user asks for a Windows screenshot.

- For a selected region, tell the user to click the green tray icon or press `Ctrl+Shift+2`, drag the rectangle, annotate if needed, then click the green checkmark in the toolbar outside the selection. The frozen, double-buffered overlay has no title bar. The local helper discovers the current Codex window and composer again at completion, focuses the editable composer, and pastes the image into the draft. It never sends Enter, replaces draft text, or clicks Send.
- Use `capture_screenshot` with `window` for the currently active top-level window.
- Use `capture_screenshot` with `screen` for the complete virtual desktop across all monitors.
- After capture, inspect the returned image and continue the user's task.
- The background hotkey helper starts with the MCP server. It keeps the latest image, its PID, and a text-free action status under the plugin's `agent/temp/runtime/` folder. If restoring the Codex input fails, the image remains in the clipboard for manual Ctrl+V; do not claim successful attachment solely from a paste-requested status.
