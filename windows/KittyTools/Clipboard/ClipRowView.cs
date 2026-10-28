// 剪贴板列表的一行、分组标题、「＋ 新建片段」行（照 mac ClipRowView.swift / mac-whisker-clipboard「列表」）。
// 行 40：内边距 10、[勾选圈 15] 图标块 24、标题（14 号；代码 / JSON 等宽 13）、右侧「来源 · 多久前」或备注（最宽 220）、
// 标记（收藏夹胶囊、带格式、片段、黄色 ★）、按住 Ctrl 才出的数字键帽，间距都是 10。
// 图标块：颜色 = 色块 → 图片 = 缩略图 → 有来源程序 = 程序图标（代码 / JSON / 链接右下角加 11 的角标）→ 种类色块。
// 都是代码建的，焦点不进来（焦点一直在搜索框）；事件由 ClipListView 接。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace KittyTools;

/// <summary>建一行时要知道的面板状态。</summary>
internal sealed record ClipRowContext(string Query, bool ShowsGroupPill, bool ShowsKeyHints, bool Multi, double Scale);

internal sealed partial class ClipRowView : Grid
{
    public const double Spacing = ClipLens.RowSpacing;

    private readonly Border _check;
    private readonly Border _keyCap;
    private bool _hovered;
    private bool _checked;
    private bool _selected;

    public ClipRowView(ClipEntry entry, int index, ClipRowContext context)
    {
        Entry = entry;
        Index = index;
        Height = ClipLens.Head;
        Padding = new Thickness(ClipLens.RowPadding, 0, ClipLens.RowPadding, 0);
        ColumnSpacing = Spacing;
        CornerRadius = Theme.Corner("Kitty.Corner.Control");
        Background = new SolidColorBrush(Colors.Transparent);
        for (var column = 0; column < 6; column++)
        {
            ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = column == 2 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto,
            });
        }

        // 0：多选时的勾选圈（15，品牌粉）。
        _check = new Border
        {
            Width = 15,
            Height = 15,
            CornerRadius = new CornerRadius(7.5),
            BorderThickness = new Thickness(1.2),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = context.Multi ? Visibility.Visible : Visibility.Collapsed,
            Child = new FontIcon
            {
                Glyph = Glyphs.Check,
                FontSize = 9,
                Foreground = new SolidColorBrush(Colors.White),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        Children.Add(_check);

        // 1：图标块。
        var tile = IconTile(entry, context.Scale);
        SetColumn(tile, 1);
        Children.Add(tile);

        // 2：标题。
        var form = entry.Kind == ClipKind.Text ? ContentForms.Detect(entry.Text) : null;
        var title = TitleBlock(entry, form, context.Query);
        SetColumn(title, 2);
        Children.Add(title);

        // 3：右侧文字（备注优先）。
        var hasNote = !string.IsNullOrWhiteSpace(entry.Note);
        var trailing = new TextBlock
        {
            Text = hasNote ? OneLine(entry.Note!) : Trailing(entry),
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = hasNote ? Theme.SecondaryText() : Tertiary(),
            MaxWidth = ClipLens.TrailingMax,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        SetColumn(trailing, 3);
        Children.Add(trailing);

        // 4：标记（收藏夹胶囊、带格式、片段、星）；没收藏时星连间距都不占。
        var markers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Spacing, VerticalAlignment = VerticalAlignment.Center };
        if (context.ShowsGroupPill && ClipboardService.Instance?.Store.GroupName(entry.GroupId) is { } group)
        {
            markers.Children.Add(new Border
            {
                CornerRadius = Theme.Corner("Kitty.Corner.Control"),
                Background = Theme.Brush("Kitty.Fill.Control", Color.FromArgb(20, 128, 128, 128)),
                Padding = new Thickness(6, 1, 6, 1),
                Child = new TextBlock { Text = group, FontSize = 11, Foreground = Theme.SecondaryText() },
            });
        }

        if (entry.Rich)
        {
            markers.Children.Add(Marker(Glyphs.RichText, Tertiary(), "带格式"));
        }

        if (entry.Snippet)
        {
            markers.Children.Add(Marker(Glyphs.Snippet, Tertiary(), "片段"));
        }

        if (entry.Favorite)
        {
            markers.Children.Add(Marker(Glyphs.StarFilled, Theme.Brush("Kitty.Favorite", Color.FromArgb(255, 255, 204, 0)), "收藏"));
        }

        if (markers.Children.Count == 0)
        {
            markers.Visibility = Visibility.Collapsed;
        }

        SetColumn(markers, 4);
        Children.Add(markers);

        // 5：按住 Ctrl 才出的数字键帽（前 9 行）。
        _keyCap = KeyCap.Create(index < 9 ? (index + 1).ToString() : string.Empty);
        _keyCap.VerticalAlignment = VerticalAlignment.Center;
        _keyCap.Visibility = context.ShowsKeyHints && index < 9 ? Visibility.Visible : Visibility.Collapsed;
        SetColumn(_keyCap, 5);
        Children.Add(_keyCap);

        AutomationProperties.SetName(this, $"{TitleText(entry)}，{(hasNote ? entry.Note : Trailing(entry))}");
        ApplyBackground();
    }

    internal ClipEntry Entry { get; }

    internal int Index { get; }

    public void SetHovered(bool hovered)
    {
        _hovered = hovered;
        ApplyBackground();
    }

    public void SetSelected(bool selected)
    {
        _selected = selected;
        ApplyBackground();
        AutomationProperties.SetItemStatus(this, selected ? "已选中" : string.Empty);
    }

    /// <summary>多选：null = 不在多选状态（勾选圈收起）。</summary>
    public void SetChecked(bool? isChecked)
    {
        _checked = isChecked == true;
        _check.Visibility = isChecked is null ? Visibility.Collapsed : Visibility.Visible;
        var accent = Theme.AccentColor;
        _check.Background = new SolidColorBrush(_checked ? accent : Colors.Transparent);
        _check.BorderBrush = _checked ? new SolidColorBrush(accent) : Theme.SecondaryText();
        _check.Child.Visibility = _checked ? Visibility.Visible : Visibility.Collapsed;
        ApplyBackground();
    }

    public void SetKeyHint(bool show) => _keyCap.Visibility = show && Index < 9 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>勾中的行铺品牌粉 0.14；悬停（不是选中行）出 Fill.Hover；选中行的底是列表背后那块高亮。</summary>
    private void ApplyBackground()
    {
        if (_checked)
        {
            var accent = Theme.AccentColor;
            Background = new SolidColorBrush(Color.FromArgb(36, accent.R, accent.G, accent.B));
        }
        else if (_hovered && !_selected)
        {
            Background = Theme.Brush("Kitty.Fill.Hover", Color.FromArgb(10, 0, 0, 0));
        }
        else
        {
            Background = new SolidColorBrush(Colors.Transparent);
        }
    }

    private static FontIcon Marker(string glyph, Brush brush, string name)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = 11, Foreground = brush, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(icon, name);
        return icon;
    }

    private static Brush Tertiary() => Theme.Brush("Kitty.Text.Tertiary", Color.FromArgb(140, 0, 0, 0));

    /// <summary>行标题（同 mac ClipItem.title）。</summary>
    public static string TitleText(ClipEntry entry) => entry.Kind switch
    {
        ClipKind.Image => entry.Width > 0 ? $"图片 {entry.Width}×{entry.Height}" : "图片",
        ClipKind.Files => string.Join("、", entry.Files.Select(file => System.IO.Path.GetFileName(file.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : file)),
        _ => ClipLens.TextTitle(entry.Text) is { Length: > 0 } title ? title : "（空白）",
    };

    /// <summary>
    /// 标题：有搜索词时从第一个命中处截取、命中词黄 0.35 底（标题本来就显示得全的一行文本不摘录）；
    /// 靠识别文字搜到的图片在「图片 宽×高」后面接命中的那段。
    /// </summary>
    private static TextBlock TitleBlock(ClipEntry entry, ContentForm? form, string query)
    {
        var code = form is ContentForm.Code or ContentForm.Json;
        var text = TitleText(entry);
        if (query.Length > 0)
        {
            if (entry.Kind == ClipKind.Image && ClipboardStore.OcrSnippet(entry, query) is { } hit)
            {
                text += "  " + hit;
            }
            else if (entry.Kind == ClipKind.Text && Search.Excerpt(text, query) is { } excerpt)
            {
                text = excerpt;
            }
        }

        var block = new TextBlock
        {
            Text = text,
            FontSize = code ? 13 : Theme.FontSize("Kitty.FontSize.RowTitle"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (code)
        {
            block.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        }

        if (query.Length > 0)
        {
            var highlighter = new TextHighlighter
            {
                Background = new SolidColorBrush(Color.FromArgb(89, 255, 204, 0)),
            };
            foreach (var (start, length) in Search.HitRanges(text, query))
            {
                highlighter.Ranges.Add(new TextRange { StartIndex = start, Length = length });
            }

            if (highlighter.Ranges.Count > 0)
            {
                block.TextHighlighters.Add(highlighter);
            }
        }

        return block;
    }

    /// <summary>「来源 · 多久前」。</summary>
    private static string Trailing(ClipEntry entry)
        => string.IsNullOrEmpty(entry.SourceName) ? Relative(entry.CopiedAt) : $"{entry.SourceName} · {Relative(entry.CopiedAt)}";

    private static string OneLine(string text) => ClipLens.TextTitle(text);

    internal static string Relative(long copiedAt)
    {
        var then = DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime();
        var span = DateTimeOffset.Now - then;
        if (span.TotalSeconds < 60)
        {
            return "刚刚";
        }

        if (span.TotalMinutes < 60)
        {
            return $"{(int)span.TotalMinutes} 分钟前";
        }

        if (then.Date == DateTime.Today)
        {
            return $"{(int)span.TotalHours} 小时前";
        }

        if (then.Date == DateTime.Today.AddDays(-1))
        {
            return "昨天";
        }

        var days = (DateTime.Today - then.Date).Days;
        return days < 7 ? $"{days} 天前" : then.Date.Year == DateTime.Today.Year ? then.ToString("M月d日") : then.ToString("yyyy年M月d日");
    }

    /// <summary>分组标题的日期（今天 / 昨天 / 10 月 26 日）。</summary>
    public static string DateLabel(long copiedAt)
    {
        var local = DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime().Date;
        var today = DateTime.Today;
        if (local == today)
        {
            return "今天";
        }

        if (local == today.AddDays(-1))
        {
            return "昨天";
        }

        return local.Year == today.Year ? $"{local.Month} 月 {local.Day} 日" : $"{local.Year} 年 {local.Month} 月 {local.Day} 日";
    }

    /// <summary>分组按的那一天（本地零点的 ticks）：过了午夜只改标题不换组。</summary>
    public static long DayKey(long copiedAt) => DateTimeOffset.FromUnixTimeMilliseconds(copiedAt).ToLocalTime().Date.Ticks;

    /// <summary>行首 24 的图标块。</summary>
    public static FrameworkElement IconTile(ClipEntry entry, double scale)
    {
        const double side = 24;
        var corner = new CornerRadius(side * 0.225);
        var form = entry.Kind == ClipKind.Text ? ContentForms.Detect(entry.Text) : null;

        // 颜色：色块（垫棋盘格，白 0.2 内描边）。
        if (form == ContentForm.Color && ContentForms.Color(entry.Text) is { } rgba)
        {
            var swatch = new Grid { Width = side, Height = side, CornerRadius = corner };
            if (rgba.Alpha < 1)
            {
                swatch.Children.Add(Checker(side));
            }

            swatch.Children.Add(new Border
            {
                CornerRadius = corner,
                Background = new SolidColorBrush(Color.FromArgb(
                    (byte)Math.Round(rgba.Alpha * 255), (byte)Math.Round(rgba.Red * 255),
                    (byte)Math.Round(rgba.Green * 255), (byte)Math.Round(rgba.Blue * 255))),
                BorderBrush = new SolidColorBrush(Color.FromArgb(51, 255, 255, 255)),
                BorderThickness = new Thickness(1),
            });
            swatch.VerticalAlignment = VerticalAlignment.Center;
            return swatch;
        }

        // 图片：缩略图铺满裁切。
        if (entry.Kind == ClipKind.Image)
        {
            var thumb = new Border
            {
                Width = side,
                Height = side,
                CornerRadius = corner,
                Background = Theme.Family.Tint(Theme.Family.Capture, 40),
                VerticalAlignment = VerticalAlignment.Center,
            };
            void Show(ImageSource image) => thumb.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill };
            if (ClipIcons.Thumbnail(entry.Id, Paths.ImagesFile(entry.Id), scale, Show) is { } cached)
            {
                Show(cached);
            }

            return thumb;
        }

        var (family, glyph) = KindOf(entry, form);
        var grid = new Grid { Width = side, Height = side, VerticalAlignment = VerticalAlignment.Center };
        var kindTile = KindTile.Create(family, glyph, side);
        grid.Children.Add(kindTile);

        // 有来源程序：换成程序图标；代码 / JSON / 链接右下角加 11 的角标。
        if (!string.IsNullOrEmpty(entry.SourceExe) && System.IO.Path.IsPathRooted(entry.SourceExe))
        {
            var app = new Border { Width = side, Height = side };
            void ShowApp(ImageSource image)
            {
                app.Background = new ImageBrush { ImageSource = image, Stretch = Stretch.Uniform };
                kindTile.Visibility = Visibility.Collapsed;
            }

            if (ClipIcons.AppIcon(entry.SourceExe, scale, ShowApp) is { } cachedApp)
            {
                ShowApp(cachedApp);
            }

            grid.Children.Add(app);
            if (form is ContentForm.Code or ContentForm.Json or ContentForm.Link)
            {
                var badge = KindTile.Create(family, glyph, 11);
                badge.HorizontalAlignment = HorizontalAlignment.Right;
                badge.VerticalAlignment = VerticalAlignment.Bottom;
                badge.Margin = new Thickness(0, 0, -2, -2);
                badge.Visibility = Visibility.Collapsed;
                void ShowBadge(ImageSource _) => badge.Visibility = Visibility.Visible;
                if (app.Background is ImageBrush)
                {
                    badge.Visibility = Visibility.Visible;
                }
                else
                {
                    ClipIcons.AppIcon(entry.SourceExe, scale, ShowBadge);
                }

                grid.Children.Add(badge);
            }
        }

        return grid;
    }

    /// <summary>种类色块的家族色和符号。</summary>
    public static (string Family, string Glyph) KindOf(ClipEntry entry, ContentForm? form) => entry.Kind switch
    {
        ClipKind.Image => ("capture", Glyphs.Image),
        ClipKind.Files => ("shortcut", entry.Files.Length == 1 && !System.IO.Directory.Exists(entry.Files[0]) ? Glyphs.File : Glyphs.Folder),
        _ => form switch
        {
            ContentForm.Color => ("general", Glyphs.Palette),
            ContentForm.Json or ContentForm.Code => ("search", Glyphs.Code),
            ContentForm.Link => ("url", Glyphs.Link),
            _ => ("clipboard", Glyphs.Paste),
        },
    };

    /// <summary>透明色块 / 图片后面的棋盘格（4 × 4 一格）。</summary>
    public static FrameworkElement Checker(double side, double cell = 4)
    {
        var canvas = new Canvas { Width = side, Height = side, Background = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)) };
        var dark = new SolidColorBrush(Color.FromArgb(255, 214, 214, 214));
        for (var row = 0; row * cell < side; row++)
        {
            for (var column = 0; column * cell < side; column++)
            {
                if ((row + column) % 2 == 0)
                {
                    continue;
                }

                var square = new Rectangle { Width = cell, Height = cell, Fill = dark };
                Canvas.SetLeft(square, column * cell);
                Canvas.SetTop(square, row * cell);
                canvas.Children.Add(square);
            }
        }

        return canvas;
    }
}

/// <summary>分组标题 24：「今天 · 12」12 semibold tertiary + 一条发丝线延伸到右边。吸顶的那条另加材质底。</summary>
internal static class ClipHeaderView
{
    public static Grid Create(string day, int count, bool sticky)
    {
        var grid = new Grid
        {
            Height = ClipListLayout.HeaderHeight,
            Padding = new Thickness(ClipLens.RowPadding, 0, ClipLens.RowPadding, 0),
            ColumnSpacing = 8,
            Background = sticky ? Theme.Brush("Kitty.CardSolid", Color.FromArgb(255, 251, 251, 251)) : null,
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var label = new TextBlock
        {
            Text = $"{day} · {count}",
            FontSize = Theme.FontSize("Kitty.FontSize.GroupHeader"),
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush("Kitty.Text.Tertiary", Color.FromArgb(140, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        grid.Children.Add(label);
        var line = new Border
        {
            Height = 1,
            Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(line, 1);
        grid.Children.Add(line);
        if (sticky)
        {
            // 吸顶的那条不进读屏（列表里那条读得到），也不接点击。
            AutomationProperties.SetAccessibilityView(grid, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            grid.IsHitTestVisible = false;
        }

        return grid;
    }

    /// <summary>片段范围第一行「＋ 新建片段 Ctrl+N」：虚线框，40 高的行里上下各让 2。</summary>
    public static Grid NewSnippetRow()
    {
        var grid = new Grid { Height = ClipListLayout.NewSnippetHeight, Background = new SolidColorBrush(Colors.Transparent) };
        grid.Children.Add(new Rectangle
        {
            Margin = new Thickness(0, 2, 0, 2),
            RadiusX = 4,
            RadiusY = 4,
            Stroke = Theme.Brush("Kitty.Text.Tertiary", Color.FromArgb(140, 0, 0, 0)),
            StrokeThickness = 1,
            StrokeDashArray = new DoubleCollection { 4, 3 },
        });
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(ClipLens.RowPadding, 0, ClipLens.RowPadding, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(new FontIcon { Glyph = Glyphs.Add, FontSize = 12, Foreground = Theme.SecondaryText() });
        row.Children.Add(new TextBlock
        {
            Text = "新建片段",
            FontSize = Theme.FontSize("Kitty.FontSize.RowTitle"),
            Foreground = Theme.SecondaryText(),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var key = KeyCap.Create("Ctrl+N");
        key.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(key);
        grid.Children.Add(row);
        AutomationProperties.SetName(grid, "新建片段");
        return grid;
    }
}
