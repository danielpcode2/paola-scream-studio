using System.Runtime.InteropServices;
using System.Text;

namespace PaolaScreenStudio;

/// <summary>Win32 calls used for capture targets, hotkeys, mouse tracking and capture exclusion.</summary>
internal static class Native
{
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const int WM_HOTKEY = 0x0312;
    public const uint MOD_ALT = 0x1;
    public const uint MOD_SHIFT = 0x4;
    public const uint MOD_NOREPEAT = 0x4000;
    public const int WH_MOUSE_LL = 14;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    public delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? name);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    public static void ExcludeFromCapture(IntPtr hwnd)
    {
        // Windows 10 2004+: the window stays visible to you but never appears in the recording.
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    }
}

/// <summary>A rectangle in physical screen pixels.</summary>
public readonly record struct ScreenRect(int X, int Y, int Width, int Height)
{
    /// <summary>H.264 needs even sizes.</summary>
    public ScreenRect Even() => this with { Width = Width / 2 * 2, Height = Height / 2 * 2 };
}

public sealed record MonitorInfo(string Name, ScreenRect Bounds, bool Primary)
{
    public override string ToString() => $"{Name} ({Bounds.Width}×{Bounds.Height}){(Primary ? " ★" : "")}";
}

public sealed record WindowInfo(IntPtr Handle, string Title)
{
    public override string ToString() => Title;
}

internal static class ScreenInfo
{
    public static List<MonitorInfo> Monitors()
    {
        var result = new List<MonitorInfo>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref Native.RECT _, IntPtr _) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(monitor, ref info))
            {
                var r = info.rcMonitor;
                var index = result.Count + 1;
                result.Add(new MonitorInfo(
                    Core.Strings.T("display.name", index),
                    new ScreenRect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top),
                    (info.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return result.OrderByDescending(m => m.Primary).ToList();
    }

    /// <summary>Visible top-level windows with a title (no cloaked UWP shells, no own windows).</summary>
    public static List<WindowInfo> Windows()
    {
        var result = new List<WindowInfo>();
        var shell = Native.GetShellWindow();
        var own = System.Diagnostics.Process.GetCurrentProcess().MainWindowTitle;
        Native.EnumWindows((hwnd, _) =>
        {
            if (hwnd == shell || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd))
            {
                return true;
            }
            if (Native.DwmGetWindowAttribute(hwnd, 14 /* DWMWA_CLOAKED */, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            {
                return true;
            }
            var length = Native.GetWindowTextLength(hwnd);
            if (length == 0)
            {
                return true;
            }
            var text = new StringBuilder(length + 1);
            Native.GetWindowText(hwnd, text, text.Capacity);
            var title = text.ToString();
            if (!string.IsNullOrWhiteSpace(title) && title != own && title != "Program Manager")
            {
                result.Add(new WindowInfo(hwnd, title));
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static ScreenRect? WindowBounds(IntPtr hwnd)
    {
        if (Native.DwmGetWindowAttribute(hwnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out Native.RECT r, Marshal.SizeOf<Native.RECT>()) != 0
            && !Native.GetWindowRect(hwnd, out r))
        {
            return null;
        }
        return new ScreenRect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    /// <summary>Bounding box of all monitors in physical pixels.</summary>
    public static ScreenRect VirtualScreen() =>
        new(Native.GetSystemMetrics(76), Native.GetSystemMetrics(77), Native.GetSystemMetrics(78), Native.GetSystemMetrics(79));
}
