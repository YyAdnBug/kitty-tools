// 便签正文 Markdown 扫描器和改字函数的单测（PLAN-v13 第 1 批）：照 mac 的 NoteMarkdownTests.swift 全部移植，期望值原样；
// 另把 NoteBatch8Tests.swift / NoteBatch8bTests.swift 里只测 NoteMarkdown 纯函数的用例一起移过来（颜色、格式合并、块格式、
// 链接、清除格式、代码块、颜色 ⇄ <span>）——这几样只有那两个文件在测。
// 跳过的（要 AppKit 的文本存储 / 字体 / 段落样式，到 WinUI 的编辑器包装那一批再对着 RichEditBox 写）：
// - NoteMarkdownTests：attributesOfEachStyle（只移了 headingSize 那几行和它隐含的几个字号）、shownLinesFadeTheirMarkers（apply / outdated）、
//   lineByLineEqualsWholeText（只移了「删掉链接的 ] 再排那一行」里 lines(covering:) 和扫描的那一半）、
//   theSwitchIsARegisteredPreference（Prefs / SettingsArchive 那一半；行距三档移了）、codeBlockLinesAreVerbatim（属性那一半；角色移了）、
//   lineHeightsFollowTheSpacing（段落样式和 textTop；行高的数移了）。
// - NoteBatch8Tests：任务五态那几条（NoteTasks 的，归 NoteTasks 的单测）、colorsAreReadableOnEveryPaper（纸色 / 对比度）、
//   boxGlyphsLineUpAndUrgentIsRed（字体量宽）、pasteTargetOnlyWhenEditableAndOnScreen（NSTextView）、storeSearchIgnoresColorNames（NoteStore）。
// - NoteBatch8bTests：singleExport*（NoteMarkdownFiles 的导出）。
using System.Diagnostics;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using BlockFormat = KittyTools.Core.Notes.NoteMarkdown.BlockFormat;
using Kind = KittyTools.Core.Notes.NoteStyles.Kind;
using KindTag = KittyTools.Core.Notes.NoteStyles.KindTag;
using Look = KittyTools.Core.Notes.NoteStyles.Look;
using Role = KittyTools.Core.Notes.NoteMarkdown.Role;
using Wrap = KittyTools.Core.Notes.NoteMarkdown.Wrap;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteMarkdownTests
{
    /// <summary>一次改完的样子：全文和选区（比加标记、粘贴成链接的结果用）。</summary>
    private sealed record Edit(string Text, NoteRange Selection);

    private static NoteRange R(int location, int length = 0) => new(location, length);

    private static string Repeat(string text, int count) => string.Concat(Enumerable.Repeat(text, count));

    private static Edit? Applied(NoteTasks.Change? change, string text)
        => change is null ? null : new Edit(change.Apply(text), change.Selection);

    private static string StateName(NoteTaskState state) => state switch
    {
        NoteTaskState.Todo => "todo",
        NoteTaskState.Doing => "doing",
        NoteTaskState.Urgent => "urgent",
        NoteTaskState.Done => "done",
        _ => "cancelled",
    };

    /// <summary>同 mac 测试里 "\(span.kind)" 的写法。</summary>
    private static string Name(Kind kind) => kind.Tag switch
    {
        KindTag.Heading => $"h{kind.Level}",
        KindTag.Link => $"link({kind.Address})",
        KindTag.Box => $"box({StateName(kind.State)})",
        KindTag.Color => $"color({NoteColors.Name(kind.Ink)})",
        KindTag.Done => "done",
        KindTag.Bold => "bold",
        KindTag.Italic => "italic",
        KindTag.Strike => "strike",
        KindTag.Code => "code",
        KindTag.Quote => "quote",
        KindTag.Bullet => "bullet",
        KindTag.Marker => "marker",
        KindTag.CodeBlock => "codeBlock",
        _ => "fence",
    };

    /// <summary>一行的样式写成好认的样子：「种类@位置:那一段字」，按位置排（同一个位置长的在前，一样长的按名字）。</summary>
    private static List<string> Marks(string line, bool markdown = true)
        => NoteStyles.Spans(line, markdown)
            .Select(span => (span.Range,
                Text: $"{Name(span.Kind)}@{span.Range.Location}:{line.Substring(span.Range.Location, span.Range.Length)}"))
            .OrderBy(item => item.Range.Location)
            .ThenBy(item => -item.Range.Length)
            .ThenBy(item => item.Text, StringComparer.Ordinal)
            .Select(item => item.Text)
            .ToList();

    private static void Expect(string line, params string[] expected)
    {
        var actual = Marks(line);
        CollectionAssert.AreEqual(expected, actual, $"{line} → {string.Join(" | ", actual)}");
    }

    private static void ExpectOff(string line, params string[] expected)
    {
        var actual = Marks(line, markdown: false);
        CollectionAssert.AreEqual(expected, actual, $"{line} → {string.Join(" | ", actual)}");
    }

    private static void Empty(params string[] lines)
    {
        foreach (var line in lines)
        {
            var actual = Marks(line);
            Assert.AreEqual(0, actual.Count, $"{line} → {string.Join(" | ", actual)}");
        }
    }

    // ---- 块 ----

    [TestMethod]
    public void Headings()
    {
        Expect("# 标题", "h1@0:# 标题", "marker@0:# ");
        Expect("###### 六级", "h6@0:###### 六级", "marker@0:###### ");
        Expect("##   多空几格", "h2@0:##   多空几格", "marker@0:##   ");
        // Tab、全角空格也算空白；前面最多 3 个空格
        Expect("#\t制表", "h1@0:#\t制表", "marker@0:#\t");
        Expect("#\u3000全角", "h1@0:#\u3000全角", "marker@0:#\u3000");
        Expect("   ## 缩进", "h2@0:   ## 缩进", "marker@3:## ");
        Empty("    # 四个空格");
        // 七个井号、没有空白、只有标记没有内容：都不是标题，原样显示
        Empty("####### 七级", "#标签");
        Empty("#", "# ", "##   ");
        // 标题的内容里认行内样式
        Expect("## 有 **粗** 字", "h2@0:## 有 **粗** 字", "marker@0:## ", "marker@5:**", "bold@7:粗", "marker@8:**");
        // 行中间的井号不算
        Empty("说 # 不是标题");
    }

    [TestMethod]
    public void QuotesAndBullets()
    {
        Expect("> 引用", "quote@0:> 引用", "marker@0:> ");
        Expect(">紧挨着", "quote@0:>紧挨着", "marker@0:>");
        // 空的引用也算（夹在几行引用中间的空行），它的 > 不藏、只变淡；只有一层，第二个 > 是内容
        Expect(">", "bullet@0:>", "quote@0:>");
        Expect("> ", "bullet@0:> ", "quote@0:> ");
        Expect(">  ", "quote@0:>  ", "marker@0:> ");
        Expect("> > 套着", "quote@0:> > 套着", "marker@0:> ");
        Expect("> 引用里的 *斜体*", "quote@0:> 引用里的 *斜体*", "marker@0:> ", "marker@7:*", "italic@8:斜体", "marker@10:*");
        Empty("说 > 不是引用", "    > 四个空格");
        // 无序列表：只有那个符号（变淡，不藏）；内容里认行内样式；行首的星号不是斜体的开头
        Expect("- 列表", "bullet@0:-");
        Expect("  + 缩进的", "bullet@2:+");
        Expect("* 星号 *斜*", "bullet@0:*", "marker@5:*", "italic@6:斜", "marker@7:*");
        Empty("-不是列表", "1. 有序的不加样式");
        Expect("1. 有序里的 **粗**", "marker@8:**", "bold@10:粗", "marker@11:**");
        // 列表项、标题的内容里不再认块：「- # x」不是标题
        Expect("- # 不是标题", "bullet@0:-");
        Expect("# > 不是引用", "h1@0:# > 不是引用", "marker@0:# ");
    }

    // ---- 行内 ----

    [TestMethod]
    public void Emphasis()
    {
        Expect("**粗**", "marker@0:**", "bold@2:粗", "marker@3:**");
        Expect("__粗__", "marker@0:__", "bold@2:粗", "marker@3:__");
        Expect("*斜*", "marker@0:*", "italic@1:斜", "marker@2:*");
        Expect("_斜_", "marker@0:_", "italic@1:斜", "marker@2:_");
        Expect("~~删~~", "marker@0:~~", "strike@2:删", "marker@3:~~");
        Expect("前 **粗** 中 *斜* 后",
            "marker@2:**", "bold@4:粗", "marker@5:**", "marker@10:*", "italic@11:斜", "marker@12:*");
        // 星号可以在词中间（中文里夹着的也行）
        Expect("这是*斜体*的", "marker@2:*", "italic@3:斜体", "marker@5:*");
        Expect("un*frigging*believable", "marker@2:*", "italic@3:frigging", "marker@11:*");
        // 又粗又斜：里面两个是粗体，外面一个是斜体
        Expect("***又粗又斜***",
            "marker@0:*", "italic@1:**又粗又斜**", "marker@1:**", "bold@3:又粗又斜", "marker@7:**", "marker@9:*");
        // 套着的
        Expect("**粗 *又斜* 粗**",
            "marker@0:**", "bold@2:粗 *又斜* 粗", "marker@4:*", "italic@5:又斜", "marker@7:*", "marker@10:**");
        Expect("*斜 ~~删~~ 斜*",
            "marker@0:*", "italic@1:斜 ~~删~~ 斜", "marker@3:~~", "strike@5:删", "marker@6:~~", "marker@10:*");
        // 多出来的星号原样留着：** 开头、* 结尾 → 斜体，前面多一个星号
        Expect("**斜*", "marker@1:*", "italic@2:斜", "marker@3:*");
    }

    /// <summary>那几条正则的误伤，和别的「不该认」的。</summary>
    [TestMethod]
    public void ThingsThatAreNotMarkup()
    {
        // 词中间的下划线不是斜体（英文、数字、汉字两边都算字）
        Empty("snake_case_name", "a_b_ c");
        Empty("中文_不是斜体_中文", "file__name__here");
        Expect("__init__", "marker@0:__", "bold@2:init", "marker@6:__");
        Expect("(_斜_)", "marker@1:_", "italic@2:斜", "marker@3:_");
        // 开头的标记后面、结尾的标记前面是空白：不认
        Empty("2 * 3 * 4", "** 不是粗体 **");
        // 紧挨着的前一个字和后一个字都是 ASCII 数字的星号是乘号：既不开也不关
        Empty("2*3*4", "箱子 60*40*30", "3*4=12", "2**3**4", "1*2 和 *3", "a*1*2");
        // 只有一边是数字的、两边是全角数字 / 汉字的照常
        Expect("*3*", "marker@0:*", "italic@1:3", "marker@2:*");
        Expect("第**3**个", "marker@1:**", "bold@3:3", "marker@4:**");
        Expect("a*b*c", "marker@1:*", "italic@2:b", "marker@3:*");
        Expect("2*x*3", "marker@1:*", "italic@2:x", "marker@3:*");
        Expect("第*3*4*个", "marker@1:*", "italic@2:3*4", "marker@5:*");
        Expect("１*２*３", "marker@1:*", "italic@2:２", "marker@3:*");
        Empty("*后面是空白 *", "~~ 不是删除线 ~~");
        // 没配对的原样显示
        Empty("**没关上", "没开头**", "*a");
        Empty("~~x", "`没关上", "[字](没关上");
        Empty("[只有方括号]", "](地址)");
        // 不同的字符不互相配
        Empty("*a_", "**a__");
        // 空的强调：一整串标记自己配不了自己
        Empty("****", "__", "a **** b");
        Empty("~~~~", "** **");
        // 删除线只认正好两个波浪号
        Empty("~删~", "~~~删~~~");
        // 反斜杠后面的标记字符不算标记（反斜杠照常显示，所以没有任何样式）
        Empty("\\*不是斜体\\*", "\\_也不是\\_");
        Expect("\\**斜\\**", "marker@2:*", "italic@3:斜\\*", "marker@6:*");
        Empty("\\`不是代码`", "\\[字](https://a.b)");
        Empty("\\# 不是标题", "[字\\](https://a.b)");
        // 两个反斜杠是「一个反斜杠」，后面的星号照常算
        Expect("\\\\*斜*", "marker@2:*", "italic@3:斜", "marker@4:*");
        // 样式不交叉：粗体收尾之后，夹在里面的那个下划线开头作废
        Expect("**a _b** c_", "marker@0:**", "bold@2:a _b", "marker@6:**");
    }

    [TestMethod]
    public void InlineCode()
    {
        Expect("`代码`", "marker@0:`", "code@1:代码", "marker@3:`");
        // 代码里的 * _ ~ [ 都不是标记；代码外面的照常
        Expect("`a*b*c_d_~~e~~[f](g)` *斜*",
            "marker@0:`", "code@1:a*b*c_d_~~e~~[f](g)", "marker@20:`", "marker@22:*", "italic@23:斜", "marker@24:*");
        // 强调的标记落在代码里：配不上
        Expect("*a `b* c`", "marker@3:`", "code@4:b* c", "marker@8:`");
        // 两个反引号开的要两个关：里面可以有单个反引号
        Expect("``a`b``", "marker@0:``", "code@2:a`b", "marker@5:``");
        Empty("``没关上`");
        // 代码里的反斜杠就是反斜杠
        Expect("`a\\`", "marker@0:`", "code@1:a\\", "marker@3:`");
        // 粗体里的代码
        Expect("**粗 `码`**", "marker@0:**", "bold@2:粗 `码`", "marker@4:`", "code@5:码", "marker@6:`", "marker@7:**");
    }

    [TestMethod]
    public void Links()
    {
        Expect("[字](https://a.b)", "marker@0:[", "link(https://a.b)@1:字", "marker@2:](https://a.b)");
        Expect("看 [这里](mailto:a@b.c) 和 [那里](x)",
            "marker@2:[", "link(mailto:a@b.c)@3:这里", "marker@5:](mailto:a@b.c)", "marker@23:[",
            "link(x)@24:那里", "marker@26:](x)");
        // 地址里的括号成对就行；方括号可以套
        Expect("[猫](https://zh.wikipedia.org/wiki/猫_(消歧义))",
            "marker@0:[", "link(https://zh.wikipedia.org/wiki/猫_(消歧义))@1:猫",
            "marker@2:](https://zh.wikipedia.org/wiki/猫_(消歧义))");
        Expect("[a [b] c](u)", "marker@0:[", "link(u)@1:a [b] c", "marker@8:](u)");
        // 字是空的、地址是空的、地址里有空白（带标题的写法）：不认
        Empty("[](https://a.b)", "[ ](https://a.b)");
        Empty("[字]()", "[字](地址 \"标题\")");
        Empty("[字] (https://a.b)");
        // 图片：原样显示，里面的强调也不认；外面的照常
        Empty("![图](x.png)", "![**粗**](x.png)");
        Expect("![图 *a](x.png) *斜*", "marker@15:*", "italic@16:斜", "marker@17:*");
        // 链接的字里认行内样式；外面的强调可以把整个链接包起来，但不能一头在里面一头在外面
        Expect("[**粗**](u)",
            "marker@0:[", "link(u)@1:**粗**", "marker@1:**", "bold@3:粗", "marker@4:**", "marker@6:](u)");
        Expect("*看 [字](u)*",
            "marker@0:*", "italic@1:看 [字](u)", "marker@3:[", "link(u)@4:字", "marker@5:](u)", "marker@9:*");
        Expect("*a [b* c](u)", "marker@3:[", "link(u)@4:b* c", "marker@8:](u)");
        // 链接里不套链接：里面那个成了，外面的方括号原样
        Expect("[a [b](u) c](v)", "marker@3:[", "link(u)@4:b", "marker@5:](u)");
        // 字里的代码可以带方括号
        Expect("[`]`](u)", "marker@0:[", "link(u)@1:`]`", "marker@1:`", "code@2:]", "marker@3:`", "marker@4:](u)");
        // 地址太长的不当链接（免得一行怪文字越扫越慢）
        var longAddress = new string('a', NoteMarkdown.AddressLimit + 1);
        Empty($"[字]({longAddress})");
        var shorter = longAddress[..^1];
        Assert.AreEqual($"marker@2:]({shorter})", Marks($"[字]({shorter})")[^1]);
    }

    /// <summary>能打开的地址：http、https（要有主机名）、mailto；别的只有下划线。</summary>
    [TestMethod]
    public void LinkAddressesThatOpen()
    {
        Assert.AreEqual("example.com", NoteMarkdown.Url("https://example.com/a?b=c")?.Host);
        Assert.IsNotNull(NoteMarkdown.Url("http://example.com"));
        Assert.IsNotNull(NoteMarkdown.Url("HTTPS://EXAMPLE.COM"));
        Assert.IsNotNull(NoteMarkdown.Url("mailto:someone@example.com"));
        Assert.IsNotNull(NoteMarkdown.Url("https://zh.wikipedia.org/wiki/猫_(消歧义)"));
        foreach (var address in new[]
                 {
                     "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.x",
                     "kitty://x", "ftp://example.com", "example.com", "/usr/bin", "", "mailto:", "https://",
                     "http:example.com", "tel:10086", "data:text/html,x", "smb://server/share",
                 })
        {
            Assert.IsNull(NoteMarkdown.Url(address), address);
        }
    }

    /// <summary>和任务叠着：任务行的内容里只认行内样式；开关关掉只剩任务的两种。</summary>
    [TestMethod]
    public void TasksAndTheSwitch()
    {
        Expect("☐ **粗** 字", "box(todo)@0:☐", "marker@2:**", "bold@4:粗", "marker@5:**");
        Expect("  ☑ 做完的 `码`", "box(done)@2:☑", "done@4:做完的 `码`", "marker@8:`", "code@9:码", "marker@10:`");
        // 任务行里不认标题、引用、列表
        Expect("☐ # 不是标题", "box(todo)@0:☐");
        Expect("☐ > 不是引用", "box(todo)@0:☐");
        Expect("☑ - 不是列表", "box(done)@0:☑", "done@2:- 不是列表");
        // 标题里的方框只是一个字
        Expect("# ☐ 不是任务", "h1@0:# ☐ 不是任务", "marker@0:# ");
        // 开关关掉：没有 Markdown 的种类，任务照常
        foreach (var line in new[] { "# 标题", "**粗** *斜* ~~删~~ `码`", "[字](https://a.b)", "> 引用", "- 列表" })
        {
            ExpectOff(line);
        }

        ExpectOff("☑ **粗**", "box(done)@0:☑", "done@2:**粗**");
        ExpectOff("☐ [字](u)", "box(todo)@0:☐");
    }

    /// <summary>不会越界、不会卡：各种怪输入扫一遍；位置都在这一行里。</summary>
    [TestMethod]
    public void OddInputsStayInBounds()
    {
        var lines = new[]
        {
            "", " ", "*", "**", "***", "_", "`", "``", "[", "]", "![", "](", "[](", "[]()", "\\", "#",
            ">", "> ", "~~", "🙂*🙂*🙂", "[🙂](https://a.b)", "*a**b**c*", "**a*b*c**", "*a**b*c**",
            "[[[[[[", "]]]]]]", "![![![a](b)", "[a](b)[c](d)[e", "`a``b```c", "**__~~`x`~~__**",
            new string('[', 20_000), Repeat("*a ", 20_000),
            Repeat("](", 20_000), Repeat("_a* ", 20_000),
            Repeat("![", 5000) + Repeat("[a](u)", 5000),
        };
        foreach (var line in lines)
        {
            var length = line.Length;
            var spans = NoteStyles.Spans(line, markdown: true);
            Assert.IsTrue(spans.All(span => span.Range.Location >= 0 && span.Range.End <= length), $"长度 {length}");
            // 标记互不相交
            var markers = spans.Where(span => span.Kind.Tag == KindTag.Marker).Select(span => span.Range)
                .OrderBy(range => range.Location).ToList();
            Assert.IsTrue(markers.Zip(markers.Skip(1)).All(pair => pair.First.End <= pair.Second.Location), $"长度 {length}");
            // 叠出来的段从前到后、互不相交、都在这一行里
            var runs = NoteStyles.Runs(spans);
            Assert.IsTrue(runs.All(run => run.Range.Length > 0 && run.Range.End <= length), $"长度 {length}");
            Assert.IsTrue(runs.Zip(runs.Skip(1)).All(pair => pair.First.Range.End <= pair.Second.Range.Location), $"长度 {length}");
        }

        // 紧挨着的写法按就近配对（没做 CommonMark 的「3 的倍数」规则）：三段都是斜体
        Assert.AreEqual(3, Marks("*a**b**c*").Count(mark => mark.StartsWith("italic", StringComparison.Ordinal)));
    }

    // ---- 叠起来 ----

    private static Dictionary<string, Look> Looks(string line)
    {
        var result = new Dictionary<string, Look>();
        foreach (var run in NoteStyles.Runs(NoteStyles.Spans(line, markdown: true)))
        {
            result[line.Substring(run.Range.Location, run.Range.Length)] = run.Look;
        }

        return result;
    }

    private static Look? At(Dictionary<string, Look> looks, string text)
        => looks.TryGetValue(text, out var look) ? look : (Look?)null;

    /// <summary>标题里的粗体还是标题的字号（一段字同时在标题和粗体里）；做完的任务里的粗体；标记压在别的上面。</summary>
    [TestMethod]
    public void LooksAreLayered()
    {
        var heading = Looks("## 有 **粗** 和 `码`");
        Assert.AreEqual<Look?>(new Look(Heading: 2, IsMarker: true), At(heading, "## "));
        Assert.AreEqual<Look?>(new Look(Heading: 2), At(heading, "有 "));
        Assert.AreEqual<Look?>(new Look(Heading: 2, IsBold: true), At(heading, "粗"));
        Assert.AreEqual<Look?>(new Look(Heading: 2, IsMarker: true), At(heading, "**"));
        Assert.AreEqual<Look?>(new Look(Heading: 2, IsCode: true), At(heading, "码"));
        var done = Looks("☑ 做完 **粗** ~~删~~");
        Assert.AreEqual<Look?>(new Look(BoxState: NoteTaskState.Done), At(done, "☑"));
        Assert.AreEqual<Look?>(new Look(IsDone: true), At(done, "做完 "));
        Assert.AreEqual<Look?>(new Look(IsBold: true, IsDone: true), At(done, "粗"));
        Assert.AreEqual<Look?>(new Look(IsStruck: true, IsDone: true), At(done, "删"));
        Assert.AreEqual<Look?>(new Look(IsDone: true, IsMarker: true), At(done, "~~"));
        var nested = Looks("> ***x*** [**y**](https://a.b)");
        Assert.AreEqual<Look?>(new Look(IsBold: true, IsItalic: true, IsQuote: true), At(nested, "x"));
        Assert.AreEqual<Look?>(new Look(IsBold: true, IsQuote: true, Link: "https://a.b"), At(nested, "y"));
        Assert.AreEqual<Look?>(new Look(IsQuote: true, IsMarker: true), At(nested, "](https://a.b)"));
        Assert.AreEqual<Look?>(new Look(IsBullet: true), At(Looks("- 项"), "-"));
        Assert.IsNull(At(Looks("- 项"), "项"));
        // 没有样式的段不给；空区间不算
        Assert.AreEqual(0, NoteStyles.Runs(new List<NoteStyles.Span>()).Count);
        Assert.AreEqual(0, NoteStyles.Runs(new List<NoteStyles.Span> { new(R(3, 0), Kind.Bold) }).Count);
    }

    // ---- 套用（AppKit 那一半跳过，见文件头）----

    /// <summary>attributesOfEachStyle 里的字号：标题按级别放大（整点）、行内代码小一号；正文 15 时一级标题 24、三级 19、
    /// 三级标题里的代码 17、正文里的代码 14（mac 那条用字体对象核对的就是这几个数）。</summary>
    [TestMethod]
    public void HeadingAndCodeSizes()
    {
        Assert.AreEqual(24.0, NoteStyles.HeadingSize(1, 15));
        Assert.AreEqual(19.0, NoteStyles.HeadingSize(3, 15));
        Assert.AreEqual(17.0, NoteStyles.CodeSize(NoteStyles.HeadingSize(3, 15)));
        Assert.AreEqual(14.0, NoteStyles.CodeSize(15));
        Assert.AreEqual(21.0, NoteStyles.HeadingSize(1, 13));
        Assert.AreEqual(15.0, NoteStyles.HeadingSize(4, 13));
        Assert.AreEqual(20.0, NoteStyles.HeadingSize(5, 20));
        Assert.AreEqual(17.0, NoteStyles.HeadingSize(6, 17));
        Assert.AreEqual(24.0, NoteStyles.HeadingSize(2, 17));
        Assert.AreEqual(25.0, NoteStyles.HeadingSize(3, 20));
    }

    /// <summary>lineByLineEqualsWholeText 的最后一段：把链接的「]」删掉，要重排的就是那一行（连换行），那一行再扫出来没有标记、没有链接。</summary>
    [TestMethod]
    public void BrokenLinkLineIsRestyledClean()
    {
        var before = "前一行 **粗**\n看 [字](https://a.b) 后\n后一行";
        var bracket = before.IndexOf(']');
        var text = before.Remove(bracket, 1);
        var line = NoteStyles.LinesCovering(R(bracket), text);
        Assert.AreEqual("看 [字(https://a.b) 后\n", text.Substring(line.Location, line.Length));
        var spans = NoteStyles.Spans(text.Substring(line.Location, line.Length - 1), markdown: true);
        Assert.IsFalse(spans.Any(span => span.Kind.Tag is KindTag.Marker or KindTag.Link));
        // 前一行没动：还认得出粗体
        Assert.IsTrue(NoteStyles.Spans("前一行 **粗**", markdown: true).Any(span => span.Kind == Kind.Bold));
    }

    // ---- 标题和摘要 ----

    private static Note NoteWith(string body) => new() { Id = "x", Body = body };

    /// <summary>标题、摘要里不带 Markdown 的标记（不看设置里的开关）；不是标记的原样。</summary>
    [TestMethod]
    public void TitlesAndPreviewsDropMarkers()
    {
        Assert.AreEqual("粗 和 斜 和 删 和 码", NoteWith("**粗** 和 *斜* 和 ~~删~~ 和 `码`").DisplayTitle);
        Assert.AreEqual("看 这里 的", NoteWith("看 [这里](https://example.com/很长的地址) 的").DisplayTitle);
        Assert.AreEqual("标题里的 粗", NoteWith("# 标题里的 **粗**").DisplayTitle);
        Assert.AreEqual("引用的一句", NoteWith("> 引用的一句").DisplayTitle);
        Assert.AreEqual("牛奶", NoteWith("- 牛奶").DisplayTitle);
        Assert.AreEqual("鸡蛋", NoteWith("  * 鸡蛋").DisplayTitle);
        Assert.AreEqual("买 牛奶", NoteWith("☐ **买** 牛奶").DisplayTitle);
        // 不是标记的不动：词里的下划线、代码里的星号、转义的、没配对的、图片、有序列表的序号
        Assert.AreEqual("snake_case_name", NoteWith("snake_case_name").DisplayTitle);
        Assert.AreEqual("a*b*c", NoteWith("`a*b*c`").DisplayTitle);
        Assert.AreEqual("\\*不是斜体\\*", NoteWith("\\*不是斜体\\*").DisplayTitle);
        Assert.AreEqual("2 * 3 * 4 和 **没关上", NoteWith("2 * 3 * 4 和 **没关上").DisplayTitle);
        // 数字中间的星号是乘号：标题里原样
        Assert.AreEqual("2*3*4", NoteWith("2*3*4").DisplayTitle);
        Assert.AreEqual("箱子 60*40*30", NoteWith("# 箱子 60*40*30").DisplayTitle);
        // 贴进来没转成方框的任务（- [ ] / - [x]）：连符号一起去；后面没跟空格的不算
        Assert.AreEqual("买牛奶", NoteWith("- [ ] 买牛奶").DisplayTitle);
        Assert.AreEqual("做完的", NoteWith("  * [x] 做完的").DisplayTitle);
        Assert.AreEqual("粗 的", NoteWith("+ [X] **粗** 的").DisplayTitle);
        Assert.AreEqual("第二行", NoteWith("- [ ]\n第二行").DisplayTitle);
        Assert.AreEqual("买牛奶 鸡蛋", NoteWith("标题\n- [ ] 买牛奶\n- [x] 鸡蛋").Preview);
        Assert.AreEqual("[ ]紧挨着", NoteWith("- [ ]紧挨着").DisplayTitle);
        Assert.AreEqual("[y] 别的", NoteWith("- [y] 别的").DisplayTitle);
        Assert.AreEqual("- [ ] 标题里的", NoteWith("# - [ ] 标题里的").DisplayTitle);
        Assert.AreEqual("![图](x.png)", NoteWith("![图](x.png)").DisplayTitle);
        Assert.AreEqual("1. 第一条", NoteWith("1. 第一条").DisplayTitle);
        // 标题、任务的内容里不再去行首的 > 和 -（它们在那里只是字）
        Assert.AreEqual("> 大于号", NoteWith("# > 大于号").DisplayTitle);
        Assert.AreEqual("- 横线", NoteWith("☑ - 横线").DisplayTitle);
        // 去掉标记之后是空的那一行跳过
        Assert.AreEqual("真正的第一行", NoteWith(">\n- \n真正的第一行").DisplayTitle);
        Assert.AreEqual("牛奶 引用 码 字", NoteWith("标题\n- **牛奶**\n> 引用 `码`\n[字](https://a.b)").Preview);
        Assert.AreEqual("粗 > 不在行首", NoteMarkdown.Plain("**粗** > 不在行首", blocks: true));
        Assert.AreEqual("> 引用", NoteMarkdown.Plain("> 引用", blocks: false));
        Assert.AreEqual("没有标记", NoteMarkdown.Plain("没有标记", blocks: true));
    }

    /// <summary>行距三档（theSwitchIsARegisteredPreference 的后一半；偏好注册那一半在设置的单测里）。</summary>
    [TestMethod]
    public void SpacingHasThreeSteps()
    {
        CollectionAssert.AreEqual(new[] { "compact", "standard", "relaxed" },
            NoteStyles.AllSpacings.Select(NoteStyles.SpacingName).ToList());
        CollectionAssert.AreEqual(new[] { 1.2, 1.45, 1.7 }, NoteStyles.AllSpacings.Select(NoteStyles.SpacingValue).ToList());
        CollectionAssert.AreEqual(new[] { "紧凑", "标准", "宽松" }, NoteStyles.AllSpacings.Select(NoteStyles.SpacingTitle).ToList());
        foreach (var spacing in NoteStyles.AllSpacings)
        {
            Assert.AreEqual<NoteSpacing?>(spacing, NoteStyles.SpacingFromName(NoteStyles.SpacingName(spacing)));
        }

        Assert.IsNull(NoteStyles.SpacingFromName("Standard"));
    }

    // ---- 代码块、行距、加标记的快捷键、粘贴成链接 ----

    /// <summary>围栏行的认法：三个以上同一种的反引号或波浪号、前面最多 3 个空格、后面可以跟语言名（反引号的语言名里不能再有反引号）；
    /// 只有空白的才能收尾。</summary>
    [TestMethod]
    public void Fences()
    {
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('`', 3, true), NoteMarkdown.FenceOf("```"));
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('`', 4, false), NoteMarkdown.FenceOf("````swift"));
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('~', 3, true), NoteMarkdown.FenceOf("~~~"));
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('`', 3, true), NoteMarkdown.FenceOf("   ```  "));
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('`', 3, false), NoteMarkdown.FenceOf("``` js"));
        Assert.AreEqual<NoteMarkdown.Fence?>(new NoteMarkdown.Fence('~', 3, false), NoteMarkdown.FenceOf("~~~ 带`反引号`的"));
        // 不是围栏：四个空格、不够三个、两种混着、行内代码、前面有字、Tab 缩进、空行
        foreach (var line in new[] { "    ```", "``", "~~", "`~~", "```a```", "``` `x`", "a```", "\t```", "" })
        {
            Assert.IsNull(NoteMarkdown.FenceOf(line), line);
        }
    }

    /// <summary>配对：开头往后找第一行「同一种字符、不少于开头的个数、后面只有空白」的围栏收尾；中间夹着的围栏是块里的字；
    /// 没关上的开头不算（照普通的一行），接着往下找；挨着的两块各是各的。</summary>
    [TestMethod]
    public void CodeBlocksPair()
    {
        static List<string> Blocks(string text)
            => NoteMarkdown.CodeBlocks(text).Select(block => text.Substring(block.Range.Location, block.Range.Length)).ToList();

        CollectionAssert.AreEqual(new[] { "```swift\nlet a = 1\n```\n" }, Blocks("前\n```swift\nlet a = 1\n```\n后"));
        // 收尾在正文末尾（没有换行）、空的块
        CollectionAssert.AreEqual(new[] { "```\nx\n```" }, Blocks("```\nx\n```"));
        CollectionAssert.AreEqual(new[] { "```\n```\n" }, Blocks("```\n```\n"));
        // 没关上：不算——刚打出开头的三个反引号，后面不会突然都成了代码
        Assert.AreEqual(0, Blocks("```\nx\n# 标题\n**粗**").Count);
        // 个数不够、带语言名、另一种字符的都不能收尾
        CollectionAssert.AreEqual(new[] { "````\na\n```\nb\n````" }, Blocks("````\na\n```\nb\n````"));
        CollectionAssert.AreEqual(new[] { "```\na\n```js\n```" }, Blocks("```\na\n```js\n```"));
        CollectionAssert.AreEqual(new[] { "~~~\n```\n~~~" }, Blocks("~~~\n```\n~~~"));
        // 没关上的开头跳过之后，后面的照样配
        CollectionAssert.AreEqual(new[] { "```\nx\n```" }, Blocks("~~~~\n```\nx\n```"));
        CollectionAssert.AreEqual(new[] { "```\na\n```\n", "```\nb\n```" }, Blocks("```\na\n```\n```\nb\n```"));
        // 每一行的角色：开头、块里、收尾；块外 null
        // x 0 换行 1 | ``` 2-4 换行 5 | a 6 换行 7 | 换行 8 | ``` 9-11 换行 12 | y 13
        var text = "x\n```\na\n\n```\ny";
        var found = NoteMarkdown.CodeBlocks(text);
        CollectionAssert.AreEqual(
            new Role?[] { null, Role.Open, Role.Content, Role.Content, Role.Close, null },
            new[] { 0, 2, 6, 8, 9, 13 }.Select(start => NoteMarkdown.RoleAt(start, found)).ToList());
        // 很多没关上的开头（一路往下都找不到收尾）：不会越来越慢——同一种字符、不少于这么多的，后面直接跳过
        Assert.AreEqual(0, NoteMarkdown.CodeBlocks(Repeat("```a\n", 20_000)).Count);
    }

    /// <summary>codeBlockLinesAreVerbatim 的纯函数那一半：代码块里每一行的角色（开头 / 块里 / 收尾，块外没有），块里的行整行一种样式、
    /// 里面什么都不认；没配上对的围栏行照普通的一行（后面的标题照常是标题）。</summary>
    [TestMethod]
    public void CodeBlockLinesAreVerbatim()
    {
        var text = "前面 **粗**\n```swift\n# 不是标题 **不粗** [不是](https://a.b)\n☐ 不是任务\n- 不是列表\n```\n后面 *斜*";
        var blocks = NoteMarkdown.CodeBlocks(text);
        Role? RoleOf(string fragment) => NoteMarkdown.RoleAt(NoteText.Line(text, text.IndexOf(fragment, StringComparison.Ordinal)).Start, blocks);
        Assert.AreEqual<Role?>(Role.Open, RoleOf("```swift"));
        Assert.AreEqual<Role?>(Role.Content, RoleOf("不是标题"));
        Assert.AreEqual<Role?>(Role.Content, RoleOf("☐ 不是"));
        Assert.AreEqual<Role?>(Role.Content, RoleOf("- 不是"));
        Assert.AreEqual<Role?>(Role.Close, RoleOf("```\n后"));
        Assert.IsNull(RoleOf("前面"));
        Assert.IsNull(RoleOf("后面"));
        var line = "# 不是标题 **不粗** [不是](https://a.b)";
        CollectionAssert.AreEqual(
            new[] { new NoteStyles.Span(R(0, line.Length), Kind.CodeBlock) }, NoteStyles.BlockSpans(line, Role.Content));
        CollectionAssert.AreEqual(
            new[] { new NoteStyles.Span(R(0, 8), Kind.Fence) }, NoteStyles.BlockSpans("```swift", Role.Open));
        // 没配上对的围栏行照普通的一行
        Assert.AreEqual(0, NoteMarkdown.CodeBlocks("```js\n# 标题").Count);
        Assert.AreEqual(NoteStyles.Shape.Heading(1), NoteStyles.ShapeOf("# 标题", markdown: true, role: null));
    }

    /// <summary>lineHeightsFollowTheSpacing 的数：每一行的行高 = 这一行的字号 × 倍数（整点），三档都对；标准档正文 22、一级标题 35、代码 20。</summary>
    [TestMethod]
    public void LineHeightsFollowTheSpacing()
    {
        foreach (var spacing in NoteStyles.AllSpacings)
        {
            var multiple = NoteStyles.SpacingValue(spacing);
            Assert.AreEqual(Math.Round(15 * multiple, MidpointRounding.AwayFromZero), NoteStyles.LineHeight(15, spacing));
            Assert.AreEqual(Math.Round(24 * multiple, MidpointRounding.AwayFromZero),
                NoteStyles.LineHeight(NoteStyles.HeadingSize(1, 15), spacing));
            Assert.AreEqual(Math.Round(14 * multiple, MidpointRounding.AwayFromZero),
                NoteStyles.LineHeight(NoteStyles.CodeSize(15), spacing));
        }

        Assert.AreEqual(22.0, NoteStyles.LineHeight(15, NoteSpacing.Standard));
        Assert.AreEqual(35.0, NoteStyles.LineHeight(24, NoteSpacing.Standard));
        Assert.AreEqual(20.0, NoteStyles.LineHeight(14, NoteSpacing.Standard));
    }

    private static Edit? Wrapped(Wrap wrap, string text, NoteRange selection)
        => Applied(NoteMarkdown.Toggle(wrap, text, selection), text);

    /// <summary>加标记的快捷键：没有选区插一对、光标在中间，再按一次（中间还空着）删掉；有选区两头加上，再按一次去掉；每一行各自包、
    /// 跳过行首的块标记和两头的空白；几段里有没包的就都包上，都包着才都去掉；斜体只认单数个星号（两个是粗体）。</summary>
    [TestMethod]
    public void WrapToggles()
    {
        // 没有选区：插一对、光标在中间；中间还空着再按：删掉
        Assert.AreEqual(new Edit("周报****", R(4)), Wrapped(Wrap.Bold, "周报", R(2)));
        Assert.AreEqual(new Edit("周报", R(2)), Wrapped(Wrap.Bold, "周报****", R(4)));
        Assert.AreEqual(new Edit("a**b", R(2)), Wrapped(Wrap.Italic, "ab", R(1)));
        Assert.AreEqual(new Edit("ab", R(1)), Wrapped(Wrap.Italic, "a**b", R(2)));
        Assert.AreEqual(new Edit("~~~~", R(2)), Wrapped(Wrap.Strike, "", R(0)));
        Assert.AreEqual(new Edit("x", R(1)), Wrapped(Wrap.Code, "x``", R(2)));
        // 光标在行首的块标记里：挪到内容开头再插
        Assert.AreEqual(new Edit("- ****牛奶", R(4)), Wrapped(Wrap.Bold, "- 牛奶", R(0)));
        Assert.AreEqual(new Edit("# ``标题", R(3)), Wrapped(Wrap.Code, "# 标题", R(1)));
        // 有选区：两头加上、选中的还是那几个字；再按一次去掉（选中的是里面的字、或连标记一起选的都认）
        Assert.AreEqual(new Edit("看**周报**了", R(3, 2)), Wrapped(Wrap.Bold, "看周报了", R(1, 2)));
        Assert.AreEqual(new Edit("看周报了", R(1, 2)), Wrapped(Wrap.Bold, "看**周报**了", R(3, 2)));
        Assert.AreEqual(new Edit("看周报了", R(1, 2)), Wrapped(Wrap.Bold, "看**周报**了", R(1, 6)));
        Assert.AreEqual(new Edit("去掉 ~~this~~", R(5, 4)), Wrapped(Wrap.Strike, "去掉 this", R(3, 4)));
        Assert.AreEqual(new Edit("a b c", R(2, 1)), Wrapped(Wrap.Code, "a `b` c", R(3, 1)));
        // 斜体只认单数个：粗体里再按 Ctrl+I 是又粗又斜，又粗又斜里按 Ctrl+I 去掉斜体
        Assert.AreEqual(new Edit("***粗***", R(3, 1)), Wrapped(Wrap.Italic, "**粗**", R(2, 1)));
        Assert.AreEqual(new Edit("**粗**", R(2, 1)), Wrapped(Wrap.Italic, "***粗***", R(3, 1)));
        Assert.AreEqual(new Edit("*粗*", R(1, 1)), Wrapped(Wrap.Bold, "***粗***", R(3, 1)));
        // 两头的空白、行首的块标记不包进去
        Assert.AreEqual(new Edit("  **周报** ", R(4, 2)), Wrapped(Wrap.Bold, "  周报 ", R(0, 5)));
        Assert.AreEqual(new Edit("- **牛奶**", R(4, 2)), Wrapped(Wrap.Bold, "- 牛奶", R(0, 4)));
        Assert.AreEqual(new Edit("☐ *任务*", R(3, 2)), Wrapped(Wrap.Italic, "☐ 任务", R(0, 4)));
        Assert.AreEqual(new Edit("> **引用**", R(4, 2)), Wrapped(Wrap.Bold, "> 引用", R(0, 4)));
        // 每一行各自包；空行、只有空白的跳过；都包着才都去掉，有一行没包就都包上（包着的那行不动）
        Assert.AreEqual(new Edit("**一行**\n\n  \n**二行**", R(2, 13)), Wrapped(Wrap.Bold, "一行\n\n  \n二行", R(0, 9)));
        Assert.AreEqual(new Edit("一行\n二行", R(0, 5)), Wrapped(Wrap.Bold, "**一行**\n**二行**", R(0, 13)));
        Assert.AreEqual(new Edit("**一行**\n**二行**", R(2, 9)), Wrapped(Wrap.Bold, "**一行**\n二行", R(0, 9)));
        // 选了几行包上之后再按：选区盖着「第一行的字……最后一行的字」，中间的标记一半在里面也连起来数
        Assert.AreEqual(new Edit("一行\n二行", R(0, 5)), Wrapped(Wrap.Bold, "**一行**\n**二行**", R(2, 9)));
        // 都是空白、选中的只有块标记：没有可包的
        Assert.IsNull(Wrapped(Wrap.Bold, "   ", R(0, 3)));
        Assert.IsNull(Wrapped(Wrap.Bold, "- ", R(0, 2)));
        // 「已经包着」问扫描器、不数字符：数字中间的星号是乘号；两头加上的星号紧挨着数字，扫描器认不出来，复验挡住——不改、响一声
        Assert.IsNull(Wrapped(Wrap.Italic, "箱子 60*40*30", R(6, 2)));
        Assert.IsNull(Wrapped(Wrap.Italic, "2*3*4", R(2, 1)));
        // 光标夹在挨着的两段中间：中间那两对标记各归各的，不当成一对空的删掉（两段不并成一段），照常插一对
        Assert.AreEqual(new Edit("**a********b**", R(7)), Wrapped(Wrap.Bold, "**a****b**", R(5)));
        Assert.AreEqual(new Edit("`x````y`", R(4)), Wrapped(Wrap.Code, "`x``y`", R(3)));
        Assert.AreEqual(new Edit("*a****b*", R(4)), Wrapped(Wrap.Italic, "*a**b*", R(3)));
    }

    private static Edit? Pasted(string pasted, string line, NoteRange selection)
        => Applied(NoteMarkdown.LinkPaste(pasted, line, selection), line);

    /// <summary>粘贴成链接：一个能打开的网址（两头的空白、换行去掉）、选中的是一行里的一段字 → 「[字](网址)」，光标在后面；几个网址、
    /// 一段话、打不开的地址（file:）、选中的在行内代码里、拼出来认不出是链接（括号不成对）的：null。</summary>
    [TestMethod]
    public void PastedUrlsBecomeLinks()
    {
        Assert.AreEqual(new Edit("看[这里](https://example.com/a)吧", R(28)), Pasted("https://example.com/a", "看这里吧", R(1, 2)));
        Assert.AreEqual(new Edit("[点我](https://a.b)", R(17)), Pasted(" https://a.b \n", "点我", R(0, 2)));
        Assert.AreEqual(new Edit("[写信](mailto:x@y.z)", R(18)), Pasted("mailto:x@y.z", "写信", R(0, 2)));
        Assert.AreEqual(new Edit("[维基](https://a.b/(x))", R(21)), Pasted("https://a.b/(x)", "维基", R(0, 2)));
        // 任务行、列表行的内容里照样
        Assert.AreEqual(new Edit("☐ 看[文档](https://a.b)", R(20)), Pasted("https://a.b", "☐ 看文档", R(3, 2)));
        // 不是一个能打开的网址
        Assert.IsNull(Pasted("https://a.b https://c.d", "两个", R(0, 2)));
        Assert.IsNull(Pasted("看看 https://a.b", "一段", R(0, 2)));
        Assert.IsNull(Pasted("file:///etc/hosts", "本地", R(0, 2)));
        Assert.IsNull(Pasted("example.com", "没协议", R(0, 3)));
        Assert.IsNull(Pasted("", "空", R(0, 1)));
        // 没有选区、选中的只有空白、在行内代码里、括号不成对、选中的字带方括号拼不成链接
        Assert.IsNull(Pasted("https://a.b", "字", R(1)));
        Assert.IsNull(Pasted("https://a.b", "a  b", R(1, 2)));
        Assert.IsNull(Pasted("https://a.b", "看 `代码` 后", R(3, 2)));
        Assert.IsNull(Pasted("https://a.b/)", "括号", R(0, 2)));
        Assert.IsNull(Pasted("https://a.b", "[半个", R(0, 3)));
    }

    /// <summary>标题和摘要：围栏行不当标题、不进摘要；块里的字照原文（不去标记）；没关上的围栏行就是普通的一行。</summary>
    [TestMethod]
    public void TitlesSkipFences()
    {
        Assert.AreEqual("let a = **1**", NoteWith("```swift\nlet a = **1**\n```\n后面").DisplayTitle);
        Assert.AreEqual("后面", NoteWith("```swift\nlet a = 1\n```\n后面").Preview);
        Assert.AreEqual("# 注释 正文", NoteWith("标题\n```\n# 注释\n```\n**正文**").Preview);
        Assert.AreEqual("真正的标题", NoteWith("~~~\n~~~\n真正的标题").DisplayTitle);
        Assert.AreEqual("```js", NoteWith("```js\n没关上").DisplayTitle);
    }

    // ---- 文字颜色（mac NoteBatch8Tests）----

    /// <summary>一行里认出来的颜色（按位置排好）。</summary>
    private static List<string> Colors(string line)
        => NoteMarkdown.Inline(line, 0, line.Length)
            .Where(span => span.Kind.Tag == KindTag.Color)
            .Select(span => $"{NoteColors.Name(span.Kind.Ink)}@{span.Range.Location}:{line.Substring(span.Range.Location, span.Range.Length)}")
            .ToList();

    [TestMethod]
    public void ColorScanning()
    {
        foreach (var color in NoteColors.All)
        {
            var name = NoteColors.Name(color);
            CollectionAssert.AreEqual(new[] { $"{name}@1:{name}的字" }, Colors($"[{name}的字]{{{name}}}"));
        }

        // 名字只认全小写的这六个；空白、没配上、空的、跨行都不算
        foreach (var line in new[] { "[字]{Red}", "[字]{RED}", "[字]{ red}", "[字]{red }", "[ ]{red}", "[] {red}", "[字]{red" })
        {
            Assert.AreEqual(0, Colors(line).Count, line);
        }

        // 反斜杠、行内代码、图片的方括号不是颜色
        foreach (var line in new[] { "\\[字]{red}", "`[字]{red}`", "![图]{red}" })
        {
            Assert.AreEqual(0, Colors(line).Count, line);
        }

        // 颜色里不套颜色：里面那个算，外面那一对原样
        CollectionAssert.AreEqual(new[] { "red@2:a" }, Colors("[[a]{red}]{blue}"));
        // 颜色里有粗体 / 链接；链接的字里可以有颜色
        CollectionAssert.AreEqual(new[] { "red@1:**粗**" }, Colors("[**粗**]{red}"));
        CollectionAssert.AreEqual(new[] { "red@2:字" }, Colors("[[字]{red}](https://a.b)"));
        CollectionAssert.AreEqual(new[] { "red@1:`码`" }, Colors("[`码`]{red}"));
    }

    private static string? Colored(NoteColor? color, string text, NoteRange selection)
        => NoteMarkdown.ApplyColor(color, text, selection)?.Apply(text);

    [TestMethod]
    public void ColorToggle()
    {
        var red = NoteColor.Red;
        // 整段、半段、跨粗体边界、跨链接
        Assert.AreEqual("[字]{red}", Colored(red, "字", R(0, 1)));
        Assert.AreEqual("[a]{red}**[b]{red}**c", Colored(red, "a**b**c", R(0, 6)));
        Assert.AreEqual("[a]{red}**[b]{red}**[c]{red}", Colored(red, "a**b**c", R(0, 8)));
        Assert.AreEqual("[[字]{red}](https://a.b)", Colored(red, "[字](https://a.b)", R(1, 1)));
        // 一半改色、默认颜色去色
        Assert.AreEqual("[ab]{red}c", Colored(red, "abc", R(0, 2)));
        Assert.AreEqual("abc", Colored(null, "[a]{red}bc", R(1, 1)));
        Assert.IsNull(NoteMarkdown.ApplyColor(null, "abc", R(0, 2)));
        // 代码、图片不能上色；图片旁边的字可以，图片自己不被包进去
        Assert.IsNull(NoteMarkdown.ApplyColor(red, "`a` b", R(0, 3)));
        Assert.AreEqual("[a]{red}\uFFFC[b]{red}", Colored(red, "a\uFFFCb", R(0, 3)));
        // 标题跳过行首的 #
        Assert.AreEqual("# [a b]{red}", Colored(red, "# a b", R(0, 5)));
        // 没有选区：不改（mac 这一条写的是「改了的话拼得出来」，没有选区时它本来就给 nil）
        Assert.IsNull(NoteMarkdown.ApplyColor(NoteColor.Purple, "**粗** *斜* ~~删~~ `码` [链](https://a.b)", R(0)));
    }

    /// <summary>一行两万字全选上色：结果对，而且时间是线性的。0.5 秒的上限是在防平方回来，不是卡性能。</summary>
    [TestMethod]
    public void ColoringAVeryLongLineStaysLinear()
    {
        const string unit = "abc **粗体** def `x`";
        const string coloredUnit = "[abc ]{red}**[粗体]{red}**[ def ]{red}`x`";
        const int repeats = 1112;
        var line = Repeat(unit, repeats);
        Assert.AreEqual(20016, line.Length);
        var clock = Stopwatch.StartNew();
        var change = NoteMarkdown.ApplyColor(NoteColor.Red, line, R(0, line.Length));
        clock.Stop();
        Assert.IsNotNull(change);
        Assert.AreEqual(Repeat(coloredUnit, repeats), change.Apply(line));
        Assert.IsTrue(clock.ElapsedMilliseconds < 500, $"一行两万字全选上色用了 {clock.ElapsedMilliseconds} ms");
    }

    [TestMethod]
    public void PlainAndStrippingRemoveColorMarkers()
    {
        Assert.AreEqual("字 和 粗", NoteMarkdown.Plain("[字]{red} 和 **粗**", blocks: false));
        Assert.AreEqual("字 **粗**", NoteMarkdown.StrippingColors("[字]{red} **粗**"));
        Assert.AreEqual("```\n[字]{red}\n```", NoteMarkdown.StrippingColors("```\n[字]{red}\n```"));
        Assert.AreEqual(3, NoteMarkdown.ColorOnlySpans("[字]{red} **粗**").Count);
        Assert.AreEqual(0, NoteMarkdown.ColorOnlySpans("**粗**").Count);
        // （这一条 mac 没有，移植时补的）标记在正文里的位置：行内代码里的不算，位置加上行首
        CollectionAssert.AreEqual(new[] { R(15, 1), R(17, 6) }, NoteMarkdown.ColorMarkers("前\n `[字]{red}`\n[字]{red}").ToList());
        Assert.IsFalse(NoteMarkdown.HasColorMarker("[字] {red}"));
    }

    [TestMethod]
    public void ColorHtmlRoundTrip()
    {
        Assert.AreEqual("<span style=\"color: #A11A14\">字</span>", NoteMarkdown.Html("[字]{red}"));
        Assert.AreEqual("<span style=\"color: #1D4FB8\">[链](https://a.b)</span>", NoteMarkdown.Html("[[链](https://a.b)]{blue}"));
        Assert.AreEqual("```\n[字]{red}\n```", NoteMarkdown.Html("```\n[字]{red}\n```"));
        foreach (var raw in new[]
                 {
                     "<span style=\"color: #a11a14\">字</span>",
                     "<span style=\"color:#A11A14;\">字</span>",
                     "<span style=\"color: #FF9C94\">字</span>",
                 })
        {
            Assert.AreEqual("[字]{red}", NoteMarkdown.BodyFromHtml(raw), raw);
        }

        // 别的 HTML、别的色值、行内代码和代码块里的都原样
        foreach (var raw in new[]
                 {
                     "<span style=\"color: #123456\">字</span>",
                     "<span class=\"x\">字</span>",
                     "<b>字</b>",
                     "`<span style=\"color: #A11A14\">字</span>`",
                     "```\n<span style=\"color: #A11A14\">字</span>\n```",
                     "<span style=\"color: #A11A14\">a<span>b</span>",
                 })
        {
            Assert.AreEqual(raw, NoteMarkdown.BodyFromHtml(raw), raw);
        }

        var body = "普通 [红]{red} **粗**\n```\n[代码]{red}\n```\n[蓝]{blue} 末";
        Assert.AreEqual(body, NoteMarkdown.BodyFromHtml(NoteMarkdown.Html(body)));
    }

    // ---- 格式合并、块格式、链接、清除格式、代码块（mac NoteBatch8bTests）----

    private static string? Blocked(BlockFormat format, string text, NoteRange selection)
        => NoteMarkdown.Block(format, text, selection)?.Apply(text);

    private static Edit? Cleared(string text, NoteRange selection) => Applied(NoteMarkdown.Clear(text, selection), text);

    private static Edit? Tinted(NoteColor? color, string text, NoteRange selection)
        => Applied(NoteMarkdown.ApplyColor(color, text, selection), text);

    private static string WithoutMarks(string text) => new(text.Where(ch => ch is not ('*' or '~')).ToArray());

    /// <summary>粗体 / 斜体 / 删除线整段一种：原来那一段并进来、中间的标记不留；用户打的、没配上的 * ** ~~ 一个都不许少。</summary>
    [TestMethod]
    public void EmphasisMergesIntoWholeRuns()
    {
        Assert.AreEqual(new Edit("**abcdef**", R(2, 6)), Wrapped(Wrap.Bold, "ab**cd**ef", R(0, 10)));
        Assert.AreEqual(new Edit("*abcdef*", R(1, 6)), Wrapped(Wrap.Italic, "ab*cd*ef", R(0, 8)));
        Assert.AreEqual(new Edit("~~123123~~", R(2, 6)), Wrapped(Wrap.Strike, "12~~312~~3", R(0, 10)));
        // 数字中间的 ** / * 是乘号、不是标记：全选加格式时原样留着、跟着一起变粗 / 斜
        Assert.AreEqual(new Edit("**12**312**3**", R(2, 10)), Wrapped(Wrap.Bold, "12**312**3", R(0, 10)));
        Assert.AreEqual(new Edit("*12*312*3*", R(1, 8)), Wrapped(Wrap.Italic, "12*312*3", R(0, 8)));
        foreach (var (wrap, line, expected) in new[]
                 {
                     (Wrap.Italic, "60*40*30 立方", "*60*40*30 立方*"),
                     (Wrap.Bold, "2**3 等于 8", "**2**3 等于 8**"),
                     (Wrap.Bold, "src/**/a.swift 和 docs", "**src/**/a.swift 和 docs**"),
                     (Wrap.Strike, "价格 ~~ 不定", "~~价格 ~~ 不定~~"),
                 })
        {
            var result = Wrapped(wrap, line, R(0, line.Length));
            // 认不出来时响一声、不改也可以；改了的话用户打的字一个都不能少
            Assert.IsTrue(result is null || result.Text == expected, $"{line} → {result?.Text ?? "nil"}");
            if (result is not null)
            {
                Assert.AreEqual(WithoutMarks(line), WithoutMarks(result.Text));
                Assert.AreEqual(line.Length + 2 * NoteMarkdown.MarkerLength(wrap), result.Text.Length, $"{line} → {result.Text}");
            }
        }

        // **ab**cd 里选中 bc（连中间的两颗星）：跨在选区边上的 a 并进来，选区外的 d 不动
        Assert.AreEqual(new Edit("**abc**d", R(3, 2)), Wrapped(Wrap.Bold, "**ab**cd", R(3, 4)));
        // **abc** 里只选 b：拆成 a、b、c 三段
        Assert.AreEqual(new Edit("**a**b**c**", R(5, 1)), Wrapped(Wrap.Bold, "**abc**", R(3, 1)));
        // 斜体、删除线也一样
        Assert.AreEqual(new Edit("*abc*d", R(2, 2)), Wrapped(Wrap.Italic, "*ab*cd", R(2, 3)));
        Assert.AreEqual(new Edit("~~abc~~d", R(3, 2)), Wrapped(Wrap.Strike, "~~ab~~cd", R(3, 4)));
        // 都已经是：去掉，选区还是那些字
        Assert.AreEqual(new Edit("看周报了", R(1, 2)), Wrapped(Wrap.Bold, "看**周报**了", R(1, 6)));
        // 没有可加的字：null（不数字符）
        Assert.IsNull(Wrapped(Wrap.Bold, "   ", R(0, 3)));
        Assert.IsNull(Wrapped(Wrap.Bold, "`代码`", R(1, 2)));
    }

    [TestMethod]
    public void EmphasisMergesLineByLine()
    {
        // 第一行已经是、第二行不是：都包上，第一行并成一段、不留原来的标记
        Assert.AreEqual(new Edit("**一行**\n**第二行**", R(2, 10)), Wrapped(Wrap.Bold, "**一**行\n第二行", R(0, 10)));
        // 两行都是：都去掉；空行和只有空白的行跳过
        Assert.AreEqual(new Edit("一行\n\n  \n二行", R(0, 9)), Wrapped(Wrap.Bold, "**一行**\n\n  \n**二行**", R(0, 17)));
        // 别的标记断开一串：粗体不能跨过斜体标记
        Assert.AreEqual(new Edit("**a*****b***", R(2, 7)), Wrapped(Wrap.Bold, "**a***b*", R(0, 8)));
    }

    [TestMethod]
    public void EmphasisKeepsCodeAndImagesAlone()
    {
        // 行内代码里的字不能加格式：选中的只有代码里的字 → null
        Assert.IsNull(Wrapped(Wrap.Italic, "a `b` c", R(3, 1)));
        // 选区跨过行内代码：两边的字各自包，代码不包
        Assert.AreEqual(new Edit("**a** `b` **c**", R(2, 11)), Wrapped(Wrap.Bold, "a `b` c", R(0, 7)));
        // 数字旁边重建出来的星号扫描器不认（复验挡住）
        Assert.IsNull(Wrapped(Wrap.Italic, "2*3*4", R(2, 1)));
    }

    [TestMethod]
    public void ColorsConsolidateFragments()
    {
        static NoteRange Full(string text) => R(0, text.Length);

        // 碎成三段、颜色没变：全选再选红，合成一段（不再响一声）
        const string fragmented = "[12]{red}[31232312]{red}[3]{red}";
        Assert.AreEqual("[12312323123]{red}", Tinted(NoteColor.Red, fragmented, Full(fragmented))?.Text);
        // 旧的颜色标记不算断开
        const string split = "[12]{red}3123[2312]{red}3";
        Assert.AreEqual("[12312323123]{red}", Tinted(NoteColor.Red, split, Full(split))?.Text);
        // 只选碎标记围着的字：外面的不动
        const string white = "白[12]{red}[3]{red}纸";
        var span = R(1, white.IndexOf("[3]{red}", StringComparison.Ordinal) + "[3]{red}".Length - 1);
        Assert.AreEqual("白[123]{red}纸", Tinted(NoteColor.Red, white, span)?.Text);
        // 一行里两种颜色一起改：合成一段新的颜色
        const string mixed = "[红]{red}[蓝]{blue}";
        Assert.AreEqual("[红蓝]{green}", Tinted(NoteColor.Green, mixed, Full(mixed))?.Text);
        // 颜色标记透明：一串能跨过旧的颜色标记
        const string pieces = "[a]{red}b[cd]{blue}e";
        Assert.AreEqual("[abcde]{red}", Tinted(NoteColor.Red, pieces, Full(pieces))?.Text);
    }

    /// <summary>复杂度锁：两万字一行，全选 Ctrl+B、全选上色都在 0.5 s 以内（Debug）。</summary>
    [TestMethod]
    public void HugeLineStaysFast()
    {
        var text = new string('字', 20_000);
        var selection = R(0, text.Length);
        var clock = Stopwatch.StartNew();
        Assert.IsNotNull(NoteMarkdown.Toggle(Wrap.Bold, text, selection));
        var bold = clock.Elapsed;
        clock.Restart();
        Assert.IsNotNull(NoteMarkdown.ApplyColor(NoteColor.Red, text, selection));
        var colored = clock.Elapsed;
        Assert.IsTrue(bold.TotalSeconds < 0.5 && colored.TotalSeconds < 0.5, $"加粗 {bold}，上色 {colored}");
    }

    [TestMethod]
    public void RebuildGivesUpWhenItCannotBeScannedBack()
    {
        // 拼出来扫描器认不出是粗体（两头紧挨着数字）：复验挡住，整次不改
        Assert.IsNull(Wrapped(Wrap.Bold, "12345", R(1, 3)));
        // 正常的一段照样能拼出来
        Assert.AreEqual(new Edit("a**2b3**c", R(3, 3)), Wrapped(Wrap.Bold, "a2b3c", R(1, 3)));
        Assert.AreEqual("a **b** c", Wrapped(Wrap.Bold, "a b c", R(2, 1))?.Text);
    }

    [TestMethod]
    public void HeadingsQuoteAndLists()
    {
        Assert.AreEqual("# 标题", Blocked(BlockFormat.Heading(1), "标题", R(0, 2)));
        Assert.AreEqual("## 标题", Blocked(BlockFormat.Heading(2), "# 标题", R(0, 1)));
        Assert.AreEqual("# 标题", Blocked(BlockFormat.Heading(1), "## 标题", R(0, 1)));
        // 缩进留着，标记加在缩进后面
        Assert.AreEqual("  # 标题", Blocked(BlockFormat.Heading(1), "  标题", R(0, 2)));
        // 引用：别的标记留着，不是引用的行加 >，都是引用才去掉
        Assert.AreEqual("> # 标题", Blocked(BlockFormat.Quote, "# 标题", R(0, 1)));
        Assert.AreEqual("> 引用\n> 普通", Blocked(BlockFormat.Quote, "> 引用\n普通", R(0, 8)));
        // 列表：把原来的块标记换成列表符号
        Assert.AreEqual("- 引用", Blocked(BlockFormat.Bullet, "> 引用", R(0, 1)));
        // 一层层套着的块标记：转换时整串换掉
        Assert.AreEqual("# 标题", Blocked(BlockFormat.Heading(1), "> 标题", R(0, 1)));
        Assert.AreEqual("# 标题", Blocked(BlockFormat.Heading(1), "> # 标题", R(0, 1)));
        Assert.AreEqual("- 项", Blocked(BlockFormat.Bullet, "> - 项", R(0, 1)));
        Assert.AreEqual("# 任务", Blocked(BlockFormat.Heading(1), "- ☐ 任务", R(0, 1)));
        // 去掉时只去自己那种标记，别的留着
        Assert.AreEqual("# 标题", Blocked(BlockFormat.Bullet, "- # 标题", R(0, 1)));
        Assert.AreEqual("- 项", Blocked(BlockFormat.Quote, "> - 项", R(0, 1)));
        Assert.AreEqual("牛奶", Blocked(BlockFormat.Bullet, "- 牛奶", R(0, 1)));
        // 有序列表：同一缩进一组、每组从 1 开始
        Assert.AreEqual("1. a\n  1. b\n2. c", Blocked(BlockFormat.Ordered, "a\n  b\nc", R(0, 7)));
        Assert.AreEqual("a\nb", Blocked(BlockFormat.Ordered, "1. a\n2. b", R(0, 7)));
        // 空行：选了好几行时空行不动，只有一行时空行也变
        Assert.AreEqual("- a\n\n- b", Blocked(BlockFormat.Bullet, "a\n\nb", R(0, 4)));
        Assert.AreEqual("  - ", Blocked(BlockFormat.Bullet, "  ", R(0, 1)));
    }

    [TestMethod]
    public void CodeBlockSpots()
    {
        const string text = "前\n```\n代码\n```\n后";
        Assert.AreEqual(NoteMarkdown.CodeSpot.Inside, NoteMarkdown.CodeSpotOf(text, R(8)));
        Assert.AreEqual(NoteMarkdown.CodeSpot.Outside, NoteMarkdown.CodeSpotOf(text, R(0, 1)));
        Assert.AreEqual(NoteMarkdown.CodeSpot.Straddles, NoteMarkdown.CodeSpotOf(text, R(0, 10)));
    }

    [TestMethod]
    public void CodeBlockToggles()
    {
        static string? Fenced(string text, NoteRange selection) => NoteMarkdown.CodeBlockChange(text, selection)?.Apply(text);

        // 光标在空行上：插三行、光标在中间
        Assert.AreEqual("a\n```\n\n```\nb", Fenced("a\n\nb", R(2)));
        // 选了字：给碰到的行上下加围栏
        Assert.AreEqual("```\na\nb\n```", Fenced("a\nb", R(0, 3)));
        // 块里：连围栏一起去掉
        Assert.AreEqual("a\n", Fenced("```\na\n```\n", R(4, 1)));
        // 一半在块里一半在外：null（界面停用 / 响一声）
        Assert.IsNull(Fenced("前\n```\na\n```\n后", R(0, 10)));
    }

    [TestMethod]
    public void LinkItem()
    {
        static Edit? Linked(string text, NoteRange selection) => Applied(NoteMarkdown.Link(text, selection), text);

        Assert.AreEqual(new Edit("看[]()这里", R(2)), Linked("看这里", R(1)));
        Assert.AreEqual(new Edit("看[这里]()", R(6)), Linked("看这里", R(1, 2)));
        Assert.IsNull(Linked("两\n行", R(0, 3)));
    }

    [TestMethod]
    public void ClearingFormat()
    {
        Assert.AreEqual(new Edit("粗体", R(0, 2)), Cleared("**粗**体", R(0, 6)));
        // 只选中间：外面照旧、会拆开
        Assert.AreEqual("**a**b**c**", Cleared("**abc**", R(3, 1))?.Text);
        // 行内代码、链接整段去掉标记；块格式不动
        Assert.AreEqual("看 代码 和 链接 了", Cleared("看 `代码` 和 [链接](https://e.com) 了", R(2, 16))?.Text);
        Assert.AreEqual("# 标题", Cleared("# **标题**", R(0, 10))?.Text);
        Assert.AreEqual("红色", Cleared("[红]{red}色", R(0, 9))?.Text);
        Assert.IsNull(Cleared("没有格式", R(0, 4)));
    }

    [TestMethod]
    public void FormattingChecks()
    {
        Assert.AreEqual<bool?>(true, NoteMarkdown.IsFormatted(Wrap.Bold, "**粗** 普通", R(2, 1)));
        Assert.AreEqual<bool?>(false, NoteMarkdown.IsFormatted(Wrap.Bold, "**粗** 普通", R(6, 2)));
        // 混着：不是全部
        Assert.AreEqual<bool?>(false, NoteMarkdown.IsFormatted(Wrap.Bold, "**粗** 普通", R(0, 8)));
        Assert.IsNull(NoteMarkdown.IsFormatted(Wrap.Bold, "`代码`", R(1, 2)));
        Assert.IsNull(NoteMarkdown.IsFormatted(Wrap.Bold, "**粗**", R(0)));
        Assert.AreEqual<bool?>(true, NoteMarkdown.BlockIsOn(BlockFormat.Bullet, "- a\n- b", R(0, 7)));
        Assert.AreEqual<bool?>(false, NoteMarkdown.BlockIsOn(BlockFormat.Bullet, "- a\nb", R(0, 5)));
        Assert.IsNull(NoteMarkdown.BlockIsOn(BlockFormat.Heading(1), "\n\n", R(0, 2)));
    }
}
