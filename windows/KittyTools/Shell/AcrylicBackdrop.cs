// 浮层的亚克力材质。不用 XAML 自带的 DesktopAcrylicBackdrop：它跟着窗口激活状态走，
// 窗口不在前台时会变成纯色；这里自己给 SystemBackdropConfiguration，IsInputActive 一直为 true。
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class AcrylicBackdrop : SystemBackdrop
{
    private DesktopAcrylicController? _controller;
    private SystemBackdropConfiguration? _configuration;
    private FrameworkElement? _root;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);

        if (!DesktopAcrylicController.IsSupported())
        {
            ProbeLog.Write("acrylic.unsupported");
            return;
        }

        _configuration = new SystemBackdropConfiguration
        {
            IsInputActive = true,
            Theme = MapTheme((xamlRoot.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default),
        };

        _controller = new DesktopAcrylicController();
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(_configuration);

        if (xamlRoot.Content is FrameworkElement root)
        {
            _root = root;
            _root.ActualThemeChanged += OnActualThemeChanged;
        }

        ProbeLog.Write("acrylic.connected", ("theme", _configuration.Theme.ToString()));
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        if (_root is not null)
        {
            _root.ActualThemeChanged -= OnActualThemeChanged;
            _root = null;
        }

        if (_controller is not null)
        {
            _controller.RemoveSystemBackdropTarget(target);
            _controller.Dispose();
            _controller = null;
        }

        _configuration = null;
        base.OnTargetDisconnected(target);
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        if (_configuration is not null)
        {
            _configuration.Theme = sender.ActualTheme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
            _configuration.IsInputActive = true;
        }
    }

    private static SystemBackdropTheme MapTheme(ElementTheme theme)
        => theme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
}
