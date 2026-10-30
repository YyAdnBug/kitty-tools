// 主界面（托盘左键，PLAN-v10 §5，照 mac Shell/HomePanel.swift）：一眼看到全部功能、点一下就用的那块面板。
// 内容和托盘菜单 / mac 菜单栏同一份、同名同序：剪贴板与启动器｜翻译｜截图与录制，关着的功能不出现，每节末尾接那一节的开关和钉图项；
// 两个功能合一节的只剩一个时节名换成它的名字；只有一格的节不画标题、连着的并成一行（分节、排版、选中怎么移动在 Core 的 HomeLayout）。
// 一格 = 30 的家族色块 + 名字 + 快捷键，一行 5 格；开关是圆的，关着中性底、开着填强调色，名字下面写「已暂停」「已开启」。
// 有关着的功能时最下面一行「N 个功能关着 · 管理…」；底栏左边有新版本时「更新到 x」，右边「设置」「退出」。
// 点功能：先收起、把前台还给打开之前的那扇窗口（划词翻译要从它取字；从托盘打开时前台是任务栏，就用 z 序最上面那扇应用窗口），
// 截图 / 识字 / 截图翻译 / 录屏再等 300 ms（同托盘菜单）；点开关原地切、不收、不弹轻提示。
// 外壳同剪贴板面板：亚克力、DWM 圆角阴影、置顶、不进任务栏和 Alt+Tab，失去激活就收起，退场不淡出。
// 入口：托盘左键 / 在图标上按 Enter、空格（贴着任务栏、靠通知区那一侧，离任务栏 12，从任务栏那边滑进来）；全局动作「打开主界面」和
// 第二次启动（鼠标所在屏的上方正中，同剪贴板面板），开着时再按 = 收起。开着时再点托盘 = 收起：点托盘时面板先失去激活收起，紧接着来的
// NIN_SELECT 不能再把它打开，收起后 300 ms 内的不开（mac 同一个坑：StatusItem.ownsClick）。
// 键盘：打开时没有选中，方向键 / Tab 才出一块中性高亮（焦点真的落在那一格上，读屏跟着念）；Enter / 空格执行，Esc 收起，Ctrl+, 设置。
// 从托盘用键盘打开时停在第一格。
// ponytail: 选中高亮是直接换格子的底色，没有 mac 那样滑过去；开着的时候格子不跟着录屏 / 钉图状态实时变，下次打开才换。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed class HomePanel : Window
{
    // 托盘菜单里那几项（不是全局动作）的 id。
    private const string PauseClipboard = "extra:pause-clipboard";
    private const string CopyTranslate = "extra:copy-translate";
    private const string PinsToggle = "extra:pins-toggle";
    private const string PinsClose = "extra:pins-close";

    /// <summary>点托盘时面板先失去激活收起；这之后多久内来的 NIN_SELECT 不再打开（ms）。</summary>
    private const long ReopenGuardMs = 300;

    private static HomePanel? _instance;
    private static long _hiddenAt;

    /// <summary>收按键的那一层（没选中格子时焦点在它上面）。</summary>
    private readonly UserControl _keys;
    private readonly StackPanel _content;
    private readonly List<ButtonBase> _tileViews = new();
    private readonly HWND _hwnd;
    private List<HomeSection> _sections = new();
    private List<HomeTile> _tiles = new();
    private int _offCount;
    private int? _selection;
    private bool _visible;
    private bool _hiding;
    private HWND _previous;
    private double _scale = 1;

    private HomePanel()
    {
        Title = Paths.ProductName + " 主界面";
        _content = new StackPanel();
        _keys = new UserControl
        {
            Content = _content,
            IsTabStop = true,
            UseSystemFocusVisuals = false,
            RequestedTheme = Theme.ElementTheme,
        };
        _keys.KeyDown += OnKeyDown;
        AutomationProperties.SetName(_keys, "主界面");
        Content = _keys;
        SystemBackdrop = new AcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        // Alt+F4 不真关（同剪贴板面板 R64 A）：当成 Esc 收起。
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            HideSelf(restoreForeground: true);
        };
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += OnActivated;
    }

    public static bool IsVisible => _instance?._visible == true;

    /// <summary>截图自检（WindowShot）用：这扇窗口的 HWND，没建过是 0。</summary>
    internal static IntPtr HandleForProbe => _instance is null ? IntPtr.Zero : Pointer(_instance._hwnd);

    // HWND.Value 是 void*：只在这里进 unsafe（整个类标 unsafe 的话里面的 async 方法不能 await，CS4004）。
    private static unsafe IntPtr Pointer(HWND hwnd) => (IntPtr)hwnd.Value;

    /// <summary>托盘左键 / 键盘选中：(x, y) 是托盘回调给的位置（拿不到图标矩形时用它）。</summary>
    public static void ShowFromTray(int x, int y, bool keyboard)
    {
        // 开着时点托盘：面板已经因为失去激活收起了，这一下不再打开（= 收起）。
        if (!keyboard && Environment.TickCount64 - _hiddenAt < ReopenGuardMs)
        {
            return;
        }

        if (IsVisible)
        {
            Hide(restoreForeground: false);
            return;
        }

        Show((x, y), keyboard);
    }

    /// <summary>全局动作「打开主界面」：开着就收起，没开就在鼠标所在屏的上方正中打开。</summary>
    public static void Toggle()
    {
        if (IsVisible)
        {
            Hide(restoreForeground: true);
        }
        else
        {
            ShowAtCursor();
        }
    }

    /// <summary>鼠标所在屏的上方正中打开（全局动作、第二次启动）。</summary>
    public static void ShowAtCursor() => Show(null, keyboard: false);

    public static void Hide(bool restoreForeground) => _instance?.HideSelf(restoreForeground);

    private static void Show((int X, int Y)? tray, bool keyboard)
    {
        try
        {
            _instance ??= new HomePanel();
            _instance.ShowSelf(tray, keyboard);
        }
        catch (Exception ex)
        {
            Log.Error("home.show-failed", ex);
        }
    }

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void ShowSelf((int X, int Y)? tray, bool keyboard)
    {
        // 和剪贴板面板、启动器只开一个。
        OverlayHost.Hide(restoreForeground: false);
        var before = Foreground.Get();
        _previous = before != default && !Foreground.IsOurs(before) && !RunningProcesses.IsShellWindow(Pointer(before))
            ? before
            : (HWND)RunningProcesses.TopAppWindow();
        _keys.RequestedTheme = Theme.ElementTheme;
        Rebuild(appearing: true);
        var edge = Place(tray, HomeLayout.Height(_sections, _offCount));
        _visible = true;
        Activate();
        Foreground.Restore(_hwnd);
        DispatcherQueue.TryEnqueue(() =>
        {
            if (keyboard && _tileViews.Count > 0)
            {
                Select(0);
            }
            else
            {
                _keys.Focus(FocusState.Programmatic);
            }
        });

        PInvoke.DwmFlush();
        // 从托盘打开：从任务栏那边滑进来；快捷键打开同剪贴板面板（往下落，开了「挤压弹开」就挤压弹开）。
        switch (edge)
        {
            case TaskbarEdge.Bottom:
                Motion.Entrance(_content, rise: 16);
                break;
            case TaskbarEdge.Top:
                Motion.Entrance(_content, rise: -16);
                break;
            case TaskbarEdge.Left:
                Motion.Entrance(_content, rise: 0, slide: -16);
                break;
            case TaskbarEdge.Right:
                Motion.Entrance(_content, rise: 0, slide: 16);
                break;
            default:
                if (SettingsService.Current.PanelSqueezeEntrance)
                {
                    Motion.SqueezeIn(_content);
                }
                else
                {
                    Motion.Entrance(_content);
                }

                break;
        }

        Log.Info($"home.show tray={tray is not null} keyboard={keyboard} tiles={_tiles.Count} off={_offCount}");
    }

    /// <summary>摆窗口：从托盘打开贴着任务栏、对着图标；别的入口在鼠标所在屏的上方正中。返回从托盘打开时任务栏在哪条边。</summary>
    private TaskbarEdge? Place((int X, int Y)? tray, double heightDip)
    {
        if (tray is { } point)
        {
            if (!Tray.TryGetIconRect(out var left, out var top, out var right, out var bottom))
            {
                (left, top, right, bottom) = (point.X, point.Y, point.X, point.Y);
            }

            var x = (left + right) / 2;
            var y = (top + bottom) / 2;
            var display = Displays.AtPoint(x, y);
            _scale = display.Scale <= 0 ? 1 : display.Scale;
            var edge = HomeLayout.Edge(Displays.MonitorBoundsAt(x, y), display.Work, x, y);
            var width = MonitorLayout.Pixels(HomeLayout.Width, _scale);
            var height = MonitorLayout.Pixels(heightDip, _scale);
            var (originX, originY) = HomeLayout.NearTray(
                display.Work, edge, left, top, right, bottom, width, height,
                MonitorLayout.Pixels(HomeLayout.TaskbarGap, _scale));
            AppWindow.MoveAndResize(HudFrame.WithFrame(this, new RectInt32(originX, originY, width, height)));
            return edge;
        }

        var at = Displays.AtCursor();
        _scale = at.Scale <= 0 ? 1 : at.Scale;
        var rect = MonitorLayout.Overlay(at.Work, _scale, HomeLayout.Width, heightDip, MonitorLayout.ClipboardTopFraction);
        AppWindow.MoveAndResize(HudFrame.WithFrame(this, new RectInt32(rect.X, rect.Y, rect.Width, rect.Height)));
        return null;
    }

    private void HideSelf(bool restoreForeground)
    {
        if (!_visible)
        {
            return;
        }

        _hiding = true;
        try
        {
            _visible = false;
            _hiddenAt = Environment.TickCount64;
            AppWindow.Hide();
            Log.Info($"home.hide restore={restoreForeground}");
            if (restoreForeground && _previous != default)
            {
                Foreground.Restore(_previous);
            }
        }
        finally
        {
            _hiding = false;
        }
    }

    private void OnActivated(object sender, Microsoft.UI.Xaml.WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding)
        {
            HideSelf(restoreForeground: false);
        }
    }

    // ---- 内容

    /// <summary>按此刻的状态重排。appearing：新打开（选中清掉）；开关切完原地刷新时选中留着。</summary>
    private void Rebuild(bool appearing)
    {
        _sections = HomeLayout.Sections(BuildSections());
        _tiles = _sections.SelectMany(section => section.Tiles).ToList();
        _offCount = Enum.GetValues<Feature>().Count(feature => !Features.IsOn(feature));
        if (appearing)
        {
            _selection = null;
        }
        else if (_selection >= _tiles.Count)
        {
            _selection = _tiles.Count == 0 ? null : _tiles.Count - 1;
        }

        Render();
    }

    /// <summary>三节，同托盘菜单（关着的功能不出现，开关和钉图项接在那一节末尾）；两个功能合一节的只剩一个时节名换成它的名字。</summary>
    private static IEnumerable<HomeSection> BuildSections()
    {
        var runtime = ShellRuntime.Instance;
        var clipboard = Features.IsOn(Feature.Clipboard);
        var launcher = Features.IsOn(Feature.Launcher);
        var translate = Features.IsOn(Feature.Translate);
        var screenshot = Features.IsOn(Feature.Screenshot);
        var recording = Features.IsOn(Feature.Recording);

        HomeTile Global(string action, string title)
            => new(action, title, SettingsWindow.HotKeyGlyph(action), SettingsWindow.HotKeyFamily(action),
                runtime?.HotKeys.ShortcutFor(action) is { Length: > 0 } key ? key : null);

        var first = new List<HomeTile>();
        if (clipboard)
        {
            first.Add(Global(HotKeyActions.Clipboard, "剪贴板历史"));
        }

        if (launcher)
        {
            first.Add(Global(HotKeyActions.Launcher, "启动器"));
        }

        if (clipboard)
        {
            first.Add(new HomeTile(PauseClipboard, "暂停记录剪贴板", Glyphs.Pause, "clipboard", IsOn: runtime?.Clipboard?.Paused == true));
        }

        yield return new HomeSection(clipboard && launcher ? "剪贴板与启动器" : clipboard ? "剪贴板" : "启动器", first);

        var second = new List<HomeTile>();
        if (translate)
        {
            second.Add(Global(HotKeyActions.SelectionTranslate, "划词翻译"));
            second.Add(Global(HotKeyActions.InputTranslate, "输入翻译"));
            second.Add(Global(HotKeyActions.TranslateReplace, "划词翻译并替换"));
            if (screenshot)
            {
                second.Add(Global(HotKeyActions.ScreenshotTranslate, "截图翻译"));
            }

            second.Add(new HomeTile(CopyTranslate, "复制即译", Glyphs.Copy, "translate", IsOn: SettingsService.Current.CopyTranslate));
        }

        yield return new HomeSection("翻译", second);

        var third = new List<HomeTile>();
        if (screenshot)
        {
            third.Add(Global(HotKeyActions.Screenshot, "截图"));
            third.Add(Global(HotKeyActions.ScreenshotLast, "截取上次区域"));
            third.Add(Global(HotKeyActions.Ocr, "识字"));
        }

        if (recording)
        {
            third.Add(Global(HotKeyActions.Record, RecordingHost.IsRecording ? "停止录屏" : "录屏"));
            third.Add(Global(HotKeyActions.Audio, AudioHost.IsRecording ? "停止录音" : "录音"));
        }

        if (screenshot)
        {
            third.Add(Global(HotKeyActions.PinClipboard, "钉住剪贴板里的图"));
            third.Add(Global(HotKeyActions.ShotHistory, "截图历史"));
            if (PinHost.Count > 0)
            {
                third.Add(new HomeTile(PinsToggle, PinHost.AllHidden ? "显示全部钉图" : "隐藏全部钉图", Glyphs.Pin, "capture"));
                third.Add(new HomeTile(PinsClose, "关闭全部钉图", Glyphs.Close, "capture"));
            }
        }

        yield return new HomeSection(screenshot && recording ? "截图与录制" : screenshot ? "截图" : "录屏", third);
    }

    private void Render()
    {
        _content.Children.Clear();
        _tileViews.Clear();
        var grid = new StackPanel
        {
            Padding = new Thickness(HomeLayout.Inset, HomeLayout.Top, HomeLayout.Inset, HomeLayout.Bottom),
        };
        var index = 0;
        for (var sectionIndex = 0; sectionIndex < _sections.Count; sectionIndex++)
        {
            var section = _sections[sectionIndex];
            if (section.Title is { } title)
            {
                var heading = new TextBlock
                {
                    Text = title,
                    FontSize = Theme.FontSize("Kitty.FontSize.GroupHeader"),
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = Theme.TertiaryText(),
                    VerticalAlignment = VerticalAlignment.Bottom,
                    Margin = new Thickness(10, 0, 0, 2),
                };
                AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
                grid.Children.Add(new Border { Height = HomeLayout.TitleHeight, Child = heading });
            }
            else if (sectionIndex > 0)
            {
                grid.Children.Add(new Border { Height = HomeLayout.UntitledGap });
            }

            var rows = new StackPanel { Spacing = HomeLayout.Gap };
            for (var start = 0; start < section.Tiles.Count; start += HomeLayout.Columns)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = HomeLayout.Gap };
                for (var offset = start; offset < Math.Min(start + HomeLayout.Columns, section.Tiles.Count); offset++)
                {
                    row.Children.Add(TileView(section.Tiles[offset], index + offset));
                }

                rows.Children.Add(row);
            }

            grid.Children.Add(rows);
            index += section.Tiles.Count;
        }

        _content.Children.Add(grid);
        if (_offCount > 0)
        {
            _content.Children.Add(OffNote());
        }

        _content.Children.Add(Bar());
        ShowSelection();
    }

    /// <summary>一格：色块（开关是圆）+ 名字 + 快捷键（开关这一行写「已暂停」「已开启」）。开关是 ToggleButton（读屏念开 / 关）。</summary>
    private ButtonBase TileView(HomeTile tile, int index)
    {
        var detail = tile.Id switch
        {
            PauseClipboard => tile.IsOn == true ? "已暂停" : string.Empty,
            CopyTranslate => tile.IsOn == true ? "已开启" : string.Empty,
            _ => tile.Key ?? string.Empty,
        };
        var icon = Icon(tile);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.Margin = new Thickness(0, 9, 0, 0);
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(icon);
        stack.Children.Add(new TextBlock
        {
            Text = tile.Title,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = HomeLayout.TileWidth - 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(3, 6, 3, 0),
        });
        stack.Children.Add(new TextBlock
        {
            Text = detail,
            FontSize = Theme.FontSize("Kitty.FontSize.KeyCap"),
            Foreground = tile.IsOn == true ? new SolidColorBrush(Theme.AccentTextColor) : Theme.TertiaryText(),
            Height = 15,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 1, 0, 0),
        });

        ButtonBase button = tile.IsOn is { } on ? new ToggleButton { IsChecked = on } : new Button();
        Flatten(button);
        button.Content = stack;
        button.Width = HomeLayout.TileWidth;
        button.Height = HomeLayout.TileHeight;
        button.Padding = new Thickness(0);
        button.CornerRadius = new CornerRadius(4);
        button.BorderThickness = new Thickness(0);
        button.HorizontalContentAlignment = HorizontalAlignment.Center;
        button.VerticalContentAlignment = VerticalAlignment.Top;
        // 点了不抢焦点（面板随后就收起了）；键盘选中时焦点真的落在格子上，系统焦点框不画，用选中底色。
        button.AllowFocusOnInteraction = false;
        button.UseSystemFocusVisuals = false;
        button.Click += (_, _) => Run(index);
        button.GotFocus += (_, _) =>
        {
            _selection = index;
            ShowSelection();
        };
        ToolTipService.SetToolTip(button, tile.Key is { } key ? $"{tile.Title}  {key}" : tile.Title);
        AutomationProperties.SetName(button, tile.Title);
        if (tile.Key is { } shortcut)
        {
            AutomationProperties.SetHelpText(button, "快捷键 " + shortcut);
        }

        _tileViews.Add(button);
        return button;
    }

    private static FrameworkElement Icon(HomeTile tile)
    {
        if (tile.IsOn is not { } on)
        {
            return KindTile.Create(tile.Family, tile.Glyph, 30);
        }

        // 开关：圆，关着中性底、开着强调色（同 mac）。
        return new Border
        {
            Width = 30,
            Height = 30,
            CornerRadius = new CornerRadius(15),
            Background = on
                ? new SolidColorBrush(Theme.AccentColor)
                : Theme.Brush("Kitty.Fill.Control", Theme.Argb(15, 128, 128, 128)),
            Child = new FontIcon
            {
                Glyph = tile.Glyph,
                FontSize = 14,
                Foreground = on
                    ? new SolidColorBrush(Theme.OnAccentColor)
                    : Theme.Brush("TextFillColorPrimaryBrush", Theme.Argb(255, 32, 32, 32)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    /// <summary>按钮的底、边、字在各状态都换成平的：平时透明、悬停 fill.hover、按下 fill.selected（要在套模板之前放进 Resources）。</summary>
    private static void Flatten(ButtonBase button)
    {
        var clear = new SolidColorBrush(Colors.Transparent);
        var hover = Theme.Brush("Kitty.Fill.Hover", Theme.Argb(10, 128, 128, 128));
        var pressed = Theme.Brush("Kitty.Fill.Selected", Theme.Argb(18, 128, 128, 128));
        var text = Theme.Brush("TextFillColorPrimaryBrush", Theme.Argb(255, 32, 32, 32));
        foreach (var prefix in new[] { "Button", "ToggleButton" })
        {
            foreach (var state in new[] { string.Empty, "Checked" })
            {
                button.Resources[$"{prefix}Background{state}"] = clear;
                button.Resources[$"{prefix}Background{state}PointerOver"] = hover;
                button.Resources[$"{prefix}Background{state}Pressed"] = pressed;
                button.Resources[$"{prefix}BorderBrush{state}"] = clear;
                button.Resources[$"{prefix}BorderBrush{state}PointerOver"] = clear;
                button.Resources[$"{prefix}BorderBrush{state}Pressed"] = clear;
                button.Resources[$"{prefix}Foreground{state}"] = text;
                button.Resources[$"{prefix}Foreground{state}PointerOver"] = text;
                button.Resources[$"{prefix}Foreground{state}Pressed"] = text;
            }
        }

        button.Background = clear;
    }

    /// <summary>「2 个功能关着 · 管理…」：点「管理…」到 设置 › 通用（「功能」那一节在里面）。</summary>
    private StackPanel OffNote()
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            Height = HomeLayout.NoteHeight,
            Padding = new Thickness(HomeLayout.Inset + 10, 0, 0, 0),
        };
        row.Children.Add(new TextBlock
        {
            Text = $"{_offCount} 个功能关着 ·",
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var manage = new HyperlinkButton
        {
            Content = "管理…",
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            IsTabStop = false,
        };
        AutomationProperties.SetName(manage, "管理功能");
        AutomationProperties.SetHelpText(manage, "打开 设置 › 通用，打开或关掉功能");
        manage.Click += (_, _) =>
        {
            HideSelf(restoreForeground: false);
            ShellRuntime.Instance?.ShowSettings(welcome: false, "general");
        };
        row.Children.Add(manage);
        return row;
    }

    /// <summary>底栏（同剪贴板面板的底栏：高 36、左右 16、组间距 12）：左边有新版本时「更新到 x」，右边「设置 Ctrl+,」「退出」。</summary>
    private Grid Bar()
    {
        var bar = new Grid
        {
            Height = HomeLayout.BarHeight,
            Padding = new Thickness(16, 0, 16, 0),
            BorderBrush = Theme.Brush("Kitty.Hairline", Theme.Argb(20, 128, 128, 128)),
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (UpdateService.AvailableVersion is { } available && !AutoUpdater.IsBusy)
        {
            var update = new HyperlinkButton
            {
                Content = $"更新到 {available}",
                FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                Padding = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center,
                IsTabStop = false,
            };
            update.Click += (_, _) =>
            {
                HideSelf(restoreForeground: false);
                _ = AutoUpdater.StartAsync();
            };
            bar.Children.Add(update);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(BarButton("设置", "Ctrl+,", "设置", () => ShellRuntime.Instance?.ShowSettings(welcome: false)));
        actions.Children.Add(BarButton("退出", null, "退出 Kitty Tools", () => ShellRuntime.Instance?.Exit()));
        Grid.SetColumn(actions, 1);
        bar.Children.Add(actions);
        return bar;
    }

    private Button BarButton(string title, string? key, string automationName, Action run)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (key is not null)
        {
            var cap = KeyCap.Create(key);
            AutomationProperties.SetAccessibilityView(cap, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            content.Children.Add(cap);
        }

        var button = new Button
        {
            Padding = new Thickness(6, 2, 6, 2),
            MinHeight = 0,
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            AllowFocusOnInteraction = false,
            IsTabStop = false,
        };
        Flatten(button);
        button.Content = content;
        AutomationProperties.SetName(button, automationName);
        button.Click += (_, _) =>
        {
            HideSelf(restoreForeground: false);
            run();
        };
        return button;
    }

    // ---- 选中、按键、执行

    private void Select(int index)
    {
        if (index < 0 || index >= _tileViews.Count)
        {
            return;
        }

        _selection = index;
        ShowSelection();
        _tileViews[index].Focus(FocusState.Keyboard);
    }

    private void ShowSelection()
    {
        var selected = Theme.Brush("Kitty.Fill.Selected", Theme.Argb(18, 128, 128, 128));
        for (var index = 0; index < _tileViews.Count; index++)
        {
            _tileViews[index].Background = index == _selection ? selected : new SolidColorBrush(Colors.Transparent);
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = IsDown(VirtualKey.Control);
        if (control && e.Key == (VirtualKey)188 /* VK_OEM_COMMA */)
        {
            e.Handled = true;
            HideSelf(restoreForeground: false);
            ShellRuntime.Instance?.ShowSettings(welcome: false);
            return;
        }

        if (control || IsDown(VirtualKey.Menu))
        {
            return;
        }

        HomeMove? move = e.Key switch
        {
            VirtualKey.Left => HomeMove.Left,
            VirtualKey.Right => HomeMove.Right,
            VirtualKey.Up => HomeMove.Up,
            VirtualKey.Down => HomeMove.Down,
            VirtualKey.Tab => IsDown(VirtualKey.Shift) ? HomeMove.Left : HomeMove.Right,
            _ => null,
        };
        if (move is { } direction)
        {
            e.Handled = true;
            if (HomeLayout.Moved(_selection, direction, HomeLayout.Rows(_sections)) is { } next)
            {
                Select(next);
            }

            return;
        }

        switch (e.Key)
        {
            // 格子有焦点时 Enter / 空格由按钮自己点（Click → Run）；这里接的是还没选中的时候。
            case VirtualKey.Enter or VirtualKey.Space:
                e.Handled = true;
                if (_selection is { } index)
                {
                    Run(index);
                }

                break;
            case VirtualKey.Escape:
                e.Handled = true;
                HideSelf(restoreForeground: true);
                break;
        }
    }

    /// <summary>点了 / 按了第 index 格：开关原地切（不收、不弹轻提示）；别的先收起、还前台，再做（要拍屏幕的再等 300 ms）。</summary>
    private async void Run(int index)
    {
        if (index < 0 || index >= _tiles.Count)
        {
            return;
        }

        var tile = _tiles[index];
        var runtime = ShellRuntime.Instance;
        switch (tile.Id)
        {
            case PauseClipboard:
                runtime?.TogglePauseClipboard(quiet: true);
                Rebuild(appearing: false);
                RefocusSelection();
                return;
            case CopyTranslate:
                runtime?.ToggleCopyTranslate(quiet: true);
                Rebuild(appearing: false);
                RefocusSelection();
                return;
        }

        HideSelf(restoreForeground: true);
        var capture = tile.Id is HotKeyActions.Screenshot or HotKeyActions.ScreenshotLast or HotKeyActions.Ocr
                          or HotKeyActions.ScreenshotTranslate ||
                      (tile.Id == HotKeyActions.Record && !RecordingHost.IsRecording);
        if (capture)
        {
            await Task.Delay(300);
        }

        Log.Info($"home.run {tile.Id}");
        switch (tile.Id)
        {
            case PinsToggle:
                PinHost.ToggleHidden();
                break;
            case PinsClose:
                PinHost.CloseAll();
                break;
            default:
                runtime?.RunAction(tile.Id);
                break;
        }
    }

    /// <summary>开关切完重排了一遍：键盘选着的那格接着有焦点，不然焦点回到收按键的那层。</summary>
    private void RefocusSelection()
    {
        if (_selection is { } index && index < _tileViews.Count)
        {
            _tileViews[index].Focus(FocusState.Keyboard);
        }
        else
        {
            _keys.Focus(FocusState.Programmatic);
        }
    }
}
