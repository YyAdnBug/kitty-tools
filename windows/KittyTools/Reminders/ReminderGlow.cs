// 提醒的「边框」（PLAN-v12 N6，照 mac Reminders/ReminderGlow.swift）：每块屏四边一圈强调色的光，鼠标点得穿；提示同时挂着（ReminderCenter）。
// 每屏四条贴边的 Win32 分层窄窗（同 ShotFlash / 状态屏压暗层的做法：窗口类的画刷填色、SetLayeredWindowAttributes 调整体透明度），
// 点穿、不激活、不进任务栏和 Alt+Tab；不开整屏透明窗。不设「不进录屏」（这台机器上设了它的分层窗口连屏幕上都不显示；录屏时本来也降成轻提醒）。
// ponytail: mac 是由边往里淡下去的一道光、慢慢呼吸；这里是一条 8 DIP 的实色细边、不动。要做渐变得换 UpdateLayeredWindow 逐像素画。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class ReminderGlow
{
    private const uint WsPopup = 0x80000000;
    private const uint ExStyle = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ | 0x08000000 /* NOACTIVATE */ |
                                 0x00080000 /* LAYERED */ | 0x00000020 /* TRANSPARENT：点穿 */;

    private const double ThicknessDip = 8;
    private const byte Alpha = 170;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> ProcPtr = &Proc;
    private static readonly HashSet<string> Registered = new(StringComparer.Ordinal);
    private static readonly List<IntPtr> Strips = new();

    public static bool IsShowing => Strips.Count > 0;

    /// <summary>出来（已经在了就不动）。颜色是此刻的强调色。</summary>
    public static void Show()
    {
        if (IsShowing)
        {
            return;
        }

        try
        {
            var color = Theme.AccentColor;
            var className = $"KittyTools.Glow.{color.R:X2}{color.G:X2}{color.B:X2}";
            if (!EnsureClass(className, (uint)(color.R | color.G << 8 | color.B << 16)))
            {
                return;
            }

            var module = PInvoke.GetModuleHandle(default(PCWSTR));
            foreach (var (bounds, scale) in ScreenCapture.Monitors())
            {
                var thickness = MonitorLayout.Pixels(ThicknessDip, scale);
                (int X, int Y, int W, int H)[] edges =
                {
                    (bounds.Left, bounds.Top, bounds.Width, thickness),
                    (bounds.Left, bounds.Bottom - thickness, bounds.Width, thickness),
                    (bounds.Left, bounds.Top + thickness, thickness, bounds.Height - 2 * thickness),
                    (bounds.Right - thickness, bounds.Top + thickness, thickness, bounds.Height - 2 * thickness),
                };
                foreach (var (x, y, width, height) in edges)
                {
                    var hwnd = (IntPtr)Native.CreateWindowEx(
                        ExStyle, className, string.Empty, WsPopup, x, y, width, height,
                        default, IntPtr.Zero, new HINSTANCE(module.Value), (void*)0).Value;
                    if (hwnd == IntPtr.Zero)
                    {
                        continue;
                    }

                    SetLayeredWindowAttributes(hwnd, 0, Alpha, 0x2 /* LWA_ALPHA */);
                    ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
                    Strips.Add(hwnd);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"reminder.glow-failed {ex.GetType().Name}");
        }
    }

    public static void Dismiss()
    {
        foreach (var hwnd in Strips)
        {
            DestroyWindow(hwnd);
        }

        Strips.Clear();
    }

    private static bool EnsureClass(string name, uint colorRef)
    {
        if (Registered.Contains(name))
        {
            return true;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = ProcPtr,
            hInstance = new HINSTANCE(module.Value),
            // 每种颜色一个窗口类、一支画刷，不释放（强调色只有几种）。
            hbrBackground = new Windows.Win32.Graphics.Gdi.HBRUSH(CreateSolidBrush(colorRef)),
        };
        fixed (char* className = name)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Warn($"reminder.glow-class-failed {Marshal.GetLastWin32Error()}");
                return false;
            }
        }

        Registered.Add(name);
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT Proc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
        => PInvoke.DefWindowProc(hwnd, msg, wParam, lParam);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateSolidBrush(uint color);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);
}
