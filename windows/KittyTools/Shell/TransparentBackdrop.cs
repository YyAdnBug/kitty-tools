// 全透明的 SystemBackdrop（REVIEW R5）：轻提示和托盘菜单的宿主窗口用它，
// 客户区里 XAML 没画东西的地方就是真正的透明（露出背后的桌面），不是系统窗口底色。
//
// 只调 DwmExtendFrameIntoClientArea 不够：扩进客户区的边框露出的是窗口底色。
// 做法照 WinUIEx 的 TransparentTintBackdrop（MIT，只看做法，不引包）：在 OnTargetConnected 里
// 给 connectedTarget.SystemBackdrop 设一个全透明的 Composition 颜色画刷。
//
// 那个画刷要系统那一套 Windows.UI.Composition 的 Compositor 建，而它要求当前线程有一个 Windows.System 的
// DispatcherQueue。WinUI 3 的 UI 线程只有 Microsoft.UI 的那个，直接 new Compositor() 抛 UnauthorizedAccessException，
// 画刷没设上，整扇窗口露出白底（0.1.0 用户反馈：提示外面一圈白色容器）。先 CreateDispatcherQueueController 补一个，
// Compositor 建一次留着用（WinUIEx 的 WindowsCompositionHelper 也是这么做的）。
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class TransparentBackdrop : SystemBackdrop
{
    private static Windows.UI.Composition.Compositor? _compositor;

    // 线程活多久它就得活多久：留着指针不放（只建一次）。
    private static IntPtr _queueController;

    protected override void OnTargetConnected(
        ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);
        try
        {
            // 接口要的是系统那一套 Windows.UI.Composition 的画刷（不是 Microsoft.UI.Composition）。
            // 这里在 UI 线程上（系统在连 backdrop 时回调）。
            connectedTarget.SystemBackdrop = SystemCompositor().CreateColorBrush(Colors.Transparent);
        }
        catch (Exception ex)
        {
            Infrastructure.Log.Warn($"backdrop.transparent-failed {ex.GetType().Name}");
        }
    }

    private static Windows.UI.Composition.Compositor SystemCompositor()
    {
        if (_compositor is not null)
        {
            return _compositor;
        }

        if (Windows.System.DispatcherQueue.GetForCurrentThread() is null)
        {
            var options = new DispatcherQueueOptions
            {
                Size = Marshal.SizeOf<DispatcherQueueOptions>(),
                ThreadType = 2, // DQTYPE_THREAD_CURRENT
                ApartmentType = 0, // DQTAT_COM_NONE
            };
            Marshal.ThrowExceptionForHR(CreateDispatcherQueueController(options, out _queueController));
        }

        _compositor = new Windows.UI.Composition.Compositor();
        return _compositor;
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

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop connectedTarget)
    {
        try
        {
            connectedTarget.SystemBackdrop = null;
        }
        catch
        {
            // 断开时设不上就算了。
        }

        base.OnTargetDisconnected(connectedTarget);
    }
}
