// 屏幕边缘那叠的感应条（PLAN-v16 V1，照 mac NoteDeckPill 的追踪区：只感应贴边那一条，宽 = 设置里的「感应范围」）。
// 药丸本身只有 12 宽（NoteDeckPillWindow），感应范围另算：一扇 Win32 分层小窗（同 RecordingFrame 的做法），整体透明度 1/255——
// 看不见，但鼠标碰得到（不加 WS_EX_TRANSPARENT）。鼠标进来 / 点一下 = 药丸那边的「靠过来」，出去了再进来才算下一次（TrackMouseEvent）。
// 压在药丸下面（SetWindowPos 插在药丸后面），药丸自己的右键菜单、按住 Alt 拖照旧是药丸收。不激活、不进任务栏和 Alt+Tab。
// 没有定时器、不轮询鼠标位置。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Windows.Graphics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.WindowsAndMessaging;

namespace KittyTools;

internal static unsafe partial class NoteDeckSense
{
    private const string ClassName = "KittyTools.NoteDeckSense";
    private const uint WsPopup = 0x80000000;
    private const uint WsExFlags = 0x00000008 /* TOPMOST */ | 0x00000080 /* TOOLWINDOW */ |
                                   0x08000000 /* NOACTIVATE */ | 0x00080000 /* LAYERED */;

    private const uint WmMouseActivate = 0x0021;
    private const uint WmMouseMove = 0x0200;
    private const uint WmLButtonDown = 0x0201;
    private const uint WmMouseLeave = 0x02A3;

    private static readonly delegate* unmanaged[Stdcall]<HWND, uint, WPARAM, LPARAM, LRESULT> WndProcPtr = &WndProc;
    private static readonly Dictionary<IntPtr, Action> Entered = new();
    private static readonly HashSet<IntPtr> Inside = new();
    private static HINSTANCE _instance;
    private static bool _registered;

    /// <summary>建一条（先不显示）；entered：鼠标进来或点了一下。建不出来给 0（那就只剩药丸自己感应）。</summary>
    public static IntPtr Create(Action entered)
    {
        if (!EnsureClass())
        {
            return IntPtr.Zero;
        }

        var hwnd = (IntPtr)Native.CreateWindowEx(
            WsExFlags, ClassName, string.Empty, WsPopup, 0, 0, 0, 0, default, IntPtr.Zero, _instance, (void*)0).Value;
        if (hwnd == IntPtr.Zero)
        {
            Log.Warn($"notes.deck-sense-create-failed {Marshal.GetLastWin32Error()}");
            return IntPtr.Zero;
        }

        SetLayeredWindowAttributes(hwnd, 0, 1, 0x2 /* LWA_ALPHA */);
        Entered[hwnd] = entered;
        return hwnd;
    }

    /// <summary>摆好（物理像素），压在 below 那扇窗口下面；shown：显示 / 收起。</summary>
    public static void Place(IntPtr hwnd, RectInt32 frame, IntPtr below, bool shown)
    {
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        const uint noActivate = 0x0010;
        var flags = noActivate | (shown ? 0x0040u /* SHOWWINDOW */ : 0x0080u /* HIDEWINDOW */);
        // 插在药丸后面：两扇都在置顶那一层，感应条在药丸下面；药丸还没有句柄时放到置顶层最上面
        var after = below != IntPtr.Zero ? below : new IntPtr(-1) /* HWND_TOPMOST */;
        SetWindowPos(hwnd, after, frame.X, frame.Y, Math.Max(frame.Width, 1), Math.Max(frame.Height, 1), flags);
    }

    public static void Destroy(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        Entered.Remove(hwnd);
        Inside.Remove(hwnd);
        DestroyWindow(hwnd);
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
        };
        fixed (char* className = ClassName)
        {
            windowClass.lpszClassName = new PCWSTR(className);
            if (PInvoke.RegisterClassEx(in windowClass) == 0)
            {
                Log.Warn($"notes.deck-sense-class-failed {Marshal.GetLastWin32Error()}");
                return false;
            }
        }

        _registered = true;
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static LRESULT WndProc(HWND hwnd, uint msg, WPARAM wParam, LPARAM lParam)
    {
        var handle = (IntPtr)hwnd.Value;
        switch (msg)
        {
            case WmMouseActivate:
                return new LRESULT(3 /* MA_NOACTIVATE */);
            case WmMouseMove:
                if (Inside.Add(handle))
                {
                    var track = new TrackMouseEventInfo { Size = (uint)sizeof(TrackMouseEventInfo), Flags = 0x2 /* TME_LEAVE */, Window = handle };
                    TrackMouseEvent(ref track);
                    Fire(handle);
                }

                return new LRESULT(0);
            case WmMouseLeave:
                Inside.Remove(handle);
                return new LRESULT(0);
            case WmLButtonDown:
                Fire(handle);
                return new LRESULT(0);
        }

        return PInvoke.DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private static void Fire(IntPtr handle)
    {
        if (Entered.TryGetValue(handle, out var entered))
        {
            try
            {
                entered();
            }
            catch (Exception ex)
            {
                Log.Warn($"notes.deck-sense-failed {ex.GetType().Name}");
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrackMouseEventInfo
    {
        public uint Size;
        public uint Flags;
        public IntPtr Window;
        public uint HoverTime;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TrackMouseEvent(ref TrackMouseEventInfo info);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hwnd);
}
