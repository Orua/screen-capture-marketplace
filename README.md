# Codex Screen Capture

Windows 截图小工具：框选屏幕、简单标注，点击绿色勾号后将图片插入当前 Codex 输入框，**保留原有文字，不自动发送**。

本仓库 fork 自 [daftlamb/screen-capture-marketplace](https://github.com/daftlamb/screen-capture-marketplace)，保留原项目历史与作者署名。改进版由 [Orua](https://github.com/Orua) 维护，同时提供独立 EXE 和 Codex 插件两种启动方式。

## 相比原项目改进了什么

- **独立 EXE**：内置所需脚本，双击即可启动；独立运行无需 Node.js，也无需先加载 Codex 插件。
- **Codex 截图图标**：单击图标或按 `Ctrl+Shift+2` 开始截图；单实例机制防止重复常驻。
- **减少闪烁**：打开时冻结桌面画面，使用双缓冲绘制，并阻止快捷键重复触发和并发截图。
- **微信式截图界面**：去掉标题栏，绿色选区边框与尺寸提示，小工具条优先放在选区外。
- **简单标注**：矩形、圆形、箭头、画笔、文字、撤销；绿色勾号完成，红色叉号或 `Esc` 取消。
- **自动插入图片**：完成时重新枚举 Codex 窗口，切换到前台，通过 UI Automation 找到当前输入框，然后仅执行图片粘贴。
- **不发送、不替换文字**：插入只使用 `Ctrl+V`，不按发送键，不点击发送按钮，不重写草稿文本。
- **成功时安静**：图片自动插入后不显示右下角提示；无法插入时保留剪贴板图片，显示约 3 秒的提示后自动消失。
- **失败可恢复**：Codex 未打开、找不到输入框或切换焦点失败时，图片仍保留在剪贴板，可手动粘贴。
- **可移植源码**：插件配置使用相对路径，移除开发机器的绝对路径；运行记录与临时图片不进入 Git。

## 下载与使用

从 [Releases](https://github.com/Orua/screen-capture-marketplace/releases/latest) 下载 `CodexScreenCapture.exe`。

1. 双击 EXE，右下角系统托盘会出现蓝紫色 Codex 云形图标与蓝色截图框。
2. 单击图标，或按 `Ctrl+Shift+2`。
3. 拖动框选屏幕，选择工具进行标注。
4. 框选后再单击左键即可确认；使用标注工具时，在选区内编辑，点击选区外或绿色勾号确认。
5. 图片进入当前 Codex 草稿；由你点击发送。

工具条在屏幕空间不足时会选择可见位置，但工具条、选区边框和尺寸提示始终不会出现在导出的图片里。

右键托盘图标可打开截图文件夹或退出。没有设置 Windows 开机自启。多个 Codex 窗口存在时，优先选择当前前台窗口，其次是截图前记住的窗口；无法可靠定位时使用剪贴板回退。

## 系统要求

- Windows 10 / 11（建议 64 位），Windows PowerShell 5.1 与 .NET Framework 4.8。
- 自动插入需要 Codex / ChatGPT Windows 桌面应用已打开，并有可编辑输入框。
- 独立 EXE 不需要 Node.js；安装为 MCP 插件时需要 Node.js 在 `PATH` 中。

EXE 内置四个运行文件，首次启动会将它们解包到 `%LOCALAPPDATA%\CodexScreenCapture\0.2.3\scripts\`。最新截图、进程编号和动作状态位于同一版本目录下的 `agent\temp\runtime\`。工具本身没有上传接口；图片插入聊天草稿后的附件处理由 Codex 负责。

## 安装为 Codex 插件

```powershell
codex plugin marketplace add Orua/screen-capture-marketplace
codex plugin add screen-capture@screen-capture-marketplace
```

重新打开 Codex 或开始新聊天后加载插件。MCP 服务启动时会自动启动托盘程序；仅在插件列表里看到它，不代表后台服务已加载。EXE 和插件共享单实例互斥锁，不会多开两个截图工具。

插件也可直接启动：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\plugins\screen-capture\scripts\hotkey.ps1
```

## 从源码构建 EXE

```powershell
git clone https://github.com/Orua/screen-capture-marketplace.git
cd screen-capture-marketplace
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\desktop\build.ps1
```

输出为 `agent\output\desktop\CodexScreenCapture.exe`。构建使用 Windows 自带 .NET Framework C# 编译器；图标由界面代码绘制。EXE 内置运行脚本，没有额外下载依赖。

可以检查内置文件解包：

```powershell
.\agent\output\desktop\CodexScreenCapture.exe --self-test
```

自检只解包和检查资源，不启动截图服务。结果写入运行目录的 `launcher-validation.json`。

## 源码结构

```text
desktop/
  Launcher.cs                  独立 EXE 启动器、内置资源解包、错误提示
  build.ps1                    编译 EXE 并嵌入脚本与图标
plugins/screen-capture/
  .codex-plugin/plugin.json    插件说明与版本
  .mcp.json                   可移植 MCP 启动配置
  scripts/
    capture-ui.cs             冻结画面、截图界面、工具条、标注与托盘图标
    capture.ps1               截图入口
    composer-paste.ps1        查找 Codex 窗口、定位输入框、仅粘贴图片
    hotkey.ps1                托盘、快捷键、单实例与动作协调
    server.mjs                MCP 工具与后台启动
  skills/screen-capture/       Agent 使用说明
```

MCP 提供 `capture_screenshot`（当前窗口或完整桌面）和 `get_last_screenshot`（最近一次框选截图）两个工具。

## 验证范围

已在 Windows 本机验证源码编译、MCP 初始化、快捷键注册，以及实际 Codex 输入框中的图片粘贴：原有草稿文字保持一致，图片成为附件，没有自动发送。截图界面做过渲染检查。完整手动框选、各标注工具和绿色勾号流程尚未进行逐项自动化验收，其他 Windows / Codex 版本需要实际试用。

参见 [CHANGELOG.md](CHANGELOG.md) 了解版本改动。生成的 EXE 通过 Release 分发；备份、截图、日志和构建输出不提交到源码仓库。