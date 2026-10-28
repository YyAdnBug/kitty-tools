// 快捷键速查表（PLAN-v8 第 4 批 H8，照 mac 的 Settings/ShortcutsSheet.swift）：设置各页标题下面一行「查看全部快捷键…」，
// 点开是一个对话框：左栏按设置页分类（20 的家族色块 + 页名，顶上搜索框），右边只列选中那一类的几组（家族色块 + 组名，键帽）。
// 从哪一页点开就停在哪一类；搜索框一打开就有焦点，打字跨类找（说明、按键、组名都算），Esc 先清空搜索再关。
// 全局快捷键从 SettingsDefaults 实时读（当前设的组合，没设写「未设置」）；面板里的按键散在各面板的按键处理里、
// 没有集中定义，就集中写在本文件的 Groups 里，每组注明对应的代码。**改了面板按键要同步这里。**
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI;

namespace KittyTools;

/// <summary>一行：几种按法（每种是「Ctrl+C」这样用 + 连起来的一个组合）和它做什么。</summary>
internal sealed record ShortcutEntry(IReadOnlyList<string> Keys, string Text)
{
    public ShortcutEntry(string key, string text)
        : this(new[] { key }, text)
    {
    }

    public ShortcutEntry(string key, string other, string text)
        : this(new[] { key, other }, text)
    {
    }
}

/// <summary>一组：属于哪一页、组名、家族色、符号、这一组的全局快捷动作、面板里的按键。</summary>
internal sealed record ShortcutGroup(
    string Page, string Title, string Family, string Glyph, IReadOnlyList<string> Globals, IReadOnlyList<ShortcutEntry> Entries);

internal static class ShortcutsSheet
{
    /// <summary>左栏的分类（就是设置页），按这个顺序排。</summary>
    private static readonly (string Page, string Title, string Glyph)[] Pages =
    {
        ("clipboard", "剪贴板", ""),
        ("launcher", "启动器", ""),
        ("translate", "翻译", ""),
        ("screenshot", "截图与录制", ""),
        ("general", "设置窗", ""),
    };

    /// <summary>在设置窗上弹出速查表，停在 <paramref name="page"/> 那一类（不是这几类的停在第一类）。</summary>
    public static async Task ShowAsync(XamlRoot root, string? page)
    {
        var groups = Groups();
        var selected = Pages.Any(item => item.Page == page) ? page! : Pages[0].Page;
        var search = new TextBox { PlaceholderText = "搜索快捷键", Margin = new Thickness(0, 0, 0, 8) };
        AutomationProperties.SetName(search, "搜索快捷键");
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single };
        foreach (var (tag, title, glyph) in Pages)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Tag = tag };
            row.Children.Add(KindTile.Create(Family(tag), glyph, 20));
            row.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
            AutomationProperties.SetName(row, title);
            list.Items.Add(row);
        }

        var left = new Grid { Width = 168 };
        left.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        left.Children.Add(search);
        Grid.SetRow(list, 1);
        left.Children.Add(list);

        var right = new StackPanel { Spacing = 4, Padding = new Thickness(16, 0, 8, 8) };
        var scroll = new ScrollViewer { Content = right, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var body = new Grid { Width = 680, Height = 440, ColumnSpacing = 8 };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.Children.Add(left);
        Grid.SetColumn(scroll, 1);
        body.Children.Add(scroll);

        void Render()
        {
            right.Children.Clear();
            var query = search.Text.Trim();
            var shown = query.Length == 0
                ? groups.Where(group => group.Page == selected).ToList()
                : groups.Select(group => Filter(group, query)).OfType<ShortcutGroup>().ToList();
            if (shown.Count == 0)
            {
                right.Children.Add(EmptyState.Create(Glyphs.Search, "没有匹配的快捷键", "换个关键词试试"));
                return;
            }

            foreach (var group in shown)
            {
                right.Children.Add(GroupView(group));
            }

            scroll.ChangeView(null, 0, null, disableAnimation: true);
        }

        list.SelectedIndex = Array.FindIndex(Pages, item => item.Page == selected);
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is FrameworkElement { Tag: string tag })
            {
                selected = tag;
                search.Text = string.Empty;
                Render();
            }
        };
        search.TextChanged += (_, _) => Render();
        // Esc 先清空搜索，再关（ContentDialog 自己的 Esc 在这之后）。
        search.PreviewKeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Escape && search.Text.Length > 0)
            {
                search.Text = string.Empty;
                args.Handled = true;
            }
        };
        Render();

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "快捷键速查",
            Content = body,
            CloseButtonText = "完成",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        // ContentDialog 默认最宽 548，装不下两栏。
        dialog.Resources["ContentDialogMaxWidth"] = 760.0;
        dialog.Opened += (_, _) => search.Focus(FocusState.Programmatic);
        await dialog.ShowAsync();
    }

    /// <summary>--ui-snapshots：搜不到时的空状态 + 剪贴板那一类的几组（不弹对话框）。</summary>
    internal static FrameworkElement ProbeView()
    {
        var panel = new StackPanel { Spacing = 4, Padding = new Thickness(16, 0, 8, 8) };
        panel.Children.Add(EmptyState.Create(Glyphs.Search, "没有匹配的快捷键", "换个关键词试试"));
        foreach (var group in Groups().Where(group => group.Page == "clipboard"))
        {
            panel.Children.Add(GroupView(group));
        }

        return panel;
    }

    /// <summary>搜索：说明、按键、组名里都要有每一个词；整组标题命中就整组留着。</summary>
    private static ShortcutGroup? Filter(ShortcutGroup group, string query)
    {
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        bool Hits(string text) => words.All(word => (group.Title + " " + text).Contains(word, StringComparison.OrdinalIgnoreCase));
        if (Hits(string.Empty))
        {
            return group;
        }

        var globals = group.Globals.Where(action => Hits(GlobalTitle(action) + " " + GlobalKeys(action))).ToList();
        var entries = group.Entries.Where(entry => Hits(entry.Text + " " + string.Join(' ', entry.Keys))).ToList();
        return globals.Count + entries.Count == 0 ? null : group with { Globals = globals, Entries = entries };
    }

    private static StackPanel GroupView(ShortcutGroup group)
    {
        var panel = new StackPanel { Spacing = 2, Margin = new Thickness(0, 12, 0, 0) };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 4) };
        header.Children.Add(KindTile.Create(group.Family, group.Glyph, 20));
        header.Children.Add(new TextBlock
        {
            Text = group.Title,
            FontWeight = FontWeights.SemiBold,
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        panel.Children.Add(header);
        foreach (var action in group.Globals)
        {
            var keys = GlobalKeys(action);
            panel.Children.Add(Row(GlobalTitle(action), keys.Length == 0 ? null : new[] { keys }, global: true));
        }

        foreach (var entry in group.Entries)
        {
            panel.Children.Add(Row(entry.Text, entry.Keys, global: false));
        }

        return panel;
    }

    /// <summary>一行：左边说明（全局的后面带一个「全局」小字），右边键帽；几种按法之间用「/」隔开。</summary>
    private static Grid Row(string text, IReadOnlyList<string>? keys, bool global)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            FontSize = Theme.FontSize("Kitty.FontSize.Body"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (global)
        {
            label.Children.Add(new TextBlock
            {
                Text = "全局",
                FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                Foreground = Theme.TertiaryText(),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        row.Children.Add(label);
        var keysPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (keys is null || keys.Count == 0)
        {
            keysPanel.Children.Add(new TextBlock
            {
                Text = "未设置",
                FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
                Foreground = Theme.SecondaryText(),
            });
        }
        else
        {
            for (var index = 0; index < keys.Count; index++)
            {
                if (index > 0)
                {
                    keysPanel.Children.Add(new TextBlock
                    {
                        Text = "/",
                        Foreground = Theme.SecondaryText(),
                        VerticalAlignment = VerticalAlignment.Center,
                    });
                }

                keysPanel.Children.Add(KeyCap.Combo(Split(keys[index])));
            }
        }

        Grid.SetColumn(keysPanel, 1);
        row.Children.Add(keysPanel);
        AutomationProperties.SetName(row, keys is null || keys.Count == 0 ? $"{text}，未设置" : $"{text}，{string.Join(" 或 ", keys)}");
        return row;
    }

    /// <summary>「Ctrl+Shift+S」拆成每个键一个键帽；「+」本身（放大字号那种）不拆。</summary>
    private static IEnumerable<string> Split(string combo)
        => combo.Length > 1 && combo.Contains('+') && !combo.EndsWith("++", StringComparison.Ordinal)
            ? combo.Split('+')
            : new[] { combo };

    private static string GlobalTitle(string action) => SettingsDefaults.Find(action)?.DisplayName ?? action;

    /// <summary>这个全局动作现在设的组合（「Alt+C」），没设返回空。</summary>
    private static string GlobalKeys(string action)
    {
        var binding = SettingsDefaults.BindingFor(SettingsService.Current, action);
        return binding.VirtualKey == 0 ? string.Empty : HotKeyRules.Format(binding.VirtualKey, binding.Modifiers);
    }

    private static string Family(string page) => page switch
    {
        "clipboard" => "clipboard",
        "launcher" => "launcher",
        "translate" => "translate",
        "screenshot" => "capture",
        _ => "general",
    };

    /// <summary>全部的组（按页排好）。面板里的按键照各面板的按键处理抄过来，改了那边要同步这里。</summary>
    private static List<ShortcutGroup> Groups() => new()
    {
        // Clipboard/ClipboardPanel.xaml.cs 的 OnKeyDown / OnKeyUp。
        new("clipboard", "剪贴板", "clipboard", Glyphs.Copy, new[] { HotKeyActions.Clipboard }, new ShortcutEntry[]
        {
            new("Enter", "粘贴选中的条目（多选时合并 / 一起 / 依次粘贴）"),
            new("Shift+Enter", "粘贴为纯文本"),
            new("Ctrl+Enter", "Ctrl+C", "只复制，不粘贴（收起面板时挪到最前）"),
            new("Ctrl+1–9", "直接粘贴第 1–9 条"),
            new("Ctrl", "按住一会儿，前 9 行右边浮出 1–9 的键帽"),
            new("↑↓", "移动选中，透镜跟着走（到头绕回）"),
            new("Shift+↑↓", "从选中的那条起整段多选"),
            new("Ctrl+单击", "Shift+单击", "多选：逐条勾选 / 选一段"),
            new("Ctrl+A", "全选（搜索框空着时）"),
            new("Tab", "打开筛选面板（收藏、收藏夹、片段、类型、形态、来源），打字过滤"),
            new("Shift+Tab", "范围在 全部 → 收藏 → 片段 之间切换"),
            new("Backspace", "搜索框空着时：第一下选中最后一个标签，第二下删掉"),
            new("Ctrl+K", "→", "打开操作面板（打字过滤，→ 进子列表，← 回上一级）"),
            new("Ctrl+O", "打开链接 / 用默认程序打开文件"),
            new("Ctrl+R", "在资源管理器中显示（文件）"),
            new("Ctrl+Shift+C", "复制路径（文件）"),
            new("Ctrl+T", "翻译（文本，或识别出文字的图片）"),
            new("Ctrl+D", "收藏 / 取消收藏（取消时同时移出收藏夹）"),
            new("Ctrl+E", "编辑内容（文本）"),
            new("Ctrl+N", "新建片段"),
            new("Delete", "删除选中的"),
            new("Ctrl+Z", "撤销（删除、删收藏夹、取消收藏后超期的）"),
            new("Ctrl+P", "固定 / 取消固定（固定后点面板外面不收起）"),
            new("Ctrl+,", "打开设置 › 剪贴板"),
            new("Esc", "逐级退出：菜单、标签待删、搜索词、多选，最后收起"),
            new("Ctrl+W", "收起"),
        }),

        // Launcher/LauncherPanel.xaml.cs 的 OnKeyDown，各键做什么在 LauncherModel（PLAN-v9-launcher K1–K9）。
        new("launcher", "启动器", "launcher", Glyphs.Search, new[] { HotKeyActions.Launcher }, new ShortcutEntry[]
        {
            new("Enter", "打开选中项（计算结果是粘贴，find 搜到的文件是在资源管理器中显示）；关机、结束进程这类要再按一次确认"),
            new("Ctrl+Enter", "在资源管理器中显示（计算结果只复制，网址用别的浏览器打开，quit 里是强制退出）"),
            new("Alt+Enter", "在资源管理器里搜索输入的字"),
            new("Shift+Enter", "用兜底搜索在网上搜输入的字"),
            new("Ctrl+Shift+Enter", "以管理员身份运行（应用）"),
            new("Tab", "补全到搜索框（计算结果接着算，文件夹接着往下找）"),
            new("Ctrl+C", "复制路径、网址或结果"),
            new("Ctrl+Shift+C", "网址复制为 Markdown 链接"),
            new("Ctrl+D", "加入 / 取消收藏（最多 8 个）"),
            new("Ctrl+Alt+↑↓", "调整收藏的顺序"),
            new("Ctrl+Delete", "从「常用」里移除选中的一项（Ctrl+Z 撤销）"),
            new("Ctrl+K", "打开操作菜单（光标在末尾时按 → 也行；右键是同一份）"),
            new("Ctrl+1–9", "打开第 1–9 项"),
            new("Ctrl", "按住一会儿，前 9 行右边换成 Ctrl+1–9 的键帽；按住 Ctrl / Alt / Shift 时选中行写着松手前按 Enter 会做什么"),
            new("↑↓", "移动选中（到头从另一头接着）"),
            new("Ctrl+,", "打开 设置 › 启动器"),
            new("Esc", "先关菜单、撤掉等确认的那一下，再清空搜索，最后收起"),
        }),

        // Core/LauncherCommands.cs、WebSearch.cs，Launcher/SystemCommands.cs。
        new("launcher", "启动器 · 输入", "launcher", Glyphs.CommandPrompt, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("空格", "开头打一个空格：搜文件"),
            new("open", "find", "搜文件并打开 / 在资源管理器中显示（后面不打字列最近打开的）"),
            new(new[] { "quit", "hide", "forcequit" }, "列出正在运行的应用：退出（关窗口）/ 最小化 / 强制退出"),
            new("kill", "列出后台进程：Enter 结束（再按一次确认）；「kill :3000」按端口找"),
            new("port", "列出在监听的端口：Enter 结束占着它的进程（有窗口的程序是退出）"),
            new("cb", "在剪贴板历史里搜"),
            new("fy", "翻译输入的文字"),
            new("ip", "本机的局域网 / 内网地址和外网地址（外网要联网查）：Enter 粘贴，Ctrl+Enter 只复制"),
            new(new[] { "g", "bing", "bd", "gh" }, "关键词 + 空格 + 要搜的字：网页搜索（设置 › 启动器 里能加能改）"),
            new(new[] { "lock", "sleep", "emptytrash" }, "系统命令（锁定、睡眠、关闭显示器、屏保、回收站、注销、重启、关机、音量）：中文、英文、拼音都能搜"),
        }),

        // Translate/TranslateWindow.cs 的 OnSourceKeyDown（焦点在原文框里时）。
        new("translate", "翻译", "translate", Glyphs.Translate,
            new[] { HotKeyActions.SelectionTranslate, HotKeyActions.InputTranslate, HotKeyActions.ScreenshotTranslate },
            new ShortcutEntry[]
            {
                new("Enter", "翻译"),
                new("Shift+Enter", "换行"),
                new("Ctrl+1–9", "复制第 1–9 个结果"),
                new("Ctrl+H", "打开翻译历史"),
                new("Ctrl+P", "固定 / 取消固定浮窗（固定后点别处不收起）"),
                new("Esc", "Ctrl+W", "关闭（历史开着时 Esc 先回到浮窗）"),
            }),

        // TranslateWindow.cs 的 OnHistoryKeyDown（焦点在历史的搜索框里时）。
        new("translate", "翻译 · 历史", "translate", Glyphs.History, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("↑↓", "移动选中"),
            new("Enter", "重新翻译这条"),
            new("Ctrl+C", "复制译文"),
            new("Ctrl+Shift+C", "复制原文"),
            new("Ctrl+D", "收藏 / 取消收藏"),
            new("Delete", "删除"),
            new("Ctrl+Z", "撤销删除"),
            new("Esc", "回到浮窗"),
        }),

        // Screenshot/SelectionOverlayWindow.cs 的 OnKeyDown 和鼠标处理。
        new("screenshot", "截图 · 框选", "capture", Glyphs.Screenshot,
            new[] { HotKeyActions.Screenshot, HotKeyActions.ScreenshotLast, HotKeyActions.Ocr },
            new ShortcutEntry[]
            {
                new("Shift", "拉框时锁定成正方形（尺寸胶囊锁了比例时按那个比例）"),
                new("Alt", "拉框时从中心往外拉"),
                new("空格", "拉框时按住：整块平移"),
                new("Ctrl", "按住出十字准线"),
                new("单击", "选中鼠标下面的整个窗口"),
                new("双击", "没选工具时双击选区：拷贝（录屏时是开始录）"),
                new("右键", "清掉选区；没有选区时退出（画了标注时不清）"),
                new(new[] { "←", "→", "↑", "↓" }, "挪选区（选中标注时挪标注）1 px，Shift 10 px"),
                new(new[] { "Ctrl+方向键", "Alt+方向键" }, "那条边往外推 / 往里收"),
                new("D", "跳到上次截的区域"),
                new("C", "复制放大镜里的色值"),
                new("Esc", "逐级退出：收下正在输入的文字、取消选中的标注、收起工具，最后退出截图"),
                new("Ctrl+W", "退出截图"),
            }),
        new("screenshot", "截图 · 标注", "capture", Glyphs.Edit, Array.Empty<string>(), new ShortcutEntry[]
        {
            new(new[] { "1", "2", "3", "4", "5" }, "矩形 · 椭圆 · 箭头 · 直线 · 画笔"),
            new(new[] { "6", "7", "8", "9", "0" }, "荧光笔 · 文字 · 序号 · 马赛克 · 聚光灯（再按一次收起工具）"),
            new("Delete", "Backspace", "删除选中的标注"),
            new(new[] { "Ctrl+Z", "Ctrl+Y", "Ctrl+Shift+Z" }, "撤销 / 重做"),
            new("Ctrl+Enter", "Esc", "文字框里收下文字（Enter 是换行；点外面也收下）"),
        }),
        new("screenshot", "截图 · 出图", "capture", Glyphs.Save, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("Enter", "Ctrl+C", "拷贝（识字 / 截图翻译时是确认，录屏时是开始录）"),
            new("Ctrl+S", "快速保存"),
            new("Ctrl+Shift+S", "另存为…"),
            new("P", "钉在屏幕上"),
            new("S", "Shift+S", "长截图：往下滚 / 往上滚"),
            new("R", "切到录屏（录屏功能开着时；画了标注不切）"),
            new("O", "识字并拷贝"),
            new("T", "截图翻译"),
        }),

        // ScrollingCapture.cs（长截图期间临时注册的键）、PinWindow.cs、RecordingCountdown.cs。
        new("screenshot", "长截图", "capture", Glyphs.Down, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("Enter", "拼好，拷贝"),
            new("Esc", "放弃"),
        }),
        new("screenshot", "钉图", "capture", Glyphs.Pin, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("滚轮", "缩放（10%–500%）"),
            new("0", "恢复 100%"),
            new("Ctrl+C", "拷贝"),
            new("Ctrl+S", "快速保存"),
            new("Ctrl+Shift+S", "另存为…"),
            new("O", "识字并拷贝"),
            new("Esc", "双击", "关闭"),
        }),
        new("screenshot", "录制", "capture", Glyphs.Record, new[] { HotKeyActions.Record }, new ShortcutEntry[]
        {
            new("Esc", "倒数的时候取消"),
        }),

        // Screenshot/ShotHistoryWindow.cs。
        new("screenshot", "截图历史", "capture", Glyphs.History, new[] { HotKeyActions.ShotHistory }, new ShortcutEntry[]
        {
            new("双击", "改标注（录制的是用默认程序打开）"),
            new("右键", "这一条的全部操作"),
            new("Delete", "删掉选中的那条（先问一次）"),
        }),

        // Settings/SettingsWindow.cs 的 OnRecordKeyDown（只在录快捷键时）。
        new("general", "设置窗", "general", Glyphs.Settings, Array.Empty<string>(), new ShortcutEntry[]
        {
            new("Esc", "录快捷键时取消；按下带 Ctrl / Alt / Shift / Win 的组合就存成新的"),
        }),
    };
}
