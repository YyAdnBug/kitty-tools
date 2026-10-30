// 首次打开的欢迎引导（MAC-DIFF「三屏欢迎引导」，照 mac Settings/OnboardingView.swift，N14）：盖在设置窗上的对话框，三屏，
// 只有一个主按钮（继续 / 开始使用），Esc 关。
// 第一屏：App 图标 + 大标题 + 全部功能两列（家族色块 + 名字 + 说明，就是 设置 › 通用 › 功能 那一份，加了功能这里自己跟上）；
// 第二屏：它住在托盘里（mac 这一屏是两项授权；Windows 上截图、粘贴回原程序都不用授权，换成托盘在哪）；
// 第三屏「按一下试试」：主要的全局快捷键一行一个（关着的功能、没设键的不列），真按下的那一行打勾（热键照常执行，面板照样弹出）；
// 底下「登录时自动打开」：首次默认勾，安装程序装的照安装时选的（R37），重看时跟着现在的状态；点「开始使用」时勾着才去开，
// 没勾不去关（用户可能早就在通用页开了，同 mac）。关于页「重看欢迎引导」再打开它。
// 和 mac 不一样（MAC-DIFF.md）：对话框是系统的底色，不是奶油底；换屏不滑动。
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    /// <summary>第三屏列的快捷键（mac：剪贴板、启动器、划词翻译、截图、截图翻译、录屏、快速记一条；Windows 没有便签）。</summary>
    private static readonly string[] OnboardingHotKeys =
    {
        HotKeyActions.Clipboard, HotKeyActions.Launcher, HotKeyActions.SelectionTranslate,
        HotKeyActions.Screenshot, HotKeyActions.ScreenshotTranslate, HotKeyActions.Record,
    };

    private bool _onboardingOpen;

    /// <summary>设置窗排好版（有 XamlRoot）之后再弹：首次安装时 BuildPage 跑在窗口显示出来之前。</summary>
    private void ShowOnboardingWhenReady(bool firstRun)
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (_shell.XamlRoot is not null)
            {
                _ = ShowOnboardingAsync(firstRun);
                return;
            }

            void OnLoaded(object sender, RoutedEventArgs args)
            {
                _shell.Loaded -= OnLoaded;
                _ = ShowOnboardingAsync(firstRun);
            }

            _shell.Loaded += OnLoaded;
        });
    }

    private async Task ShowOnboardingAsync(bool firstRun)
    {
        if (_onboardingOpen || _shell.XamlRoot is null)
        {
            return;
        }

        _onboardingOpen = true;
        // R37：安装程序装的，安装时已经问过开机启动：设置里记的照注册表实际的值（通用页那个开关显示得对）。
        if (SetupRecord.IsInstalled)
        {
            SettingsService.Current.StartWithWindows = Autostart.IsEnabled();
        }

        var autostart = new CheckBox
        {
            Content = "登录时自动打开，开机后快捷键就能用",
            IsChecked = SetupRecord.IsInstalled ? Autostart.IsEnabled() : firstRun || Autostart.IsEnabled(),
        };
        var checks = new Dictionary<string, FontIcon>();
        var screen = 0;
        var body = new Border { Width = 540, MinHeight = 400, Child = OnboardingWelcome() };
        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Content = body,
            PrimaryButtonText = "继续",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = _shell.XamlRoot,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 620.0;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (screen >= 2)
            {
                return;
            }

            // 前两屏的主按钮是翻到下一屏，不关对话框。
            args.Cancel = true;
            screen++;
            body.Child = screen == 1 ? OnboardingTray() : OnboardingTry(checks, autostart);
            dialog.PrimaryButtonText = screen == 2 ? "开始使用" : "继续";
        };

        void OnPressed(string action)
        {
            if (checks.TryGetValue(action, out var check) && check.Visibility != Visibility.Visible)
            {
                check.Visibility = Visibility.Visible;
                Motion.Appear(check);
            }
        }

        var hotKeys = ShellRuntime.Instance?.HotKeys;
        if (hotKeys is not null)
        {
            hotKeys.Pressed += OnPressed;
        }

        var result = ContentDialogResult.None;
        try
        {
            result = await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            // 同一扇窗口同时只能开一个对话框（导入确认之类开着时）：这次不弹。
            Log.Warn($"settings.onboarding-failed {ex.GetType().Name}");
        }
        finally
        {
            if (hotKeys is not null)
            {
                hotKeys.Pressed -= OnPressed;
            }

            _onboardingOpen = false;
        }

        if (result == ContentDialogResult.Primary && autostart.IsChecked == true && !Autostart.IsEnabled())
        {
            if (Autostart.Set(true))
            {
                SettingsService.Current.StartWithWindows = true;
                SettingsService.Save();
            }
            else
            {
                NoticeHost.Show("没能写入开机启动", "注册表 Run 项写入失败", NoticeTone.Warning);
            }
        }

        SettingsService.MarkStarted();
        if (_currentPage == "general")
        {
            BuildPage("general");
        }
    }

    /// <summary>大标题（26）+ 一两句说明，居中（mac Heading）。</summary>
    private static StackPanel OnboardingHeading(string title, string subtitle)
    {
        var heading = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        heading.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 26,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        heading.Children.Add(new TextBlock
        {
            Text = subtitle,
            Foreground = Theme.SecondaryText(),
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        return heading;
    }

    /// <summary>白卡（mac 引导里那张卡：圆角、卡片底）。</summary>
    private static Border OnboardingCard(UIElement child) => new()
    {
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(16, 12, 16, 12),
        Background = Theme.CardBackground(),
        Child = child,
    };

    private static TextBlock OnboardingCaption(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = Theme.SecondaryText(),
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    /// <summary>第一屏：图标、标题、全部功能两列。</summary>
    private UIElement OnboardingWelcome()
    {
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(0, 8, 0, 0) };
        var icon = AppIconImage(64);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        panel.Children.Add(icon);
        panel.Children.Add(OnboardingHeading(
            "欢迎使用 Kitty Tools",
            "这些小工具都住在托盘里，用快捷键随叫随到。\n用不上的可以到 设置 › 通用 › 功能 里关掉。"));

        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var features = Enum.GetValues<Feature>();
        for (var index = 0; index < features.Length; index++)
        {
            if (index % 2 == 0)
            {
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }

            var feature = features[index];
            var item = new Grid { ColumnSpacing = 10 };
            item.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            item.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var tile = FeatureTile(feature);
            tile.VerticalAlignment = VerticalAlignment.Top;
            item.Children.Add(tile);
            var text = new StackPanel { Spacing = 1 };
            text.Children.Add(new TextBlock { Text = Features.Title(feature), FontWeight = Microsoft.UI.Text.FontWeights.Medium });
            text.Children.Add(new TextBlock
            {
                Text = Features.Blurb(feature),
                FontSize = 12,
                Foreground = Theme.SecondaryText(),
                TextWrapping = TextWrapping.Wrap,
            });
            Grid.SetColumn(text, 1);
            item.Children.Add(text);
            Grid.SetRow(item, index / 2);
            Grid.SetColumn(item, index % 2);
            grid.Children.Add(item);
        }

        panel.Children.Add(OnboardingCard(grid));
        return panel;
    }

    /// <summary>第二屏：它住在托盘里（mac 这一屏是授权）。</summary>
    private static UIElement OnboardingTray()
    {
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(0, 40, 0, 0) };
        var tile = KindTile.Create("general", Glyphs.ChevronUp, 48);
        tile.HorizontalAlignment = HorizontalAlignment.Center;
        panel.Children.Add(tile);
        panel.Children.Add(OnboardingHeading(
            "它住在托盘里",
            "Windows 11 默认把新图标收进任务栏右下角的「^」里。\n点开「^」找到 Kitty Tools，可以把它拖到任务栏上；点它看全部功能。"));
        panel.Children.Add(OnboardingCaption("麦克风这类授权等用到时再问；以后都在 设置 › 通用 › 权限 里"));
        return panel;
    }

    /// <summary>第三屏：按一下试试 + 登录时自动打开。</summary>
    private static UIElement OnboardingTry(Dictionary<string, FontIcon> checks, CheckBox autostart)
    {
        var panel = new StackPanel { Spacing = 14, Padding = new Thickness(0, 8, 0, 0) };
        panel.Children.Add(OnboardingHeading(
            "按一下试试", "在任何程序里按下这些键，对应的功能就会出来。\n现在按一下，按过的会打勾。"));

        var rows = new StackPanel { Spacing = 10 };
        checks.Clear();
        foreach (var action in OnboardingHotKeys)
        {
            if (!Features.IsOnFor(action) ||
                SettingsDefaults.BindingFor(SettingsService.Current, action).VirtualKey == 0 ||
                SettingsDefaults.Find(action) is not { } definition)
            {
                continue;
            }

            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
            row.Children.Add(HotKeyTile(action));
            var name = new TextBlock { Text = definition.DisplayName, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            var keys = SettingsUi.KeyCaps(HotKeyManager.FormatFor(action));
            Grid.SetColumn((FrameworkElement)keys, 2);
            row.Children.Add(keys);
            var check = new FontIcon
            {
                Glyph = Glyphs.Check,
                FontSize = 14,
                Foreground = Theme.Success(),
                Visibility = Visibility.Collapsed,
                VerticalAlignment = VerticalAlignment.Center,
            };
            AutomationProperties.SetName(check, $"按过了「{definition.DisplayName}」");
            Grid.SetColumn(check, 3);
            row.Children.Add(check);
            checks[action] = check;
            rows.Children.Add(row);
        }

        panel.Children.Add(OnboardingCard(rows));
        autostart.HorizontalAlignment = HorizontalAlignment.Center;
        panel.Children.Add(autostart);
        panel.Children.Add(OnboardingCaption("提示从屏幕底部正中冒出来（任务栏上方）\n换键、看面板里的按键：设置 › 快捷键"));
        return panel;
    }
}
