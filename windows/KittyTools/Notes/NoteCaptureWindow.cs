// 快速记一条的面板（PLAN-v13 第 5 批，照 mac Notes/NoteCapture.swift + NoteCaptureView.swift；规则在 Core 的 NoteCaptureRules）：
// 和剪贴板面板、启动器同位置同宽（屏幕上方，720 DIP）、同一套外壳（亚克力、系统圆角阴影、置顶、不进 Alt+Tab），三块只开一个。
// 顶上一行「记到」+ 记成新便签时的标题框（占位「标题（可不填）」）/ 记到已有的某条时它的标题 + 右边一排目的地（新便签 + 最近的 8 条，
// 各是它的纸色圆点，选中的外面一圈强调色）；中间多行输入框（Enter 记下、Shift+Enter 换行，组字时不误提交；Tab 去标题框），3 行起、最多 8 行；
// 底栏左边是键位提示，存不了时换成原因；右边「记下 ↵」。
// 收起：Esc 清空草稿（提示里能「恢复」）、Ctrl+W / 再按一次快捷键 / 点别处留着草稿。草稿停手 1 秒、收起、退出前存进 notes-draft.json。
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.System;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed class NoteCaptureWindow : Window
{
    private const double WidthDip = 720;
    private const double LineDip = 22;

    private readonly Grid _root;
    private readonly TextBox _title;
    private readonly TextBlock _targetTitle;
    private readonly StackPanel _dots;
    private readonly TextBox _body;
    private readonly PanelFooter _footer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _draftTimer;
    private string? _destination;
    private bool _visible;
    private bool _hiding;
    private bool _composing;
    private HWND _hwnd;
    private HWND _previousForeground;
    private double _scale = 1;

    private static NoteCaptureWindow? _instance;

    public static bool IsOpen => _instance?._visible == true;

    private static string DraftPath => Path.Combine(Paths.DataDirectory, NoteCaptureRules.DraftName);

    private NoteCaptureWindow()
    {
        Title = Paths.ProductName + " 快速记一条";
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
            Hide(clear: false);
        };
        _hwnd = (HWND)WinRT.Interop.WindowNative.GetWindowHandle(this);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated && _visible && !_hiding)
            {
                // 点别处：收起，草稿留着（不还前台：用户点的那个窗口已经是前台了）
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (_visible && PInvoke.GetForegroundWindow() != _hwnd)
                    {
                        Hide(clear: false, restoreForeground: false);
                    }
                });
            }
        };

        _root = new Grid { RequestedTheme = Theme.ElementTheme, Padding = new Thickness(18, 0, 18, 0) };
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = KindTile.Create("notes", FeatureIcons.NotesCapture, 20);
        icon.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(icon);
        var label = new TextBlock { Text = "记到", Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(label, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Grid.SetColumn(label, 1);
        header.Children.Add(label);
        _title = new TextBox { PlaceholderText = "标题（可不填）", FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_title, "新便签的标题");
        SearchLine.MakePlain(_title);
        _title.TextChanged += (_, _) => DraftChanged();
        _title.KeyDown += OnTitleKeyDown;
        Grid.SetColumn(_title, 2);
        header.Children.Add(_title);
        _targetTitle = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Visibility = Visibility.Collapsed,
        };
        Grid.SetColumn(_targetTitle, 2);
        header.Children.Add(_targetTitle);
        _dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(_dots, 3);
        header.Children.Add(_dots);
        _root.Children.Add(header);

        _body = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            PlaceholderText = "记点什么…",
            FontSize = 15,
            IsSpellCheckEnabled = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_body, "便签内容");
        SearchLine.MakePlain(_body);
        ScrollViewer.SetVerticalScrollBarVisibility(_body, ScrollBarVisibility.Auto);
        _body.TextChanged += (_, _) =>
        {
            DraftChanged();
            Resize();
        };
        _body.TextCompositionStarted += (_, _) => _composing = true;
        _body.TextCompositionEnded += (_, _) => _composing = false;
        _body.PreviewKeyDown += OnBodyKeyDown;
        Grid.SetRow(_body, 1);
        _root.Children.Add(_body);

        _footer = new PanelFooter { Margin = new Thickness(-18, 0, -18, 0) };
        Grid.SetRow(_footer, 2);
        _root.Children.Add(_footer);
        _root.KeyDown += OnRootKeyDown;
        Content = _root;

        _draftTimer = DispatcherQueue.CreateTimer();
        _draftTimer.Interval = TimeSpan.FromMilliseconds(NoteCaptureRules.DraftDelayMs);
        _draftTimer.IsRepeating = false;
        _draftTimer.Tick += (_, _) => SaveDraft();

        if (ReadDraft() is { } saved)
        {
            Put(saved);
        }
    }

    // ---- 打开、收起 ----

    /// <summary>全局快捷键：开着就收起（留着草稿），没开就打开。</summary>
    public static void Toggle()
    {
        if (IsOpen)
        {
            _instance!.Hide(clear: false);
            return;
        }

        if (NoteStore.Instance is null)
        {
            NoticeHost.Show("便签这次用不了", NotesRecovery.Unavailable ?? "便签的数据打不开", NoticeTone.Warning);
            return;
        }

        OverlayHost.Hide(restoreForeground: false);
        _instance ??= new NoteCaptureWindow();
        _instance.Show();
    }

    public static void HideIfOpen() => _instance?.Hide(clear: false);

    /// <summary>退出前：草稿落盘。</summary>
    public static void Flush() => _instance?.SaveDraft();

    private void Show()
    {
        IdleReclaimer.Cancel();
        var before = Foreground.Get();
        _previousForeground = before != default && !Foreground.IsOurs(before) ? before : default;
        _root.RequestedTheme = Theme.ElementTheme;
        if (Target is null)
        {
            _destination = null;
        }

        RefreshHeader();
        _footer.HideNotice();
        RefreshFooter();
        _visible = true;
        Resize();
        Activate();
        Foreground.Restore(_hwnd);
        DispatcherQueue.TryEnqueue(() =>
        {
            _body.Focus(FocusState.Programmatic);
            _body.SelectionStart = _body.Text.Length;
        });
        if (SettingsService.Current.PanelSqueezeEntrance)
        {
            Motion.SqueezeIn(_root);
        }
        else
        {
            Motion.Entrance(_root);
        }

        Log.Info("notes.capture-show");
    }

    private void Hide(bool clear, bool restoreForeground = true)
    {
        if (!_visible)
        {
            return;
        }

        _hiding = true;
        try
        {
            _visible = false;
            if (clear)
            {
                Reset();
            }

            SaveDraft();
            AppWindow.Hide();
            IdleReclaimer.Schedule();
            if (restoreForeground && _previousForeground != default)
            {
                Foreground.Restore(_previousForeground);
            }
        }
        finally
        {
            _hiding = false;
        }
    }

    private void Resize()
    {
        if (!_visible)
        {
            return;
        }

        var display = Displays.AtCursor();
        _scale = display.Scale <= 0 ? 1 : display.Scale;
        var lines = Math.Clamp(_body.Text.Count(ch => ch == '\r' || ch == '\n') + 1, 3, 8);
        var height = 44 + lines * LineDip + 24 + 36;
        var rect = MonitorLayout.Overlay(display.Work, _scale, WidthDip, height, MonitorLayout.ClipboardTopFraction);
        AppWindow.MoveAndResize(new RectInt32(rect.X, rect.Y, rect.Width, rect.Height));
    }

    // ---- 目的地 ----

    private List<Note> Destinations => NoteStore.Instance is { } store
        ? NoteCaptureRules.Destinations(store.Book.Active)
        : new List<Note>();

    private Note? Target => _destination is { } id ? Destinations.FirstOrDefault(note => note.Id == id) : null;

    private void Select(int index)
    {
        var list = Destinations;
        if (index != 0 && index > list.Count)
        {
            SystemSound.Beep();
            return;
        }

        _destination = index == 0 ? null : list[index - 1].Id;
        DraftChanged();
        RefreshHeader();
        RefreshFooter();
        _body.Focus(FocusState.Programmatic);
        Announce(index == 0 ? "记成新便签" : $"记到「{list[index - 1].DisplayTitle}」");
    }

    private void RefreshHeader()
    {
        var target = Target;
        _title.Visibility = target is null ? Visibility.Visible : Visibility.Collapsed;
        _targetTitle.Visibility = target is null ? Visibility.Collapsed : Visibility.Visible;
        _targetTitle.Text = target?.DisplayTitle ?? string.Empty;
        _dots.Children.Clear();
        var selected = target is null ? 0 : Destinations.FindIndex(note => note.Id == target.Id) + 1;
        _dots.Children.Add(Dot(null, 0, selected == 0));
        var list = Destinations;
        for (var index = 0; index < list.Count; index++)
        {
            _dots.Children.Add(Dot(list[index], index + 1, selected == index + 1));
        }
    }

    private FrameworkElement Dot(Note? note, int index, bool selected)
    {
        var dark = Theme.EffectiveTheme == ElementTheme.Dark;
        FrameworkElement face;
        if (note is null)
        {
            face = new FontIcon { Glyph = Glyphs.Add, FontSize = 10 };
        }
        else
        {
            var tone = NotePaper.Of(note).Tone(dark);
            face = new Ellipse
            {
                Width = 12,
                Height = 12,
                Fill = new SolidColorBrush(Theme.ToColor((uint)tone.Paper)),
                Stroke = new SolidColorBrush(Theme.ToColor((uint)tone.Strip)),
                StrokeThickness = 1.5,
            };
        }

        var button = new Button
        {
            Content = face,
            Width = 22,
            Height = 22,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(11),
            BorderThickness = new Thickness(selected ? 2 : 0),
            BorderBrush = new SolidColorBrush(Theme.AccentColor),
            Background = new SolidColorBrush(Colors.Transparent),
            IsTabStop = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, note is null ? "新便签" : $"记到「{note.DisplayTitle}」");
        ToolTipService.SetToolTip(button, note is null ? "新便签（Ctrl+1）" : $"{note.DisplayTitle}（Ctrl+{index + 1}）");
        button.Click += (_, _) => Select(index);
        return button;
    }

    // ---- 按键 ----

    private static bool Down(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnRootKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var control = Down(VirtualKey.Control);
        if (e.Key == VirtualKey.Escape)
        {
            Cancel();
            e.Handled = true;
        }
        else if (control && e.Key == VirtualKey.W)
        {
            Hide(clear: false);
            e.Handled = true;
        }
        else if (control && e.Key is >= VirtualKey.Number1 and <= VirtualKey.Number9)
        {
            Select(e.Key - VirtualKey.Number1);
            e.Handled = true;
        }
    }

    private void OnBodyKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_composing)
        {
            return;
        }

        if (e.Key == VirtualKey.Enter && !Down(VirtualKey.Shift) && !Down(VirtualKey.Control))
        {
            Save();
            e.Handled = true;
        }
        else if (e.Key == VirtualKey.Tab && !Down(VirtualKey.Shift) && Target is null)
        {
            _title.Focus(FocusState.Keyboard);
            e.Handled = true;
        }
    }

    private void OnTitleKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is VirtualKey.Enter or VirtualKey.Tab)
        {
            // Enter 不保存，回正文
            _body.Focus(FocusState.Keyboard);
            e.Handled = true;
        }
    }

    // ---- 存 ----

    private void Save()
    {
        if (NoteStore.Instance is not { } store)
        {
            return;
        }

        var target = Target;
        var (outcome, body, notice) = NoteCaptureRules.Check(_body.Text.Replace("\r\n", "\n").Replace('\r', '\n'), _title.Text, target);
        if (outcome == NoteCaptureRules.Outcome.Empty)
        {
            SystemSound.Beep();
            return;
        }

        if (outcome == NoteCaptureRules.Outcome.TooLong)
        {
            _footer.ShowNotice(notice ?? string.Empty, success: false);
            Announce(notice ?? string.Empty);
            return;
        }

        string id;
        if (target is not null)
        {
            store.SetBody(target.Id, body);
            store.Flush();
            id = target.Id;
        }
        else
        {
            id = store.Create(body, NoteText.TrimSpacesAndNewlines(_title.Text)).Id;
        }

        Reset();
        Hide(clear: false);
        if (store.SaveProblem is { } problem)
        {
            NoticeHost.Show("记下了，但还没存上", problem, NoticeTone.Warning);
        }
        else
        {
            NoticeHost.Show("已记下", store.Book.Find(id)?.DisplayTitle ?? string.Empty, NoticeTone.Normal,
                new NoticeAction("打开", () => NotesHost.Open(id), Opens: true));
        }
    }

    /// <summary>Esc：清空并收起；清掉的不是空的，提示里能「恢复」。</summary>
    private void Cancel()
    {
        var cleared = Current;
        Reset();
        Hide(clear: false);
        if (!cleared.IsEmpty)
        {
            NoticeHost.Show("已清空草稿", "几秒内点「恢复」能放回来", NoticeTone.Normal,
                new NoticeAction("恢复", () => Restore(cleared)));
        }
    }

    private void Restore(NoteCaptureRules.Draft cleared)
    {
        Put(NoteCaptureRules.Restored(Current, cleared));
        Show();
    }

    // ---- 草稿 ----

    private NoteCaptureRules.Draft Current
        => new(_title.Text, _body.Text.Replace("\r\n", "\n").Replace('\r', '\n'), _destination);

    private void Put(NoteCaptureRules.Draft draft)
    {
        _title.Text = draft.Title;
        _body.Text = draft.Body;
        _destination = draft.Destination;
    }

    private void Reset()
    {
        _title.Text = string.Empty;
        _body.Text = string.Empty;
        _destination = null;
        _footer.HideNotice();
    }

    private void DraftChanged()
    {
        _footer.HideNotice();
        _draftTimer.Stop();
        _draftTimer.Start();
    }

    private void SaveDraft()
    {
        _draftTimer.Stop();
        var draft = Current;
        try
        {
            if (draft.IsEmpty)
            {
                if (File.Exists(DraftPath))
                {
                    File.Delete(DraftPath);
                }

                return;
            }

            Directory.CreateDirectory(Paths.DataDirectory);
            File.WriteAllText(DraftPath + ".tmp", draft.Json());
            File.Move(DraftPath + ".tmp", DraftPath, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.capture-draft-failed {ex.GetType().Name}");
        }
    }

    private static NoteCaptureRules.Draft? ReadDraft()
    {
        try
        {
            return File.Exists(DraftPath) ? NoteCaptureRules.Draft.Read(File.ReadAllText(DraftPath)) : null;
        }
        catch
        {
            return null;
        }
    }

    // ---- 底栏 ----

    private void RefreshFooter()
    {
        _footer.ClearActions();
        var hints = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        void Hint(string text, string key)
        {
            var item = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            item.Children.Add(new TextBlock { Text = text, FontSize = 12, Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center });
            item.Children.Add(KeyCap.Create(key));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, $"{text}：{key}");
            hints.Children.Add(item);
        }

        Hint("换行", "Shift+Enter");
        if (Target is null)
        {
            Hint("标题", "Tab");
        }

        Hint("新便签", "Ctrl+1");
        var count = Destinations.Count;
        if (count > 0)
        {
            Hint("记到已有的", count == 1 ? "Ctrl+2" : $"Ctrl+2–{count + 1}");
        }

        Hint("取消", "Esc");
        _footer.SetLeading(hints);
        _footer.AddVerb("记下", "Enter", primary: true, Save);
    }

    private void Announce(string text)
    {
        if (Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_root) is { } peer)
        {
            peer.RaiseNotificationEvent(
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.ActionCompleted,
                Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantMostRecent, text, "notes.capture");
        }
    }
}
