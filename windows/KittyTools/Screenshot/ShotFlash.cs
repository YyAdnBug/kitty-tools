// 「截完图放哪」选「都不要」时右下角闪一下（PLAN-v9 S7，同 mac：截图只在右下角闪一下，仍然进历史）：
// 角落卡那个位置、那么大的一块白，从 0.85 不透明淡到没有（约 0.4 s），然后销毁。
// 一扇 Win32 分层小窗（同 RecordingFrame 的做法：窗口类的白画刷填色、SetLayeredWindowAttributes 调整体透明度），
// 点穿、不激活、不进任务栏和 Alt+Tab；圆角交给 DWM。系统关了动画效果时只亮 0.15 s 不渐变。
// 不设「不进录屏」：这台机器上设了它的分层窗口连屏幕上都不显示（2136e58b）；它只亮 0.4 s，录进去也只是一闪。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class ShotFlash
{
    private const string ClassName = "KittyTools.ShotFlash";
    private const uint WsPopup = 0x80000000;
    private const uint WsExFlags = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ |
                                   0x08000000 /* NOACTIVATE */ | 0x00080000 /* LAYERED */ | 0x00000020 /* TRANSPARENT */;

    private const double StartAlpha = 217;
    private const double DurationMs = 400;
    private const double MarginDip = 16;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> WndProcPtr = &WndProc;
    private static HINSTANCE _instance;
    private static bool _registered;

    /// <summary>在那张截图本来会出角落卡的地方闪一下（大小按 ScreenshotCard.CardSize）。</summary>
    public static void Show(PixelBounds origin)
    {
        try
        {
            if (!EnsureClass())
            {
                return;
            }

            var display = Displays.AtPoint(origin.Left, origin.Top);
            var scale = display.Scale <= 0 ? 1 : display.Scale;
            var (widthDip, heightDip) = ScreenshotCard.CardSize(origin.Width, origin.Height);
            var width = MonitorLayout.Pixels(widthDip, scale);
            var height = MonitorLayout.Pixels(heightDip, scale);
            var margin = MonitorLayout.Pixels(MarginDip, scale);
            var hwnd = (IntPtr)Native.CreateWindowEx(
                WsExFlags, ClassName, string.Empty, WsPopup,
                display.Work.Right - width - margin, display.Work.Bottom - height - margin, width, height,
                default, IntPtr.Zero, _instance, (void*)0).Value;
            if (hwnd == IntPtr.Zero)
            {
                Log.Warn($"shot.flash-create-failed {Marshal.GetLastWin32Error()}");
                return;
            }

            var round = 2; // DWMWCP_ROUND
            DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &round, sizeof(int));
            SetLayeredWindowAttributes(hwnd, 0, (byte)StartAlpha, 0x2 /* LWA_ALPHA */);
            ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
            FadeOut(hwnd);
        }
        catch (Exception ex)
        {
            Log.Warn($"shot.flash-failed {ex.GetType().Name}");
        }
    }

    /// <summary>每 16 ms 降一次整体透明度（先快后慢），到 0 就销毁；关了动画效果时停 0.15 s 直接销毁。</summary>
    private static void FadeOut(IntPtr hwnd)
    {
        var timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        var started = Environment.TickCount64;
        var reduced = Motion.Reduced;
        timer.Interval = TimeSpan.FromMilliseconds(reduced ? 150 : 16);
        timer.IsRepeating = !reduced;
        timer.Tick += (_, _) =>
        {
            var progress = reduced ? 1 : Math.Clamp((Environment.TickCount64 - started) / DurationMs, 0, 1);
            if (progress >= 1)
            {
                timer.Stop();
                DestroyWindow(hwnd);
                return;
            }

            var eased = 1 - (1 - progress) * (1 - progress);
            SetLayeredWindowAttributes(hwnd, 0, (byte)Math.Round(StartAlpha * (1 - eased)), 0x2);
        };
        timer.Start();
    }

    private static bool EnsureClass()
    {
        if (_registered)
        {
            return true;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        _instance = new HINSTANCE(module.Value);
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = WndProcPtr,
            hInstance = _instance,
            // 白画刷整个进程只建这一个，不释放。
            hbrBackground = new Windows.Win32.Graphics.Gdi.HBRUSH(CreateSolidBrush(0x00FFFFFF)),
        };
        fixed (char* className = ClassName)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Warn($"shot.flash-class-failed {Marshal.GetLastWin32Error()}");
                return false;
            }
        }

        _registered = true;
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT WndProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
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

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, int* value, int size);
}
