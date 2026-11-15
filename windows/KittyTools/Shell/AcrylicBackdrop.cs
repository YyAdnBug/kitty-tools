// 浮层的亚克力材质。不用 XAML 自带的 DesktopAcrylicBackdrop：它跟着窗口激活状态走，
// 窗口不在前台时会变成纯色；这里自己给 SystemBackdropConfiguration，IsInputActive 一直为 true。
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using KittyTools.Infrastructure;

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
            Log.Info("acrylic.unsupported");
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

        Log.Info("acrylic.connected");
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

    // 配置是自己给的（上面的 _configuration），系统给的默认配置不用。不重写的话默认实现转回基类：窗口关掉、
    // 目标已经断开以后系统还会发一次（失去激活 / 换主题），基类对着断开的目标返回 E_INVALIDARG，在原生回调里
    // 抛 ArgumentException、整个进程闪退（--ui-snapshots 退出时 Debug / Release 每次都崩，crash log stage xaml）。
    protected override void OnDefaultSystemBackdropConfigurationChanged(
        ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        if (_configuration is not null)
        {
            _configuration.Theme = MapTheme(sender.ActualTheme);
            _configuration.IsInputActive = true;
        }
    }

    private static SystemBackdropTheme MapTheme(ElementTheme theme)
        => theme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
}
