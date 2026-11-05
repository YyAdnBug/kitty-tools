// 提醒的「边框」（PLAN-v12 N6，第 7 批补成渐变 + 呼吸；照 mac Reminders/ReminderGlow.swift）：每块屏四条贴边的窄窗，
// 一层强调色的渐变（屏幕边上 0.85、往里 28 DIP 淡到没有），透明度在 1 和 0.35 之间慢慢呼吸（单程 1.2 s），减弱动态效果时只亮着。
// 提示同时挂着（ReminderCenter），「知道了」在提示上点；边框只负责让余光看到。
// 做法：Win32 分层窗口逐像素透明（UpdateLayeredWindow，32 位预乘 alpha 的 DIB，交给系统后本进程不留位图）；呼吸只换整体透明度
// （UpdateLayeredWindow 不带位图，只给 BLENDFUNCTION）。点穿、不激活、不进任务栏和 Alt+Tab；不开整屏透明窗（WinUI 透明窗在用户机器上是白的）。
// 上下两条横贯整屏、左右两条竖贯整屏（四个角叠两层，略亮一点，同 mac）。不设「不进录屏」（这台机器上设了它的分层窗口连屏幕上都不显示；
// 录屏时本来也降成轻提醒）。
// ponytail: 呼吸靠 UI 线程上 30 Hz 的计时器逐帧算（mac 交给渲染服务）；只在边框挂着的时候跑，知道了就停。要省就换 DirectComposition。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class ReminderGlow
{
    private const uint WsPopup = 0x80000000;
    private const uint ExStyle = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ | 0x08000000 /* NOACTIVATE */ |
                                 0x00080000 /* LAYERED */ | 0x00000020 /* TRANSPARENT：点穿 */;

    private const string ClassName = "KittyTools.ReminderGlow";
    private const uint UlwAlpha = 0x2;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> ProcPtr = &Proc;
    private static bool _registered;
    private static readonly List<IntPtr> Strips = new();
    private static DispatcherQueueTimer? _breath;
    private static long _shownAt;
    private static byte _lastAlpha;

    public static bool IsShowing => Strips.Count > 0;

    /// <summary>出来（已经在了就不动）。颜色是此刻的强调色。</summary>
    public static void Show()
    {
        if (IsShowing || !EnsureClass())
        {
            return;
        }

        try
        {
            var color = Theme.AccentColor;
            var module = PInvoke.GetModuleHandle(default(PCWSTR));
            foreach (var (bounds, scale) in ScreenCapture.Monitors())
            {
                var depth = MonitorLayout.Pixels(ReminderGlowCurve.Depth, scale);
                (int X, int Y, int W, int H, Edge Edge)[] edges =
                {
                    (bounds.Left, bounds.Top, bounds.Width, depth, Edge.Top),
                    (bounds.Left, bounds.Bottom - depth, bounds.Width, depth, Edge.Bottom),
                    (bounds.Left, bounds.Top, depth, bounds.Height, Edge.Left),
                    (bounds.Right - depth, bounds.Top, depth, bounds.Height, Edge.Right),
                };
                foreach (var (x, y, width, height, edge) in edges)
                {
                    var hwnd = (IntPtr)Native.CreateWindowEx(
                        ExStyle, ClassName, string.Empty, WsPopup, x, y, width, height,
                        default, IntPtr.Zero, new HINSTANCE(module.Value), (void*)0).Value;
                    if (hwnd == IntPtr.Zero)
                    {
                        continue;
                    }

                    if (!Paint(hwnd, x, y, width, height, depth, edge, color))
                    {
                        DestroyWindow(hwnd);
                        continue;
                    }

                    ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */);
                    Strips.Add(hwnd);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"reminder.glow-failed {ex.GetType().Name}");
        }

        if (!IsShowing)
        {
            return;
        }

        _shownAt = Environment.TickCount64;
        _lastAlpha = 0;
        _breath = DispatcherQueue.GetForCurrentThread()?.CreateTimer();
        if (_breath is null)
        {
            SetAlpha(255);
            return;
        }

        _breath.Interval = TimeSpan.FromMilliseconds(33);
        _breath.IsRepeating = true;
        _breath.Tick += (_, _) => Breathe();
        _breath.Start();
    }

    public static void Dismiss()
    {
        _breath?.Stop();
        _breath = null;
        foreach (var hwnd in Strips)
        {
            DestroyWindow(hwnd);
        }

        Strips.Clear();
    }

    private enum Edge
    {
        Top,
        Bottom,
        Left,
        Right,
    }

    /// <summary>每拍：按出现了多久算整体透明度；减弱动态效果时淡入完就停表。</summary>
    private static void Breathe()
    {
        var seconds = (Environment.TickCount64 - _shownAt) / 1000.0;
        var reduced = Motion.Reduced;
        var alpha = (byte)Math.Round(255 * ReminderGlowCurve.Opacity(seconds, reduced));
        if (alpha != _lastAlpha)
        {
            SetAlpha(alpha);
        }

        if (reduced && seconds >= MotionCurves.FadeInSeconds)
        {
            _breath?.Stop();
        }
    }

    private static void SetAlpha(byte alpha)
    {
        _lastAlpha = alpha;
        var blend = new BlendFunction { SourceConstantAlpha = alpha, AlphaFormat = 1 /* AC_SRC_ALPHA */ };
        foreach (var hwnd in Strips)
        {
            UpdateLayeredWindow(hwnd, IntPtr.Zero, null, null, IntPtr.Zero, null, 0, &blend, UlwAlpha);
        }
    }

    /// <summary>画一条：贴着屏幕边那头最亮（ReminderGlowCurve.Alpha），预乘 alpha；交给系统后位图当场放掉。一开始整体透明度是 0（淡入）。</summary>
    private static bool Paint(IntPtr hwnd, int x, int y, int width, int height, int depth, Edge edge, Windows.UI.Color color)
    {
        var screenDc = GetDC(IntPtr.Zero);
        var memoryDc = CreateCompatibleDC(screenDc);
        var bitmap = IntPtr.Zero;
        var previous = IntPtr.Zero;
        try
        {
            var info = new BitmapInfo
            {
                Size = 40, // sizeof(BITMAPINFOHEADER)：这个结构体后面多带了一个颜色表的位置
                Width = width,
                Height = -height,
                Planes = 1,
                BitCount = 32,
            };
            bitmap = CreateDIBSection(screenDc, &info, 0, out var bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
            {
                return false;
            }

            // 先按「离屏幕边几个像素」算好一行一列的颜色，再铺满（横条每行一样、竖条每列一样）。
            var ramp = new uint[depth];
            for (var distance = 0; distance < depth; distance++)
            {
                var alpha = ReminderGlowCurve.Alpha(distance, depth);
                var a = (uint)Math.Round(255 * alpha);
                var r = (uint)Math.Round(color.R * alpha);
                var g = (uint)Math.Round(color.G * alpha);
                var b = (uint)Math.Round(color.B * alpha);
                ramp[distance] = a << 24 | r << 16 | g << 8 | b;
            }

            var pixels = new Span<uint>((void*)bits, width * height);
            for (var row = 0; row < height; row++)
            {
                for (var column = 0; column < width; column++)
                {
                    var distance = edge switch
                    {
                        Edge.Top => row,
                        Edge.Bottom => height - 1 - row,
                        Edge.Left => column,
                        _ => width - 1 - column,
                    };
                    pixels[row * width + column] = distance < depth ? ramp[distance] : 0;
                }
            }

            previous = SelectObject(memoryDc, bitmap);
            var position = new Point32 { X = x, Y = y };
            var size = new Size32 { Width = width, Height = height };
            var source = new Point32();
            var blend = new BlendFunction { SourceConstantAlpha = 0, AlphaFormat = 1 /* AC_SRC_ALPHA */ };
            if (!UpdateLayeredWindow(hwnd, screenDc, &position, &size, memoryDc, &source, 0, &blend, UlwAlpha))
            {
                Log.Warn($"reminder.glow-update-failed {Marshal.GetLastWin32Error()}");
                return false;
            }

            return true;
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                SelectObject(memoryDc, previous);
            }

            if (bitmap != IntPtr.Zero)
            {
                DeleteObject(bitmap);
            }

            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private static bool EnsureClass()
    {
        if (_registered)
        {
            return true;
        }

        var module = PInvoke.GetModuleHandle(default(PCWSTR));
        var windowClass = new WNDCLASSEXW
        {
            cbSize = (uint)sizeof(WNDCLASSEXW),
            lpfnWndProc = ProcPtr,
            hInstance = new HINSTANCE(module.Value),
        };
        fixed (char* className = ClassName)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Warn($"reminder.glow-class-failed {Marshal.GetLastWin32Error()}");
                return false;
            }
        }

        _registered = true;
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT Proc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
        => PInvoke.DefWindowProc(hwnd, msg, wParam, lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfo
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
        public uint Colors;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point32
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Size32
    {
        public int Width;
        public int Height;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UpdateLayeredWindow(
        IntPtr hwnd, IntPtr destinationDc, Point32* position, Size32* size, IntPtr sourceDc, Point32* source,
        uint key, BlendFunction* blend, uint flags);

    [LibraryImport("user32.dll")]
    private static partial IntPtr GetDC(IntPtr window);

    [LibraryImport("user32.dll")]
    private static partial int ReleaseDC(IntPtr window, IntPtr dc);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateCompatibleDC(IntPtr dc);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr CreateDIBSection(IntPtr dc, BitmapInfo* info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [LibraryImport("gdi32.dll")]
    private static partial IntPtr SelectObject(IntPtr dc, IntPtr obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteObject(IntPtr obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DeleteDC(IntPtr dc);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hwnd, int command);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);
}
