// 录屏的选区边框（2026-10-29 用户反馈：开录后选区的边框就没了，不知道在录哪）。照 mac ScreenRecorder.showFrame：
// 倒数一开始就出、停止 / 放弃 / 取消那一刻收；选区外一圈 2 的截图强调色（品牌粉）实线（RecordingFrameRules）。
// 贴着屏幕边、外面放不下的那一侧：录屏收进选区里面画（线不进录屏，整屏、最大化的窗口也看得出在录哪；mac 是不画，
// 用户反馈「还是没有边框」后改的），前提是「不进截图 / 录屏」设上了，设不上（老系统）就照 mac 不画；长截图一律只画外面。
// mac 倒数时走蚂蚁线、录制中带呼吸发光；这里只画静止的实线。
// 四条细窗口各占一条边，纯色靠窗口类的背景画刷（不建 XAML、不自己画）；WS_EX_LAYERED | WS_EX_TRANSPARENT 让鼠标点穿，
// 不激活、不进任务栏和 Alt+Tab，WDA_EXCLUDEFROMCAPTURE 不进截图和别的录屏（线本来就在选区外，不会录进这段）。
// 录的是一扇窗口时（WGC 跟着窗口录），每 200 ms 按窗口现在的位置重摆。
// 长截图也用它（同 mac ScrollCapture 的 ScrollBorderView）：另一套四条，录屏时也能截长图，两套各管各的。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class RecordingFrame
{
    private const string ClassName = "KittyTools.RecordingFrame";
    private const uint WsPopup = 0x80000000;
    private const uint WsExFlags = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ |
                                   0x08000000 /* NOACTIVATE */ | 0x00080000 /* LAYERED */ | 0x00000020 /* TRANSPARENT */;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> WndProcPtr = &WndProc;
    private static readonly Frame Recording = new("record", insideAtEdges: true);
    private static readonly Frame Scrolling = new("scroll", insideAtEdges: false);
    private static HINSTANCE _instance;
    private static bool _registered;

    /// <summary>录屏：倒数开始时出（倒数过就已经在了，录屏开始时再调是空操作）。window 不是 0 时跟着那扇窗口走。</summary>
    public static void Show(PixelBounds region, IntPtr window = default) => Recording.Show(region, window);

    public static void Hide() => Recording.Hide();

    /// <summary>长截图：选区收起、开始滚时出，完成 / 放弃时收。</summary>
    public static void ShowScrolling(PixelBounds region) => Scrolling.Show(region, IntPtr.Zero);

    public static void HideScrolling() => Scrolling.Hide();

    private sealed class Frame
    {
        private readonly string _name;
        private readonly bool _insideAtEdges;
        private readonly IntPtr[] _strips = new IntPtr[4];
        /// <summary>四条都设上了 WDA_EXCLUDEFROMCAPTURE：这时才敢把线画进选区里面。</summary>
        private bool _excluded;
        private bool _shown;
        private IntPtr _window;
        private PixelBounds _region;
        private DispatcherQueueTimer? _follow;

        public Frame(string name, bool insideAtEdges)
        {
            _name = name;
            _insideAtEdges = insideAtEdges;
        }

        public void Show(PixelBounds region, IntPtr window)
        {
            if (_shown || !EnsureClass())
            {
                return;
            }

            _shown = true;
            _window = window;
            _excluded = true;
            var created = 0;
            for (var i = 0; i < _strips.Length; i++)
            {
                var hwnd = (IntPtr)Native.CreateWindowEx(
                    WsExFlags, ClassName, string.Empty, WsPopup, 0, 0, 0, 0, default, IntPtr.Zero, _instance, (void*)0).Value;
                _strips[i] = hwnd;
                if (hwnd == IntPtr.Zero)
                {
                    _excluded = false;
                    Log.Warn($"record.frame-create-failed {_name} {Marshal.GetLastWin32Error()}");
                    continue;
                }

                created++;
                if (!SetLayeredWindowAttributes(hwnd, 0, 255, 0x2 /* LWA_ALPHA */))
                {
                    Log.Warn($"record.frame-layered-failed {_name} {Marshal.GetLastWin32Error()}");
                }

                if (!SetWindowDisplayAffinity(hwnd, 0x11 /* WDA_EXCLUDEFROMCAPTURE */))
                {
                    _excluded = false;
                    Log.Warn($"record.frame-affinity-failed {_name} {Marshal.GetLastWin32Error()}");
                }
            }

            Place(window != IntPtr.Zero && WindowBounds(window) is { } bounds ? bounds : region);
            if (window != IntPtr.Zero)
            {
                _follow = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
                _follow.Interval = TimeSpan.FromMilliseconds(200);
                _follow.IsRepeating = true;
                _follow.Tick += (_, _) =>
                {
                    if (WindowBounds(_window) is { } moved && moved != _region)
                    {
                        Place(moved);
                    }
                };
                _follow.Start();
            }

            Log.Info($"record.frame-shown {_name} created={created} excluded={_excluded}");
        }

        public void Hide()
        {
            if (!_shown)
            {
                return;
            }

            _shown = false;
            _window = IntPtr.Zero;
            _follow?.Stop();
            _follow = null;
            for (var i = 0; i < _strips.Length; i++)
            {
                if (_strips[i] != IntPtr.Zero)
                {
                    DestroyWindow(_strips[i]);
                    _strips[i] = IntPtr.Zero;
                }
            }
        }

        private void Place(PixelBounds region)
        {
            _region = region;
            var monitor = PInvoke.MonitorFromPoint(
                new System.Drawing.Point(region.Left + region.Width / 2, region.Top + region.Height / 2),
                MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
            var info = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
            if (monitor == default || !PInvoke.GetMonitorInfo(monitor, ref info))
            {
                return;
            }

            var strips = RecordingFrameRules.Strips(
                region.Left, region.Top, region.Right, region.Bottom,
                info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom,
                Displays.ScaleOf(monitor), insideAtEdges: _insideAtEdges && _excluded);
            // 坐标不算隐私：真机上边框没出来时，看日志就知道是没建出来、摆错了地方，还是四条都是空的。
            Log.Info($"record.frame-place {_name} region={region.Left},{region.Top},{region.Right},{region.Bottom} " +
                     $"screen={info.rcMonitor.left},{info.rcMonitor.top},{info.rcMonitor.right},{info.rcMonitor.bottom} " +
                     $"strips={string.Join(' ', strips.Select(strip => strip.IsEmpty ? "-" : $"{strip.X},{strip.Y},{strip.Width}x{strip.Height}"))}");
            for (var i = 0; i < _strips.Length; i++)
            {
                var hwnd = _strips[i];
                if (hwnd == IntPtr.Zero)
                {
                    continue;
                }

                var strip = strips[i];
                if (strip.IsEmpty)
                {
                    ShowWindow(hwnd, 0 /* SW_HIDE */);
                    continue;
                }

                if (!SetWindowPos(hwnd, new IntPtr(-1) /* HWND_TOPMOST */, strip.X, strip.Y, strip.Width, strip.Height,
                        0x0010 /* SWP_NOACTIVATE */ | 0x0040 /* SWP_SHOWWINDOW */))
                {
                    Log.Warn($"record.frame-pos-failed {_name} {Marshal.GetLastWin32Error()}");
                }
            }
        }
    }

    /// <summary>窗口看得见的边界（DWMWA_EXTENDED_FRAME_BOUNDS，不含看不见的拉伸边，同 WindowList）；窗口没了返回 null。</summary>
    private static PixelBounds? WindowBounds(IntPtr window)
        => DwmGetWindowAttribute(window, 9, out RECT frame, sizeof(RECT)) == 0 && frame.right > frame.left
            ? new PixelBounds(frame.left, frame.top, frame.right, frame.bottom)
            : null;

    private static bool EnsureClass()
    {
        if (_registered)
        {
            return true;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        _instance = new HINSTANCE(module.Value);
        var color = Theme.Shot.Accent;
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = WndProcPtr,
            hInstance = _instance,
            // 画刷整个进程只建这一个，不释放。
            hbrBackground = new HBRUSH(CreateSolidBrush((uint)(color.R | (color.G << 8) | (color.B << 16)))),
        };
        fixed (char* className = ClassName)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Warn($"record.frame-class-failed {Marshal.GetLastWin32Error()}");
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

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);

    [LibraryImport("dwmapi.dll")]
    private static partial int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);

    // LibraryImport 的源生成器认不出 CsWin32 生成的 RECT（SYSLIB1051），这里自己声明一个（同 WindowList）。
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }
}
