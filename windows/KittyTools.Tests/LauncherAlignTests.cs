// PLAN-v9-launcher（启动器对齐 mac）的纯函数单测：带对象模式的解析和补全提示、cb / fy、快捷链接和网页搜索的提示 / 兜底 / 校验、
// 列表的前缀和与面板高度、收藏和常用、进程 / 端口的过滤和排序、几样文字。期望值能对上 mac 单测的照抄，出处写在每个测试上面。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class LauncherModesTests
{
    // mac SystemCommandsTests.requestParsing、FileSearchTests.request
    [TestMethod]
    public void ClassifyNeedsSpaceAfterKeyword()
    {
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify("quit").Mode);
        Assert.AreEqual((LauncherMode.Quit, string.Empty), LauncherCommands.Classify("quit "));
        Assert.AreEqual((LauncherMode.Quit, "saf"), LauncherCommands.Classify("Quit  saf"));
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify("quitall").Mode);
        Assert.AreEqual((LauncherMode.ForceQuit, "微信"), LauncherCommands.Classify("forcequit 微信"));
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify("hider x").Mode);
        Assert.AreEqual((LauncherMode.Hide, "x"), LauncherCommands.Classify("hide x"));
        Assert.AreEqual((LauncherMode.FileSearch, "foo bar"), LauncherCommands.Classify("open foo bar"));
        Assert.AreEqual((LauncherMode.FileFind, "季度"), LauncherCommands.Classify("Find  季度"));
        Assert.AreEqual((LauncherMode.FileSearch, "readme"), LauncherCommands.Classify(" readme"));
        Assert.AreEqual((LauncherMode.FileSearch, string.Empty), LauncherCommands.Classify("open "));
        Assert.AreEqual(LauncherMode.Normal, LauncherCommands.Classify("eject ").Mode); // Windows 不做 eject（D4）
    }

    // mac FileSearchTests.request（isTooShort）
    [TestMethod]
    public void OneLatinLetterIsTooShort()
    {
        Assert.IsTrue(LauncherCommands.IsTooShort("a"));
        Assert.IsTrue(LauncherCommands.IsTooShort("a b"));
        Assert.IsFalse(LauncherCommands.IsTooShort("ab"));
        Assert.IsFalse(LauncherCommands.IsTooShort("报")); // 1 个汉字照查
        Assert.IsFalse(LauncherCommands.IsTooShort(string.Empty)); // 最近的文件
    }

    // mac SystemCommandsTests.requestParsing（promptItems）、FileSearch.promptItems
    [TestMethod]
    public void KeywordPromptsExactFirstPartialLater()
    {
        var quit = LauncherCommands.PromptItems("quit");
        CollectionAssert.AreEqual(new[] { "quit " }, quit.Exact.Select(item => item.Completion).ToArray());
        CollectionAssert.AreEqual(new[] { "system-kill" }, LauncherCommands.PromptItems("ki").Partial.Select(item => item.Target).ToArray());
        CollectionAssert.AreEqual(new[] { "file-open" }, LauncherCommands.PromptItems("op").Partial.Select(item => item.Target).ToArray());
        Assert.AreEqual(0, LauncherCommands.PromptItems("x").Partial.Count); // 一个字不出
        Assert.IsTrue(quit.Exact.All(item => item.Kind == LauncherKind.Prompt));
        Assert.IsFalse(LauncherKind.Prompt.IsRecorded());
    }

    // mac LauncherTests：clipQuery / translateQuery
    [TestMethod]
    public void ClipAndTranslateKeywords()
    {
        Assert.AreEqual(string.Empty, LauncherCommands.ClipQuery("cb"));
        Assert.AreEqual("token", LauncherCommands.ClipQuery("cb  token"));
        Assert.IsNull(LauncherCommands.ClipQuery("cbx"));
        Assert.AreEqual("会议", LauncherCommands.ClipQuery("CB 会议"));
        Assert.AreEqual("打开剪贴板历史", LauncherCommands.ClipItem(string.Empty).Title);
        Assert.AreEqual("hello world", LauncherCommands.TranslateQuery("fy hello world"));
        Assert.IsNull(LauncherCommands.TranslateQuery("fy "));
        Assert.IsNull(LauncherCommands.TranslateQuery("fy"));
        Assert.AreEqual("fy ", LauncherCommands.TranslatePrompts("fy").Single().Completion);
        // 副标题的释义（R16）：只放第一行；没翻过的空着。
        Assert.AreEqual("int. 你好", LauncherCommands.TranslateItem("hello", "\n  int. 你好  \nn. 招呼").Subtitle);
        Assert.AreEqual(string.Empty, LauncherCommands.TranslateItem("hello").Subtitle);
        Assert.AreEqual(string.Empty, LauncherText.FirstLine(" \n \n"));
        Assert.AreEqual(0, LauncherCommands.TranslatePrompts("fyx").Count);
    }

    [TestMethod]
    public void EmptyTextsFollowMode()
    {
        Assert.AreEqual("没有后台进程", LauncherCommands.EmptyText(LauncherMode.Kill, string.Empty, loading: false));
        Assert.AreEqual("没有进程在监听这个端口", LauncherCommands.EmptyText(LauncherMode.Kill, ":3000", loading: false));
        Assert.AreEqual("没有找到监听这个端口的进程", LauncherCommands.EmptyText(LauncherMode.Port, "80", loading: false));
        Assert.AreEqual("没有匹配的进程", LauncherCommands.EmptyText(LauncherMode.Port, "node", loading: false));
        Assert.AreEqual("没有正在运行的应用", LauncherCommands.EmptyText(LauncherMode.Quit, string.Empty, loading: false));
        Assert.AreEqual("再输入一个字母", LauncherCommands.EmptyText(LauncherMode.FileSearch, "a", loading: false));
        Assert.AreEqual("正在读取端口…", LauncherCommands.EmptyText(LauncherMode.Port, string.Empty, loading: true));
        Assert.AreEqual("后台进程", LauncherCommands.GroupTitle(LauncherMode.Kill, string.Empty));
        Assert.IsNull(LauncherCommands.GroupTitle(LauncherMode.Kill, "node"));
    }

    [TestMethod]
    public void ConfirmationTexts()
    {
        Assert.AreEqual("再按 Enter 结束，没存的内容会丢失", LauncherCommands.KillConfirmation());
        Assert.AreEqual("再按 Enter 结束「node」，没存的内容会丢失", LauncherCommands.KillConfirmation("node"));
        Assert.AreEqual("再按 Ctrl+Enter 强制退出「记事本」，没存的内容会丢失",
            LauncherCommands.ForceQuitConfirmation("Ctrl+Enter", "记事本"));
    }
}

[TestClass]
public sealed class LauncherProcessRowsTests
{
    private static LauncherProcess Process(int pid, string name, long mb, int[] ports, bool window = false, string? exe = null)
        => new(pid, name, name, mb * 1024 * 1024, ports, window, exe);

    // mac LauncherBatch6Tests：kill 的行和「kill :30」
    [TestMethod]
    public void ProcessRowAndPortFilter()
    {
        var node = LauncherCommands.ProcessItem(Process(4321, "node", 312, new[] { 3000 }));
        Assert.AreEqual("PID 4321 · 312 MB · 监听 :3000", node.Subtitle);
        Assert.AreEqual(LauncherKind.Process, node.Kind);
        Assert.AreEqual("kill node", node.Completion);
        var idle = LauncherCommands.ProcessItem(Process(7, "idle", 10, Array.Empty<int>()));
        var targets = new List<LauncherItem> { node, idle };
        CollectionAssert.AreEqual(new[] { node }, LauncherCommands.FilterTargets(targets, LauncherMode.Kill, ":30"));
        CollectionAssert.AreEqual(new[] { node }, LauncherCommands.FilterTargets(targets, LauncherMode.Kill, ":"));
        Assert.AreEqual(node, LauncherCommands.FilterTargets(targets, LauncherMode.Kill, "4321").First());
        Assert.AreEqual(2, LauncherCommands.FilterTargets(targets, LauncherMode.Kill, string.Empty).Count);
    }

    // mac Processes.items 的排法：监听端口的 → 不在系统目录里的 → 内存大的
    [TestMethod]
    public void KillOrderListeningThenUserThenMemory()
    {
        var sorted = LauncherCommands.SortProcesses(new[]
        {
            Process(1, "big-system", 900, Array.Empty<int>(), exe: @"C:\Windows\System32\svchost.exe"),
            Process(2, "small-user", 10, Array.Empty<int>(), exe: @"C:\Users\a\tool.exe"),
            Process(3, "server", 5, new[] { 8080 }),
            Process(4, "big-user", 500, Array.Empty<int>(), exe: @"C:\Program Files\x\x.exe"),
        }, @"C:\Windows");
        CollectionAssert.AreEqual(new[] { 3, 4, 2, 1 }, sorted.Select(process => process.Pid).ToArray());
    }

    // mac LauncherBatch6Tests：port 一个端口一行、按端口号排；父进程也在监听同一个端口时只列父进程；只输数字按开头筛
    [TestMethod]
    public void PortRows()
    {
        var master = Process(10, "nginx", 20, new[] { 80, 443 });
        var worker = Process(11, "nginx", 20, new[] { 80 });
        var node = Process(20, "node", 100, new[] { 5180, 3000 });
        var items = LauncherCommands.PortItems(new[] { master, worker, node }, new Dictionary<int, int> { [11] = 10 });
        CollectionAssert.AreEqual(new[] { ":80", ":443", ":3000", ":5180" }, items.Select(item => item.Title).ToArray());
        Assert.AreEqual("10:80", items[0].Target);
        Assert.AreEqual("node · PID 20", items[2].Subtitle);
        Assert.AreEqual("port 3000", items[2].Completion);
        CollectionAssert.AreEqual(new[] { ":80" }, LauncherCommands.FilterTargets(items, LauncherMode.Port, "80").Select(item => item.Title).ToArray());
        CollectionAssert.AreEqual(new[] { ":80" }, LauncherCommands.FilterTargets(items, LauncherMode.Port, ":8").Select(item => item.Title).ToArray());
        Assert.AreEqual(string.Empty, LauncherCommands.PortDigits(":"));
        Assert.IsNull(LauncherCommands.PortDigits("node"));
    }

    [TestMethod]
    public void PortRowsWithWindowsQuitOthersKill()
    {
        var app = Process(1, "chrome", 300, new[] { 9222 }, window: true);
        var daemon = Process(2, "redis", 30, new[] { 6379 });
        Assert.AreEqual(LauncherMode.Quit, LauncherCommands.RowMode(LauncherMode.Port, app));
        Assert.AreEqual(LauncherMode.Kill, LauncherCommands.RowMode(LauncherMode.Port, daemon));
        Assert.AreEqual(LauncherMode.Kill, LauncherCommands.RowMode(LauncherMode.Kill, daemon));
        Assert.AreEqual(LauncherMode.Hide, LauncherCommands.RowMode(LauncherMode.Hide, app));
    }

    // mac SystemCommands.targets：前台那个排第一，其余按名字；Tab 补成「关键词 名字」
    [TestMethod]
    public void AppTargetsFrontmostFirst()
    {
        var items = LauncherCommands.AppTargets(new[]
        {
            Process(1, "notepad", 20, Array.Empty<int>(), window: true),
            Process(2, "chrome", 300, Array.Empty<int>(), window: true),
            Process(3, "code", 500, Array.Empty<int>(), window: true),
        }, foregroundPid: 3, "quit");
        CollectionAssert.AreEqual(new[] { "code", "chrome", "notepad" }, items.Select(item => item.Title).ToArray());
        Assert.AreEqual("quit code", items[0].Completion);
    }
}

[TestClass]
public sealed class LauncherWebSearchTests
{
    private static List<SearchEngine> Engines() => new()
    {
        new() { Id = "ad", Name = "苹果文档", Keyword = "ad", UrlTemplate = "https://developer.apple.com/documentation", Fallback = true },
        new() { Id = "notes", Name = "笔记", Keyword = string.Empty, UrlTemplate = @"%USERPROFILE%\Notes" },
        new() { Id = "gh", Name = "GitHub", Keyword = "gh", UrlTemplate = "https://github.com/search?q={query}" },
        new() { Id = "nokw", Name = "无关键词", Keyword = string.Empty, UrlTemplate = "https://x.com/?q={query}", Fallback = true },
    };

    // mac LauncherTests：quicklinks / promptItems / 快捷链接不参与关键词直达和兜底
    [TestMethod]
    public void QuicklinksPromptsAndFallback()
    {
        var engines = Engines();
        var items = WebSearch.QuicklinkItems(engines);
        Assert.AreEqual(2, items.Count);
        Assert.AreEqual(LauncherKind.Url, items[0].Kind);
        Assert.AreEqual("https://developer.apple.com/documentation", items[0].Target);
        Assert.IsTrue(items[0].Names.Contains("pingguowendang") && items[0].Names.Contains("ad"));
        Assert.AreEqual(LauncherKind.Path, items[1].Kind);
        Assert.IsFalse(items[1].Target.StartsWith('%'));
        Assert.IsTrue(items[1].Target.EndsWith(@"\Notes", StringComparison.Ordinal));

        var exact = WebSearch.PromptItems("gh", engines);
        CollectionAssert.AreEqual(new[] { "gh " }, exact.Exact.Select(item => item.Completion).ToArray());
        Assert.AreEqual(0, exact.Partial.Count);
        Assert.AreEqual(LauncherKind.Prompt, WebSearch.PromptItems("git", engines).Partial.First().Kind);
        Assert.AreEqual(0, WebSearch.PromptItems("x", engines).Partial.Count);

        Assert.IsNull(WebSearch.KeywordItem("ad swift", engines));
        CollectionAssert.AreEqual(new[] { "用 无关键词 搜索「swift」" },
            WebSearch.FallbackItems("swift", engines).Select(item => item.Title).ToArray());
        Assert.AreEqual("nokw", WebSearch.Primary(engines)?.Id);
    }

    // mac SettingsListTests.engineTitles + SearchEngineDetail.problem
    [TestMethod]
    public void TitlesAndProblems()
    {
        var engines = Engines();
        Assert.AreEqual("未命名", WebSearch.Title(new SearchEngine { Name = " " }));
        Assert.AreEqual("快捷链接", WebSearch.KindTitle(engines[0]));
        Assert.AreEqual("搜索 · 没有本地结果时兜底", WebSearch.KindTitle(engines[3]));
        Assert.AreEqual("搜索 · 只用关键词", WebSearch.KindTitle(engines[2]));
        Assert.IsTrue(WebSearch.IsPreset("google") && !WebSearch.IsPreset("custom-1a2b3c4d"));

        Assert.IsNull(WebSearch.Problem(engines[1], engines)); // 路径的快捷链接
        Assert.AreEqual("还没填名称", WebSearch.Problem(new SearchEngine { Id = "a", UrlTemplate = "https://a.com" }, engines));
        Assert.AreEqual("网址不完整", WebSearch.Problem(new SearchEngine { Id = "a", Name = "a", UrlTemplate = "abc" }, engines));
        Assert.AreEqual("网址不完整", WebSearch.Problem(new SearchEngine { Id = "a", Name = "a", UrlTemplate = "https://" }, engines));
        Assert.AreEqual("关键词「cb」留给剪贴板指令",
            WebSearch.Problem(new SearchEngine { Id = "a", Name = "a", Keyword = "cb", UrlTemplate = "https://a.com/?q={query}" }, engines));
        var duplicate = new SearchEngine { Id = "dup", Name = "又一个", Keyword = "GH", UrlTemplate = "https://b.com/?q={query}" };
        var list = engines.Append(duplicate).ToList();
        Assert.AreEqual("关键词和「GitHub」重复，用的是靠前的那个", WebSearch.Problem(duplicate, list));
        Assert.AreEqual("没有关键词也不兜底，用不上",
            WebSearch.Problem(new SearchEngine { Id = "a", Name = "a", UrlTemplate = "https://a.com/?q={query}" }, engines));
    }
}

[TestClass]
public sealed class LauncherTextTests
{
    // mac LauncherBatch5Tests：markdownLink
    [TestMethod]
    public void MarkdownLinkEscapes()
        => Assert.AreEqual("[a \\[b\\]](https://x.com/a%20b%29)", LauncherText.MarkdownLink("a [b]", "https://x.com/a b)"));

    [TestMethod]
    public void MiddleEllipsisKeepsBothEnds()
    {
        Assert.AreEqual("abc…hij", LauncherText.MiddleEllipsis("abcdefghij", 7));
        Assert.AreEqual("short", LauncherText.MiddleEllipsis("short", 7));
        Assert.AreEqual(7, LauncherText.MiddleEllipsis(@"C:\Users\someone\Documents\Projects\report.pdf", 7).Length);
    }

    [TestMethod]
    public void RelativeTimeInChinese()
    {
        const long now = 10_000_000_000;
        Assert.AreEqual("刚刚", LauncherText.RelativeTime(now - 30_000, now));
        Assert.AreEqual("5分钟前", LauncherText.RelativeTime(now - 5 * 60_000, now));
        Assert.AreEqual("3小时前", LauncherText.RelativeTime(now - 3 * 3_600_000, now));
        Assert.AreEqual("昨天", LauncherText.RelativeTime(now - 30 * 3_600_000L, now));
        Assert.AreEqual("3天前", LauncherText.RelativeTime(now - 3 * 86_400_000L, now));
        Assert.AreEqual("刚刚", LauncherText.RelativeTime(now + 60_000, now)); // 将来的当成刚刚
        Assert.AreEqual("历史 · github.com · 3天前", LauncherText.HistorySubtitle("历史 · github.com", now - 3 * 86_400_000L, now));
    }

    [TestMethod]
    public void MemoryKindHostCompletion()
    {
        Assert.AreEqual("312 MB", LauncherText.Memory(312L * 1024 * 1024));
        Assert.AreEqual("1.5 GB", LauncherText.Memory(1536L * 1024 * 1024));
        // mac FileSearchTests.kindTitleAndItem
        Assert.AreEqual("DMG", LauncherText.FileKindTitle(@"C:\x\a.dmg", folder: false));
        Assert.AreEqual("文件夹", LauncherText.FileKindTitle(@"C:\x\Docs", folder: true));
        Assert.AreEqual("文件", LauncherText.FileKindTitle(@"C:\x\Makefile", folder: false));
        Assert.AreEqual("github.com", LauncherText.Host("https://www.github.com/x"));
        Assert.IsNull(LauncherText.Host("maps://?q=x"));
        Assert.IsTrue(LauncherText.IsWebLink(new LauncherItem { Kind = LauncherKind.Url, Target = "https://a.com" }));
        Assert.IsFalse(LauncherText.IsWebLink(new LauncherItem { Kind = LauncherKind.Url, Target = "maps://?q=x" }));
        // mac LauncherTests.tabCompletionAndAlternates
        Assert.AreEqual("37", LauncherText.Completion(new LauncherItem { Kind = LauncherKind.Calculation, Completion = "37" }));
        Assert.AreEqual(@"C:\Windows\", LauncherText.Completion(new LauncherItem { Kind = LauncherKind.Path, Target = @"C:\Windows", IsFolder = true }));
        Assert.AreEqual(@"C:\a.txt", LauncherText.Completion(new LauncherItem { Kind = LauncherKind.Path, Target = @"C:\a.txt" }));
        Assert.AreEqual("记事本", LauncherText.Completion(new LauncherItem { Kind = LauncherKind.App, Title = "记事本" }));
        Assert.IsNull(LauncherText.Completion(new LauncherItem { Kind = LauncherKind.Process, Title = "node" }));
    }

    // mac 体检 A25：应用的副标题不写和「应用」重复的话
    [TestMethod]
    public void AppSubtitle()
    {
        Assert.AreEqual("WeChat", LauncherText.AppSubtitle("微信", "WeChat.exe", "Programs"));
        Assert.AreEqual(string.Empty, LauncherText.AppSubtitle("Visual Studio Code", "Code.exe", "Visual Studio Code"));
        Assert.AreEqual("Microsoft Office", LauncherText.AppSubtitle("Word", "WINWORD.EXE", "Microsoft Office"));
        Assert.AreEqual(string.Empty, LauncherText.AppSubtitle("记事本", null, "Programs"));
    }

    [TestMethod]
    public void MayMatchIsNecessaryForScore()
    {
        var item = new LauncherItem
        {
            Names = new List<string> { "visual studio code" },
            Initials = new List<string> { "vsc" },
        };
        Assert.IsTrue(LauncherMatch.MayMatch(LauncherMatch.Tokens("vis"), item));
        Assert.IsTrue(LauncherMatch.MayMatch(LauncherMatch.Tokens("vsc"), item));
        Assert.IsTrue(LauncherMatch.MayMatch(LauncherMatch.Tokens("Studio Code"), item));
        Assert.IsFalse(LauncherMatch.MayMatch(LauncherMatch.Tokens("zzz"), item));
        foreach (var query in new[] { "vis", "vsc", "studio code", "zzz", "co" })
        {
            Assert.AreEqual(LauncherMatch.Score(query, item) > 0, LauncherMatch.Score(query, item) > 0 && LauncherMatch.MayMatch(LauncherMatch.Tokens(query), item));
        }
    }
}

[TestClass]
public sealed class LauncherLayoutTests
{
    // mac LauncherPanelView.offset / height
    [TestMethod]
    public void PrefixSumsWithGroups()
    {
        var layout = new LauncherListLayout(new[] { 40.0, 40.0, 40.0 }, new[] { 0, 2 });
        Assert.AreEqual(28, layout.Top(0));
        Assert.AreEqual(68, layout.Top(1));
        Assert.AreEqual(136, layout.Top(2)); // 28 + 40 + 40 + 28
        Assert.AreEqual(176, layout.TotalHeight);
        Assert.AreEqual(108, layout.GroupTop(2));
        Assert.IsTrue(layout.StartsGroup(2) && !layout.StartsGroup(1));
        CollectionAssert.AreEqual(new[] { 0, 2 }, layout.GroupRows.ToArray());
    }

    [TestMethod]
    public void PanelHeightFollowsMac()
    {
        // 搜索线 56 + 上下内缩 12 + 分组 28 + 三行 + 底栏 36
        Assert.AreEqual(56 + 12 + 28 + 120 + 36.0, LauncherListLayout.PanelHeight(new[] { 40.0, 40.0, 40.0 }, 1, showsEmpty: false));
        // 十行：最多露 8.5 行
        Assert.AreEqual(56 + 12 + 8 * 40 + 20 + 36.0, LauncherListLayout.PanelHeight(Enumerable.Repeat(40.0, 10).ToList(), 0, false));
        // 计算卡 64
        Assert.AreEqual(56 + 12 + 104 + 36.0, LauncherListLayout.PanelHeight(new[] { 64.0, 40.0 }, 0, false));
        // 有查询没结果：一行字 52；空查询什么都没有：只有搜索线和底栏
        Assert.AreEqual(56 + 52 + 36.0, LauncherListLayout.PanelHeight(Array.Empty<double>(), 0, showsEmpty: true));
        Assert.AreEqual(56 + 36.0, LauncherListLayout.PanelHeight(Array.Empty<double>(), 0, showsEmpty: false));
        // Ctrl+K 菜单开着：至少放得下菜单（离搜索线 8、底栏上方 4）
        Assert.AreEqual(56 + 8 + 250 + 4 + 36.0, LauncherListLayout.PanelHeight(new[] { 40.0 }, 0, false, menuHeight: 250));
    }

    [TestMethod]
    public void RevealKeepsRowAndHeaderVisible()
    {
        var layout = new LauncherListLayout(Enumerable.Repeat(40.0, 10).ToList(), new[] { 0 });
        // 第 5 行在下面看不见：滚到它的底 + 内缩刚好露出来
        Assert.AreEqual(6 + 28 + 240 + 6 - 100.0, layout.Reveal(5, 0, 100));
        // 已经露全：不滚
        Assert.IsNull(layout.Reveal(1, 0, 200));
        // 第一行（带分组标题）在上面被滚出去了：回到顶
        Assert.AreEqual(0.0, layout.Reveal(0, 50, 200));
        Assert.IsNull(layout.Reveal(10, 0, 100));
    }
}

[TestClass]
public sealed class LauncherHomeTests
{
    private static LauncherItem Item(string id) => new() { Kind = LauncherKind.App, Target = id, Title = id };

    // mac LauncherModel.home：先收藏（藏起还原不出来的）、再常用补足 8 行，重复的跳过
    [TestMethod]
    public void FavoritesThenFrequentUpToEight()
    {
        var (items, favorites) = LauncherHome.Merge(
            new LauncherItem?[] { Item("a"), null, Item("b") },
            new LauncherItem?[] { Item("b"), Item("c"), null, Item("d"), Item("e"), Item("f"), Item("g"), Item("h"), Item("i") });
        Assert.AreEqual(2, favorites);
        CollectionAssert.AreEqual(new[] { "a", "b", "c", "d", "e", "f", "g", "h" }, items.Select(item => item.Target).ToArray());
    }

    [TestMethod]
    public void GroupsAndFavoriteLimit()
    {
        CollectionAssert.AreEqual(new[] { new LauncherGroup(0, "收藏"), new LauncherGroup(2, "常用") }, LauncherHome.Groups(5, 2));
        CollectionAssert.AreEqual(new[] { new LauncherGroup(0, "收藏") }, LauncherHome.Groups(2, 2));
        CollectionAssert.AreEqual(new[] { new LauncherGroup(0, "常用") }, LauncherHome.Groups(3, 0));
        Assert.AreEqual(0, LauncherHome.Groups(0, 0).Count);
        Assert.IsTrue(LauncherHome.CanAddFavorite(7));
        Assert.IsFalse(LauncherHome.CanAddFavorite(8));
    }

    // mac LauncherUsage.swapFavorites：只和看得见的邻居换，藏着的不挡着
    [TestMethod]
    public void SwapSkipsHiddenFavorites()
    {
        var order = new[] { "a", "hidden", "b", "c" };
        var visible = new[] { "a", "b", "c" };
        CollectionAssert.AreEqual(new[] { "b", "hidden", "a", "c" }, LauncherHome.Swap(order, visible, "b", -1)!);
        CollectionAssert.AreEqual(new[] { "a", "hidden", "c", "b" }, LauncherHome.Swap(order, visible, "b", 1)!);
        Assert.IsNull(LauncherHome.Swap(order, visible, "a", -1));
        Assert.IsNull(LauncherHome.Swap(order, visible, "c", 1));
        Assert.IsNull(LauncherHome.Swap(order, visible, "hidden", 1));
    }
}
