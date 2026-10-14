$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "composer-paste.ps1")

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, "Local\CodexScreenCaptureHotkey", [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

$outputDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\agent\temp\runtime"))
$pidPath = Join-Path $outputDirectory "hotkey.pid"
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pidPath)) | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot "capture-ui.cs") -ReferencedAssemblies @("System.Drawing.dll","System.Windows.Forms.dll","System.dll")
$hotkeyTypeSource = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class CodexHotkeyNative
{
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

public sealed class CodexHotkeyFilter : IMessageFilter
{
    public event EventHandler HotkeyPressed;

    public bool PreFilterMessage(ref Message message)
    {
        if (message.Msg == 0x0312 && message.WParam.ToInt32() == 1)
        {
            EventHandler handler = HotkeyPressed;
            if (handler != null) handler(this, EventArgs.Empty);
            return true;
        }
        return false;
    }
}
"@
Add-Type -TypeDefinition $hotkeyTypeSource -ReferencedAssemblies @("System.Windows.Forms.dll")

$captureScript = Join-Path $PSScriptRoot "capture.ps1"
$latestScreenshot = Join-Path $outputDirectory "last.png"
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

$form = New-Object Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = [Windows.Forms.FormWindowState]::Minimized
$form.Opacity = 0
$form.Text = "Codex Screen Capture"
$form.Add_Shown({ $form.Hide() })
$handle = $form.Handle

$filter = New-Object CodexHotkeyFilter
[Windows.Forms.Application]::AddMessageFilter($filter)

$notifyIcon = New-Object Windows.Forms.NotifyIcon
$trayIcon = [CaptureUi]::TrayIcon()
$notifyIcon.Icon = $trayIcon
$notifyIcon.Text = "Codex 截图 - Ctrl+Shift+2"
$notifyIcon.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$captureItem = $menu.Items.Add("截图并插入 Codex (Ctrl+Shift+2)")
$openItem = $menu.Items.Add("打开截图文件夹")
$exitItem = $menu.Items.Add("退出")
$notifyIcon.ContextMenuStrip = $menu

$script:lastCodexTarget = [CodexComposerPaste]::RememberForeground()
$rememberTimer = New-Object Windows.Forms.Timer
$rememberTimer.Interval = 500
$rememberTimer.add_Tick({
    $target = [CodexComposerPaste]::RememberForeground()
    if ($null -ne $target) { $script:lastCodexTarget = $target }
})
$rememberTimer.Start()
$script:captureBusy = $false

function Invoke-RegionCapture {
    if ($script:captureBusy) { return }
    $script:captureBusy = $true
    try {
    $target = [CodexComposerPaste]::RememberForeground()
    if ($null -eq $target) { $target = $script:lastCodexTarget }
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ('"' + $captureScript + '"'),
        "-Mode",
        "region",
        "-OutputPath",
        ('"' + $latestScreenshot + '"'),
        "-Annotate",
        "-PasteHelperPid",
        [string]$PID
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = $arguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    while (-not $process.HasExited) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 60
    }
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $latestScreenshot)) {
        return
    }

    $sourceImage = [Drawing.Image]::FromFile($latestScreenshot)
    $clipboardImage = New-Object Drawing.Bitmap($sourceImage)
    try {
        [Windows.Forms.Clipboard]::SetImage($clipboardImage)
    }
    finally {
        $sourceImage.Dispose()
        $clipboardImage.Dispose()
    }

    $notifyIcon.BalloonTipTitle = "Codex Screen Capture"
    $pasteStatus = [CodexComposerPaste]::Paste($target)
    [IO.File]::WriteAllText((Join-Path $outputDirectory "last-result.json"),
        (@{ capturedAt = [DateTime]::UtcNow.ToString('o'); pasteStatus = $pasteStatus; sent = $false } | ConvertTo-Json))
    $notifyIcon.BalloonTipText = if ($pasteStatus -eq "paste-requested") {
        "图片已粘贴到 Codex 草稿，未发送。"
    } else {
        "图片已复制。请点击 Codex 输入框按 Ctrl+V（自动插入未完成）。"
    }
    $notifyIcon.ShowBalloonTip(2500)
    }
    catch {
        $notifyIcon.BalloonTipTitle = "Codex 截图"
        $notifyIcon.BalloonTipText = "截图未完成，请重试。"
        $notifyIcon.ShowBalloonTip(2500)
        [IO.File]::WriteAllText((Join-Path $outputDirectory "last-error.txt"), $_.Exception.Message)
    }
    finally { $script:captureBusy = $false }
}

$filter.add_HotkeyPressed({ Invoke-RegionCapture })
$captureItem.add_Click({ Invoke-RegionCapture })
$notifyIcon.add_MouseClick({ if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) { Invoke-RegionCapture } })
$openItem.add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $outputDirectory + '"') })
$exitItem.add_Click({ $form.Close() })

$registered = [CodexHotkeyNative]::RegisterHotKey($handle, 1, 0x0002 -bor 0x0004 -bor 0x4000, 0x32)
if (-not $registered) {
    $notifyIcon.Dispose()
    $trayIcon.Dispose()
    [Windows.Forms.Application]::RemoveMessageFilter($filter)
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    throw "Ctrl+Shift+2 is already registered by another application."
}

# Publish readiness only after compilation and global hotkey registration succeed.
[IO.File]::WriteAllText($pidPath, [string]$PID)

try {
    [Windows.Forms.Application]::Run($form)
}
finally {
    $rememberTimer.Stop()
    $rememberTimer.Dispose()
    [CodexHotkeyNative]::UnregisterHotKey($handle, 1) | Out-Null
    [Windows.Forms.Application]::RemoveMessageFilter($filter)
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $menu.Dispose()
    $form.Dispose()
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
