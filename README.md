# Screen Capture Marketplace

A repo marketplace for the `screen-capture` Codex plugin.

The plugin captures Windows screenshots and supports region annotation before copying the final image to the clipboard.

## Install from GitHub

Users can add the marketplace with:

```powershell
codex plugin marketplace add daftlamb/screen-capture-marketplace
```

Then restart the ChatGPT desktop app or Codex, open Plugins, choose `Screen Capture Marketplace`, and install `Screen Capture`.

To pin a branch:

```powershell
codex plugin marketplace add daftlamb/screen-capture-marketplace --ref main
```

## Install from a local folder

For local testing:

```powershell
codex plugin marketplace add C:\Users\111\Documents\screen-capture-marketplace
```

Then restart the ChatGPT desktop app or Codex and install `Screen Capture` from the plugin directory.

## Use

Press `Ctrl+Shift+2`, drag a screen region, annotate if needed, then click `Copy`.

The copied image can be pasted directly into ChatGPT, Codex, WeChat, or another app.

The toolbar includes pen, box, arrow, text, undo, copy, cancel, and mouse-wheel zoom.

## Notes

- Windows only.
- Uses PowerShell, WinForms, Node.js, and the bundled MCP server.
- Uses `%TEMP%\codex-screen-capture` for scratch files.
- The final region capture is copied to the Windows clipboard.
