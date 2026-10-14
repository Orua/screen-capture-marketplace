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
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    delegate bool EnumWindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint pid);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUIINFO info);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr w);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr w);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr w, int command);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr w);
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
        if (IsIconic(window)) ShowWindow(window,9);
        uint unused;
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
        uint target = GetWindowThreadProcessId(window, out unused);
        bool a = foreground != current && AttachThreadInput(current,foreground,true);
        bool b = target != current && target != foreground && AttachThreadInput(current,target,true);
        try { BringWindowToTop(window); SetForegroundWindow(window); }
        finally { if (b) AttachThreadInput(current,target,false); if (a) AttachThreadInput(current,foreground,false); }
        for (int i=0;i<10 && GetForegroundWindow()!=window;i++) Thread.Sleep(40);
        return GetForegroundWindow()==window;
    }

    static AutomationElement FindComposer(IntPtr window)
    {
        UIntPtr ignored;
        SendMessageTimeout(window,0x003D,UIntPtr.Zero,new IntPtr(-25),2,200,out ignored);
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
                target.Composer.SetFocus();
                focusedComposer = true;
            } catch { target.Composer=null; }
        }
        // Electron can keep its DOM focus while exposing only a native renderer HWND.
        // In that case restore exactly the focus remembered before the capture overlay.
        if (!focusedComposer) {
            if (remembered == null || remembered.Window != target.Window || remembered.ProcessId != target.ProcessId)
                return "no-composer-found";
            target.Focus = remembered.Focus;
            if (target.Focus == IntPtr.Zero ||
                (target.Focus != target.Window && !IsChild(target.Window, target.Focus)))
                return "input-focus-unavailable";
            uint thread = GetWindowThreadProcessId(target.Window, out pid);
            uint ours = GetCurrentThreadId();
            bool attached = AttachThreadInput(ours, thread, true);
            try { SetFocus(target.Focus); }
            finally { if (attached) AttachThreadInput(ours, thread, false); }
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
