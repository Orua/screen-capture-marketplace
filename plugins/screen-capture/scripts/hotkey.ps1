$ErrorActionPreference = "Stop"

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, "Local\CodexScreenCaptureHotkey", [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

$pidPath = Join-Path $env:TEMP "codex-screen-capture\hotkey.pid"
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($pidPath)) | Out-Null
[IO.File]::WriteAllText($pidPath, [string]$PID)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
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
$outputDirectory = Join-Path $env:TEMP "codex-screen-capture"
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
$notifyIcon.Icon = [Drawing.SystemIcons]::Application
$notifyIcon.Text = "Codex Screen Capture - Ctrl+Shift+2"
$notifyIcon.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$captureItem = $menu.Items.Add("Capture region (Ctrl+Shift+2)")
$openItem = $menu.Items.Add("Open screenshot folder")
$exitItem = $menu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $menu

function Invoke-RegionCapture {
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
        "-Annotate"
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = $arguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
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
    $notifyIcon.BalloonTipText = "Copied. Paste the screenshot where you want it."
    $notifyIcon.ShowBalloonTip(2500)
}

$filter.add_HotkeyPressed({ Invoke-RegionCapture })
$captureItem.add_Click({ Invoke-RegionCapture })
$openItem.add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $outputDirectory + '"') })
$exitItem.add_Click({ $form.Close() })

$registered = [CodexHotkeyNative]::RegisterHotKey($handle, 1, 0x0002 -bor 0x0004, 0x32)
if (-not $registered) {
    $notifyIcon.Dispose()
    [Windows.Forms.Application]::RemoveMessageFilter($filter)
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    throw "Ctrl+Shift+2 is already registered by another application."
}

try {
    [Windows.Forms.Application]::Run($form)
}
finally {
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
