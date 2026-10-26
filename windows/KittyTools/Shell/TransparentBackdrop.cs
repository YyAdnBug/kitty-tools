// 全透明的 SystemBackdrop（REVIEW R5）：轻提示和托盘菜单的宿主窗口用它，
// 客户区里 XAML 没画东西的地方就是真正的透明（露出背后的桌面），不是系统窗口底色。
//
// 只调 DwmExtendFrameIntoClientArea 不够：扩进客户区的边框露出的是窗口底色。
// 做法照 WinUIEx 的 TransparentTintBackdrop（MIT，只看做法，不引包）：在 OnTargetConnected 里
// 给 connectedTarget.SystemBackdrop 设一个全透明的 Composition 颜色画刷。
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class TransparentBackdrop : SystemBackdrop
{
    protected override void OnTargetConnected(
        ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);
        try
        {
            // 接口要的是系统那一套 Windows.UI.Composition 的画刷（不是 Microsoft.UI.Composition）。
            // 这里在 UI 线程上（系统在连 backdrop 时回调），可以新建一个 Compositor。
            var compositor = new Windows.UI.Composition.Compositor();
            connectedTarget.SystemBackdrop = compositor.CreateColorBrush(Colors.Transparent);
        }
        catch (Exception ex)
        {
            Infrastructure.Log.Warn($"backdrop.transparent-failed {ex.GetType().Name}");
        }
    }

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
