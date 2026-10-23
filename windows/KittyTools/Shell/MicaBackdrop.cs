// 设置窗的 Mica。和 AcrylicBackdrop 同样的理由：自己给配置，跟着元素深浅色走。
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed partial class MicaThemeBackdrop : SystemBackdrop
{
    private MicaController? _controller;
    private SystemBackdropConfiguration? _configuration;
    private FrameworkElement? _root;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);

        if (!MicaController.IsSupported())
        {
            Log.Info("mica.unsupported");
            return;
        }

        _configuration = new SystemBackdropConfiguration
        {
            IsInputActive = true,
            Theme = MapTheme((xamlRoot.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default),
        };

        _controller = new MicaController();
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(_configuration);

        if (xamlRoot.Content is FrameworkElement root)
        {
            _root = root;
            _root.ActualThemeChanged += OnActualThemeChanged;
        }
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
            _configuration.Theme = MapTheme(sender.ActualTheme);
            _configuration.IsInputActive = true;
        }
    }

    private static SystemBackdropTheme MapTheme(ElementTheme theme)
        => theme == ElementTheme.Dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light;
}
