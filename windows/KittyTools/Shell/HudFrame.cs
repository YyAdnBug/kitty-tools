// 小浮条（录音控制条、录屏控制条）的窗口外壳（0.1.0）：窗口就是浮条那么大，内容铺满；留着系统的细边框，
// 圆角、阴影、发丝线都由 DWM 画（同轻提示、截图卡片）。以前是「透明窗口里画一块圆角深色条」，
// 透明那层在用户机器上是白的，浮条外面多一圈白色容器（0.1.0 用户反馈）。
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace KittyTools;

internal static partial class HudFrame
{
    /// <summary>置顶、不能改大小、不进 Alt+Tab、不抢焦点，8 圆角。在 Show 之前调。</summary>
    public static void Apply(Window window)
    {
        window.AppWindow.IsShownInSwitchers = false;
        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        window.AppWindow.SetPresenter(presenter);
        window.ExtendsContentIntoTitleBar = true;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        // R22：显示但不抢焦点（用户接着打的字还在原来的程序里）。
        SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x08000000 /* WS_EX_NOACTIVATE */);
        var round = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, ref round, sizeof(int));
    }

    /// <summary>客户区要摆成 <paramref name="client"/>（物理像素）时窗口该多大：把系统边框加回去，客户区位置不动。</summary>
    public static RectInt32 WithFrame(Window window, RectInt32 client)
    {
        var frameX = Math.Max(0, window.AppWindow.Size.Width - window.AppWindow.ClientSize.Width);
        var frameY = Math.Max(0, window.AppWindow.Size.Height - window.AppWindow.ClientSize.Height);
        return new RectInt32(
            client.X - frameX / 2, client.Y - frameY / 2, client.Width + frameX, client.Height + frameY);
    }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static partial int GetWindowLong(IntPtr hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    [LibraryImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static partial int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
