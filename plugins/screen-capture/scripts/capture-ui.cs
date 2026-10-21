using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class CaptureUi
{
    static ClipboardNotice notice;
    public static void ShowNotice(string message)
    {
        if (notice != null && !notice.IsDisposed) notice.Close();
        notice = new ClipboardNotice(message);
        notice.Show();
    }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint processId);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int L, T, R, B; }

    // B design: original Codex cloud/terminal motif with blue capture corners.
    // Draw from source at each icon size so the executable and tray stay consistent.
    public static Bitmap IconBitmap(int size)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.ScaleTransform(size / 256f, size / 256f);
            using (var cloud = new GraphicsPath()) {
                cloud.StartFigure();
                cloud.AddBezier(96, 69, 100, 45, 140, 40, 158, 61);
                cloud.AddBezier(158, 61, 184, 52, 210, 73, 205, 98);
                cloud.AddBezier(205, 98, 226, 114, 220, 142, 204, 153);
                cloud.AddBezier(204, 153, 207, 180, 185, 200, 163, 193);
                cloud.AddBezier(163, 193, 144, 213, 117, 206, 107, 190);
                cloud.AddBezier(107, 190, 81, 201, 59, 180, 64, 158);
                cloud.AddBezier(64, 158, 44, 145, 44, 122, 58, 109);
                cloud.AddBezier(58, 109, 51, 86, 73, 64, 96, 69);
                cloud.CloseFigure();
                using (var fill = new LinearGradientBrush(new Rectangle(48, 45, 174, 163), Color.FromArgb(188, 158, 255), Color.FromArgb(46, 32, 255), 90f)) {
                    var blend = new ColorBlend();
                    blend.Colors = new Color[] { Color.FromArgb(188,158,255), Color.FromArgb(104,121,255), Color.FromArgb(46,32,255) };
                    blend.Positions = new float[] { 0f, .5f, 1f };
                    fill.InterpolationColors = blend; g.FillPath(fill, cloud);
                }
            }
            using (var pen = new Pen(Color.White, 11)) {
                pen.StartCap = pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new PointF[] { new PointF(93,105), new PointF(109,128), new PointF(93,151) });
                g.DrawLine(pen, 137, 153, 166, 153);
            }
            using (var pen = new Pen(Color.FromArgb(0, 104, 255), 17)) {
                pen.StartCap = pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                g.DrawLines(pen, new PointF[] { new PointF(22,65), new PointF(22,22), new PointF(65,22) });
                g.DrawLines(pen, new PointF[] { new PointF(191,22), new PointF(234,22), new PointF(234,65) });
                g.DrawLines(pen, new PointF[] { new PointF(234,191), new PointF(234,234), new PointF(191,234) });
                g.DrawLines(pen, new PointF[] { new PointF(65,234), new PointF(22,234), new PointF(22,191) });
            }
        }
        return bitmap;
    }

    public static Icon TrayIcon()
    {
        using (var bitmap = IconBitmap(64)) {
            IntPtr handle = bitmap.GetHicon();
            try { return (Icon)Icon.FromHandle(handle).Clone(); }
            finally { DestroyIcon(handle); }
        }
    }
    internal static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath(); float d = radius * 2;
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right-d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right-d, r.Bottom-d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom-d, d, d, 90, 90); path.CloseFigure(); return path;
    }

    public static Bitmap Desktop(Rectangle bounds)
    {
        var image = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(image)) g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
        return image;
    }

    public static void CapturePlain(string mode, string output)
    {
        Rectangle bounds = SystemInformation.VirtualScreen;
        if (mode == "window") {
            NativeRect r;
            if (!GetWindowRect(GetForegroundWindow(), out r)) throw new InvalidOperationException("无法读取窗口范围");
            bounds = Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
        }
        using (var image = Desktop(bounds)) image.Save(output, ImageFormat.Png);
    }

    public static bool Run(string output, uint parentProcess)
    {
        SetProcessDPIAware();
        Rectangle bounds = SystemInformation.VirtualScreen;
        using (var desktop = Desktop(bounds))
        using (var overlay = new CaptureOverlay(desktop, bounds, output, parentProcess))
            return overlay.ShowDialog() == DialogResult.OK;
    }

    public static void Preview(string input, string output)
    {
        using (var image = new Bitmap(input))
        using (var overlay = new CaptureOverlay(image, new Rectangle(0,0,image.Width,image.Height), "", 0)) {
            overlay.SelectForPreview(new Rectangle(220, 130, Math.Min(650, image.Width-260), Math.Min(380,image.Height-250)));
            overlay.DrawPreview(output);
        }
    }
}

// Failure notices use a bounded timer instead of an OS balloon timeout, which
// Windows may extend. This window never takes keyboard focus from another app.
internal sealed class ClipboardNotice : Form
{
    readonly Timer timer = new Timer();
    readonly Font noticeFont = new Font("Microsoft YaHei UI", 10);
    readonly string message;
    internal ClipboardNotice(string text)
    {
        message = text;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
        ClientSize = new Size(360, 82);
        var work = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(work.Right-Width-16,work.Bottom-Height-16);
        using(var shape=CaptureUi.Rounded(new RectangleF(0,0,Width,Height),10)) Region=new Region(shape);
        timer.Interval = 3200;
        timer.Tick += delegate { timer.Stop(); Close(); };
        Shown += delegate { timer.Start(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000080; return p; } }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(Color.FromArgb(247,250,248));
        TextRenderer.DrawText(e.Graphics,message,noticeFont,new Rectangle(18,14,Width-36,Height-28),Color.FromArgb(39,58,48),TextFormatFlags.WordBreak|TextFormatFlags.VerticalCenter);
    }
    protected override void Dispose(bool disposing)
    {
        if(disposing) { timer.Dispose(); noticeFont.Dispose(); }
        base.Dispose(disposing);
    }
}

internal sealed class CaptureOverlay : Form
{
    readonly Bitmap desktop; readonly string output; readonly uint parentProcess;
    readonly List<Mark> marks = new List<Mark>(); readonly ToolTip tips = new ToolTip();
    Rectangle selection; Point start; Mark pending; bool selecting, confirmOnRelease; string tool = "move";
    CaptureToolbar toolbar; TextBox textBox;
    static readonly Color Green = Color.FromArgb(7, 193, 96);
    readonly Font uiFont = new Font("Microsoft YaHei UI", 10);
    readonly Font markFont = new Font("Microsoft YaHei UI", 16, FontStyle.Bold);

    internal CaptureOverlay(Bitmap frozen, Rectangle bounds, string destination, uint parent)
    {
        desktop = frozen; output = destination; parentProcess = parent;
        FormBorderStyle = FormBorderStyle.None; StartPosition = FormStartPosition.Manual;
        Bounds = bounds; TopMost = true; ShowInTaskbar = false; KeyPreview = true;
        DoubleBuffered = true; Cursor = Cursors.Cross; Font = uiFont;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Shown += delegate { Activate(); Focus(); };
    }

    internal void SelectForPreview(Rectangle r) { selection = r; }
    internal void DrawPreview(string path)
    {
        using (var image = new Bitmap(desktop.Width, desktop.Height)) {
            using (var g = Graphics.FromImage(image)) PaintSurface(g);
            using (var bar = new Bitmap(330, 48)) {
                using (var g = Graphics.FromImage(bar)) CaptureToolbar.PaintPreview(g);
                using (var g = Graphics.FromImage(image)) g.DrawImageUnscaled(bar, selection.Right-330, selection.Bottom+12);
            }
            image.Save(path, ImageFormat.Png);
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { PaintSurface(e.Graphics); }
    void PaintSurface(Graphics g)
    {
        g.DrawImageUnscaled(desktop, 0, 0);
        using (var shade = new SolidBrush(Color.FromArgb(110, 0, 0, 0))) g.FillRectangle(shade, ClientRectangle);
        if (selection.Width > 1 && selection.Height > 1) {
            g.DrawImage(desktop, selection, selection, GraphicsUnit.Pixel);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var old = g.Save(); g.SetClip(selection);
            foreach (var mark in marks) mark.Draw(g, markFont);
            if (pending != null) pending.Draw(g, markFont);
            g.Restore(old);
            using (var pen = new Pen(Green, 2)) g.DrawRectangle(pen, selection);
            using (var fill = new SolidBrush(Green)) {
                foreach (var p in new Point[] { selection.Location, new Point(selection.Right,selection.Top), new Point(selection.Left,selection.Bottom), new Point(selection.Right,selection.Bottom), new Point(selection.Left+selection.Width/2,selection.Top), new Point(selection.Left+selection.Width/2,selection.Bottom), new Point(selection.Left,selection.Top+selection.Height/2), new Point(selection.Right,selection.Top+selection.Height/2) })
                    g.FillRectangle(fill, p.X-3, p.Y-3, 6, 6);
            }
            string size = selection.Width + " × " + selection.Height;
            float y = selection.Top >= 28 ? selection.Top-26 : selection.Top+8;
            SizeF measure = g.MeasureString(size, uiFont);
            using (var bg = new SolidBrush(Color.FromArgb(185, 24, 24, 24))) g.FillRectangle(bg, selection.Left, y, measure.Width+14, 23);
            g.DrawString(size, uiFont, Brushes.White, selection.Left+7, y+2);
        } else {
            using (var fill = new SolidBrush(Color.FromArgb(210, 28, 28, 28))) {
                var r = new RectangleF(ClientSize.Width/2-140, 32, 280, 38);
                using (var shape = CaptureUi.Rounded(r, 8)) g.FillPath(fill, shape);
                g.DrawString("拖动框选截图 · Esc 取消", uiFont, Brushes.White, r.Left+22, r.Top+10);
            }
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Right) { CancelCapture(); return; }
        if (e.Button != MouseButtons.Left) return;
        CommitText(); start = e.Location;
        if (!selection.IsEmpty && (tool == "move" || !selection.Contains(e.Location))) {
            // Finish on mouse-up so the confirmation click cannot reach Codex.
            confirmOnRelease = true; Capture = true; return;
        }
        if (selection.IsEmpty) {
            selecting = true; selection = new Rectangle(e.X,e.Y,0,0); marks.Clear();
            if (toolbar != null) toolbar.Hide();
        } else if (selection.Contains(e.Location)) {
            if (tool == "text") { BeginText(e.Location); return; }
            pending = new Mark { Kind=tool, Start=e.Location, End=e.Location };
            if (tool == "pen") pending.Points.Add(e.Location);
        }
        Capture = true;
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (selecting) { selection = Rect(start, Clamp(e.Location)); Invalidate(); }
        else if (pending != null) { pending.End = ClampSelection(e.Location); if (pending.Kind == "pen") pending.Points.Add(pending.End); Invalidate(selection); }
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e); Capture = false;
        if (confirmOnRelease && e.Button == MouseButtons.Left) {
            confirmOnRelease=false; Complete(); return;
        }
        if (selecting) { selecting = false; if (selection.Width > 3 && selection.Height > 3) ShowToolbar(); else selection = Rectangle.Empty; }
        if (pending != null) { marks.Add(pending); pending=null; Invalidate(selection); }
    }
    Point Clamp(Point p) { return new Point(Math.Max(0,Math.Min(ClientSize.Width-1,p.X)), Math.Max(0,Math.Min(ClientSize.Height-1,p.Y))); }
    Point ClampSelection(Point p) { return new Point(Math.Max(selection.Left,Math.Min(selection.Right-1,p.X)), Math.Max(selection.Top,Math.Min(selection.Bottom-1,p.Y))); }
    static Rectangle Rect(Point a, Point b) { return Rectangle.FromLTRB(Math.Min(a.X,b.X),Math.Min(a.Y,b.Y),Math.Max(a.X,b.X),Math.Max(a.Y,b.Y)); }

    void ShowToolbar()
    {
        if (toolbar == null) toolbar = new CaptureToolbar(this);
        Point bottom = PointToScreen(new Point(selection.Right-toolbar.Width, selection.Bottom+12));
        Rectangle work = Screen.FromPoint(PointToScreen(selection.Location)).Bounds;
        int x = Math.Max(work.Left+8, Math.Min(work.Right-toolbar.Width-8, bottom.X));
        int y = bottom.Y;
        if (y+toolbar.Height > work.Bottom-8) y = PointToScreen(selection.Location).Y-toolbar.Height-12;
        if (y < work.Top+8) y = work.Bottom-toolbar.Height-8;
        toolbar.Location = new Point(x,y); toolbar.Show(this); toolbar.BringToFront();
    }
    internal void Pick(string key)
    {
        CommitText();
        if (key == "done") { Complete(); return; }
        if (key == "cancel") { CancelCapture(); return; }
        if (key == "undo") { if (marks.Count > 0) marks.RemoveAt(marks.Count-1); Invalidate(selection); return; }
        tool = key; Cursor = key == "text" ? Cursors.IBeam : Cursors.Cross;
        toolbar.SetSelected(key);
    }
    void BeginText(Point point)
    {
        textBox = new TextBox { Font=markFont, ForeColor=Color.FromArgb(235,65,65), BackColor=Color.White, BorderStyle=BorderStyle.FixedSingle, Location=point, Width=Math.Max(40,Math.Min(300,selection.Right-point.X)) };
        textBox.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress=true; CommitText(); Focus(); } };
        Controls.Add(textBox); textBox.BringToFront(); textBox.Focus();
    }
    void CommitText()
    {
        if (textBox == null) return;
        if (!String.IsNullOrWhiteSpace(textBox.Text)) marks.Add(new Mark { Kind="text", Start=textBox.Location, Text=textBox.Text });
        Controls.Remove(textBox); textBox.Dispose(); textBox=null; Invalidate(selection);
    }
    void Complete()
    {
        CommitText(); if (selection.Width <= 3 || selection.Height <= 3) return;
        using (var image = new Bitmap(selection.Width, selection.Height)) {
            using (var g = Graphics.FromImage(image)) {
                g.DrawImage(desktop, new Rectangle(Point.Empty,selection.Size), selection, GraphicsUnit.Pixel);
                g.TranslateTransform(-selection.Left,-selection.Top); g.SmoothingMode=SmoothingMode.AntiAlias;
                foreach (var mark in marks) mark.Draw(g,markFont);
            }
            image.Save(output,ImageFormat.Png); Clipboard.SetImage(image);
        }
        // Transfer the foreground privilege while this capture process still owns it.
        if (parentProcess != 0) CaptureUi.AllowSetForegroundWindow(parentProcess);
        DialogResult = DialogResult.OK; Close();
    }
    void CancelCapture() { DialogResult = DialogResult.Cancel; Close(); }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress=true; CancelCapture(); }
        else if (e.Control && e.KeyCode == Keys.Z) { e.SuppressKeyPress=true; Pick("undo"); }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { if (toolbar != null) toolbar.Dispose(); if (textBox != null) textBox.Dispose(); tips.Dispose(); uiFont.Dispose(); markFont.Dispose(); }
        base.Dispose(disposing);
    }
    internal sealed class Mark
    {
        public string Kind, Text; public Point Start, End; public List<Point> Points = new List<Point>();
        public void Draw(Graphics g, Font font)
        {
            using (var pen = new Pen(Color.FromArgb(235,65,65),3)) {
                pen.StartCap=pen.EndCap=LineCap.Round; pen.LineJoin=LineJoin.Round;
                Rectangle r=Rect(Start,End);
                if (Kind == "rect") g.DrawRectangle(pen,r);
                else if (Kind == "ellipse") g.DrawEllipse(pen,r);
                else if (Kind == "arrow") { using(var cap=new AdjustableArrowCap(4,5)) { pen.CustomEndCap=cap; g.DrawLine(pen,Start,End); } }
                else if (Kind == "pen" && Points.Count > 1) g.DrawLines(pen,Points.ToArray());
                else if (Kind == "text") { using(var brush=new SolidBrush(pen.Color)) g.DrawString(Text,font,brush,Start); }
            }
        }
    }
}

internal sealed class CaptureToolbar : Form
{
    readonly CaptureOverlay owner; readonly ToolTip tips = new ToolTip(); readonly List<ToolButton> buttons = new List<ToolButton>();
    static readonly string[] Keys = { "rect", "ellipse", "arrow", "pen", "text", "undo", "cancel", "done" };
    static readonly string[] Names = { "矩形", "圆形", "箭头", "画笔", "文字", "撤销 Ctrl+Z", "取消 Esc", "插入 Codex（保留文字，不发送）" };
    internal CaptureToolbar(CaptureOverlay overlay)
    {
        owner=overlay; FormBorderStyle=FormBorderStyle.None; ShowInTaskbar=false; TopMost=true;
        StartPosition=FormStartPosition.Manual; ClientSize=new Size(330,48); BackColor=Color.White;
        DoubleBuffered=true;
        using(var shape=CaptureUi.Rounded(new RectangleF(0,0,330,48),8)) Region=new Region(shape);
        for(int i=0;i<Keys.Length;i++) {
            var b=new ToolButton(Keys[i]); b.Location=new Point(5+i*40,5); b.Size=new Size(38,38);
            tips.SetToolTip(b,Names[i]); b.Click+=delegate(object sender,EventArgs e) { owner.Pick(((ToolButton)sender).Key); };
            buttons.Add(b); Controls.Add(b);
        }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle |= 0x08000000; return p; } }
    internal void SetSelected(string key) { foreach(var b in buttons) { b.Selected=b.Key==key; b.Invalidate(); } }
    internal static void PaintPreview(Graphics g)
    {
        g.SmoothingMode=SmoothingMode.AntiAlias;
        using(var fill=new SolidBrush(Color.White)) using(var shape=CaptureUi.Rounded(new RectangleF(0,0,330,48),8)) g.FillPath(fill,shape);
        for(int i=0;i<Keys.Length;i++) ToolButton.Draw(g,Keys[i],new Rectangle(5+i*40,5,38,38),false,false);
    }
    protected override void Dispose(bool disposing) { if(disposing) tips.Dispose(); base.Dispose(disposing); }
}

internal sealed class ToolButton : Control
{
    public readonly string Key; public bool Selected; bool hover;
    internal ToolButton(string key) { Key=key; Cursor=Cursors.Hand; SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true); }
    protected override void OnMouseEnter(EventArgs e) { hover=true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover=false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnPaint(PaintEventArgs e) { Draw(e.Graphics,Key,ClientRectangle,Selected,hover); }
    internal static void Draw(Graphics g,string key,Rectangle bounds,bool selected,bool hover)
    {
        g.SmoothingMode=SmoothingMode.AntiAlias;
        if(selected||hover) using(var fill=new SolidBrush(selected?Color.FromArgb(225,246,235):Color.FromArgb(242,244,246))) using(var shape=CaptureUi.Rounded(bounds,6)) g.FillPath(fill,shape);
        var state=g.Save(); g.TranslateTransform(bounds.X+7,bounds.Y+7);
        Color color=key=="done"?Color.FromArgb(7,174,94):key=="cancel"?Color.FromArgb(215,80,80):Color.FromArgb(54,61,65);
        using(var pen=new Pen(color,2)) {
            pen.StartCap=pen.EndCap=LineCap.Round; pen.LineJoin=LineJoin.Round;
            if(key=="rect") g.DrawRectangle(pen,5,5,14,14);
            else if(key=="ellipse") g.DrawEllipse(pen,5,5,14,14);
            else if(key=="arrow") { g.DrawLine(pen,5,19,19,5); g.DrawLines(pen,new Point[]{new Point(10,5),new Point(19,5),new Point(19,14)}); }
            else if(key=="pen") g.DrawLines(pen,new Point[]{new Point(4,20),new Point(5,14),new Point(16,3),new Point(21,8),new Point(10,19),new Point(4,20)});
            else if(key=="text") { g.DrawLine(pen,5,5,19,5);g.DrawLine(pen,12,5,12,20);g.DrawLine(pen,8,20,16,20); }
            else if(key=="undo") { g.DrawArc(pen,5,7,15,12,190,280);g.DrawLines(pen,new Point[]{new Point(8,3),new Point(4,8),new Point(10,9)}); }
            else if(key=="cancel") { g.DrawLine(pen,6,6,18,18);g.DrawLine(pen,18,6,6,18); }
            else if(key=="done") g.DrawLines(pen,new Point[]{new Point(4,12),new Point(10,18),new Point(21,5)});
        }
        g.Restore(state);
    }
}
