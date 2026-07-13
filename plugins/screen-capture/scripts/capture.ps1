param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("region", "window", "screen")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [switch]$Annotate
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ScreenCaptureNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
}
"@

[ScreenCaptureNative]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Get-ActiveWindowRectangle {
    $handle = [ScreenCaptureNative]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) {
        throw "No active window was found."
    }

    [ScreenCaptureNative+RECT]$nativeRect = [ScreenCaptureNative+RECT]::new()
    $dwmResult = [ScreenCaptureNative]::DwmGetWindowAttribute(
        $handle,
        9,
        [ref]$nativeRect,
        [Runtime.InteropServices.Marshal]::SizeOf($nativeRect)
    )

    if ($dwmResult -ne 0 -and -not [ScreenCaptureNative]::GetWindowRect($handle, [ref]$nativeRect)) {
        throw "The active window bounds could not be read."
    }

    $left = [int]$nativeRect.Left
    $top = [int]$nativeRect.Top
    $width = [int]$nativeRect.Right - $left
    $height = [int]$nativeRect.Bottom - $top
    return [Drawing.Rectangle]::new($left, $top, $width, $height)
}

function Select-ScreenRectangle {
    $virtualBounds = [Windows.Forms.SystemInformation]::VirtualScreen
    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = $virtualBounds
    $form.BackColor = [Drawing.Color]::Black
    $form.Opacity = 0.28
    $form.Cursor = [Windows.Forms.Cursors]::Cross
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.Text = "Drag to capture. Press Esc to cancel."

    $state = [PSCustomObject]@{
        Start = [Drawing.Point]::Empty
        Current = [Drawing.Point]::Empty
        Selecting = $false
        Result = $null
    }

    $form.Add_MouseDown({
        if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
            $state.Start = [Drawing.Point]::new([int]$_.X, [int]$_.Y)
            $state.Current = [Drawing.Point]::new([int]$_.X, [int]$_.Y)
            $state.Selecting = $true
        }
    })

    $form.Add_MouseMove({
        if ($state.Selecting) {
            $state.Current = [Drawing.Point]::new([int]$_.X, [int]$_.Y)
            $form.Invalidate()
        }
    })

    $form.Add_Paint({
        if (-not $state.Selecting) { return }

        $left = [Math]::Min($state.Start.X, $state.Current.X)
        $top = [Math]::Min($state.Start.Y, $state.Current.Y)
        $width = [Math]::Abs($state.Current.X - $state.Start.X)
        $height = [Math]::Abs($state.Current.Y - $state.Start.Y)
        $selection = [Drawing.Rectangle]::new([int]$left, [int]$top, [int]$width, [int]$height)
        $fill = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(140, 30, 144, 255))
        $pen = New-Object Drawing.Pen([Drawing.Color]::White, 2)
        try {
            $_.Graphics.FillRectangle($fill, $selection)
            $_.Graphics.DrawRectangle($pen, $selection)
        }
        finally {
            $fill.Dispose()
            $pen.Dispose()
        }
    })

    $form.Add_MouseUp({
        if (-not $state.Selecting -or $_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }

        $mouseX = [int]$_.X
        $mouseY = [int]$_.Y
        $left = [int][Math]::Min($state.Start.X, $mouseX)
        $top = [int][Math]::Min($state.Start.Y, $mouseY)
        $width = [int][Math]::Abs($mouseX - $state.Start.X)
        $height = [int][Math]::Abs($mouseY - $state.Start.Y)
        if ($width -gt 2 -and $height -gt 2) {
            $state.Result = [Drawing.Rectangle]::new(
                [int]($virtualBounds.Left + $left),
                [int]($virtualBounds.Top + $top),
                $width,
                $height
            )
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })

    $form.Add_KeyDown({
        if ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $form.DialogResult = [Windows.Forms.DialogResult]::Cancel
            $form.Close()
        }
    })

    $form.Add_Shown({
        $form.Activate()
        $form.Focus()
    })

    $dialogResult = $form.ShowDialog()
    $form.Dispose()
    if ($dialogResult -ne [Windows.Forms.DialogResult]::OK -or $null -eq $state.Result) {
        exit 2
    }

    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 120
    return $state.Result
}

function Save-ScreenRectangle([Drawing.Rectangle]$Rectangle, [string]$Path) {
    if ($Rectangle.Width -le 0 -or $Rectangle.Height -le 0) {
        throw "The screenshot rectangle is empty."
    }

    $directory = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $bitmap = New-Object Drawing.Bitmap(
        $Rectangle.Width,
        $Rectangle.Height,
        [Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(
            $Rectangle.Left,
            $Rectangle.Top,
            0,
            0,
            $Rectangle.Size,
            [Drawing.CopyPixelOperation]::SourceCopy
        )
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Read-AnnotationText {
    Add-Type -AssemblyName Microsoft.VisualBasic
    return [Microsoft.VisualBasic.Interaction]::InputBox("Text to add:", "Add text", "")
}

function Show-AnnotationEditor([string]$Path) {
    $source = [Drawing.Image]::FromFile($Path)
    $bitmap = New-Object Drawing.Bitmap($source)
    $source.Dispose()

    $form = New-Object Windows.Forms.Form
    $form.Text = "Annotate screenshot"
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $workingArea = [Windows.Forms.SystemInformation]::WorkingArea
    $clientWidth = [Math]::Min($workingArea.Width - 80, [Math]::Max(340, $bitmap.Width))
    $clientHeight = [Math]::Min($workingArea.Height - 80, [Math]::Max(220, $bitmap.Height))
    $form.ClientSize = [Drawing.Size]::new([int]$clientWidth, [int]$clientHeight)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.KeyPreview = $true

    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = [Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $panel.BackColor = [Drawing.SystemColors]::Control

    $pictureBox = New-Object Windows.Forms.PictureBox
    $pictureBox.Image = $bitmap
    $pictureBox.SizeMode = [Windows.Forms.PictureBoxSizeMode]::StretchImage
    $pictureBox.Width = $bitmap.Width
    $pictureBox.Height = $bitmap.Height
    $pictureBox.TabStop = $true
    $panel.Controls.Add($pictureBox)

    $form.Controls.Add($panel)

    $state = [PSCustomObject]@{
        Tool = "pen"
        Drawing = $false
        Start = [Drawing.Point]::Empty
        Current = [Drawing.Point]::Empty
        Last = [Drawing.Point]::Empty
        Saved = $false
    }
    $history = New-Object System.Collections.ArrayList
    $toolButtons = @{}
    $toolTip = New-Object Windows.Forms.ToolTip
    $zoomState = [PSCustomObject]@{
        Value = 1.0
        Min = 0.5
        Max = 4.0
    }

    function Update-Zoom([double]$NextZoom) {
        $zoomState.Value = [Math]::Max($zoomState.Min, [Math]::Min($zoomState.Max, $NextZoom))
        $pictureBox.Width = [Math]::Max(1, [int][Math]::Round($bitmap.Width * $zoomState.Value))
        $pictureBox.Height = [Math]::Max(1, [int][Math]::Round($bitmap.Height * $zoomState.Value))
        $pictureBox.Invalidate()
    }

    function Convert-ToImagePoint([int]$X, [int]$Y) {
        $imageX = [int][Math]::Floor($X / $zoomState.Value)
        $imageY = [int][Math]::Floor($Y / $zoomState.Value)
        $imageX = [Math]::Max(0, [Math]::Min($bitmap.Width - 1, $imageX))
        $imageY = [Math]::Max(0, [Math]::Min($bitmap.Height - 1, $imageY))
        return [Drawing.Point]::new([int]$imageX, [int]$imageY)
    }

    function Invoke-ZoomWheel([int]$Delta) {
        if ($Delta -eq 0) { return }
        $step = if ($Delta -gt 0) { 1.12 } else { 1 / 1.12 }
        Update-Zoom ($zoomState.Value * $step)
    }

    function New-LucideIcon([string]$Name, [Drawing.Color]$Color) {
        $icon = New-Object Drawing.Bitmap(24, 24, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($icon)
        $pen = New-Object Drawing.Pen($Color, 2)
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            switch ($Name) {
                "pen" {
                    $graphics.DrawLine($pen, 15, 4, 20, 9)
                    $graphics.DrawLine($pen, 20, 9, 9, 20)
                    $graphics.DrawLine($pen, 9, 20, 4, 20)
                    $graphics.DrawLine($pen, 4, 20, 4, 15)
                    $graphics.DrawLine($pen, 4, 15, 15, 4)
                }
                "box" {
                    $graphics.DrawRectangle($pen, [Drawing.Rectangle]::new(5, 5, 14, 14))
                }
                "arrow" {
                    $graphics.DrawLine($pen, 5, 19, 19, 5)
                    $graphics.DrawLine($pen, 10, 5, 19, 5)
                    $graphics.DrawLine($pen, 19, 5, 19, 14)
                }
                "text" {
                    $graphics.DrawLine($pen, 5, 6, 19, 6)
                    $graphics.DrawLine($pen, 12, 6, 12, 19)
                    $graphics.DrawLine($pen, 9, 19, 15, 19)
                }
                "undo" {
                    $graphics.DrawLine($pen, 8, 7, 4, 11)
                    $graphics.DrawLine($pen, 4, 11, 8, 15)
                    $graphics.DrawArc($pen, [Drawing.Rectangle]::new(5, 6, 14, 12), 205, 280)
                }
                "copy" {
                    $graphics.DrawRectangle($pen, [Drawing.Rectangle]::new(8, 8, 11, 11))
                    $graphics.DrawRectangle($pen, [Drawing.Rectangle]::new(5, 5, 11, 11))
                }
                "x" {
                    $graphics.DrawLine($pen, 6, 6, 18, 18)
                    $graphics.DrawLine($pen, 18, 6, 6, 18)
                }
            }
        }
        finally {
            $pen.Dispose()
            $graphics.Dispose()
        }
        return $icon
    }

    function New-ToolbarButton([string]$Key, [string]$Tip, [scriptblock]$OnClick) {
        $button = New-Object Windows.Forms.Button
        $button.Width = 36
        $button.Height = 34
        $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = 0
        $button.BackColor = [Drawing.Color]::White
        $button.Image = New-LucideIcon $Key ([Drawing.Color]::FromArgb(44, 44, 44))
        $button.Margin = [Windows.Forms.Padding]::new(2, 3, 2, 3)
        $button.TabStop = $false
        $toolTip.SetToolTip($button, $Tip)
        $button.add_Click($OnClick)
        return $button
    }

    $toolbar = New-Object Windows.Forms.FlowLayoutPanel
    $toolbar.AutoSize = $true
    $toolbar.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $toolbar.BackColor = [Drawing.Color]::White
    $toolbar.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $toolbar.FlowDirection = [Windows.Forms.FlowDirection]::LeftToRight
    $toolbar.WrapContents = $false
    $toolbar.Padding = [Windows.Forms.Padding]::new(6, 4, 6, 4)
    $toolbar.Location = [Drawing.Point]::new(14, 14)

    $dragState = [PSCustomObject]@{
        Dragging = $false
        Start = [Drawing.Point]::Empty
        Origin = [Drawing.Point]::Empty
    }
    $toolbar.add_MouseDown({
        if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        $dragState.Dragging = $true
        $dragState.Start = [Drawing.Point]::new([int]$_.X, [int]$_.Y)
        $dragState.Origin = $toolbar.Location
    })
    $toolbar.add_MouseMove({
        if (-not $dragState.Dragging) { return }
        $nextX = [Math]::Max(0, $dragState.Origin.X + [int]$_.X - $dragState.Start.X)
        $nextY = [Math]::Max(0, $dragState.Origin.Y + [int]$_.Y - $dragState.Start.Y)
        $toolbar.Location = [Drawing.Point]::new([int]$nextX, [int]$nextY)
    })
    $toolbar.add_MouseUp({ $dragState.Dragging = $false })

    $form.Controls.Add($toolbar)
    $toolbar.BringToFront()

    function Push-History {
        [void]$history.Add((New-Object Drawing.Bitmap($bitmap)))
        if ($history.Count -gt 20) {
            $history[0].Dispose()
            $history.RemoveAt(0)
        }
    }

    function Set-Tool([string]$Tool) {
        $state.Tool = $Tool
        $pictureBox.Cursor = if ($Tool -eq "text") { [Windows.Forms.Cursors]::IBeam } else { [Windows.Forms.Cursors]::Cross }
        foreach ($key in $toolButtons.Keys) {
            $toolButtons[$key].BackColor = if ($key -eq $Tool) { [Drawing.Color]::FromArgb(220, 236, 255) } else { [Drawing.Color]::White }
        }
    }

    function Get-AnnotationPen {
        $pen = New-Object Drawing.Pen([Drawing.Color]::Red, 4)
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        return $pen
    }

    function Draw-Arrow([Drawing.Graphics]$Graphics, [Drawing.Point]$Start, [Drawing.Point]$End) {
        $pen = Get-AnnotationPen
        $cap = New-Object Drawing.Drawing2D.AdjustableArrowCap(6, 8)
        $pen.CustomEndCap = $cap
        try {
            $Graphics.DrawLine($pen, $Start, $End)
        }
        finally {
            $cap.Dispose()
            $pen.Dispose()
        }
    }

    function Draw-Rect([Drawing.Graphics]$Graphics, [Drawing.Point]$Start, [Drawing.Point]$End) {
        $left = [int][Math]::Min($Start.X, $End.X)
        $top = [int][Math]::Min($Start.Y, $End.Y)
        $width = [int][Math]::Abs($End.X - $Start.X)
        $height = [int][Math]::Abs($End.Y - $Start.Y)
        $pen = Get-AnnotationPen
        try {
            $Graphics.DrawRectangle($pen, [Drawing.Rectangle]::new($left, $top, $width, $height))
        }
        finally {
            $pen.Dispose()
        }
    }

    function Draw-Text([Drawing.Point]$Location) {
        $text = Read-AnnotationText
        if ([string]::IsNullOrWhiteSpace($text)) { return }

        Push-History
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $font = New-Object Drawing.Font("Microsoft YaHei UI", 24, [Drawing.FontStyle]::Bold)
        $brush = New-Object Drawing.SolidBrush([Drawing.Color]::Red)
        try {
            $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $graphics.DrawString($text, $font, $brush, [Drawing.PointF]::new([single]$Location.X, [single]$Location.Y))
        }
        finally {
            $brush.Dispose()
            $font.Dispose()
            $graphics.Dispose()
        }
        $pictureBox.Invalidate()
    }

    function Copy-Annotation {
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
        $clipboardImage = New-Object Drawing.Bitmap($bitmap)
        try {
            [Windows.Forms.Clipboard]::SetImage($clipboardImage)
        }
        finally {
            $clipboardImage.Dispose()
        }
        $state.Saved = $true
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    }

    $toolButtons["pen"] = New-ToolbarButton "pen" "Pen" { Set-Tool "pen" }
    $toolButtons["rect"] = New-ToolbarButton "box" "Box" { Set-Tool "rect" }
    $toolButtons["arrow"] = New-ToolbarButton "arrow" "Arrow" { Set-Tool "arrow" }
    $toolButtons["text"] = New-ToolbarButton "text" "Text" { Set-Tool "text" }
    foreach ($key in @("pen", "rect", "arrow", "text")) {
        $toolbar.Controls.Add($toolButtons[$key])
    }

    $divider = New-Object Windows.Forms.Label
    $divider.Width = 1
    $divider.Height = 28
    $divider.Margin = [Windows.Forms.Padding]::new(6, 6, 6, 3)
    $divider.BackColor = [Drawing.Color]::FromArgb(220, 220, 220)
    $toolbar.Controls.Add($divider)

    $undoButton = New-ToolbarButton "undo" "Undo" {
        if ($history.Count -le 0) { return }
        $lastBitmap = $history[$history.Count - 1]
        $history.RemoveAt($history.Count - 1)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.DrawImageUnscaled($lastBitmap, 0, 0)
        }
        finally {
            $graphics.Dispose()
            $lastBitmap.Dispose()
        }
        $pictureBox.Invalidate()
    }
    $copyButton = New-ToolbarButton "copy" "Copy" { Copy-Annotation }
    $cancelButton = New-ToolbarButton "x" "Cancel" {
        $form.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $form.Close()
    }
    $toolbar.Controls.Add($undoButton)
    $toolbar.Controls.Add($copyButton)
    $toolbar.Controls.Add($cancelButton)
    Set-Tool "pen"

    $pictureBox.add_MouseEnter({ $pictureBox.Focus() })
    $pictureBox.add_MouseWheel({ Invoke-ZoomWheel ([int]$_.Delta) })
    $panel.add_MouseWheel({ Invoke-ZoomWheel ([int]$_.Delta) })

    $pictureBox.add_MouseDown({
        if ($_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }

        $point = Convert-ToImagePoint ([int]$_.X) ([int]$_.Y)
        if ($state.Tool -eq "text") {
            Draw-Text $point
            return
        }

        Push-History
        $state.Drawing = $true
        $state.Start = $point
        $state.Current = $point
        $state.Last = $point
    })

    $pictureBox.add_MouseMove({
        if (-not $state.Drawing) { return }
        $point = Convert-ToImagePoint ([int]$_.X) ([int]$_.Y)
        $state.Current = $point

        if ($state.Tool -eq "pen") {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $pen = Get-AnnotationPen
            try {
                $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $graphics.DrawLine($pen, $state.Last, $point)
            }
            finally {
                $pen.Dispose()
                $graphics.Dispose()
            }
            $state.Last = $point
        }

        $pictureBox.Invalidate()
    })

    $pictureBox.add_MouseUp({
        if (-not $state.Drawing -or $_.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
        $state.Drawing = $false
        $point = Convert-ToImagePoint ([int]$_.X) ([int]$_.Y)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            if ($state.Tool -eq "rect") {
                Draw-Rect $graphics $state.Start $point
            }
            elseif ($state.Tool -eq "arrow") {
                Draw-Arrow $graphics $state.Start $point
            }
        }
        finally {
            $graphics.Dispose()
        }
        $pictureBox.Invalidate()
    })

    $pictureBox.add_Paint({
        if (-not $state.Drawing) { return }

        $_.Graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphicsState = $_.Graphics.Save()
        try {
            $_.Graphics.ScaleTransform([single]$zoomState.Value, [single]$zoomState.Value)
            if ($state.Tool -eq "rect") {
                Draw-Rect $_.Graphics $state.Start $state.Current
            }
            elseif ($state.Tool -eq "arrow") {
                Draw-Arrow $_.Graphics $state.Start $state.Current
            }
        }
        finally {
            $_.Graphics.Restore($graphicsState)
        }
    })

    $form.add_KeyDown({
        if ($_.Control -and ($_.KeyCode -eq [Windows.Forms.Keys]::C -or $_.KeyCode -eq [Windows.Forms.Keys]::S)) {
            Copy-Annotation
        }
        elseif ($_.Control -and $_.KeyCode -eq [Windows.Forms.Keys]::Z) {
            $undoButton.PerformClick()
        }
        elseif ($_.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $cancelButton.PerformClick()
        }
    })

    try {
        [void]$form.ShowDialog()
    }
    finally {
        foreach ($item in $history) {
            $item.Dispose()
        }
        $pictureBox.Image = $null
        foreach ($button in $toolButtons.Values) {
            if ($button.Image) { $button.Image.Dispose() }
        }
        foreach ($button in @($undoButton, $copyButton, $cancelButton)) {
            if ($button.Image) { $button.Image.Dispose() }
        }
        $toolTip.Dispose()
        $bitmap.Dispose()
        $form.Dispose()
    }

    if (-not $state.Saved) {
        exit 2
    }
}

switch ($Mode) {
    "region" { $captureRectangle = Select-ScreenRectangle }
    "window" { $captureRectangle = Get-ActiveWindowRectangle }
    "screen" { $captureRectangle = [Windows.Forms.SystemInformation]::VirtualScreen }
}

Save-ScreenRectangle -Rectangle $captureRectangle -Path $OutputPath

if ($Annotate) {
    Show-AnnotationEditor -Path $OutputPath
}
