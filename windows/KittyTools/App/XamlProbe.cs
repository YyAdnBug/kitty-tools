// 诊断用（KITTY_XAML_PROBE=1）：Release AOT 下查主题资源和 NavigationView 到底哪一步不行。
// 只在设置了环境变量时运行，结果写进日志；审查完可以把整个文件删掉。
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static class XamlProbe
{
    public static void Run()
    {
        if (Environment.GetEnvironmentVariable("KITTY_XAML_PROBE") != "1")
        {
            return;
        }

        Log.Info("probe.begin");
        Step("app.resources.exists", () => Log.Info($"probe.app.resources count={Application.Current.Resources.Count}"));

        Step("resources.set", () => Application.Current.Resources["ProbeKey"] = "probe-value");
        Step("resources.get", () =>
        {
            var value = Application.Current.Resources.TryGetValue("ProbeKey", out var found);
            Log.Info($"probe.resources.get found={value} value={found}");
        });

        Step("theme.card-brush", () =>
            Log.Info($"probe.theme.card-brush {Describe("CardBackgroundFillColorDefaultBrush")}"));
        Step("theme.text-brush", () =>
            Log.Info($"probe.theme.text-brush {Describe("TextFillColorPrimaryBrush")}"));
        Step("theme.accent", () =>
            Log.Info($"probe.theme.accent {Describe("SystemAccentColor")} light1 {Describe("SystemAccentColorLight1")}"));
        Step("theme.overlay-corner", () =>
            Log.Info($"probe.theme.overlay-corner {Describe("OverlayCornerRadius")}"));

        // x:Bind 用得上的类型信息：造一个面板出来（剪贴板面板在 Release AOT 里已经能用）。
        Step("xaml.panel", () =>
        {
            var panel = new ClipboardPanel();
            Log.Info($"probe.xaml.panel ok type={panel.GetType().Name}");
        });

        // NavigationView：第一版在 AOT 下崩在这里。
        Step("navigationview.create", () =>
        {
            var nav = new NavigationView { PaneDisplayMode = NavigationViewPaneDisplayMode.Left };
            nav.MenuItems.Add(new NavigationViewItem { Content = "通用" });
            nav.FooterMenuItems.Add(new NavigationViewItem { Content = "关于" });
            Log.Info("probe.navigationview.create ok");
        });

        Step("navigationview.window", () =>
        {
            var nav = new NavigationView { IsSettingsVisible = true };
            nav.MenuItems.Add(new NavigationViewItem { Content = "通用", Icon = new SymbolIcon(Symbol.Home) });
            nav.FooterMenuItems.Add(new NavigationViewItem { Content = "关于", Icon = new SymbolIcon(Symbol.Setting) });
            nav.Content = new TextBlock { Text = "NavigationView 在 AOT 里能不能用", Margin = new Thickness(24) };
            var window = new Window { Title = "Kitty Tools probe", Content = nav };
            window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(100, 100, 720, 480));
            window.Activate();
            Log.Info("probe.navigationview.window ok");
        });

        Step("navigationview.content", () =>
        {
            // 设置页那种用法：在 NavigationView 里放一个 x:Bind 的数据模板。
            var nav = new NavigationView();
            var frame = new Frame();
            nav.Content = frame;
            frame.Content = new ClipboardPanel();
            Log.Info("probe.navigationview.content ok");
        });

        Log.Info("probe.end");
    }

    private static void Step(string name, Action action)
    {
        try
        {
            action();
            Log.Info($"probe.ok {name}");
        }
        catch (Exception ex)
        {
            Log.Info($"probe.fail {name} :: {ex}");
        }
    }

    private static string Describe(string key)
    {
        if (!Application.Current.Resources.TryGetValue(key, out var value))
        {
            return "<missing>";
        }

        return value switch
        {
            SolidColorBrush brush => $"{brush.Color}",
            Brush => value.GetType().Name,
            CornerRadius radius => $"{radius.TopLeft}",
            _ => $"{value}",
        };
    }
}

