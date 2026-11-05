// 选状态的面板（PLAN-v12 N5，照 mac StatusScreen/StatusPicker.swift）：按状态屏的全局快捷键先出它（这时键盘鼠标还没被拦）。
// 外壳同主界面 / 剪贴板面板：亚克力、DWM 圆角阴影、置顶、不进 Alt+Tab，鼠标所在屏中央，失去激活就收起。
// 一行最多 4 张卡片、多了折行；卡片 = 缩小的真画面（StatusScreenView.Preview，200 × 125）+ 下面一行数字键帽（前 9 张）和标题。
// 选中 = 卡片外一圈强调色（2）；悬停铺一层淡底、不改选中。默认选中上次进入的那个。
// 键盘：←→↑↓ 换选中、1–9 直接进入那一张、Enter 进入、Esc / Ctrl+W 收起；开着时再按一次快捷键 = 选中下一张。点卡片直接进入。
// 底栏照启动器：左边只提示键位的「选择 ←→ · 直接进入 1–9 · 取消 Esc」，右边能点的「进入 ↩」。
// 设置里开了「按快捷键直接进入排在最前面的状态」时不出面板（ToggleOrEnterFirst）。
// 和剪贴板面板、启动器、主界面互斥：打开它收起那几块。
// ponytail: mac 选中的卡片长成整屏、选中时放大到 1.04 没做（Windows 版全 App 不做「从小放到大」，0.1.0 用户定）；进入就是整屏直接出来。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed class StatusPicker : Window
{
    private const double CardWidth = 200;
    private const double CardHeight = 125;
    private const double Gap = 12;
    private const int PerRow = 4;

    private static StatusPicker? _instance;

    private readonly UserControl _keys;
    private readonly Grid _grid;
    private readonly ScrollViewer _scroll;
    private readonly HWND _hwnd;
    private readonly List<Border> _cards = new();
    private List<StatusPreset> _presets = new();
    private int _selection;
    private bool _visible;
    private bool _hiding;
    private HWND _previous;

    private StatusPicker()
    {
        Title = Paths.ProductName + " 状态屏";
        _grid = new Grid { ColumnSpacing = Gap, RowSpacing = Gap, Margin = new Thickness(16, 16, 16, 12) };
        _scroll = new ScrollViewer { Content = _grid, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var footer = new PanelFooter { Status = "选择 ←→ · 直接进入 1–9 · 取消 Esc" };
        footer.AddVerb("进入", "↩", primary: true, EnterSelected);
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(footer, 1);
        layout.Children.Add(_scroll);
        layout.Children.Add(footer);
        _keys = new UserControl
        {
            Content = layout,
            IsTabStop = true,
            UseSystemFocusVisuals = false,
            RequestedTheme = Theme.ElementTheme,
        };
        _keys.KeyDown += OnKeyDown;
        AutomationProperties.SetName(_keys, "选一个状态进入");
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
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            HideSelf(restoreForeground: true);
        };
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding)
            {
                HideSelf(restoreForeground: false);
            }
        };
    }

    public static bool IsVisible => _instance?._visible == true;

    /// <summary>
    /// 全局快捷键：设置里开了「直接进入」就进排在最前面的状态；否则开着时选中下一张、没开就打开（默认选中上次进入的）。
    /// </summary>
    public static void ToggleOrEnterFirst()
    {
        if (SettingsService.Current.StatusScreenHotKeyEntersFirst)
        {
            Hide();
            StatusScreenHost.Enter(StatusScreenHost.Presets[0]);
            return;
        }

        if (_instance is { _visible: true } open)
        {
            open.Select(StatusScreenRules.NextIndex(open._selection, open._presets.Count));
            return;
        }

        try
        {
            _instance ??= new StatusPicker();
            _instance.ShowSelf();
        }
        catch (Exception ex)
        {
            Log.Error("status.picker-failed", ex);
        }
    }

    public static void Hide() => _instance?.HideSelf(restoreForeground: false);

    private void ShowSelf()
    {
        OverlayHost.Hide(restoreForeground: false);
        HomePanel.Hide(restoreForeground: false);
        var before = Foreground.Get();
        _previous = before != default && !Foreground.IsOurs(before) ? before : default;
        _keys.RequestedTheme = Theme.ElementTheme;
        _presets = StatusScreenHost.Presets;
        Build();

        // 鼠标所在屏中央；高超过可见区九成时里面滚。
        var display = Displays.AtCursor();
        var scale = display.Scale <= 0 ? 1 : display.Scale;
        var columns = Math.Min(PerRow, _presets.Count);
        var rows = (_presets.Count + PerRow - 1) / PerRow;
        var widthDip = 32 + columns * CardWidth + (columns - 1) * Gap;
        var heightDip = Math.Min(
            16 + 12 + rows * (CardHeight + 30) + (rows - 1) * Gap + 36,
            display.Work.Height / scale * 0.9);
        var width = MonitorLayout.Pixels(widthDip, scale);
        var height = MonitorLayout.Pixels(heightDip, scale);
        AppWindow.MoveAndResize(new RectInt32(
            display.Work.Left + (display.Work.Width - width) / 2, display.Work.Top + (display.Work.Height - height) / 2, width, height));
        _visible = true;
        Activate();
        Foreground.Restore(_hwnd);
        Select(StatusScreenRules.DefaultIndex(_presets, SettingsService.Current.StatusScreenLastPreset));
        DispatcherQueue.TryEnqueue(() => _keys.Focus(FocusState.Programmatic));
        Motion.Entrance(_scroll);
        Log.Info($"status.picker-show count={_presets.Count}");
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
            AppWindow.Hide();
            // 卡片里的预览放掉（下次打开按那时的列表重建）。
            _grid.Children.Clear();
            _cards.Clear();
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

    private void Build()
    {
        _grid.Children.Clear();
        _grid.RowDefinitions.Clear();
        _grid.ColumnDefinitions.Clear();
        _cards.Clear();
        var columns = Math.Min(PerRow, _presets.Count);
        for (var column = 0; column < columns; column++)
        {
            _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(CardWidth) });
        }

        for (var index = 0; index < _presets.Count; index++)
        {
            if (index % PerRow == 0)
            {
                _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }

            var card = Card(_presets[index], index);
            Grid.SetRow(card, index / PerRow);
            Grid.SetColumn(card, index % PerRow);
            _grid.Children.Add(card);
            _cards.Add(card);
        }
    }

    /// <summary>一张卡片：缩小的真画面 + 一行（数字键帽 + 标题）；外面一圈选中描边（没选中是透明的）。</summary>
    private Border Card(StatusPreset preset, int index)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(2, 6, 2, 0) };
        if (index < 9)
        {
            line.Children.Add(KeyCap.Create((index + 1).ToString()));
        }

        line.Children.Add(new TextBlock
        {
            Text = preset.Title,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        var stack = new StackPanel();
        stack.Children.Add(StatusScreenView.Preview(preset, CardWidth - 8, CardHeight - 8 * CardHeight / CardWidth));
        stack.Children.Add(line);
        var card = new Border
        {
            Padding = new Thickness(2),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(2),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
            Background = new SolidColorBrush(Colors.Transparent),
            Child = stack,
        };
        AutomationProperties.SetName(card, $"{preset.Title}，{StatusPresets.Summary(preset)}");
        card.PointerEntered += (_, _) => card.Background = Theme.Brush("SubtleFillColorSecondaryBrush", Theme.Argb(20, 128, 128, 128));
        card.PointerExited += (_, _) => card.Background = new SolidColorBrush(Colors.Transparent);
        card.Tapped += (_, _) => EnterAt(index);
        return card;
    }

    private void Select(int index)
    {
        if (_cards.Count == 0)
        {
            return;
        }

        _selection = Math.Clamp(index, 0, _cards.Count - 1);
        for (var i = 0; i < _cards.Count; i++)
        {
            _cards[i].BorderBrush = new SolidColorBrush(i == _selection ? Theme.AccentColor : Colors.Transparent);
        }

        _cards[_selection].StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        AutomationProperties.SetName(_keys, "选一个状态进入：" + _presets[_selection].Title);
    }

    private void EnterSelected() => EnterAt(_selection);

    /// <summary>进入第 index 张：面板先收起（不还前台：状态屏马上盖上来），再进。</summary>
    private void EnterAt(int index)
    {
        if (index < 0 || index >= _presets.Count)
        {
            return;
        }

        var preset = _presets[index];
        HideSelf(restoreForeground: false);
        StatusScreenHost.Enter(preset);
    }

    private static bool IsDown(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var columns = Math.Max(1, Math.Min(PerRow, _presets.Count));
        e.Handled = true;
        switch (e.Key)
        {
            case VirtualKey.Left:
                Select(_selection - 1);
                break;
            case VirtualKey.Right:
                Select(_selection + 1);
                break;
            case VirtualKey.Up:
                Select(_selection - columns);
                break;
            case VirtualKey.Down:
                Select(_selection + columns);
                break;
            case VirtualKey.Enter:
                EnterSelected();
                break;
            case VirtualKey.Escape:
                HideSelf(restoreForeground: true);
                break;
            case VirtualKey.W when IsDown(VirtualKey.Control):
                HideSelf(restoreForeground: true);
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9:
                EnterAt(e.Key - VirtualKey.Number1);
                break;
            case >= VirtualKey.NumberPad1 and <= VirtualKey.NumberPad9:
                EnterAt(e.Key - VirtualKey.NumberPad1);
                break;
            default:
                e.Handled = false;
                break;
        }
    }
}
