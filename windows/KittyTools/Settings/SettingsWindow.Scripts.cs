// 设置 › 启动器 › 脚本命令（PLAN-v18 L1 第 8 批，mac ScriptsSection / ScriptGuide / NewScriptSheet）：启动器页上一行「脚本命令 ›」，
// 点进来：总开关（默认开）、「怎么写脚本 ›」、让 AI 来写（复制给 AI 的写法说明、把 AI 给的脚本从剪贴板新建——先看全文再存）、
// 脚本文件夹（新建脚本——先出小对话框选名字、关键词、结果方式、语言；在资源管理器中打开）、一个自己的脚本都没有时「用例子新建」、
// 另加的文件夹（只读、能移除）、读不成的脚本和原因（橙字）。
// 「怎么写脚本」：让 AI 来写、三步上手、一个能直接用的例子（查天气）、开头几行能写什么、列表、用什么跑、安全和同步。
// mac 的「把脚本文件拖进来导入」没做：Windows 上直接把文件放进脚本文件夹就行（下载来的照样先看全文）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private bool _scriptsListening;

    /// <summary>「结果给谁」六种的说法（新建对话框、说明页一样）。</summary>
    private static readonly (ScriptMode Mode, string Title)[] ScriptModeTitles =
    {
        (ScriptMode.Island, "提示里显示最后一行"),
        (ScriptMode.Paste, "粘贴到前台应用"),
        (ScriptMode.Copy, "复制到剪贴板"),
        (ScriptMode.Full, "在窗口里看全部输出"),
        (ScriptMode.List, "列出几条结果来挑"),
        (ScriptMode.None, "不显示"),
    };

    /// <summary>开头能写的字段：写法、做什么、怎么填（mac ScriptGuidePage.fields，语言换成 Windows 的）。</summary>
    private static readonly (string Name, string Title, string Detail)[] ScriptFields =
    {
        ("@kitty.title", "名字", "启动器里显示的名字，不写就用文件名"),
        ("@kitty.keyword", "关键词", "在启动器里打它就排第一；「命令和别名」里还能改"),
        ("@kitty.mode", "结果给谁", "island 提示里显示最后一行（不写就是它）、paste 粘贴到前台应用、copy 复制、full 在窗口里看全部输出、list 每行一条结果可以挑、none 不显示"),
        ("@kitty.argument1", "参数（最多 3 个）",
            "写参数的名字，如「城市」；在启动器里输「关键词 空格 文字」，PowerShell 里是 $args[0]（批处理 %~1），带空格的用引号括起来（\"New York\"）。" +
            "可以不填的写成 {\"placeholder\": \"城市\", \"optional\": true}；要直接拼进网址的再加 \"percentEncoded\": true；只能从几个里挑的写 " +
            "\"type\": \"dropdown\", \"data\": [{\"title\": \"耳机\", \"value\": \"headphones\"}]（打到这里时列出来挑，交给脚本的是 value）；" +
            "密码写 \"type\": \"password\"（行上不显示、不记进使用记录，但打的时候搜索框里看得见）"),
        ("@kitty.description", "副标题", "启动器里名字下面的那行小字"),
        ("@kitty.icon", "图标", "一个 emoji、同一个文件夹里的图片文件名；深色主题换一张写在 @kitty.iconDark（这一版启动器里先都画脚本的图标）"),
        ("@kitty.confirm", "先确认再跑", "写一句话：Enter 第一下只显示这句，再按一次才跑；列表脚本打字时就跑，不能写"),
        ("@kitty.timeout", "超时", "秒数，不写是 60 秒，写 0 不限"),
        ("@kitty.filter", "只跑一次", "列表脚本才写：打完「关键词 空格」时跑一次，之后打的字由启动器按标题、说明过滤（认拼音、首字母），脚本收不到参数"),
    };

    /// <summary>启动器页上那一行：「脚本命令 ›」，小字写有几个、读不成几个。</summary>
    private void AddScriptsRow()
    {
        _content.Children.Add(SettingsUi.Section("脚本命令"));
        string detail;
        if (!SettingsService.Current.LauncherScripts)
        {
            detail = "关着";
        }
        else
        {
            var own = ScriptLibrary.Scripts.Count(script => !script.IsBundled);
            var problems = ScriptLibrary.Problems.Count;
            detail = (own > 0 ? $"{own} 个自己的脚本" : "把脚本放进文件夹，就是启动器里的一条命令") +
                     $"，{BuiltinTools.Commands.Count} 个自带的" + (problems > 0 ? $"，{problems} 个读不成" : string.Empty);
        }

        AddSubpageRow("脚本命令", detail, () => OpenLauncherSubpage("scripts"));
    }

    /// <summary>读完换上时（后台读的）：开着这一页就重画（文件夹里新放的、读不成的跟着变）。</summary>
    private void ListenScripts()
    {
        if (_scriptsListening)
        {
            return;
        }

        _scriptsListening = true;
        ScriptLibrary.Changed += () =>
        {
            if (_currentPage == "launcher" && _launcherSubpage == "scripts")
            {
                BuildPage("launcher");
            }
        };
    }

    private void BuildLauncherScripts()
    {
        ListenScripts();
        if (!ScriptLibrary.IsLoaded)
        {
            // 还没呼出过启动器：读一遍（读完 Changed 重画这一页）
            ScriptLibrary.Refresh();
        }

        var settings = SettingsService.Current;
        var on = settings.LauncherScripts;
        var back = new HyperlinkButton { Content = "‹ 启动器", Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => OpenLauncherSubpage(null);
        AutomationProperties.SetName(back, "返回启动器设置");
        _content.Children.Add(back);
        _content.Children.Add(Header("脚本命令", "脚本文件夹里的每个脚本就是启动器里的一条命令"));
        AddToggle("启用脚本命令", "PowerShell（.ps1）、批处理（.cmd）、装了 Python 时的 .py；关掉后启动器里不出、自带的几条也不出",
            on, isOn =>
            {
                settings.LauncherScripts = isOn;
                SettingsService.Save();
                TouchScriptsNew();
                ScriptLibrary.Refresh();
                BuildPage("launcher");
            });

        Button Action(string text, Action run)
        {
            var button = new Button { Content = text, IsEnabled = on };
            AutomationProperties.SetName(button, text);
            button.Click += (_, _) => run();
            return button;
        }

        StackPanel Buttons(params Button[] buttons)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var button in buttons)
            {
                row.Children.Add(button);
            }

            return row;
        }

        AddSubpageRow("怎么写脚本", "三步上手、开头几行怎么写、结果给谁，带一个能直接用的例子", () => OpenLauncherSubpage("script-guide"));
        _content.Children.Add(SettingsUi.Card("让 AI 来写", "把写法说明贴给你常用的 AI、在最后写上想做什么；它给的脚本复制下来，点「从剪贴板新建」",
            Buttons(Action("复制写法说明", CopyScriptGuide), Action("从剪贴板新建", NewScriptFromClipboard))));
        _content.Children.Add(SettingsUi.Card("脚本文件夹", ScriptLibrary.DefaultFolder,
            Buttons(Action("新建脚本", () => _ = NewScriptAsync()), Action("在资源管理器中打开", () => LauncherOpeners.Start(ScriptLibrary.EnsureDefaultFolder())))));
        if (on && ScriptLibrary.HasNoOwnScripts)
        {
            _content.Children.Add(SettingsUi.Card("还没有自己的脚本", "用查天气的例子新建一个，在启动器里输「tq 空格 北京」就能跑；或者点上面的「新建脚本」选好语言和结果方式",
                Action("用例子新建", NewScriptExample)));
        }

        // 另加的文件夹（只读）
        _content.Children.Add(SettingsUi.Section("其他文件夹", "比如放在网盘、几台电脑共用的脚本文件夹（只读，不往里写）"));
        var added = (settings.LauncherScriptFolders ?? new List<string>()).ToList();
        void StoreFolders(List<string> updated)
        {
            settings.LauncherScriptFolders = updated.Count == 0 ? null : updated;
            SettingsService.Save();
            ScriptLibrary.Refresh();
            BuildPage("launcher");
        }

        foreach (var folder in added)
        {
            var exists = Directory.Exists(folder);
            var target = folder;
            _content.Children.Add(SettingsUi.Card(Path.GetFileName(folder.TrimEnd('\\')) is { Length: > 0 } name ? name : folder,
                exists ? folder : folder + "（找不到）", Action("移除", () => StoreFolders(added.Where(item => !string.Equals(item, target, StringComparison.OrdinalIgnoreCase)).ToList())),
                problem: !exists));
        }

        var addFolder = Action("添加文件夹…", () => { });
        addFolder.Click += async (_, _) =>
        {
            var picker = new FolderPicker(AppWindow.Id);
            if (await picker.PickSingleFolderAsync() is { Path: { Length: > 0 } chosen } &&
                !added.Contains(chosen, StringComparer.OrdinalIgnoreCase) &&
                !string.Equals(chosen, ScriptLibrary.DefaultFolder, StringComparison.OrdinalIgnoreCase))
            {
                StoreFolders(added.Append(chosen).ToList());
            }
        };
        _content.Children.Add(addFolder);

        // 读不成的
        var problems = on ? ScriptLibrary.Problems : Array.Empty<ScriptLibrary.Problem>();
        if (problems.Count > 0)
        {
            _content.Children.Add(SettingsUi.Section("读不成的脚本"));
            foreach (var problem in problems)
            {
                var path = problem.Path;
                _content.Children.Add(SettingsUi.Card(Path.GetFileName(path), ScriptCommand.ProblemText(problem.Kind),
                    Action("在资源管理器中显示", () => LauncherOpeners.Reveal(path)), problem: true));
            }
        }

        _content.Children.Add(SettingsUi.Footnote(
            "脚本以你的身份运行，能用 Kitty Tools 已有的权限，只放你信得过的脚本；从网上下载的，第一次运行前会先给你看一眼全文。" +
            "脚本文件不跟着同步，也不进设置的导出；别名和开关跟着导出导入走。"));
    }

    private void BuildScriptGuide()
    {
        var back = new HyperlinkButton { Content = "‹ 脚本命令", Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 4) };
        back.Click += (_, _) => OpenLauncherSubpage("scripts");
        AutomationProperties.SetName(back, "返回脚本命令");
        _content.Children.Add(back);
        _content.Children.Add(Header("怎么写脚本", "一个脚本文件就是启动器里的一条命令"));

        // 让 AI 来写
        _content.Children.Add(SettingsUi.Section("让 AI 来写"));
        _content.Children.Add(GuideText(
            "不会写也没关系：把这份写法说明复制给你常用的 AI，在最后一段写上想让脚本做什么，AI 会照规矩写好。把它给的脚本复制下来，" +
            "回到「脚本命令」点「从剪贴板新建」，看一眼就能存。"));
        var copy = new Button { Content = "复制写法说明" };
        copy.Click += (_, _) => CopyScriptGuide();
        var full = GuideCode(ScriptTemplates.AIGuide);
        full.Visibility = Visibility.Collapsed;
        var toggle = new HyperlinkButton { Content = "看说明全文" };
        toggle.Click += (_, _) =>
        {
            var showing = full.Visibility == Visibility.Visible;
            full.Visibility = showing ? Visibility.Collapsed : Visibility.Visible;
            toggle.Content = showing ? "看说明全文" : "收起说明全文";
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(copy);
        row.Children.Add(toggle);
        _content.Children.Add(row);
        _content.Children.Add(full);

        // 三步上手
        _content.Children.Add(SettingsUi.Section("三步上手"));
        _content.Children.Add(SettingsUi.Card("1  在「脚本命令」里点「新建脚本」", "选好名字、关键词、结果给谁、用什么写，脚本文件夹里多一个照模板写好的脚本，用记事本打开"));
        _content.Children.Add(SettingsUi.Card("2  改开头几行，下面写要跑的命令", "开头几行写它叫什么、关键词、结果给谁；下面就是普通的 PowerShell 或批处理"));
        _content.Children.Add(SettingsUi.Card("3  保存，在启动器里输关键词，按 Enter", "不用重启；改了随时生效"));
        _content.Children.Add(SettingsUi.Footnote("脚本用文件自己的「编辑」打开（.ps1 一般是记事本）；双击 .ps1、.cmd 会直接运行，别双击。PowerShell 脚本存成「UTF-8 带 BOM」，不然中文是乱码（记事本另存为时选）。"));

        // 例子
        _content.Children.Add(SettingsUi.Section("一个例子：查天气"));
        _content.Children.Add(GuideCode(ScriptTemplates.Example));
        var copyExample = new Button { Content = "复制这个例子" };
        copyExample.Click += (_, _) =>
        {
            Paster.WriteText(ScriptTemplates.Example);
            NoticeHost.Show("已复制例子", "贴进脚本文件夹里的一个 .ps1 文件（存成 UTF-8 带 BOM）就能用", NoticeTone.Normal);
        };
        var newExample = new Button { Content = "用它新建" };
        newExample.Click += (_, _) => NewScriptExample();
        var exampleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        exampleRow.Children.Add(copyExample);
        exampleRow.Children.Add(newExample);
        _content.Children.Add(exampleRow);
        _content.Children.Add(SettingsUi.Footnote("在启动器里输「tq 空格 北京」，Enter 后提示里显示北京的天气。要联网。"));

        // 字段
        _content.Children.Add(SettingsUi.Section("开头几行能写什么"));
        var fields = new StackPanel { Spacing = 10 };
        foreach (var (name, title, detail) in ScriptFields)
        {
            var item = new StackPanel { Spacing = 2 };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new TextBlock { Text = name, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Foreground = Theme.PrimaryText(), VerticalAlignment = VerticalAlignment.Center });
            head.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold });
            item.Children.Add(head);
            item.Children.Add(new TextBlock { Text = detail, FontSize = 12, Foreground = Theme.SecondaryText(), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            AutomationProperties.SetName(item, $"{name}，{title}：{detail}");
            fields.Children.Add(item);
        }

        _content.Children.Add(Card(fields));
        _content.Children.Add(SettingsUi.Footnote(
            "PowerShell、Python 的注释用 #，批处理用 :: 或 REM。网上常见的另一种写法（字段以 @raycast. 开头）也认。文件名里带 .template. 的、点开头的不列出来。"));

        // 列表
        _content.Children.Add(SettingsUi.Section("列出几条结果让人挑"));
        _content.Children.Add(GuideText("mode 写 list 时，脚本每打印一行就是一条结果，写成「结果⇥说明」（中间是 Tab，PowerShell 里写 `t），Enter 粘贴选中的那条。打字时会重新跑。"));
        _content.Children.Add(GuideCode("{\"items\": [{\"title\": \"显示的\", \"subtitle\": \"说明\", \"arg\": \"Enter 粘贴的\"}]}"));
        _content.Children.Add(GuideText("要显示的和粘贴的不一样时，打印上面这样一段 JSON。每条还可以写 url（Enter 用浏览器打开）、path（Enter 打开文件或文件夹）、autocomplete（Tab 填进搜索框，接在关键词后面）、\"valid\": false（不能选）。", secondary: true));

        // 用什么跑
        _content.Children.Add(SettingsUi.Section("用什么跑"));
        _content.Children.Add(GuideText(
            "看扩展名，不看第一行：.ps1 用 Windows PowerShell 5.1（powershell -NoProfile -ExecutionPolicy Bypass -File，不读你的配置文件，起一次约 0.2 秒）；" +
            ".cmd / .bat 用 cmd；.py 要装了 Python（带 py 启动器）才认。.sh、.js 这类 Windows 版不认，列在「读不成的脚本」里。"));
        _content.Children.Add(GuideText(
            "工作目录是脚本所在的文件夹，没有窗口、读不到键盘。能用的环境变量：KITTY_SCRIPT_DIR（脚本所在的文件夹）、KITTY_DATA_DIR（Kitty Tools 的数据目录）、" +
            "KITTY_VERSION。PATH 每次从系统重读，刚装的命令不用重启也找得到。退出码不是 0 算出错，最后一行显示在提示里。输出按系统的代码页读（中文 Windows 是 GBK），" +
            "Python 和存成 UTF-8 的批处理按 UTF-8 读。", secondary: true));

        // 安全和同步
        _content.Children.Add(SettingsUi.Section("安全和同步"));
        _content.Children.Add(GuideText(
            "脚本以你的身份运行，能用 Kitty Tools 已有的权限，只放你信得过的。从网上下载的脚本（带「来自其他计算机」的标记），第一次运行前会先给你看一眼全文；" +
            "里面有看不见的字时不让运行。"));
        _content.Children.Add(GuideText(
            "脚本文件不跟着同步，也不进设置的导出；别名和开关跟着导出导入走。几台电脑共用，就把脚本文件夹放进网盘，在每台「添加文件夹…」。", secondary: true));
    }

    private static TextBlock GuideText(string text, bool secondary = false) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        FontSize = secondary ? 12 : 13,
        Foreground = secondary ? Theme.SecondaryText() : Theme.PrimaryText(),
        IsTextSelectionEnabled = true,
        Margin = new Thickness(2, 2, 2, 4),
    };

    private static Border GuideCode(string text) => new()
    {
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(12),
        Background = Theme.CardBackground(),
        Child = new TextBlock
        {
            Text = text,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        },
    };

    /// <summary>拨过开关、新建过脚本，「新」就算看过了（光点进这一页不算，同 mac）。</summary>
    private static void TouchScriptsNew() => WhatsNewHost.TouchSection("launcher", "脚本命令");

    private static void CopyScriptGuide()
    {
        Paster.WriteText(ScriptTemplates.AIGuide);
        NoticeHost.Show("已复制脚本写法说明", "贴给你常用的 AI，在最后一段写上想做什么", NoticeTone.Normal);
    }

    /// <summary>「从剪贴板新建」：剪贴板里是一整个脚本（带不带 ``` 都行）就先给看全文，点了才存。</summary>
    private void NewScriptFromClipboard()
    {
        TouchScriptsNew();
        if (ScriptTemplates.FromClipboard(ClipboardFormats.ReadTextForPin()) is not { } found)
        {
            NoticeHost.Show("剪贴板里不是脚本", "要开头几行写了 @kitty.title 的一整个脚本：先把 AI 给的代码块复制下来", NoticeTone.Warning);
            return;
        }

        var name = ScriptTemplates.SuggestedName(found.Text, found.Language);
        var summary = ScriptCommand.Parse(found.Text, Path.Combine(ScriptLibrary.DefaultFolder, name), ScriptLibrary.PythonAvailable()) switch
        {
            { Script: { Keyword: { } keyword } } => $"存成「{name}」，在启动器里输 {keyword} 试试",
            { Script: { } script } => $"存成「{name}」，在启动器里按名字「{script.Title}」找它",
            { Problem: { } problem } => $"存成「{name}」，现在还跑不了：{ScriptCommand.ProblemText(problem)}",
            _ => $"存成「{name}」",
        };
        ScriptTextWindow.ReviewNew(name, found.Text, summary, () => SaveScript(found.Text, name, found.Language, edit: false));
    }

    private void NewScriptExample()
    {
        TouchScriptsNew();
        SaveScript(ScriptTemplates.Example + "\n", ScriptTemplates.ExampleName, ScriptLanguage.PowerShell, edit: true, next: "在启动器里输「tq 空格 北京」试试");
    }

    /// <summary>存进默认文件夹（重名加数字），要的话用编辑器打开；提示里说接下来怎么用、带「在资源管理器中显示」。</summary>
    private void SaveScript(string text, string name, ScriptLanguage language, bool edit, string? next = null)
    {
        if (ScriptLibrary.Save(text, name, language) is not { } path)
        {
            NoticeHost.Show($"没存上「{name}」", "脚本文件夹写不进去", NoticeTone.Error);
            return;
        }

        if (edit)
        {
            ScriptLibrary.Edit(path);
        }

        var keyword = text.Split('\n').Take(40).Select(ScriptCommand.Field).OfType<(string Prefix, string Key, string Value)>()
            .FirstOrDefault(field => field.Key == "keyword").Value;
        NoticeHost.Show($"已存成「{Path.GetFileName(path)}」", next ?? (keyword is { Length: > 0 } ? $"在启动器里输 {keyword} 试试" : "在启动器里按名字找它"),
            NoticeTone.Normal, new NoticeAction("在资源管理器中显示", () => LauncherOpeners.Reveal(path), Opens: true));
        if (_currentPage == "launcher")
        {
            BuildPage("launcher");
        }
    }

    /// <summary>「新建脚本」的小对话框（mac NewScriptSheet）：名字、关键词、结果给谁、用什么写；建好用编辑器打开。</summary>
    private async Task NewScriptAsync()
    {
        TouchScriptsNew();
        var title = new TextBox { Header = "名字", PlaceholderText = "比如：短链接", MaxLength = 60 };
        var keyword = new TextBox { Header = "关键词（可以不填）", PlaceholderText = "在启动器里打的词，比如 dl", MaxLength = 24 };
        var mode = new ComboBox { Header = "结果给谁", ItemsSource = ScriptModeTitles.Select(item => item.Title).ToList(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var python = ScriptLibrary.PythonAvailable();
        var languages = new List<(ScriptLanguage Language, string Title)> { (ScriptLanguage.PowerShell, "PowerShell（.ps1）"), (ScriptLanguage.Batch, "批处理（.cmd）") };
        if (python)
        {
            languages.Add((ScriptLanguage.Python, "Python（.py）"));
        }

        var language = new ComboBox { Header = "用什么写", ItemsSource = languages.Select(item => item.Title).ToList(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(title, "脚本名字");
        AutomationProperties.SetName(keyword, "关键词");
        AutomationProperties.SetName(mode, "结果给谁");
        AutomationProperties.SetName(language, "用什么写");
        var panel = new StackPanel { Spacing = 12, MinWidth = 360 };
        panel.Children.Add(title);
        panel.Children.Add(keyword);
        panel.Children.Add(mode);
        panel.Children.Add(language);
        if (!python)
        {
            panel.Children.Add(SettingsUi.Footnote("装了 Python（带 py 启动器）之后这里多一个 Python。"));
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = Theme.ElementTheme,
            Title = "新建脚本",
            Content = panel,
            PrimaryButtonText = "新建",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
            XamlRoot = _content.XamlRoot,
        };
        title.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        var chosen = languages[Math.Max(0, language.SelectedIndex)].Language;
        var name = title.Text.Trim();
        var word = new string(LauncherMatch.Fold(keyword.Text).Where(ch => !char.IsWhiteSpace(ch)).ToArray());
        var text = ScriptTemplates.Template(name, word.Length == 0 ? null : word, ScriptModeTitles[Math.Max(0, mode.SelectedIndex)].Mode, chosen);
        SaveScript(text, ScriptTemplates.NewFileName(name, word, chosen), chosen, edit: true,
            next: word.Length > 0 ? $"改好保存，在启动器里输 {word} 试试" : $"改好保存，在启动器里按名字「{name}」找它");
    }
}
