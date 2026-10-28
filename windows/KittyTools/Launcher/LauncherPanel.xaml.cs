// 启动器面板（PLAN-v9-launcher，照 mac LauncherPanelView）：搜索线 + 列表（LauncherListView，分组标题、40 的行、64 的计算卡）+ 底栏。
// 焦点一直在搜索框，方向键、Enter、Ctrl 组合键都在这里分给模型（状态和动作全在 LauncherModel）。高度随内容（Core 的
// LauncherListLayout.PanelHeight），顶边不动。按住 Ctrl 150 ms 后前九行的种类换成「Ctrl+N」键帽；按住 Ctrl / Alt / Shift 时
// 选中行的副标题换成替代动作。Ctrl+K（或光标在末尾时 →）开面板里的操作菜单（剪贴板的 ClipPalette），开着时搜索框用来过滤；
// 右键是同一份动作的系统菜单。底栏左边是种类，右边「主动作 ↩」「操作 Ctrl+K」，有新版本时多一枚「更新到 x」。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.System;

namespace KittyTools;

public sealed partial class LauncherPanel : UserControl
{
    private readonly LauncherListView _list = new();
    private readonly ClipPalette _palette = new();
    private readonly Dictionary<string, BitmapImage> _icons = new();
    private readonly Dictionary<string, byte[]?> _pathIcons = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _pendingHosts = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _pendingPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _keyHintTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _shiftTimer;
    private bool _active;
    private bool _composing;
    private bool _iconLoadQueued;
    private bool _suppressSearch;
    private bool _showKeyHints;
    private int _selected = -1;

    /// <summary>选中的那一项的 id：异步到的新结果按它保持选中（结果换掉之后就对不上 _selected 的位置了）。</summary>
    private string? _selectedId;
    private LauncherAlternate _alternate = LauncherAlternate.None;
    private double _paletteHeight;
    private string? _savedQuery;

    /// <summary>底栏现在摆的是哪一套：没变就不重建（按 ↓ 连发时多半不变）。</summary>
    private string _footerKey = string.Empty;

    public LauncherPanel()
    {
        InitializeComponent();
        SearchLineControl.ExtendHairline();
        SearchBox.PlaceholderText = Placeholder;
        AutomationProperties.SetName(SearchBox, "搜索应用、网址、命令或文件");
        SearchBox.TextChanged += OnSearchTextChanged;
        AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: true);
        AddHandler(UIElement.KeyUpEvent, new KeyEventHandler(OnKeyUp), handledEventsToo: true);
        SearchBox.TextCompositionStarted += (_, _) => _composing = true;
        SearchBox.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            OnSearchTextChanged(SearchBox, null!);
        };
        _keyHintTimer = DispatcherQueue.CreateTimer();
        _keyHintTimer.Interval = TimeSpan.FromMilliseconds(150);
        _keyHintTimer.IsRepeating = false;
        _keyHintTimer.Tick += (_, _) => SetKeyHints(true);
        // Shift 在 Windows 上也用来打大写和符号：按住 300 ms 没打别的键才换副标题，不然打一个大写字母副标题就闪一下。
        _shiftTimer = DispatcherQueue.CreateTimer();
        _shiftTimer.Interval = TimeSpan.FromMilliseconds(300);
        _shiftTimer.IsRepeating = false;
        _shiftTimer.Tick += (_, _) => SetAlternate(LauncherAlternate.Shift);

        ListHost.Children.Insert(0, _list);
        // 菜单下面垫一层：点到菜单外面只关菜单，不落到后面的结果上（剪贴板那边用户报过点击穿透）。
        ListHost.Children.Add(_palette.Scrim);
        ListHost.Children.Add(_palette);
        _palette.Closed += OnPaletteClosed;
        _palette.FilterReset += () => SetSearchQuietly(string.Empty);
        _list.ItemTapped += index =>
        {
            CloseMenu();
            if (Model is { } model)
            {
                model.UserMovedSelection = true;
            }

            Select(index, MotionCurve.Glide);
        };
        _list.ItemDoubleTapped += index =>
        {
            if (Model is { } model && index < model.Results.Count)
            {
                Select(index, MotionCurve.Instant);
                model.KeyRepeat = false;
                model.Execute(model.Results[index]);
                AfterAction();
            }
        };
        _list.ItemRightTapped += OnItemRightTapped;

        // 空闲两分钟后放掉缓存的图标位图，下次打开再按需解码。
        IdleReclaimer.Register(ReleaseCaches);
    }

    public event Action? CloseRequested;

    public event Action? SettingsRequested;

    /// <summary>内容高度变了（DIP，是否带动画）：浮层窗口据此改高度、顶边不动。</summary>
    public event Action<double, bool>? HeightRequested;

    private const string Placeholder = "搜索应用、网址、命令或文件";

    private TextBox SearchBox => SearchLineControl.Box;

    private static LauncherModel? Model => LauncherModel.Instance;

    private LauncherItem? SelectedItem
        => Model is { } model && _selected >= 0 && _selected < model.Results.Count ? model.Results[_selected] : null;

    /// <summary>空闲回收：放掉暂时不用的图标位图。</summary>
    public void ReleaseCaches()
    {
        _icons.Clear();
        _pathIcons.Clear();
        Log.Info("launcher.caches-released");
    }

    /// <summary>按当前结果算出来的面板高度（mac height(for:)）。</summary>
    public double ContentHeightDip
    {
        get
        {
            if (Model is not { } model)
            {
                return LauncherListLayout.SearchHeight + LauncherListLayout.BarHeight;
            }

            var heights = model.Results.Select(item => LauncherListLayout.HeightOf(item.Kind)).ToList();
            return LauncherListLayout.PanelHeight(
                heights, model.Groups.Count, model.ShowsEmptyText, _palette.IsOpen ? _paletteHeight : 0);
        }
    }

    /// <summary>
    /// 模型的回调接到这块面板上：每次呼出都接一次（截图自检会另建几块面板、把回调接走，真正那块再呼出时要接回来）。
    /// </summary>
    private void Wire()
    {
        if (Model is not { } model)
        {
            return;
        }

        model.HidePanel = () => CloseRequested?.Invoke();
        model.ReplaceQuery = text =>
        {
            SearchBox.Text = text;
            SearchBox.SelectionStart = text.Length;
        };
        model.ShowBarNotice = (text, actionText, action, success) => Footer.ShowNotice(text, actionText, action, success);
        model.Announce = Announce;
        model.ResultsChanged = keep =>
        {
            if (_active)
            {
                Render(keep ?? (model.UserMovedSelection ? _selectedId : null), resetScroll: false);
            }
        };
    }

    public void OnShown()
    {
        Wire();
        _active = true;
        _footerKey = string.Empty;
        _alternate = LauncherAlternate.None;
        Footer.HideNotice();
        SetKeyHints(false);
        if (Model is not { } model)
        {
            return;
        }

        model.PrepareForShow();
        ApplyInputScope();
        SetSearchQuietly(model.Query);
        Render(model.KeptSelection, resetScroll: true);
        if (model.ResumesQuery)
        {
            // 接着上次的查询：字全选着，直接打字就替换（mac）。
            SearchBox.SelectAll();
        }

        FocusSearch();
    }

    public void OnHidden()
    {
        _active = false;
        Model?.DidHide(SelectedItem?.Id);
        _palette.Close();
        SetSearchQuietly(string.Empty);
        _selected = -1;
        _selectedId = null;
        _list.SetItems(new LauncherListLayout(Array.Empty<double>(), Array.Empty<int>()), new Dictionary<int, string>(), -1,
            _ => throw new InvalidOperationException());
        _keyHintTimer.Stop();
        _shiftTimer.Stop();
        _showKeyHints = false;
        Footer.HideNotice();
    }

    public void FocusSearch()
    {
        if (!SearchBox.Focus(FocusState.Programmatic))
        {
            _ = FocusManager.TryFocusAsync(SearchBox, FocusState.Programmatic);
        }
    }

    /// <summary>调试 / 从别处带查询打开（截图和手测用）。</summary>
    public void SetQuery(string query)
    {
        if (Model is not { } model)
        {
            return;
        }

        SetSearchQuietly(query);
        model.Search(query);
        Render(null, resetScroll: true);
        FocusSearch();
    }

    /// <summary>截图自检摆状态（UiSnapshotProbe）：launcher-home / -calc / -kill / -empty / -actions / -keys。</summary>
    public void ApplyProbeState(string name)
    {
        switch (name)
        {
            case "launcher-home":
                SetQuery(string.Empty);
                break;
            case "launcher-calc":
                SetQuery("10 km to mi");
                break;
            case "launcher-kill":
                SetQuery("kill ");
                break;
            case "launcher-port":
                SetQuery("port ");
                break;
            case "launcher-empty":
                SetQuery("zzqqxxyy");
                break;
            case "launcher-prompt":
                SetQuery("g");
                break;
            case "launcher-actions":
                SetQuery("a");
                ToggleActions();
                break;
            case "launcher-calc-actions":
                // 计算结果的 Ctrl+K：「复制十六进制」右边那行小字（三级文字）。
                SetQuery("0xFF + 1");
                ToggleActions();
                break;
            case "launcher-keys":
                SetQuery("a");
                SetKeyHints(true);
                break;
            default:
                SetQuery("a");
                break;
        }
    }

    /// <summary>设置 › 启动器「呼出时切到英文输入法」（L1）：搜索框的输入范围设成半角字母数字，输入法在这个框里默认英文，不动系统设置。</summary>
    private void ApplyInputScope()
    {
        var scope = new InputScope();
        scope.Names.Add(new InputScopeName(SettingsService.Current.LauncherRomanInput
            ? InputScopeNameValue.AlphanumericHalfWidth
            : InputScopeNameValue.Default));
        SearchBox.InputScope = scope;
    }

    // ---- 搜索和渲染

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        // 组字时不搜；删空了要搜（回到收藏 / 常用、菜单的过滤词清空），所以不挡空串。
        if (!_active || _suppressSearch || _composing)
        {
            return;
        }

        if (_palette.IsOpen)
        {
            _palette.SetFilter(SearchBox.Text);
            return;
        }

        // 字和模型的查询一样就不重搜：WinUI 的 TextChanged 是异步发的，SetSearchQuietly 那个开关拦不住它，
        // 不拦的话呼出时接着上次的查询、关掉 Ctrl+K 菜单这几处会再搜一遍、选中跳回第一行。
        if (Model is not { } model || SearchBox.Text == model.Query)
        {
            return;
        }

        if (model.CanUndoForget)
        {
            Footer.HideNotice();
        }

        model.UserMovedSelection = false;
        model.Search(SearchBox.Text);
        Render(null, resetScroll: true);
    }

    /// <summary>改搜索框里的字但不触发搜索（呼出、开关菜单时）。</summary>
    private void SetSearchQuietly(string text)
    {
        _suppressSearch = true;
        SearchBox.Text = text;
        SearchBox.SelectionStart = text.Length;
        _suppressSearch = false;
    }

    /// <summary>按模型的结果重画列表：keepId 那一项还在就留在它上面（上膛的那一项优先），否则回到第一行。</summary>
    private void Render(string? keepId, bool resetScroll)
    {
        if (Model is not { } model)
        {
            return;
        }

        var results = model.Results;
        var heights = results.Select(item => LauncherListLayout.HeightOf(item.Kind)).ToList();
        var layout = new LauncherListLayout(heights, model.Groups.Select(group => group.Row).ToList());
        var titles = new Dictionary<int, string>();
        foreach (var group in model.Groups)
        {
            titles.TryAdd(group.Row, group.Title);
        }

        var keep = model.ArmedId ?? keepId;
        var index = keep is null ? -1 : results.FindIndex(item => item.Id == keep);
        _selected = index >= 0 ? index : results.Count > 0 ? 0 : -1;
        _selectedId = _selected >= 0 ? results[_selected].Id : null;
        _pendingHosts.Clear();
        _pendingPaths.Clear();
        _list.SetItems(layout, titles, _selected, BuildRow);
        _list.Visibility = results.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = model.EmptyText;
        EmptyText.Visibility = model.ShowsEmptyText ? Visibility.Visible : Visibility.Collapsed;
        if (resetScroll)
        {
            _list.ScrollToTop();
        }

        if (_selected >= 0)
        {
            _list.Reveal(_selected);
        }

        _footerKey = string.Empty;
        UpdateFooter();
        HeightRequested?.Invoke(ContentHeightDip, false);
        LoadSiteIcons();
        LoadPathIcons();
    }

    private LauncherRowView BuildRow(int index)
    {
        var item = Model!.Results[index];
        var row = new LauncherRowView(item, index, Context(item, index));
        // 滚出来的新行要的网站图标、文件图标也攒成一批去查（Render 末尾那一次只管得到当时建好的行）。
        if ((_pendingHosts.Count > 0 || _pendingPaths.Count > 0) && !_iconLoadQueued)
        {
            _iconLoadQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                _iconLoadQueued = false;
                LoadSiteIcons();
                LoadPathIcons();
            });
        }

        return row;
    }

    private LauncherRowContext Context(LauncherItem item, int index)
    {
        var model = Model!;
        var selected = index == _selected;
        var armed = model.IsArmed(item);
        var alternate = selected ? model.AlternateSubtitle(item, _alternate) : null;
        var hotKey = selected && item.HotKeyAction is { } action && !_showKeyHints
            ? ShellRuntime.Instance?.HotKeys.ShortcutFor(action)
            : null;
        return new LauncherRowContext(
            alternate ?? item.Subtitle,
            alternate is not null && !armed,
            armed,
            KindName(item),
            hotKey,
            IconFor(item));
    }

    private static string KindName(LauncherItem item)
        => item.Kind == LauncherKind.Path
            ? LauncherText.FileKindTitle(item.Target, item.IsFolder)
            : PanelFooterText.LauncherKindName(item.Kind, item.Target);

    /// <summary>某一行的副标题 / 快捷键键帽按现在的选中、上膛、修饰键重算（不重建整行）。</summary>
    private void RefreshRow(int index)
    {
        if (Model is not { } model || index < 0 || index >= model.Results.Count || _list.RowAt(index) is not { } row)
        {
            return;
        }

        var context = Context(model.Results[index], index);
        row.SetSubtitle(context.Subtitle, context.SubtitleIsAlternate, context.Armed);
        row.SetHotKey(context.HotKey);
    }

    /// <summary>换选中：撤掉上膛、不能再撤销移除，高亮滑过去、露出这一行，底栏跟着换。</summary>
    private void Select(int index, MotionCurve curve)
    {
        if (Model is not { } model || index < 0 || index >= model.Results.Count)
        {
            return;
        }

        var old = _selected;
        var disarmed = model.Disarm();
        if (model.CanUndoForget)
        {
            Footer.HideNotice();
        }

        model.DropUndo();
        _selected = index;
        _selectedId = model.Results[index].Id;
        _list.SetSelection(index, curve);
        _list.Reveal(index);
        RefreshRow(old);
        RefreshRow(index);
        if (disarmed || old != index)
        {
            UpdateFooter();
        }
    }

    private void MoveSelection(int delta, bool repeat)
    {
        if (Model is not { } model || model.Results.Count == 0)
        {
            return;
        }

        model.UserMovedSelection = true;
        var count = model.Results.Count;
        var index = ((_selected < 0 ? 0 : _selected) + delta + count) % count;
        // 连发不动画（mac：键盘单按 snap、连发 instant）。
        Select(index, repeat ? MotionCurve.Instant : MotionCurve.Snap);
    }

    /// <summary>执行了一下但面板还开着（上膛了、补全了、响了一声）：上膛的那一项选中、副标题换成确认提示、底栏换危险色。</summary>
    private void AfterAction()
    {
        if (!_active || Model is not { } model)
        {
            return;
        }

        if (model.ArmedId is { } armed)
        {
            var index = model.Results.FindIndex(item => item.Id == armed);
            if (index >= 0 && index != _selected)
            {
                var old = _selected;
                _selected = index;
                _selectedId = armed;
                _list.SetSelection(index, MotionCurve.Snap);
                _list.Reveal(index);
                RefreshRow(old);
            }
        }

        RefreshRow(_selected);
        _footerKey = string.Empty;
        UpdateFooter();
    }

    // ---- 图标

    private ImageSource? IconFor(LauncherItem item)
    {
        string key;
        byte[]? bytes;
        switch (item.Kind)
        {
            case LauncherKind.Setting when SettingsExe is not null:
                // 系统设置的页：用「设置」应用的图标（mac 用系统设置 App 的图标）。取 SystemSettings.exe 的系统图标：
                // 开始菜单里那张商店 logo 四周留白很大，缩到 24 只剩一个小齿轮。
                key = "path:" + SettingsExe;
                bytes = PathIcon(SettingsExe);
                break;
            case LauncherKind.Setting:
                key = "settings-app";
                bytes = SettingsAppIcon();
                break;
            case LauncherKind.Url or LauncherKind.Search:
                if (LauncherText.Host(item.Target) is not { } host)
                {
                    return null;
                }

                bytes = SiteIcons.Peek(host, out var found);
                // 没查过浏览器图标库时先用的是链接预览那张：键分开，查到浏览器的那张后换得上（不被位图缓存挡住）。
                key = "site:" + host + (found ? ":browser" : ":preview");
                if (!found)
                {
                    _pendingHosts.Add(host);
                }

                break;
            case LauncherKind.App when item.IconData is { Length: > 0 } data:
                key = "app:" + item.Target;
                bytes = data;
                break;
            case LauncherKind.App or LauncherKind.Path:
                key = "path:" + item.Target;
                bytes = PathIcon(item.Target);
                break;
            case LauncherKind.Process when item.Process?.ExePath is { } exe:
                key = "path:" + exe;
                bytes = PathIcon(exe);
                break;
            default:
                return null;
        }

        if (bytes is not { Length: > 0 })
        {
            return null;
        }

        if (_icons.TryGetValue(key, out var cached))
        {
            return cached;
        }

        var image = new BitmapImage { DecodePixelWidth = 48 };
        _icons[key] = image;
        _ = LoadIconAsync(image, bytes);
        return image;
    }

    /// <summary>
    /// 文件、exe 的系统图标（按路径缓存；读不到的也记着，不反复读）。没读过的先空着、攒成一批去后台读：
    /// ShellIcons.LoadPng 里同步等 PNG 编码，在 UI 线程上调会把 UI 线程锁死（编码的续体要回 UI 线程）。
    /// </summary>
    private byte[]? PathIcon(string path)
    {
        if (_pathIcons.TryGetValue(path, out var cached))
        {
            return cached;
        }

        _pendingPaths.Add(path);
        return null;
    }

    /// <summary>这一轮布局要的文件 / exe 图标在线程池里读；读完记进缓存、重画一次。</summary>
    private void LoadPathIcons()
    {
        if (_pendingPaths.Count == 0)
        {
            return;
        }

        var paths = _pendingPaths.ToList();
        _pendingPaths.Clear();
        foreach (var path in paths)
        {
            _pathIcons[path] = null; // 读着的不再排进下一批
        }

        _ = LoadPathIconsAsync(paths, XamlRoot?.RasterizationScale ?? 1.0);
    }

    private async Task LoadPathIconsAsync(List<string> paths, double scale)
    {
        var loaded = await Task.Run(() => paths.Select(path => (Path: path, Bytes: ReadPathIcon(path, scale))).ToList());
        var any = false;
        foreach (var (path, bytes) in loaded)
        {
            _pathIcons[path] = bytes;
            any |= bytes is not null;
        }

        if (any && _active)
        {
            Render(_selectedId, resetScroll: false);
        }
    }

    private static byte[]? ReadPathIcon(string path, double scale)
    {
        try
        {
            return File.Exists(path) || Directory.Exists(path) ? ShellIcons.LoadPng(path, scale, 24) : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.path-icon-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>「设置」应用的 exe（没有就是 null，退回开始菜单里的商店 logo）。</summary>
    private static readonly string? SettingsExe = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows), "ImmersiveControlPanel", "SystemSettings.exe") is var exe &&
        File.Exists(exe)
            ? exe
            : null;

    private static byte[]? SettingsAppIcon()
        => AppCatalog.Instance?.Apps
            .FirstOrDefault(app => app.Target.Contains("immersivecontrolpanel", StringComparison.OrdinalIgnoreCase))
            ?.IconData;

    /// <summary>这一轮布局报上来的网站主机攒成一批，在后台查本机浏览器的图标库；查到了再重画一次。</summary>
    private void LoadSiteIcons()
    {
        if (_pendingHosts.Count == 0)
        {
            return;
        }

        var hosts = _pendingHosts.ToList();
        _pendingHosts.Clear();
        SiteIcons.Load(hosts, () =>
        {
            if (_active)
            {
                Render(_selectedId, resetScroll: false);
            }
        });
    }

    private static async Task LoadIconAsync(BitmapImage image, byte[] bytes)
    {
        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            await image.SetSourceAsync(stream);
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.icon-failed {ex.GetType().Name}");
        }
    }

    // ---- 底栏

    /// <summary>
    /// 底栏（mac bar）：左边是选中项的种类（16 色块 + 种类名），右边「主动作 ↩」（上膛 / 强制的字和键帽是危险色）·「操作 Ctrl+K」；
    /// 有新版本时右边最前面多一枚「更新到 x」（mac 在左边种类后面；Windows 底栏左边要让给就地提示）。没有选中项时只剩它。
    /// </summary>
    private void UpdateFooter()
    {
        var item = SelectedItem;
        var update = UpdateService.AvailableVersion;
        var primary = item is null || Model is not { } model ? default : model.PrimaryAction(item);
        var key = item is null
            ? "|" + update
            : $"{item.Kind}|{item.Target}|{item.IsFolder}|{primary.Title}|{primary.Danger}|{update}";
        if (key == _footerKey)
        {
            return;
        }

        _footerKey = key;
        Footer.ClearActions();
        if (update is not null)
        {
            Footer.AddVerb($"更新到 {update}", null, primary: false, () =>
            {
                CloseRequested?.Invoke();
                if (!AutoUpdater.IsBusy)
                {
                    _ = AutoUpdater.StartAsync();
                }
            });
        }

        if (item is null)
        {
            Footer.SetLeading(null);
            Footer.Status = string.Empty;
            return;
        }

        Footer.SetLeading(KindTile.Create(KindTile.FamilyOf(item.Kind, item.Target), FooterGlyph(item), 16));
        Footer.Status = KindName(item);
        Footer.AddVerb(primary.Title, "↩", primary: true, ExecuteSelected, primary.Danger);
        Footer.AddVerb("操作", "Ctrl+K", primary: false, ToggleActions);
    }

    /// <summary>底栏左边 16 色块的符号：只看种类（mac familySymbol）。</summary>
    private static string FooterGlyph(LauncherItem item) => item.Kind switch
    {
        LauncherKind.App => Glyphs.App,
        LauncherKind.Path => item.IsFolder ? Glyphs.Folder : Glyphs.File,
        LauncherKind.Action => Glyphs.Command,
        LauncherKind.Command => Glyphs.Shutdown,
        LauncherKind.Setting => Glyphs.Settings,
        _ => KindTile.GlyphOf(item.Kind, item.Target),
    };

    // ---- 按键

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_active || Model is not { } model)
        {
            return;
        }

        var control = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        var alt = IsDown(VirtualKey.Menu);
        var repeat = e.KeyStatus.WasKeyDown;
        switch (e.Key)
        {
            case VirtualKey.Control:
                // 按住 Ctrl 150 ms 才浮现键帽。
                if (!_showKeyHints)
                {
                    _keyHintTimer.Stop();
                    _keyHintTimer.Start();
                }

                SetAlternate(LauncherAlternate.Control);
                return;
            case VirtualKey.Menu:
                SetAlternate(LauncherAlternate.Alt);
                return;
            case VirtualKey.Shift:
                if (!e.KeyStatus.WasKeyDown)
                {
                    _shiftTimer.Stop();
                    _shiftTimer.Start();
                }

                return;
        }

        // 按着 Shift 又打了别的键（大写字母、符号）：是在打字，不是要看 Shift+Enter。
        _shiftTimer.Stop();
        if (_alternate == LauncherAlternate.Shift && e.Key != VirtualKey.Enter)
        {
            SetAlternate(LauncherAlternate.None);
        }

        if (_palette.IsOpen && HandlePaletteKey(e, control))
        {
            return;
        }

        var item = SelectedItem;
        switch (e.Key)
        {
            case VirtualKey.Escape:
                // 先撤上膛，再清空搜索，最后收起。
                e.Handled = true;
                model.DropUndo();
                if (model.Disarm())
                {
                    AfterAction();
                }
                else if (SearchBox.Text.Length > 0)
                {
                    SearchBox.Text = string.Empty;
                }
                else
                {
                    CloseRequested?.Invoke();
                }

                break;
            case VirtualKey.Down:
            case VirtualKey.Up:
                e.Handled = true;
                var delta = e.Key == VirtualKey.Down ? 1 : -1;
                if (control && alt && item is not null && model.MoveFavorite(item, delta))
                {
                    break;
                }

                MoveSelection(delta, repeat);
                break;
            case VirtualKey.Enter:
                e.Handled = true;
                if (item is null && !alt && !shift)
                {
                    break;
                }

                model.KeyRepeat = repeat;
                if (alt)
                {
                    model.SearchInExplorer();
                }
                else if (shift && !control)
                {
                    model.SearchWeb();
                }
                else if (item is null)
                {
                    break;
                }
                else if (control && shift)
                {
                    model.RunAsAdmin(item);
                }
                else if (control)
                {
                    model.CommandReturn(item);
                }
                else
                {
                    model.Execute(item);
                }

                AfterAction();
                break;
            case VirtualKey.Tab:
                // 没得补也吞掉，不让焦点跳到别的控件。
                e.Handled = true;
                if (item is not null)
                {
                    model.Complete(item);
                }

                break;
            // 菜单开着时 → 交给过滤框（HandlePaletteKey 没接它）；不然光标在末尾按 → 会把刚开的菜单又关掉。
            case VirtualKey.Right when item is not null && CaretAtEnd && !_palette.IsOpen:
                e.Handled = true;
                ToggleActions();
                break;
            case VirtualKey.K when control:
                e.Handled = true;
                ToggleActions();
                break;
            case VirtualKey.C when control && SearchBox.SelectionLength == 0 && item is not null:
                if (shift)
                {
                    if (LauncherText.IsWebLink(item))
                    {
                        e.Handled = true;
                        model.Copy(item, LauncherModel.CopyFormat.Markdown);
                    }
                }
                else if (model.CopyTitle(item) is not null)
                {
                    e.Handled = true;
                    model.Copy(item);
                }

                break;
            case VirtualKey.D when control:
                e.Handled = true;
                if (item is not null)
                {
                    model.ToggleFavorite(item);
                }

                break;
            case VirtualKey.Delete when control && model.IsShowingHome:
                // 「常用」里 Ctrl+Delete：忘掉这一项（有查询时照常删到词尾）。收藏上没有这个动作，响一声。
                e.Handled = true;
                if (item is not null)
                {
                    model.Forget(item);
                }

                break;
            case VirtualKey.Z when control && model.CanUndoForget:
                e.Handled = true;
                Footer.HideNotice();
                model.UndoForget();
                break;
            case (VirtualKey)188 when control:
                // Ctrl+,（VK_OEM_COMMA）：直达设置 › 启动器。
                e.Handled = true;
                SettingsRequested?.Invoke();
                break;
            case >= VirtualKey.Number1 and <= VirtualKey.Number9 when control:
                e.Handled = true;
                var number = (int)e.Key - (int)VirtualKey.Number1;
                if (number < model.Results.Count)
                {
                    model.KeyRepeat = repeat;
                    model.Execute(model.Results[number]);
                    AfterAction();
                }

                break;
        }
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Control:
                _keyHintTimer.Stop();
                SetKeyHints(false);
                SetAlternate(LauncherAlternate.None);
                break;
            case VirtualKey.Menu:
            case VirtualKey.Shift:
                _shiftTimer.Stop();
                SetAlternate(LauncherAlternate.None);
                break;
        }
    }

    private bool CaretAtEnd => SearchBox.SelectionLength == 0 && SearchBox.SelectionStart == SearchBox.Text.Length;

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void ExecuteSelected()
    {
        if (Model is { } model && SelectedItem is { } item)
        {
            model.KeyRepeat = false;
            model.Execute(item);
            AfterAction();
        }
    }

    /// <summary>按住修饰键：选中行的副标题换成它的替代动作（mac alternateSubtitle）。</summary>
    private void SetAlternate(LauncherAlternate alternate)
    {
        if (_alternate == alternate)
        {
            return;
        }

        _alternate = alternate;
        RefreshRow(_selected);
    }

    private void SetKeyHints(bool show)
    {
        if (_showKeyHints == show)
        {
            return;
        }

        _showKeyHints = show;
        _list.SetShortcutsShown(show);
        RefreshRow(_selected);
    }

    // ---- Ctrl+K 菜单、右键菜单

    /// <summary>Ctrl+K / → / 底栏「操作」：没有选中项时不打开；开着时再按是关。</summary>
    private void ToggleActions()
    {
        if (_palette.IsOpen)
        {
            _palette.Close();
            return;
        }

        if (Model is not { } model || SelectedItem is not { } item)
        {
            return;
        }

        // 点菜单项（不经过 Enter）执行的也要刷新上膛的副标题和底栏。
        var actions = model.ActionsFor(item)
            .Select(action => action.Run is { } run
                ? action with
                {
                    Run = () =>
                    {
                        model.KeyRepeat = false;
                        run();
                        AfterAction();
                    },
                }
                : action)
            .ToList();
        _savedQuery = SearchBox.Text;
        SetSearchQuietly(string.Empty);
        var sections = actions.Select(action => action.Section).Distinct().Count();
        _paletteHeight = Math.Min(actions.Count * ClipPalette.RowHeight + Math.Max(0, sections - 1) * 9, ClipPalette.MaxListHeight) + 12;
        _palette.HorizontalAlignment = HorizontalAlignment.Right;
        _palette.VerticalAlignment = VerticalAlignment.Bottom;
        _palette.Margin = new Thickness(0, 0, 16, 4);
        _palette.Open("actions", actions);
        SearchBox.PlaceholderText = "搜索操作";
        SearchLineControl.SetSymbol(Glyphs.Command);
        HeightRequested?.Invoke(ContentHeightDip, false);
        FocusSearch();
    }

    private void CloseMenu()
    {
        if (_palette.IsOpen)
        {
            _palette.Close();
        }
    }

    private void OnPaletteClosed()
    {
        SetSearchQuietly(_savedQuery ?? string.Empty);
        _savedQuery = null;
        SearchBox.PlaceholderText = Placeholder;
        SearchLineControl.SetSymbol(Glyphs.Search);
        if (_active)
        {
            HeightRequested?.Invoke(ContentHeightDip, false);
            FocusSearch();
        }
    }

    /// <summary>
    /// 菜单开着时的按键（mac handleMenuCommand）：↑↓ 选、Enter 执行、Esc / 过滤词为空时 ← 只关菜单；Tab 关菜单再补全；
    /// 菜单里标着的 Ctrl 组合键先关菜单再照常做。返回 true = 已经处理。
    /// </summary>
    private bool HandlePaletteKey(KeyRoutedEventArgs e, bool control)
    {
        switch (e.Key)
        {
            case VirtualKey.Escape:
                e.Handled = true;
                if (!_palette.Back())
                {
                    _palette.Close();
                }

                return true;
            case VirtualKey.Up:
                e.Handled = true;
                _palette.Move(-1);
                return true;
            case VirtualKey.Down:
                e.Handled = true;
                _palette.Move(1);
                return true;
            case VirtualKey.Enter when !control && !IsDown(VirtualKey.Menu) && !IsDown(VirtualKey.Shift):
                e.Handled = true;
                if (Model is { } model)
                {
                    model.KeyRepeat = e.KeyStatus.WasKeyDown;
                }

                _palette.Activate();
                AfterAction();
                return true;
            case VirtualKey.Left when SearchBox.Text.Length == 0:
                e.Handled = true;
                if (!_palette.Back())
                {
                    _palette.Close();
                }

                return true;
            case VirtualKey.K when control:
                e.Handled = true;
                _palette.Close();
                return true;
        }

        // Tab、Ctrl+Enter / Alt+Enter / Shift+Enter、别的 Ctrl 组合键：先关菜单再照常做；过滤框里有字时 Ctrl+A / V / X / Z / Delete 交给输入框。
        if (e.Key == VirtualKey.Tab || e.Key == VirtualKey.Enter ||
            (control && e.Key is not (VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu)))
        {
            if (control && SearchBox.Text.Length > 0 &&
                e.Key is VirtualKey.A or VirtualKey.V or VirtualKey.X or VirtualKey.Z or VirtualKey.Back or VirtualKey.Delete)
            {
                return true;
            }

            _palette.Close();
        }

        return false;
    }

    /// <summary>右键（mac：和 Ctrl+K 同一份动作，对着被点的那一行）：用系统的菜单，节和节之间一条分隔线，不写键位。</summary>
    private void OnItemRightTapped(int index, FrameworkElement row, Windows.Foundation.Point position)
    {
        if (Model is not { } model || index >= model.Results.Count)
        {
            return;
        }

        CloseMenu();
        Select(index, MotionCurve.Glide);
        var item = model.Results[index];
        var menu = new MenuFlyout();
        var lastSection = int.MinValue;
        foreach (var action in model.ActionsFor(item))
        {
            if (lastSection != int.MinValue && action.Section != lastSection)
            {
                menu.Items.Add(new MenuFlyoutSeparator());
            }

            lastSection = action.Section;
            var run = action.Run ?? (() => { });
            menu.Items.Add(ActionMenu.Create(new ActionMenuItem(action.Glyph, action.Title, null, () =>
            {
                model.KeyRepeat = false;
                run();
                AfterAction();
            }, action.Danger)));
        }

        menu.Closed += (_, _) => FocusSearch();
        menu.ShowAt(row, new FlyoutShowOptions { Position = position });
    }

    private void Announce(string text)
    {
        try
        {
            var peer = FrameworkElementAutomationPeer.FromElement(this) ?? FrameworkElementAutomationPeer.CreatePeerForElement(this);
            peer?.RaiseNotificationEvent(
                AutomationNotificationKind.ActionCompleted,
                AutomationNotificationProcessing.ImportantMostRecent,
                text,
                "kitty-launcher");
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.announce-failed {ex.GetType().Name}");
        }
    }
}
