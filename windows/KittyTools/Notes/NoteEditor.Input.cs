// 便签正文编辑器的按键、粘贴、点击、右键菜单、查找条、图片载入（PLAN-v13 第 4 批，照 mac NoteTextView 的 doCommand / performKeyEquivalent /
// mouseDown / paste / menu(for:)；按键表在 PLAN-v13 §3.3）：
// - 回车：列表行、任务行续上同样的标记（任务一律 ☐），空项退出；Tab / Shift+Tab：列表行缩进 / 退回一级，别的行 Tab 是制表符；
//   在行首打「- [ ]」再按空格：换成方框。代码块里这些都不做（照原文）。
// - Ctrl+T 任务切换；Ctrl+B / I / Shift+X / E 粗体、斜体、删除线、行内代码（NoteMarkdown.Toggle）；Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z 撤销重做；
//   Ctrl+F 查找；Esc（查找条开着先关它）、Ctrl+W 交给外面收起。
// - 粘贴一律当纯文本（存的就是纯文本）；选中一段字粘贴一个网址 = 粘成链接（NoteMarkdown.LinkPaste）。粘贴图片在第 7 批。
// - 点方框切换状态；按住 Ctrl 点链接打开（只认 http / https / mailto）。
// - 右键菜单：剪切 / 拷贝 / 粘贴、格式 ›、任务状态 ›、文字颜色 ›（同 mac 的正文菜单）。
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace KittyTools;

internal sealed partial class NoteEditor
{
    private TextBox? _find;

    private static bool Down(VirtualKey key)
        => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>选区碰到的那几行（不含最后一行的换行）：开头、那一段字、选区相对它的位置。</summary>
    private (int Start, string Block, NoteRange Selection) BlockOfSelection()
    {
        var selection = Selection;
        var first = NoteText.Line(_text, selection.Location);
        var last = NoteText.Line(_text, selection.Length > 0 ? Math.Max(selection.End - 1, selection.Location) : selection.Location);
        var end = Math.Max(last.ContentsEnd, first.ContentsEnd);
        return (first.Start, _text[first.Start..end], new NoteRange(selection.Location - first.Start, selection.Length));
    }

    private bool InCodeBlock(int lineStart) => NoteMarkdown.RoleAt(lineStart, _blocks) is not null;

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_composing)
        {
            return;
        }

        var control = Down(VirtualKey.Control);
        var shift = Down(VirtualKey.Shift);
        var alt = Down(VirtualKey.Menu);
        if (alt)
        {
            return;
        }

        e.Handled = (e.Key, control, shift) switch
        {
            (VirtualKey.Enter, false, false) => Newline(),
            (VirtualKey.Tab, false, _) => Indent(shift),
            (VirtualKey.Space, false, false) => Shorthand(),
            (VirtualKey.T, true, false) => ToggleTask(),
            (VirtualKey.B, true, false) => Wrap(NoteMarkdown.Wrap.Bold),
            (VirtualKey.I, true, false) => Wrap(NoteMarkdown.Wrap.Italic),
            (VirtualKey.X, true, true) => Wrap(NoteMarkdown.Wrap.Strike),
            (VirtualKey.E, true, false) => Wrap(NoteMarkdown.Wrap.Code),
            (VirtualKey.Z, true, false) => Do(Undo),
            (VirtualKey.Y, true, false) or (VirtualKey.Z, true, true) => Do(Redo),
            (VirtualKey.F, true, false) => Do(ShowFind),
            (VirtualKey.W, true, false) => Do(() => CloseRequested?.Invoke()),
            (VirtualKey.C, true, false) or (VirtualKey.Insert, true, false) => CopySelection(cut: false),
            (VirtualKey.X, true, false) => CopySelection(cut: true),
            (VirtualKey.Delete, false, true) => CopySelection(cut: true),
            (VirtualKey.Escape, false, false) => Do(() => CloseRequested?.Invoke()),
            _ => false,
        };
    }

    private static bool Do(Action action)
    {
        action();
        return true;
    }

    private bool Newline()
    {
        var selection = Selection;
        if (selection.Length > 0)
        {
            return false;
        }

        var (start, _, contentsEnd) = NoteText.Line(_text, selection.Location);
        if (InCodeBlock(start) || NoteTasks.Newline(_text[start..contentsEnd], selection.Location - start) is not { } change)
        {
            return false;
        }

        ApplyChange(change, start);
        return true;
    }

    private bool Indent(bool outdent)
    {
        var selection = Selection;
        var (start, _, contentsEnd) = NoteText.Line(_text, selection.Location);
        if (selection.Length == 0 && !InCodeBlock(start) &&
            NoteTasks.Indent(_text[start..contentsEnd], selection.Location - start, outdent) is { } change)
        {
            if (change.Replacements.Count > 0)
            {
                ApplyChange(change, start);
            }

            return true;
        }

        if (outdent)
        {
            // 不是列表行：Shift+Tab 照常（焦点挪到上一个控件）
            return false;
        }

        InsertText("\t");
        return true;
    }

    private bool Shorthand()
    {
        var selection = Selection;
        if (selection.Length > 0)
        {
            return false;
        }

        var (start, _, contentsEnd) = NoteText.Line(_text, selection.Location);
        if (InCodeBlock(start) || NoteTasks.Shorthand(_text[start..contentsEnd], selection.Location - start) is not { } change)
        {
            return false;
        }

        ApplyChange(change, start);
        return true;
    }

    public bool ToggleTask()
    {
        var (start, block, selection) = BlockOfSelection();
        if (InCodeBlock(start) || NoteTasks.Toggle(block, selection) is not { } change)
        {
            SystemSound.Beep();
            return true;
        }

        ApplyChange(change, start);
        return true;
    }

    public void SetTaskState(NoteTaskState state)
    {
        var (start, block, selection) = BlockOfSelection();
        if (InCodeBlock(start) || NoteTasks.SetState(state, block, selection) is not { } change)
        {
            SystemSound.Beep();
            return;
        }

        ApplyChange(change, start);
    }

    private bool Wrap(NoteMarkdown.Wrap wrap)
    {
        var (start, block, selection) = BlockOfSelection();
        if (InCodeBlock(start) || NoteMarkdown.Toggle(wrap, block, selection) is not { } change)
        {
            SystemSound.Beep();
            return true;
        }

        ApplyChange(change, start);
        return true;
    }

    public void SetTextColor(NoteColor? color)
    {
        var (start, block, selection) = BlockOfSelection();
        if (InCodeBlock(start) || NoteMarkdown.ApplyColor(color, block, selection) is not { } change)
        {
            SystemSound.Beep();
            return;
        }

        ApplyChange(change, start);
    }

    // ---- 粘贴 ----

    /// <summary>拷贝 / 剪切：拷的是存的形式（Markdown 的标记、图片的令牌都在，贴回便签原样回来）；剪切一步撤销。</summary>
    private bool CopySelection(bool cut)
    {
        var selection = Selection;
        if (selection.Length == 0)
        {
            return true;
        }

        var package = new DataPackage();
        package.SetText(SelectedText);
        Clipboard.SetContent(package);
        if (cut)
        {
            ApplyChange(new NoteTasks.Change(
                new[] { new NoteTasks.Replacement(new NoteRange(0, selection.Length), string.Empty) },
                new NoteRange(0, 0)), selection.Location);
        }

        return true;
    }

    private void OnPaste(object sender, TextControlPasteEventArgs e)
    {
        e.Handled = true;
        _ = PasteAsync();
    }

    private async Task PasteAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            if (content.Contains(StandardDataFormats.Bitmap) || content.Contains(StandardDataFormats.StorageItems))
            {
                if (await PasteImagesAsync(content))
                {
                    return;
                }
            }

            if (!content.Contains(StandardDataFormats.Text))
            {
                return;
            }

            var text = await content.GetTextAsync();
            var selection = Selection;
            if (selection.Length > 0)
            {
                var (start, _, contentsEnd) = NoteText.Line(_text, selection.Location);
                if (!InCodeBlock(start) && selection.End <= contentsEnd &&
                    NoteMarkdown.LinkPaste(text, _text[start..contentsEnd], new NoteRange(selection.Location - start, selection.Length)) is { } link)
                {
                    ApplyChange(link, start);
                    return;
                }
            }

            InsertText(text);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.paste-failed {ex.GetType().Name}");
        }
    }

    // ---- 点击 ----

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_box);
        if (!point.Properties.IsLeftButtonPressed)
        {
            return;
        }

        int position;
        try
        {
            position = _box.Document.GetRangeFromPoint(point.Position, PointOptions.ClientCoordinates).StartPosition;
        }
        catch
        {
            return;
        }

        position = Math.Clamp(position, 0, _text.Length);
        var (start, _, contentsEnd) = NoteText.Line(_text, position);
        if (InCodeBlock(start))
        {
            return;
        }

        var line = _text[start..contentsEnd];
        // 方框：落点在方框这个字的左右两边都算（RichEdit 给的是最近的字的边界）
        if (NoteTasks.Box(line) is { } box && (position - start == box || position - start == box + 1))
        {
            var flipped = NoteTasks.Flipped(line[box]);
            var selection = Selection;
            ApplyChange(new NoteTasks.Change(
                new[] { new NoteTasks.Replacement(new NoteRange(box, 1), flipped.ToString()) },
                new NoteRange(selection.Location - start, selection.Length)), start);
            e.Handled = true;
            return;
        }

        if (Down(VirtualKey.Control))
        {
            foreach (var span in NoteStyles.Spans(line, _markdown))
            {
                if (span.Kind.Tag == NoteStyles.KindTag.Link && span.Kind.Address is { } address &&
                    span.Range.Location <= position - start && position - start <= span.Range.End &&
                    NoteMarkdown.Url(address) is { } url)
                {
                    _ = Windows.System.Launcher.LaunchUriAsync(url);
                    e.Handled = true;
                    return;
                }
            }
        }
    }

    // ---- 右键菜单 ----

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            Add(menu.Items, "剪切", Glyphs.Cut, () => CopySelection(cut: true), Selection.Length > 0, "Ctrl+X");
            Add(menu.Items, "拷贝", Glyphs.Copy, () => CopySelection(cut: false), Selection.Length > 0, "Ctrl+C");
            Add(menu.Items, "粘贴", Glyphs.Paste, () => _ = PasteAsync(), true, "Ctrl+V");
            menu.Items.Add(new MenuFlyoutSeparator());

            var format = new MenuFlyoutSubItem { Text = "格式" };
            Add(format.Items, "粗体", null, () => Wrap(NoteMarkdown.Wrap.Bold), true, "Ctrl+B");
            Add(format.Items, "斜体", null, () => Wrap(NoteMarkdown.Wrap.Italic), true, "Ctrl+I");
            Add(format.Items, "删除线", null, () => Wrap(NoteMarkdown.Wrap.Strike), true, "Ctrl+Shift+X");
            Add(format.Items, "行内代码", null, () => Wrap(NoteMarkdown.Wrap.Code), true, "Ctrl+E");
            menu.Items.Add(format);

            var tasks = new MenuFlyoutSubItem { Text = "任务状态" };
            var current = NoteTasks.StateIn(BlockOfSelection().Block, BlockOfSelection().Selection);
            foreach (var state in NoteTasks.AllStates)
            {
                var item = new ToggleMenuFlyoutItem
                {
                    Text = $"{NoteTasks.Character(state)} {NoteTasks.Title(state)}",
                    IsChecked = current == state,
                };
                item.Click += (_, _) => SetTaskState(state);
                tasks.Items.Add(item);
            }

            menu.Items.Add(tasks);

            var colors = new MenuFlyoutSubItem { Text = "文字颜色" };
            foreach (var color in NoteColors.All)
            {
                var item = new MenuFlyoutItem
                {
                    Text = NoteColors.Title(color),
                    Icon = new PathIcon
                    {
                        Data = new Microsoft.UI.Xaml.Media.EllipseGeometry
                        {
                            Center = new Windows.Foundation.Point(8, 8), RadiusX = 6, RadiusY = 6,
                        },
                        Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                            Rgb(_dark ? NoteColors.Dark(color) : NoteColors.Light(color))),
                    },
                };
                item.Click += (_, _) => SetTextColor(color);
                colors.Items.Add(item);
            }

            colors.Items.Add(new MenuFlyoutSeparator());
            var plain = new MenuFlyoutItem { Text = "默认颜色" };
            plain.Click += (_, _) => SetTextColor(null);
            colors.Items.Add(plain);
            menu.Items.Add(colors);
        };
        return menu;
    }

    private static void Add(IList<MenuFlyoutItemBase> items, string text, string? glyph, Action action, bool enabled, string? key = null)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled, KeyboardAcceleratorTextOverride = key ?? string.Empty };
        if (glyph is not null)
        {
            item.Icon = new FontIcon { Glyph = glyph };
        }

        item.Click += (_, _) => action();
        items.Add(item);
    }

    // ---- 查找 ----

    private void ShowFind()
    {
        if (_find is null)
        {
            _find = new TextBox
            {
                PlaceholderText = "在这条便签里查找",
                Margin = new Thickness(12, 8, 12, 0),
            };
            _find.KeyDown += (_, e) =>
            {
                if (e.Key == VirtualKey.Enter)
                {
                    FindNext(backwards: Down(VirtualKey.Shift));
                    e.Handled = true;
                }
                else if (e.Key == VirtualKey.Escape)
                {
                    HideFind();
                    e.Handled = true;
                }
            };
            _find.TextChanged += (_, _) => FindNext(backwards: false, fromSelectionStart: true);
            _root.Children.Add(_find);
        }

        _find.Visibility = Visibility.Visible;
        var selected = Selection;
        if (selected.Length is > 0 and < 200)
        {
            _find.Text = _text.Substring(selected.Location, selected.Length);
        }

        _find.Focus(FocusState.Programmatic);
        _find.SelectAll();
    }

    private void HideFind()
    {
        if (_find is not null)
        {
            _find.Visibility = Visibility.Collapsed;
        }

        Focus();
    }

    /// <summary>查找条开着吗（Esc 先关它，外面据此决定 Esc 收不收这条便签）。</summary>
    public bool IsFinding => _find is { Visibility: Visibility.Visible };

    private void FindNext(bool backwards, bool fromSelectionStart = false)
    {
        var query = _find?.Text ?? string.Empty;
        if (query.Length == 0)
        {
            return;
        }

        var selection = Selection;
        int found;
        if (backwards)
        {
            var before = Math.Max(selection.Location - 1, 0);
            found = before > 0 ? _text.LastIndexOf(query, before, StringComparison.CurrentCultureIgnoreCase) : -1;
            if (found < 0)
            {
                found = _text.LastIndexOf(query, StringComparison.CurrentCultureIgnoreCase);
            }
        }
        else
        {
            var from = fromSelectionStart ? selection.Location : selection.End;
            found = from < _text.Length ? _text.IndexOf(query, from, StringComparison.CurrentCultureIgnoreCase) : -1;
            if (found < 0)
            {
                found = _text.IndexOf(query, StringComparison.CurrentCultureIgnoreCase);
            }
        }

        if (found < 0)
        {
            SystemSound.Beep();
            return;
        }

        SetSelection(new NoteRange(found, query.Length));
        _box.Document.Selection.ScrollIntoView(PointOptions.None);
    }

    /// <summary>在正文里标出第一处命中（全部便签窗口从搜索结果打开一条时）。</summary>
    public void Reveal(NoteRange range)
    {
        SetSelection(range);
        _box.Document.Selection.ScrollIntoView(PointOptions.None);
    }

    // ---- 图片 ----

    /// <summary>粘贴里有图（第 7 批：存进图片目录再插进正文）；这一批还没有，返回 false 照文字粘。</summary>
    private partial Task<bool> PasteImagesAsync(DataPackageView content);

    /// <summary>把正文里占位的 U+FFFC 一张张换成图（从图片目录读；读不到的留着空位）。</summary>
    private partial Task LoadImagesAsync();
}
