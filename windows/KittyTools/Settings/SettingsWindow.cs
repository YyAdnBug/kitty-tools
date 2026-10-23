// 设置窗：左侧 NavigationView，三页（通用 / 快捷键 / 关于），Mica。
// 第 1 批只做 PLAN §5.7 的三页；其它页在各模块那批里补。
using System.Diagnostics;
using System.Text.Json;
using KittyTools.Infrastructure;
using KittyTools.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.Core;
using Windows.Win32;

namespace KittyTools;

internal sealed class SettingsWindow : Window
{
    private readonly Grid _shell;
    private readonly Border _navBorder;
    private readonly StackPanel _navPanel;
    private readonly Dictionary<string, Button> _navButtons = new();
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _content;
    private readonly InfoBar _hotKeyError;
    private readonly Windows.Win32.Foundation.HWND _hwnd;
    private readonly int _width;
    private readonly int _height;

    private bool _firstRun;
    private string _currentPage = "general";
    private string? _recordingAction;
    private TextBlock? _recordHint;

    public SettingsWindow()
    {
        Title = Paths.ProductName + " 设置";
        _content = new StackPanel { Spacing = 18 };
        _scroll = new ScrollViewer
        {
            Content = _content,
            Padding = new Thickness(32, 24, 32, 32),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };

        // 左栏自己搭：Release AOT 下 NavigationView 会在渲染时 0xc000027b 崩掉
        // （Debug 正常），所以用一排 Button 做导航。外观和 NavigationView 的左栏一致。
        _navPanel = new StackPanel { Spacing = 2, Padding = new Thickness(8, 16, 8, 8) };
        _navPanel.Children.Add(new TextBlock
        {
            Text = "Kitty Tools",
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Margin = new Thickness(10, 0, 0, 12),
        });
        _navPanel.Children.Add(CreateNavButton("general", "通用", "\uE713"));
        _navPanel.Children.Add(CreateNavButton("hotkeys", "快捷键", "\uE765"));
        _navPanel.Children.Add(CreateNavButton("about", "关于", "\uE946"));

        _navBorder = new Border
        {
            Background = NavBackground(),
            Child = new ScrollViewer { Content = _navPanel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        Grid.SetColumn(_navBorder, 0);
        Grid.SetColumn(_scroll, 1);

        _shell = new Grid { RequestedTheme = Theme.ElementTheme };
        _shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        _shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _shell.Children.Add(_navBorder);
        _shell.Children.Add(_scroll);

        _hotKeyError = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            IsOpen = false,
            IsClosable = true,
        };
        _shell.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnRecordKeyDown), handledEventsToo: true);

        Content = _shell;
        SystemBackdrop = new MicaThemeBackdrop();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _hwnd = (Windows.Win32.Foundation.HWND)hwnd;
        var scale = PInvoke.GetDpiForWindow(_hwnd) / 96.0;
        _width = (int)Math.Round(980 * scale);
        _height = (int)Math.Round(720 * scale);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(_width, _height));
        AppWindow.SetIcon(Paths.ExecutablePath);

        BuildPage("general");
        Closed += (_, _) =>
        {
            IsClosed = true;
            Log.Info("settings.closed");
        };
    }

    public bool IsClosed { get; private set; }

    public void ShowPage(bool welcome)
    {
        _firstRun = welcome;
        _currentPage = "general";
        BuildPage("general");
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Restore();
        }

        Activate();
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + Math.Max(0, (area.Width - _width) / 2),
            area.Y + Math.Max(0, (area.Height - _height) / 2)));
        Foreground.Restore(_hwnd);
        Log.Info($"settings.show firstRun={welcome}");
    }

    public void RefreshTheme()
    {
        _shell.RequestedTheme = Theme.ElementTheme;
        _navBorder.Background = NavBackground();
        if (_recordingAction is null)
        {
            BuildPage(_currentPage);
        }
    }

    private void BuildPage(string page)
    {
        _currentPage = page;
        _content.Children.Clear();
        switch (page)
        {
            case "hotkeys":
                BuildHotKeys();
                break;
            case "about":
                BuildAbout();
                break;
            default:
                BuildGeneral();
                break;
        }

        UpdateNavSelection();
    }

    private Button CreateNavButton(string tag, string text, string glyph)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16 });
        content.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        var button = new Button
        {
            Tag = tag,
            Content = content,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(4),
        };
        button.Click += (_, _) => BuildPage(tag);
        _navButtons[tag] = button;
        return button;
    }

    private void UpdateNavSelection()
    {
        foreach (var (tag, button) in _navButtons)
        {
            button.Background = tag == _currentPage
                ? new SolidColorBrush(Windows.UI.Color.FromArgb(28, Theme.BrandPink.R, Theme.BrandPink.G, Theme.BrandPink.B))
                : new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
        }
    }

    private static Brush NavBackground()
        => new SolidColorBrush(Theme.ElementTheme == ElementTheme.Dark
            ? Windows.UI.Color.FromArgb(255, 32, 32, 32)
            : Windows.UI.Color.FromArgb(255, 243, 243, 243));

    private void BuildGeneral()
    {
        _content.Children.Add(Header("通用", "启动、外观和更新。"));
        if (_firstRun)
        {
            _content.Children.Add(BuildWelcome());
        }

        AddToggle("登录时自动打开",
            "开机后在托盘里运行，快捷键随时可用。",
            SettingsService.Current.StartWithWindows,
            isOn =>
            {
                if (!Autostart.Set(isOn))
                {
                    NoticeHost.Show("没能写入开机启动", "注册表 Run 项写入失败", NoticeTone.Error);
                    return;
                }

                SettingsService.Current.StartWithWindows = isOn;
                SettingsService.Save();
            });

        AddCombo("外观", "跟随系统 / 浅色 / 深色。",
            new[] { "跟随系统", "浅色", "深色" },
            SettingsService.Current.Theme switch { "light" => 1, "dark" => 2, _ => 0 },
            index =>
            {
                SettingsService.Current.Theme = index switch { 1 => "light", 2 => "dark", _ => "system" };
                SettingsService.Save();
                Theme.ApplyTo(_shell);
                BuildPage(_currentPage);
            });

        AddCombo("强调色", "品牌粉，或者跟随系统的强调色。",
            new[] { "品牌粉", "跟随系统" },
            SettingsService.Current.Accent == "system" ? 1 : 0,
            index =>
            {
                SettingsService.Current.Accent = index == 1 ? "system" : "brand";
                SettingsService.Save();
                Theme.ApplyAccent();
                BuildPage(_currentPage);
            });

        AddToggle("自动检查更新", "每天检查一次；Windows 版的更新不标 latest。",
            SettingsService.Current.AutoCheckUpdates,
            isOn =>
            {
                SettingsService.Current.AutoCheckUpdates = isOn;
                SettingsService.Save();
            });

        var dataButton = new Button { Content = "打开数据目录" };
        dataButton.Click += (_, _) => OpenDataDirectory();
        _content.Children.Add(dataButton);
    }

    private Border BuildWelcome()
    {
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock
        {
            Text = "欢迎使用 Kitty Tools",
            FontSize = 22,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "它会一直在托盘里运行。Windows 11 默认把新图标收进任务栏右下角的「^」溢出区，" +
                   "点开「^」找到 Kitty Tools，可以把它拖到任务栏上。\n\n" +
                   "默认快捷键：剪贴板 Alt+C、启动器 Alt+Space、划词翻译 Alt+E、输入翻译 Alt+T、" +
                   "截图翻译 Alt+S、截图 Alt+X、识字 Alt+O。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });

        var autostart = new CheckBox
        {
            Content = "登录时自动打开",
            IsChecked = SettingsService.Current.StartWithWindows,
        };
        panel.Children.Add(autostart);

        var start = new Button
        {
            Content = "开始使用",
            Background = new SolidColorBrush(Theme.BrandPink),
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 255, 255)),
        };
        start.Click += (_, _) =>
        {
            var enabled = autostart.IsChecked == true;
            SettingsService.Current.StartWithWindows = enabled;
            Autostart.Set(enabled);
            SettingsService.MarkStarted();
            _firstRun = false;
            BuildPage("general");
            NoticeHost.Show("可以开始了", "快捷键随时在托盘菜单里", NoticeTone.Normal);
        };
        panel.Children.Add(start);

        return Card(panel);
    }

    private void BuildHotKeys()
    {
        _content.Children.Add(Header("快捷键", "点「录制」后按新的组合；至少带 Ctrl 或 Alt，或者单独一个 F1–F24。"));

        _hotKeyError.IsOpen = false;
        _content.Children.Add(_hotKeyError);

        _recordHint = new TextBlock
        {
            Text = " ",
            Opacity = 0.7,
            FontSize = 12,
        };
        _content.Children.Add(_recordHint);

        foreach (var definition in SettingsDefaults.DefaultHotKeys)
        {
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var name = new TextBlock
            {
                Text = definition.DisplayName,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var shortcut = new TextBlock
            {
                Text = HotKeyManager.FormatFor(definition.Action),
                FontFamily = new FontFamily("Consolas"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var failure = ShellRuntime.Instance?.HotKeys.FailureFor(definition.Action);
            var status = new TextBlock
            {
                Text = SettingsDefaults.BindingFor(SettingsService.Current, definition.Action).VirtualKey == 0
                    ? "未设置"
                    : failure ?? (ShellRuntime.Instance?.HotKeys.IsRegistered(definition.Action) == true ? "正常" : ""),
                Foreground = failure is null
                    ? new SolidColorBrush(Windows.UI.Color.FromArgb(180, 128, 128, 128))
                    : new SolidColorBrush(Windows.UI.Color.FromArgb(255, 196, 43, 28)),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };

            var record = new Button { Content = "录制", Tag = definition.Action };
            record.Click += (_, _) => BeginRecording(definition.Action);
            var clear = new Button { Content = "清空", Tag = definition.Action };
            clear.Click += (_, _) => ClearHotKey(definition.Action);
            clear.IsEnabled = SettingsDefaults.BindingFor(SettingsService.Current, definition.Action).VirtualKey != 0;

            Grid.SetColumn(name, 0);
            Grid.SetColumn(shortcut, 1);
            Grid.SetColumn(status, 2);
            Grid.SetColumn(record, 3);
            Grid.SetColumn(clear, 4);
            row.Children.Add(name);
            row.Children.Add(shortcut);
            row.Children.Add(status);
            row.Children.Add(record);
            row.Children.Add(clear);
            _content.Children.Add(row);
        }

        var reset = new Button { Content = "全部恢复默认" };
        reset.Click += (_, _) =>
        {
            SettingsService.Current.HotKeys.Clear();
            SettingsDefaults.Apply(SettingsService.Current);
            SettingsService.Save();
            ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
            BuildPage("hotkeys");
        };
        _content.Children.Add(reset);
    }

    private void BeginRecording(string action)
    {
        _recordingAction = action;
        _hotKeyError.IsOpen = false;
        if (_recordHint is not null)
        {
            _recordHint.Text = $"正在录制「{SettingsDefaults.Find(action)?.DisplayName}」：按新的组合，Esc 取消。";
        }
    }

    private void OnRecordKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_recordingAction is null)
        {
            return;
        }

        e.Handled = true;
        if (e.Key == VirtualKey.Escape)
        {
            StopRecording("已取消");
            return;
        }

        var key = (uint)e.Key;
        var modifiers = HotKeyModifiers.None;
        if (IsDown(VirtualKey.Control)) modifiers |= HotKeyModifiers.Control;
        if (IsDown(VirtualKey.Menu)) modifiers |= HotKeyModifiers.Alt;
        if (IsDown(VirtualKey.Shift)) modifiers |= HotKeyModifiers.Shift;
        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows)) modifiers |= HotKeyModifiers.Win;

        if (HotKeyRules.IsModifierKey(key))
        {
            if (_recordHint is not null)
            {
                _recordHint.Text = "再按一个普通键（修饰键本身不算）。Esc 取消。";
            }
            return;
        }

        var validation = HotKeyRules.Validate(key, modifiers);
        if (!validation.Ok)
        {
            _hotKeyError.Message = validation.Reason ?? "这个组合不能用";
            _hotKeyError.IsOpen = true;
            return;
        }

        var action = _recordingAction;
        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(key, modifiers));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        StopRecording("已保存");
        BuildPage("hotkeys");
        var failure = ShellRuntime.Instance?.HotKeys.FailureFor(action);
        if (failure is not null)
        {
            _hotKeyError.Message = $"组合已保存，但注册失败：{failure}";
            _hotKeyError.IsOpen = true;
        }
    }

    private void ClearHotKey(string action)
    {
        SettingsDefaults.SetBinding(SettingsService.Current, action, new HotKeyBinding(0, HotKeyModifiers.None));
        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(SettingsService.Current);
        BuildPage("hotkeys");
    }

    private void StopRecording(string hint)
    {
        _recordingAction = null;
        if (_recordHint is not null)
        {
            _recordHint.Text = hint;
        }
    }

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void BuildAbout()
    {
        _content.Children.Add(Header("关于", ""));
        var version = typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";
        _content.Children.Add(new TextBlock
        {
            Text = $"Kitty Tools {version}（Windows 原生版）",
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        _content.Children.Add(new TextBlock
        {
            Text = "第 1 批：壳。剪贴板、翻译、启动器、截图分别在后面几批接上。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.75,
        });

        _content.Children.Add(ChangelogBlock());

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var update = new Button { Content = "检查更新", IsEnabled = false };
        var data = new Button { Content = "打开数据目录" };
        data.Click += (_, _) => OpenDataDirectory();
        buttons.Children.Add(update);
        buttons.Children.Add(data);
        _content.Children.Add(buttons);
    }

    private UIElement ChangelogBlock()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Resources", "changelog.json");
            if (!File.Exists(path))
            {
                return new TextBlock { Text = "更新日志在第 6 批接上。", Opacity = 0.6 };
            }

            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(new TextBlock { Text = "更新日志", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (root.TryGetProperty("entries", out var entries) && entries.ValueKind == JsonValueKind.Array)
            {
                foreach (var entry in entries.EnumerateArray().Take(5))
                {
                    var version = entry.TryGetProperty("version", out var v) ? v.GetString() : "";
                    var summary = entry.TryGetProperty("summary", out var s) ? s.GetString() : "";
                    panel.Children.Add(new TextBlock
                    {
                        Text = $"{version}  {summary}",
                        TextWrapping = TextWrapping.Wrap,
                        Opacity = 0.8,
                    });
                }
            }

            return panel;
        }
        catch (Exception ex)
        {
            Log.Error("changelog.read-failed", ex);
            return new TextBlock { Text = "更新日志读不出来。", Opacity = 0.6 };
        }
    }

    private void OpenDataDirectory()
    {
        try
        {
            Directory.CreateDirectory(Paths.DataDirectory);
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{Paths.DataDirectory}\"",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Error("settings.open-data-failed", ex);
        }
    }

    private static UIElement Header(string title, string subtitle)
    {
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 28,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            panel.Children.Add(new TextBlock
            {
                Text = subtitle,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        return panel;
    }

    private void AddToggle(string title, string subtitle, bool value, Action<bool> changed)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = subtitle, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        var toggle = new ToggleSwitch { IsOn = value, HorizontalAlignment = HorizontalAlignment.Left };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(panel, 0);
        Grid.SetColumn(toggle, 1);
        row.Children.Add(panel);
        row.Children.Add(toggle);
        _content.Children.Add(row);
    }

    private void AddCombo(string title, string subtitle, string[] items, int selected, Action<int> changed)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = subtitle, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        var combo = new ComboBox { SelectedIndex = selected, MinWidth = 160 };
        foreach (var item in items)
        {
            combo.Items.Add(item);
        }
        combo.SelectionChanged += (_, _) => changed(combo.SelectedIndex);
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(panel, 0);
        Grid.SetColumn(combo, 1);
        row.Children.Add(panel);
        row.Children.Add(combo);
        _content.Children.Add(row);
    }

    private static Border Card(UIElement child) => new()
    {
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(18),
        Background = new SolidColorBrush(Theme.ElementTheme == ElementTheme.Dark
            ? Windows.UI.Color.FromArgb(36, 255, 255, 255)
            : Windows.UI.Color.FromArgb(18, 0, 0, 0)),
        Child = child,
    };
}
