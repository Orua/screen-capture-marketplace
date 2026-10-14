Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
$ErrorActionPreference = 'Stop'

# No draft text is read, replaced, saved, or submitted. Only an image paste is sent.
Add-Type -ReferencedAssemblies @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.ControlType].Assembly.Location,
    [System.Windows.Rect].Assembly.Location,
    'System.dll'
) -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;

public sealed class CodexPasteTarget
{
    public IntPtr Window;
    public IntPtr Focus;
    public uint ProcessId;
    public AutomationElement Composer;
}

public static class CodexComposerPaste
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct GUIINFO {
        public int cbSize; public uint flags;
        public IntPtr active, focus, capture, menu, move, caret; public RECT rect;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT {
        public ushort vk, scan; public uint flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT {
        public int dx, dy; public uint mouseData, flags, time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)] struct UNION {
        [FieldOffset(0)] public KEYBDINPUT key;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION data; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    delegate bool EnumWindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern bool GetPhysicalCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint pid);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUIINFO info);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr w);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr w);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr w, int command);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] input, int size);

    static bool IsCodex(IntPtr window, out uint pid)
    {
        pid = 0;
        if (!IsWindow(window)) return false;
        GetWindowThreadProcessId(window, out pid);
        try {
            var process = Process.GetProcessById((int)pid);
            string name = process.ProcessName;
            string file = process.MainModule.FileName;
            return (name.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("Codex", StringComparison.OrdinalIgnoreCase)) &&
                (file.IndexOf(@"\WindowsApps\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 file.IndexOf(@"\OpenAI\Codex\", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 file.IndexOf(@"\OpenAI\ChatGPT\", StringComparison.OrdinalIgnoreCase) >= 0);
        } catch { return false; }
    }

    public static CodexPasteTarget RememberForeground()
    {
        IntPtr window = GetForegroundWindow();
        uint pid;
        if (!IsCodex(window, out pid)) return null;
        uint thread = GetWindowThreadProcessId(window, out pid);
        var info = new GUIINFO { cbSize = Marshal.SizeOf(typeof(GUIINFO)) };
        GetGUIThreadInfo(thread, ref info);
        return new CodexPasteTarget { Window = window, Focus = info.focus, ProcessId = pid };
    }

    static bool BelongsTo(AutomationElement element, IntPtr window)
    {
        for (int depth = 0; element != null && depth < 40; depth++) {
            if (element.Current.NativeWindowHandle == window.ToInt32()) return true;
            element = TreeWalker.RawViewWalker.GetParent(element);
        }
        return false;
    }

    static bool IsComposer(AutomationElement element)
    {
        var current = element.Current;
        if (!current.IsEnabled || current.IsOffscreen || !current.IsKeyboardFocusable) return false;
        string id = current.AutomationId ?? "";
        string name = current.Name ?? "";
        return id.Equals("prompt-textarea", StringComparison.OrdinalIgnoreCase) ||
            id.IndexOf("composer", StringComparison.OrdinalIgnoreCase) >= 0 ||
            ((current.ControlType == ControlType.Edit || current.ControlType == ControlType.Document) &&
             (name.IndexOf("Ask", StringComparison.OrdinalIgnoreCase) >= 0 ||
              name.IndexOf("Message", StringComparison.OrdinalIgnoreCase) >= 0 ||
              name.IndexOf("协作", StringComparison.OrdinalIgnoreCase) >= 0 ||
              name.IndexOf("输入消息", StringComparison.OrdinalIgnoreCase) >= 0 ||
              name.Equals("随心输入") || name.Equals("消息输入框") ||
              name.Equals("Message", StringComparison.OrdinalIgnoreCase)));
    }

    public static void RememberComposer(CodexPasteTarget target)
    {
        if (target == null) return;
        try {
            var focused = AutomationElement.FocusedElement;
            if (focused != null && IsComposer(focused) && BelongsTo(focused, target.Window))
                target.Composer = focused;
        } catch { }
    }

    public static CodexPasteTarget FindCurrentTarget(CodexPasteTarget preferred)
    {
        var candidates = new List<CodexPasteTarget>();
        EnumWindows(delegate(IntPtr window, IntPtr ignored) {
            uint pid;
            if (IsWindowVisible(window) && IsCodex(window, out pid))
                candidates.Add(new CodexPasteTarget { Window=window, ProcessId=pid });
            return true;
        }, IntPtr.Zero);
        if (candidates.Count == 0) return null;
        IntPtr foreground = GetForegroundWindow();
        foreach (var candidate in candidates) if (candidate.Window == foreground) return candidate;
        if (preferred != null) foreach (var candidate in candidates)
            if (candidate.Window == preferred.Window && candidate.ProcessId == preferred.ProcessId) return candidate;
        return candidates[0]; // EnumWindows returns the current desktop's Z-order.
    }

    static bool Activate(IntPtr window)
    {
        if (GetForegroundWindow()==window) return true;
        if (IsIconic(window)) ShowWindow(window,9);
        // The capture process grants us foreground permission at completion.
        // Do not attach input queues: that resets key state and can disturb IME.
        BringWindowToTop(window); SetForegroundWindow(window);
        for (int i=0;i<10 && GetForegroundWindow()!=window;i++) Thread.Sleep(40);
        return GetForegroundWindow()==window;
    }

    static AutomationElement FindComposer(IntPtr window)
    {
        var root = AutomationElement.FromHandle(window);
        var inputs = root.FindAll(TreeScope.Descendants,new OrCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),
            new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document)));
        AutomationElement candidate = null;
        double score = Double.MinValue;
        RECT native; GetWindowRect(window,out native);
        for (int i=0;i<inputs.Count;i++) {
            var input = inputs[i]; var info = input.Current;
            if (!info.IsEnabled || info.IsOffscreen || !info.IsKeyboardFocusable) continue;
            var r=info.BoundingRectangle;
            if (r.IsEmpty || r.Width<120 || r.Height<18 || r.Height>(native.B-native.T)*0.4) continue;
            double value=IsComposer(input)?10000:0;
            // Recognize an unnamed Chromium composer only among editable controls
            // in the bottom part of the chat window, never a top search/address bar.
            if (r.Top < native.T+(native.B-native.T)*0.58 && value==0) continue;
            if (value==0 && info.ControlType!=ControlType.Edit) continue;
            value += r.Bottom+r.Width*0.05;
            if(value>score) { score=value; candidate=input; }
        }
        return candidate;
    }

    public static string InspectCurrent(CodexPasteTarget preferred)
    {
        var target=FindCurrentTarget(preferred);
        if(target==null) return "no-codex-window";
        if(!Activate(target.Window)) return "focus-not-restored";
        try { return FindComposer(target.Window)==null?"no-composer-found":"composer-found"; }
        catch { return "composer-unavailable"; }
    }

    static INPUT Key(ushort vk, bool up)
    {
        return new INPUT { type = 1, data = new UNION {
            key = new KEYBDINPUT { vk = vk, flags = up ? 2u : 0u }
        }};
    }

    static INPUT MouseAt(int x, int y, uint flags)
    {
        int left=GetSystemMetrics(76), top=GetSystemMetrics(77);
        int width=GetSystemMetrics(78), height=GetSystemMetrics(79);
        return new INPUT { type=0, data=new UNION { mouse=new MOUSEINPUT {
            dx=(int)Math.Round((x-left)*65535.0/Math.Max(1,width-1)),
            dy=(int)Math.Round((y-top)*65535.0/Math.Max(1,height-1)),
            flags=flags|0x8000u|0x4000u
        }}};
    }

    static bool FocusComposerNaturally(AutomationElement composer, IntPtr window)
    {
        if (composer.Current.HasKeyboardFocus) return true;
        if (GetForegroundWindow()!=window) return false;
        if ((GetAsyncKeyState(1)&0x8000)!=0 || (GetAsyncKeyState(2)&0x8000)!=0) return false;
        var bounds=composer.Current.BoundingRectangle;
        var point = new System.Windows.Point(bounds.Left+Math.Min(16,bounds.Width/2),bounds.Top+Math.Min(16,bounds.Height/2));
        // Use the real caret position when the accessibility provider supplies it.
        object pattern;
        if (composer.TryGetCurrentPattern(TextPattern.Pattern,out pattern)) {
            var ranges=((TextPattern)pattern).GetSelection();
            if(ranges.Length==1) {
                System.Windows.Rect[] rectangles=ranges[0].GetBoundingRectangles();
                if(rectangles.Length>0 && !rectangles[0].IsEmpty &&
                   rectangles[0].Left>=bounds.Left && rectangles[0].Left<bounds.Right &&
                   rectangles[0].Top>=bounds.Top && rectangles[0].Top<bounds.Bottom)
                    point=new System.Windows.Point(rectangles[0].Left+Math.Min(2,rectangles[0].Width/2),rectangles[0].Top+rectangles[0].Height/2);
            }
        }
        IntPtr previous=IntPtr.Zero;
        try {
            previous=SetThreadDpiAwarenessContext(new IntPtr(-4));
            POINT cursor; bool restore=GetPhysicalCursorPos(out cursor);
            var click=new INPUT[] { MouseAt((int)point.X,(int)point.Y,1),MouseAt((int)point.X,(int)point.Y,2),MouseAt((int)point.X,(int)point.Y,4) };
            uint sent=SendInput((uint)click.Length,click,Marshal.SizeOf(typeof(INPUT)));
            if(sent!=click.Length) {
                var release=new INPUT[] {MouseAt((int)point.X,(int)point.Y,4)};
                SendInput(1,release,Marshal.SizeOf(typeof(INPUT))); return false;
            }
            Thread.Sleep(80);
            if(restore) { var move=new INPUT[] {MouseAt(cursor.X,cursor.Y,1)}; SendInput(1,move,Marshal.SizeOf(typeof(INPUT))); }
        } finally { if(previous!=IntPtr.Zero) SetThreadDpiAwarenessContext(previous); }
        return GetForegroundWindow()==window && composer.Current.HasKeyboardFocus;
    }

    public static string Paste(CodexPasteTarget target)
    {
        var remembered = target;
        target = FindCurrentTarget(remembered);
        if (target == null) return "no-codex-target";
        uint pid;
        if (!IsCodex(target.Window, out pid) || pid != target.ProcessId) return "target-closed";
        if (!Activate(target.Window)) return "focus-not-restored";

        // Rediscover the current composer after activating the current window.
        // Do not use a stale AutomationElement from before the screenshot.
        try { target.Composer = FindComposer(target.Window); } catch { target.Composer=null; }

        bool focusedComposer = false;
        if (target.Composer != null) {
            try {
                if (!BelongsTo(target.Composer, target.Window)) return "composer-changed";
                focusedComposer = FocusComposerNaturally(target.Composer,target.Window);
            } catch { target.Composer=null; }
        }
        // Preserve an already restored native focus only. Never force a foreign
        // HWND's focus or change its input queue / IME context as a fallback.
        if (!focusedComposer) {
            if (remembered == null || remembered.Window != target.Window || remembered.ProcessId != target.ProcessId)
                return "no-composer-found";
            target.Focus = remembered.Focus;
            if (target.Focus == IntPtr.Zero ||
                (target.Focus != target.Window && !IsChild(target.Window, target.Focus)))
                return "input-focus-unavailable";
            uint thread = GetWindowThreadProcessId(target.Window, out pid);
            var info = new GUIINFO { cbSize = Marshal.SizeOf(typeof(GUIINFO)) };
            if (!GetGUIThreadInfo(thread, ref info) || info.focus != target.Focus)
                return "input-focus-not-restored";
        }
        // Never combine the paste with keys the user is still holding.
        for (int i = 0; i < 20; i++) {
            if ((GetAsyncKeyState(0x10) & 0x8000) == 0 &&
                (GetAsyncKeyState(0x11) & 0x8000) == 0 &&
                (GetAsyncKeyState(0x12) & 0x8000) == 0) break;
            Thread.Sleep(50);
            if (i == 19) return "modifier-still-held";
        }
        if (GetForegroundWindow() != target.Window || !IsCodex(target.Window, out pid) ||
            pid != target.ProcessId) return "focus-changed";
        var keys = new INPUT[] { Key(0x11, false), Key(0x56, false), Key(0x56, true), Key(0x11, true) };
        uint sent = SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT)));
        if (sent != keys.Length) {
            // Release our keys even if Windows accepted only part of the sequence.
            var release = new INPUT[] { Key(0x56, true), Key(0x11, true) };
            SendInput((uint)release.Length, release, Marshal.SizeOf(typeof(INPUT)));
            return "paste-blocked";
        }
        return "paste-requested";
    }
}
'@
