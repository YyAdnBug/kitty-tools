// 剪贴板面板里的对话框（照 mac Clipboard/Dialogs.swift、mac-whisker-clipboard「浮起的东西」）：备注、编辑内容 / 新建片段、
// 新建收藏夹、管理收藏夹。画在面板里，从搜索线下沿落下：宽 708、圆角 card，只压暗列表区，不开系统对话框窗口；
// 标题 13 semibold、提示 11，键位提示和底栏一个写法（动词 + 键帽，只提示不能点），保存是主按钮（不能保存时置灰）。
// 键盘：Esc 取消、Ctrl+Enter 保存（单行的 Enter 也保存）；关掉后焦点回到搜索框。
using KittyTools.Core;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;

namespace KittyTools;

internal sealed partial class ClipDialogHost : Grid
{
    /// <summary>新建片段的占位符说明（同 mac Snippet.placeholderHelp）。</summary>
    public const string PlaceholderHelp =
        "{date} 日期、{time} 时间、{datetime} 日期和时间、{weekday} 星期几、{uuid} 随机编号、" +
        "{clipboard} 当前剪贴板、{clipboard:1}–{clipboard:9} 历史第 N 条文字（不算片段）、{cursor} 粘贴后光标停在这里";

    private readonly Grid _card;
    /// <summary>保存：返回 false = 留着对话框（比如名字不能用，原因已经显示出来）。</summary>
    private Func<bool>? _save;
    private Func<bool>? _canSave;
    private Button? _saveButton;
    private Action<KeyRoutedEventArgs>? _keys;

    public ClipDialogHost()
    {
        Visibility = Visibility.Collapsed;
        Background = new SolidColorBrush(Color.FromArgb(46, 0, 0, 0));
        _card = new Grid
        {
            Margin = new Thickness(6, 6, 6, 0),
            Padding = new Thickness(14, 12, 14, 12),
            RowSpacing = 10,
            VerticalAlignment = VerticalAlignment.Top,
            CornerRadius = Theme.Corner("Kitty.Corner.Card"),
            Background = Theme.Brush("Kitty.CardSolid", Color.FromArgb(255, 251, 251, 251)),
            BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            BorderThickness = new Thickness(1),
        };
        Children.Add(_card);
        // 点压暗的地方 = 取消（同点菜单外面）。
        Tapped += (_, args) =>
        {
            if (ReferenceEquals(args.OriginalSource, this))
            {
                Close();
            }
        };
        AddHandler(KeyDownEvent, new KeyEventHandler(OnKeyDown), handledEventsToo: false);
    }

    public bool IsOpen => Visibility == Visibility.Visible;

    public event Action? Closed;

    public void Close()
    {
        if (!IsOpen)
        {
            return;
        }

        Visibility = Visibility.Collapsed;
        _card.Children.Clear();
        _card.RowDefinitions.Clear();
        _save = null;
        _canSave = null;
        _saveButton = null;
        _keys = null;
        Closed?.Invoke();
    }

    /// <summary>备注：单行，Enter 保存、Esc 取消、空着保存 = 清除。</summary>
    public void ShowNote(string? note, Action<string?> save)
    {
        var box = Input("给这条起个名字，搜索时能搜到", note ?? string.Empty);
        Open("备注", new FrameworkElement[] { box }, () =>
        {
            save(string.IsNullOrWhiteSpace(box.Text) ? null : box.Text.Trim());
            return true;
        }, () => true,
            hint: null, singleLine: box);
        Focus(box);
    }

    /// <summary>
    /// 编辑内容 / 新建片段：正文 200 高；新建片段顶上多一行可选的「名称」（存成备注），焦点先在名称框、Enter / Tab 切到正文。
    /// 正文去掉空白为空、或和原文一样时「保存」置灰、Ctrl+Enter 不生效（mac canSave）。提示只说相关的。
    /// </summary>
    public void ShowText(string title, string initial, bool asksName, string? hint, Action<string?, string> save)
    {
        var body = new TextBox
        {
            Text = initial,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 200,
            FontSize = 14,
            IsSpellCheckEnabled = false,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(body, ScrollBarVisibility.Auto);
        StyleInput(body);
        var fields = new List<FrameworkElement>();
        TextBox? name = null;
        if (asksName)
        {
            name = Input("名称（可选，用于搜索）", string.Empty);
            name.KeyDown += (_, args) =>
            {
                if (args.Key == VirtualKey.Enter && !IsDown(VirtualKey.Control))
                {
                    args.Handled = true;
                    Focus(body);
                }
            };
            fields.Add(name);
        }

        fields.Add(body);
        body.TextChanged += (_, _) => RefreshSave();
        Open(title, fields, () =>
        {
            save(name?.Text, body.Text);
            return true;
        },
            () => body.Text.Trim().Length > 0 && body.Text != initial, hint, singleLine: null);
        Focus((Control?)name ?? body);
        if (name is null)
        {
            body.SelectionStart = body.Text.Length;
        }
    }

    /// <summary>新建收藏夹：名字去空白、不重名、最多 24 字（满了右边显示「24/24」，不悄悄截断）。</summary>
    public void ShowNewGroup(Func<string, string?> create)
    {
        var box = Input("收藏夹名称", string.Empty);
        box.MaxLength = ClipGroups.MaxNameLength;
        var counter = Counter(box);
        var error = ErrorText();
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(box);
        Grid.SetColumn(counter, 1);
        row.Children.Add(counter);
        box.TextChanged += (_, _) =>
        {
            error.Visibility = Visibility.Collapsed;
            RefreshSave();
        };
        Open("新建收藏夹", new FrameworkElement[] { row, error }, () =>
        {
            if (create(box.Text) is { } problem)
            {
                error.Text = problem;
                error.Visibility = Visibility.Visible;
                return false;
            }

            return true;
        }, () => box.Text.Trim().Length > 0, hint: null, singleLine: box, saveText: "新建");
        Focus(box);
    }

    /// <summary>
    /// 管理收藏夹（mac ManageGroupsDialog）：键盘列表（行 28、名字 + 条数 + 「−」）+ 下面「新建收藏夹」输入框。焦点一直在输入框：
    /// ↑↓ 移动选中；输入框空着时 Enter 就地改名、Ctrl+Delete 删除（有字时 Enter 新建）；双击一行也改名；拖动一行排序。
    /// </summary>
    public void ShowManageGroups(ClipGroupsModel model)
    {
        var list = new StackPanel();
        var scroll = new ScrollViewer { Content = list, MaxHeight = 28 * 6.5, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var input = Input("新建收藏夹", string.Empty);
        input.MaxLength = ClipGroups.MaxNameLength;
        var counter = Counter(input);
        var error = ErrorText();
        var selected = 0;
        TextBox? renaming = null;
        string? renamingId = null;

        void Rebuild()
        {
            list.Children.Clear();
            var groups = model.Groups();
            selected = Math.Clamp(selected, 0, Math.Max(0, groups.Count - 1));
            if (groups.Count == 0)
            {
                list.Children.Add(new TextBlock
                {
                    Text = "还没有收藏夹。放进收藏夹的条目都算收藏，不会被清理",
                    FontSize = 12,
                    Foreground = Theme.SecondaryText(),
                    Margin = new Thickness(8, 4, 8, 4),
                    TextWrapping = TextWrapping.Wrap,
                });
                return;
            }

            for (var index = 0; index < groups.Count; index++)
            {
                var (id, name, count) = groups[index];
                var at = index;
                var row = new Grid
                {
                    Height = 28,
                    Padding = new Thickness(8, 0, 4, 0),
                    ColumnSpacing = 8,
                    CornerRadius = Theme.Corner("Kitty.Corner.Control"),
                    Background = index == selected
                        ? Theme.Brush("Kitty.Fill.Selected", Color.FromArgb(18, 0, 0, 0))
                        : new SolidColorBrush(Colors.Transparent),
                };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new FontIcon { Glyph = Glyphs.Folder, FontSize = 13, Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center });
                FrameworkElement title;
                if (renamingId == id)
                {
                    renaming = Input(string.Empty, name);
                    renaming.Height = 22;
                    renaming.MinHeight = 22;
                    renaming.Padding = new Thickness(6, 1, 6, 1);
                    renaming.MaxLength = ClipGroups.MaxNameLength;
                    var box = renaming;
                    box.KeyDown += (_, args) =>
                    {
                        if (args.Key == VirtualKey.Enter)
                        {
                            args.Handled = true;
                            if (model.Rename(id, box.Text) is { } problem)
                            {
                                error.Text = problem;
                                error.Visibility = Visibility.Visible;
                                return;
                            }

                            renamingId = null;
                            renaming = null;
                            Rebuild();
                            Focus(input);
                        }
                        else if (args.Key == VirtualKey.Escape)
                        {
                            args.Handled = true;
                            renamingId = null;
                            renaming = null;
                            Rebuild();
                            Focus(input);
                        }
                    };
                    title = box;
                }
                else
                {
                    title = new TextBlock { Text = name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
                }

                Grid.SetColumn(title, 1);
                row.Children.Add(title);
                var countText = new TextBlock
                {
                    Text = count.ToString(),
                    FontSize = 11,
                    Foreground = Theme.Brush("Kitty.Text.Tertiary", Color.FromArgb(140, 0, 0, 0)),
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(countText, 2);
                row.Children.Add(countText);
                var remove = new Button
                {
                    Content = new FontIcon { Glyph = Glyphs.Remove, FontSize = 11 },
                    Foreground = new SolidColorBrush(Theme.Value(0xFF3B30, 0xFF453A)),
                    Background = new SolidColorBrush(Colors.Transparent),
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(6, 2, 6, 2),
                    IsTabStop = false,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                AutomationProperties.SetName(remove, $"删除收藏夹 {name}");
                remove.Click += (_, _) =>
                {
                    model.Delete(id, name);
                    Rebuild();
                    Focus(input);
                };
                Grid.SetColumn(remove, 3);
                row.Children.Add(remove);
                row.Tapped += (_, _) =>
                {
                    selected = at;
                    Rebuild();
                    Focus(input);
                };
                row.DoubleTapped += (_, args) =>
                {
                    args.Handled = true;
                    selected = at;
                    renamingId = id;
                    Rebuild();
                    if (renaming is { } box)
                    {
                        Focus(box);
                        box.SelectAll();
                    }
                };
                AttachDrag(row, at, groups.Count, (from, to) =>
                {
                    model.Move(id, to - from);
                    selected = to;
                    Rebuild();
                    Focus(input);
                });
                AutomationProperties.SetName(row, $"{name}，{count} 条");
                list.Children.Add(row);
            }
        }

        input.KeyDown += (_, args) =>
        {
            var groups = model.Groups();
            switch (args.Key)
            {
                case VirtualKey.Up when groups.Count > 0:
                    args.Handled = true;
                    selected = (selected - 1 + groups.Count) % groups.Count;
                    Rebuild();
                    break;
                case VirtualKey.Down when groups.Count > 0:
                    args.Handled = true;
                    selected = (selected + 1) % groups.Count;
                    Rebuild();
                    break;
                case VirtualKey.Enter when input.Text.Trim().Length == 0 && groups.Count > 0:
                    args.Handled = true;
                    renamingId = groups[selected].Id;
                    Rebuild();
                    if (renaming is { } box)
                    {
                        Focus(box);
                        box.SelectAll();
                    }

                    break;
                case VirtualKey.Enter:
                    args.Handled = true;
                    if (model.Create(input.Text) is { } problem)
                    {
                        error.Text = problem;
                        error.Visibility = Visibility.Visible;
                        break;
                    }

                    input.Text = string.Empty;
                    selected = model.Groups().Count - 1;
                    Rebuild();
                    break;
                case VirtualKey.Delete or VirtualKey.Back when IsDown(VirtualKey.Control) && input.Text.Length == 0 && groups.Count > 0:
                    args.Handled = true;
                    model.Delete(groups[selected].Id, groups[selected].Name);
                    Rebuild();
                    break;
            }
        };
        input.TextChanged += (_, _) => error.Visibility = Visibility.Collapsed;

        var inputRow = new Grid { ColumnSpacing = 8 };
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        inputRow.Children.Add(input);
        Grid.SetColumn(counter, 1);
        inputRow.Children.Add(counter);
        var keys = KeyHints(("选择", "↑↓"), ("改名", "Enter"), ("删除", "Ctrl+Delete"));
        keys.Children.Add(new TextBlock { Text = "· 拖动排序", FontSize = 11, Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center });
        Rebuild();
        Open("管理收藏夹", new FrameworkElement[] { scroll, inputRow, error, keys }, () => true, () => true, hint: null, singleLine: null,
            saveText: "完成", cancel: false);
        _keys = args =>
        {
            // 对话框开着时 Ctrl+Z 撤销删掉的收藏夹（mac）。
            if (args.Key == VirtualKey.Z && IsDown(VirtualKey.Control) && input.Text.Length == 0 && renaming is null)
            {
                args.Handled = true;
                model.Undo();
                Rebuild();
            }
        };
        Focus(input);
    }

    /// <summary>拖动一行排序：跟手（不动画），松手按落点换位置。</summary>
    private static void AttachDrag(Grid row, int index, int count, Action<int, int> moved)
    {
        double? start = null;
        row.PointerPressed += (_, args) =>
        {
            if (args.GetCurrentPoint(row).Properties.IsLeftButtonPressed)
            {
                start = args.GetCurrentPoint(row.Parent as UIElement).Position.Y;
            }
        };
        row.PointerMoved += (_, args) =>
        {
            if (start is not { } origin || !args.GetCurrentPoint(row).Properties.IsLeftButtonPressed)
            {
                return;
            }

            var delta = args.GetCurrentPoint(row.Parent as UIElement).Position.Y - origin;
            if (Math.Abs(delta) > 4)
            {
                row.CapturePointer(args.Pointer);
                row.Translation = new System.Numerics.Vector3(0, (float)delta, 0);
                Canvas.SetZIndex(row, 1);
            }
        };
        row.PointerReleased += (_, args) =>
        {
            if (start is not { } origin)
            {
                return;
            }

            start = null;
            var delta = args.GetCurrentPoint(row.Parent as UIElement).Position.Y - origin;
            row.ReleasePointerCaptures();
            row.Translation = default;
            var target = Math.Clamp(index + (int)Math.Round(delta / 28), 0, count - 1);
            if (Math.Abs(delta) > 4 && target != index)
            {
                moved(index, target);
            }
        };
    }

    private void Open(
        string title, IReadOnlyList<FrameworkElement> fields, Func<bool> save, Func<bool> canSave, string? hint, TextBox? singleLine,
        string saveText = "保存", bool cancel = true)
    {
        _card.Children.Clear();
        _card.RowDefinitions.Clear();
        _save = save;
        _canSave = canSave;
        var rows = new List<FrameworkElement>
        {
            new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold },
        };
        rows.AddRange(fields);
        if (singleLine is null && cancel)
        {
            var hints = KeyHints(("保存", "Ctrl+Enter"));
            if (hint is not null)
            {
                hints.Children.Add(new TextBlock
                {
                    Text = "· " + hint,
                    FontSize = 11,
                    Foreground = Theme.SecondaryText(),
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                    MaxWidth = 560,
                });
            }

            rows.Add(hints);
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        if (cancel)
        {
            var cancelButton = new Button { Content = "取消", IsTabStop = false };
            cancelButton.Click += (_, _) => Close();
            buttons.Children.Add(cancelButton);
        }

        _saveButton = new Button
        {
            Content = saveText,
            Style = Application.Current.Resources["AccentButtonStyle"] as Style,
            IsTabStop = false,
        };
        _saveButton.Click += (_, _) => Save();
        buttons.Children.Add(_saveButton);
        rows.Add(buttons);
        for (var index = 0; index < rows.Count; index++)
        {
            _card.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            SetRow(rows[index], index);
            _card.Children.Add(rows[index]);
        }

        if (singleLine is not null)
        {
            singleLine.KeyDown += (_, args) =>
            {
                if (args.Key == VirtualKey.Enter)
                {
                    args.Handled = true;
                    Save();
                }
            };
        }

        RefreshSave();
        Visibility = Visibility.Visible;
        Motion.Entrance(_card, MotionCurve.Settle, rise: -8);
    }

    private void RefreshSave()
    {
        if (_saveButton is not null)
        {
            var ok = _canSave?.Invoke() != false;
            _saveButton.IsEnabled = ok;
            _saveButton.Opacity = ok ? 1 : 0.35;
        }
    }

    private void Save()
    {
        if (_canSave?.Invoke() == false || _save is not { } save)
        {
            return;
        }

        if (save())
        {
            Close();
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        _keys?.Invoke(args);
        if (args.Handled)
        {
            return;
        }

        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            Close();
        }
        else if (args.Key == VirtualKey.Enter && IsDown(VirtualKey.Control))
        {
            args.Handled = true;
            Save();
        }
    }

    private static TextBox Input(string placeholder, string text)
    {
        var box = new TextBox { PlaceholderText = placeholder, Text = text, FontSize = 14, IsSpellCheckEnabled = false };
        StyleInput(box);
        return box;
    }

    /// <summary>焦点环品牌粉（mac）：只有拿着焦点的那个画粉色边，别的是发丝线。</summary>
    private static void StyleInput(TextBox box)
    {
        var accent = new SolidColorBrush(Theme.AccentColor);
        box.Resources["TextControlBorderBrushFocused"] = accent;
        box.Resources["TextControlElevationBorderFocusedBrush"] = accent;
        box.SelectionHighlightColor = new SolidColorBrush(Color.FromArgb(102, Theme.AccentColor.R, Theme.AccentColor.G, Theme.AccentColor.B));
    }

    private static TextBlock Counter(TextBox box)
    {
        var counter = new TextBlock
        {
            FontSize = 11,
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        box.TextChanged += (_, _) =>
        {
            var full = box.Text.Length >= ClipGroups.MaxNameLength;
            counter.Text = $"{box.Text.Length}/{ClipGroups.MaxNameLength}";
            counter.Visibility = full ? Visibility.Visible : Visibility.Collapsed;
        };
        return counter;
    }

    private static TextBlock ErrorText() => new()
    {
        FontSize = 11,
        Foreground = new SolidColorBrush(Theme.Value(0xFF3B30, 0xFF453A)),
        Visibility = Visibility.Collapsed,
    };

    private static StackPanel KeyHints(params (string Verb, string Key)[] hints)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var (verb, key) in hints)
        {
            var pair = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            pair.Children.Add(new TextBlock { Text = verb, FontSize = 11, Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center });
            var cap = KeyCap.Create(key);
            cap.VerticalAlignment = VerticalAlignment.Center;
            pair.Children.Add(cap);
            row.Children.Add(pair);
        }

        return row;
    }

    private static void Focus(Control control)
    {
        if (!control.Focus(FocusState.Programmatic))
        {
            control.Loaded += (_, _) => control.Focus(FocusState.Programmatic);
        }
    }

    private static bool IsDown(VirtualKey key)
        => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
}

/// <summary>管理收藏夹对话框要的操作（面板实现，写库、刷新列表、底栏提示）。返回 string 的是「不能用的原因」，null = 成了。</summary>
internal sealed record ClipGroupsModel(
    Func<IReadOnlyList<(string Id, string Name, int Count)>> Groups,
    Func<string, string?> Create,
    Func<string, string, string?> Rename,
    Action<string, string> Delete,
    Action<string, int> Move,
    Action Undo);
