// 全透明的窗口背景（PLAN-v27 I2，灵动岛样式的轻提示）：窗口里只剩自己画的那颗黑胶囊，外面一圈透出下面的东西。
// WinUI 3 的窗口不设 SystemBackdrop 时，DWM 在内容后面垫一整块实色——0.1.0「透明窗口里画胶囊」外面那圈白就是它，
// 光把 XAML 的 Background 设成透明没用。这里给 ICompositionSupportsSystemBackdrop 一块 alpha 为 0 的画刷，把那块实色换掉。
// 画刷要系统合成器（Windows.UI.Composition，不是 Microsoft.UI.Composition）的；系统合成器要这个线程有 Windows.System 的 DispatcherQueue，
// WinUI 的线程上不一定有，没有就用 CoreMessaging 建一个（只建一次、不放）。
// 窗口不能有 DWM 边框和阴影（presenter 不带边框、圆角设成不圆）：不然透明的胶囊外面还是一圈方形的阴影。
// ponytail: 透明处照样接鼠标（胶囊两头的那几个角），要点穿得改成分层窗口；提示一两秒就收，先不管。
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class TransparentBackdrop : SystemBackdrop
{
    private static Windows.UI.Composition.Compositor? _compositor;
    private static IntPtr _queueController;

    /// <summary>接上过没有（--island-shape-probe 记日志用；false = 退回了实色）。</summary>
    public static bool LastConnected { get; private set; }

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        try
        {
            EnsureSystemQueue();
            _compositor ??= new Windows.UI.Composition.Compositor();
            target.SystemBackdrop = _compositor.CreateColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            LastConnected = true;
            Log.Info("transparent-backdrop.connected");
        }
        catch (Exception ex)
        {
            LastConnected = false;
            Log.Warn($"transparent-backdrop.failed {ex.GetType().Name}");
        }
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        target.SystemBackdrop = null;
        base.OnTargetDisconnected(target);
    }

    private static void EnsureSystemQueue()
    {
        if (Windows.System.DispatcherQueue.GetForCurrentThread() is not null || _queueController != IntPtr.Zero)
        {
            return;
        }

        var options = new DispatcherQueueOptions
        {
            Size = Marshal.SizeOf<DispatcherQueueOptions>(),
            ThreadType = 2, // DQTYPE_THREAD_CURRENT
            ApartmentType = 0, // DQTAT_COM_NONE
        };
        var result = CreateDispatcherQueueController(options, out _queueController);
        if (result < 0)
        {
            throw new COMException("CreateDispatcherQueueController", result);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DispatcherQueueOptions
    {
        public int Size;
        public int ThreadType;
        public int ApartmentType;
    }

    [LibraryImport("CoreMessaging.dll")]
    private static partial int CreateDispatcherQueueController(DispatcherQueueOptions options, out IntPtr controller);
}
