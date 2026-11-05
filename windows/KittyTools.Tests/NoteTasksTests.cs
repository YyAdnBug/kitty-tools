// 便签里的任务和列表（Core/Notes/NoteTasks.cs）的单测，照 mac NoteTasksTests.swift：认标记、Ctrl+T 切换（mac ⌘T）、选区跟着替换挪、
// 回车续行和空项退出、Tab / Shift+Tab 缩进、打「- [ ]」的自动转换、和 Markdown 互转、任务进度，期望值原样。
// 跳过的：spansOfALine、dirtyLinesCoverTheEdit、pendingMergesEdits（NoteStyles：正文编辑器一行要哪些样式、要重排哪几行，Windows 在编辑器里）；
// sampleNoteAndTitlesStillWork 里示例便签那一半（NoteSample），标题和摘要那一半留着。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteTasksTests
{
    private static NoteRange Range(int location, int length = 0) => new(location, length);

    private static NoteTasks.Lead TaskLead(NoteTaskState state) => new(NoteTasks.LeadKind.Task, state);

    private static NoteTasks.Lead Bullet(char symbol) => new(NoteTasks.LeadKind.Bullet, Symbol: symbol);

    private static NoteTasks.Lead Ordered(int number, char symbol) => new(NoteTasks.LeadKind.Ordered, Symbol: symbol, Number: number);

    /// <summary>把一次改动套到 text 上（从后往前换），返回改完的文字。</summary>
    private static string? Applied(NoteTasks.Change? change, string text) => change?.Apply(text);

    // ---- 认标记 ----

    [TestMethod]
    public void PrefixesOfTasks()
    {
        var open = NoteTasks.PrefixOf("☐ 周报");
        Assert.AreEqual(TaskLead(NoteTaskState.Todo), open?.Lead);
        Assert.AreEqual(0, open?.Indent);
        Assert.AreEqual(2, open?.ContentStart);
        var done = NoteTasks.PrefixOf("  \t☑ 订会议室");
        Assert.AreEqual(TaskLead(NoteTaskState.Done), done?.Lead);
        Assert.AreEqual(3, done?.Indent);
        Assert.AreEqual(5, done?.ContentStart);
        // 方框在行尾（后面的空格没了）也算；后面直接跟字的不算
        var bare = NoteTasks.PrefixOf("☐");
        Assert.AreEqual(TaskLead(NoteTaskState.Todo), bare?.Lead);
        Assert.IsFalse(bare?.HasSpace ?? true);
        Assert.AreEqual(1, bare?.ContentStart);
        Assert.IsNull(NoteTasks.PrefixOf("☐周报"));
        Assert.IsNull(NoteTasks.PrefixOf("☑\t周报"));
        // 行中间的方框不算
        Assert.IsNull(NoteTasks.PrefixOf("记得 ☐ 周报"));
        Assert.IsNull(NoteTasks.Box("a ☑ b"));
        Assert.AreEqual(0, NoteTasks.Box("☐ a"));
        Assert.AreEqual(4, NoteTasks.Box("    ☑"));
        Assert.IsNull(NoteTasks.Box("- a"));
        Assert.IsNull(NoteTasks.Box(string.Empty));
        Assert.AreEqual('☑', NoteTasks.Flipped('☐'));
        Assert.AreEqual('☐', NoteTasks.Flipped('☑'));
    }

    [TestMethod]
    public void PrefixesOfLists()
    {
        Assert.AreEqual(Bullet('-'), NoteTasks.PrefixOf("- 牛奶")?.Lead);
        Assert.AreEqual(Bullet('*'), NoteTasks.PrefixOf("  * 鸡蛋")?.Lead);
        Assert.AreEqual(Bullet('+'), NoteTasks.PrefixOf("+ ")?.Lead);
        // 符号后面要有空格：「-5」「**粗**」「---」都不是列表
        Assert.IsNull(NoteTasks.PrefixOf("-5 度"));
        Assert.IsNull(NoteTasks.PrefixOf("**粗**"));
        Assert.IsNull(NoteTasks.PrefixOf("---"));
        Assert.IsNull(NoteTasks.PrefixOf("-"));
        var ordered = NoteTasks.PrefixOf(" 12. 第十二");
        Assert.AreEqual(Ordered(12, '.'), ordered?.Lead);
        Assert.AreEqual(3, ordered?.MarkerLength);
        Assert.AreEqual(5, ordered?.ContentStart);
        Assert.AreEqual(Ordered(3, ')'), NoteTasks.PrefixOf("3) 第三")?.Lead);
        // 「2026.」后面没空格、十位以上的一长串数字、空行、普通行
        Assert.IsNull(NoteTasks.PrefixOf("2026.10"));
        Assert.IsNull(NoteTasks.PrefixOf("1."));
        Assert.IsNull(NoteTasks.PrefixOf("1234567890. 太长"));
        Assert.IsNull(NoteTasks.PrefixOf(string.Empty));
        Assert.IsNull(NoteTasks.PrefixOf("   "));
        Assert.IsNull(NoteTasks.PrefixOf("普通的一行"));
    }

    // ---- Ctrl+T ----

    [TestMethod]
    public void ToggleSingleLine()
    {
        // 普通行 → 任务：光标跟着往后让；光标在行首时落到方框后面
        var change = NoteTasks.Toggle("周报", Range(1));
        Assert.AreEqual("☐ 周报", Applied(change, "周报"));
        Assert.AreEqual(Range(3), change?.Selection);
        Assert.AreEqual(Range(2), NoteTasks.Toggle("周报", Range(0))?.Selection);
        // 保留缩进
        change = NoteTasks.Toggle("  周报", Range(4));
        Assert.AreEqual("  ☐ 周报", Applied(change, "  周报"));
        Assert.AreEqual(Range(6), change?.Selection);
        // 任务（做完没做完都一样）→ 普通行
        change = NoteTasks.Toggle("☐ 周报", Range(4));
        Assert.AreEqual("周报", Applied(change, "☐ 周报"));
        Assert.AreEqual(Range(2), change?.Selection);
        change = NoteTasks.Toggle("\t☑ 周报", Range(1));
        Assert.AreEqual("\t周报", Applied(change, "\t☑ 周报"));
        Assert.AreEqual(Range(1), change?.Selection);
        // 光标夹在方框和空格中间：收到行首
        Assert.AreEqual(Range(0), NoteTasks.Toggle("☐ 周报", Range(1))?.Selection);
        // 无序列表项：符号换成方框
        change = NoteTasks.Toggle("- 牛奶", Range(4));
        Assert.AreEqual("☐ 牛奶", Applied(change, "- 牛奶"));
        Assert.AreEqual(Range(4), change?.Selection);
        Assert.AreEqual("  ☐ 鸡蛋", Applied(NoteTasks.Toggle("  * 鸡蛋", Range(0)), "  * 鸡蛋"));
        // 有序的保留序号
        Assert.AreEqual("☐ 1. 第一", Applied(NoteTasks.Toggle("1. 第一", Range(0)), "1. 第一"));
        // 空行：先按 Ctrl+T 再打字
        change = NoteTasks.Toggle(string.Empty, Range(0));
        Assert.AreEqual("☐ ", Applied(change, string.Empty));
        Assert.AreEqual(Range(2), change?.Selection);
        Assert.AreEqual("  ☐ ", Applied(NoteTasks.Toggle("  ", Range(2)), "  "));
        // 方框在行尾（没有空格）也去得掉
        Assert.AreEqual(string.Empty, Applied(NoteTasks.Toggle("☐", Range(1)), "☐"));
    }

    [TestMethod]
    public void ToggleSeveralLines()
    {
        // 有一行还不是任务：都变成任务（已经是的不动、空行不动）
        const string mixed = "周报\n☑ 订会议室\n\n- 报销单";
        var change = NoteTasks.Toggle(mixed, Range(0, mixed.Length));
        Assert.AreEqual("☐ 周报\n☑ 订会议室\n\n☐ 报销单", Applied(change, mixed));
        // 选区照旧盖着这几行（开头不挪，末尾跟着变长）
        Assert.AreEqual(Range(0, mixed.Length + 2), change?.Selection);
        // 都是任务：都去掉
        const string tasks = "☐ 周报\n  ☑ 订会议室\n☐ 报销单";
        change = NoteTasks.Toggle(tasks, Range(2, 10));
        Assert.AreEqual("周报\n  订会议室\n报销单", Applied(change, tasks));
        Assert.AreEqual(Range(0, 8), change?.Selection);
        // 选了好几行、全是空行：没有可改的
        Assert.IsNull(NoteTasks.Toggle("\n\n", Range(0, 2)));
        // 替换是从前到后、互不相交的
        var ranges = NoteTasks.Toggle(mixed, Range(0, 3))?.Replacements.Select(replacement => replacement.Range).ToList();
        CollectionAssert.AreEqual(new[] { Range(0), Range(11, 1) }, ranges);
        // Windows 换行也分得开
        Assert.AreEqual("☐ a\r\n☐ b", Applied(NoteTasks.Toggle("a\r\nb", Range(0, 4)), "a\r\nb"));
    }

    [TestMethod]
    public void SelectionFollowsReplacements()
    {
        var insert = new[] { new NoteTasks.Replacement(Range(2), "☐ ") };
        // 光标在插入点前面不动、正好在插入点上挪到后面、在后面跟着让
        Assert.AreEqual(Range(1), NoteTasks.Mapped(Range(1), insert));
        Assert.AreEqual(Range(4), NoteTasks.Mapped(Range(2), insert));
        Assert.AreEqual(Range(7), NoteTasks.Mapped(Range(5), insert));
        // 一段选区的开头正好在插入点上：不挪，选区变长
        Assert.AreEqual(Range(2, 5), NoteTasks.Mapped(Range(2, 3), insert));
        var remove = new[] { new NoteTasks.Replacement(Range(2, 2), string.Empty) };
        Assert.AreEqual(Range(2), NoteTasks.Mapped(Range(3), remove));
        Assert.AreEqual(Range(2), NoteTasks.Mapped(Range(4), remove));
        Assert.AreEqual(Range(1, 4), NoteTasks.Mapped(Range(1, 6), remove));
    }

    // ---- 回车、Tab、自动转换 ----

    [TestMethod]
    public void NewlineContinuesLists()
    {
        // 任务：下一行带「☐ 」（做完的那行续出来的也是没做完的），保留缩进
        var change = NoteTasks.Newline("☐ 周报", 4);
        Assert.AreEqual("☐ 周报\n☐ ", Applied(change, "☐ 周报"));
        Assert.AreEqual(Range(7), change?.Selection);
        Assert.AreEqual("  ☑ 订会议室\n  ☐ ", Applied(NoteTasks.Newline("  ☑ 订会议室", 8), "  ☑ 订会议室"));
        // 光标在中间：后半句带到新的一条上
        change = NoteTasks.Newline("☐ 周报和月报", 4);
        Assert.AreEqual("☐ 周报\n☐ 和月报", Applied(change, "☐ 周报和月报"));
        Assert.AreEqual(Range(7), change?.Selection);
        // 无序：同一个符号；有序：下一个数字、同一种分隔
        Assert.AreEqual("* 牛奶\n* ", Applied(NoteTasks.Newline("* 牛奶", 4), "* 牛奶"));
        Assert.AreEqual("\t- 牛奶\n\t- ", Applied(NoteTasks.Newline("\t- 牛奶", 5), "\t- 牛奶"));
        Assert.AreEqual("9. 九\n10. ", Applied(NoteTasks.Newline("9. 九", 4), "9. 九"));
        Assert.AreEqual("1) 一\n2) ", Applied(NoteTasks.Newline("1) 一", 4), "1) 一"));
        // 不是列表行、光标还在标记前面：照常换行
        Assert.IsNull(NoteTasks.Newline("普通的一行", 3));
        Assert.IsNull(NoteTasks.Newline("☐ 周报", 0));
        Assert.IsNull(NoteTasks.Newline("  ☐ 周报", 3));
        Assert.IsNull(NoteTasks.Newline("☐ 周报", 99));
    }

    [TestMethod]
    public void NewlineOnAnEmptyItemLeavesTheList()
    {
        // 空任务、空列表项：去掉标记（留着缩进），光标在缩进后面
        var change = NoteTasks.Newline("☐ ", 2);
        Assert.AreEqual(string.Empty, Applied(change, "☐ "));
        Assert.AreEqual(Range(0), change?.Selection);
        change = NoteTasks.Newline("  - ", 4);
        Assert.AreEqual("  ", Applied(change, "  - "));
        Assert.AreEqual(Range(2), change?.Selection);
        Assert.AreEqual(string.Empty, Applied(NoteTasks.Newline("3. ", 3), "3. "));
        Assert.AreEqual(string.Empty, Applied(NoteTasks.Newline("☑", 1), "☑"));
        // 后面只有空白也算空的
        Assert.AreEqual(string.Empty, Applied(NoteTasks.Newline("☐   ", 3), "☐   "));
    }

    [TestMethod]
    public void TabIndentsListLines()
    {
        var change = NoteTasks.Indent("☐ 周报", 4, outdent: false);
        Assert.AreEqual("  ☐ 周报", Applied(change, "☐ 周报"));
        Assert.AreEqual(Range(6), change?.Selection);
        Assert.AreEqual("  - a", Applied(NoteTasks.Indent("- a", 0, outdent: false), "- a"));
        Assert.AreEqual("  1. a", Applied(NoteTasks.Indent("1. a", 0, outdent: false), "1. a"));
        // 退回：两个空格；只有一个就退一个；行首是 Tab 退那一个 Tab
        change = NoteTasks.Indent("    ☐ 周报", 8, outdent: true);
        Assert.AreEqual("  ☐ 周报", Applied(change, "    ☐ 周报"));
        Assert.AreEqual(Range(6), change?.Selection);
        change = NoteTasks.Indent(" ☐ 周报", 0, outdent: true);
        Assert.AreEqual("☐ 周报", Applied(change, " ☐ 周报"));
        Assert.AreEqual(Range(0), change?.Selection);
        Assert.AreEqual("- a", Applied(NoteTasks.Indent("\t- a", 4, outdent: true), "\t- a"));
        // 没有缩进可退：这一下吞掉，什么都不改
        change = NoteTasks.Indent("☐ 周报", 2, outdent: true);
        Assert.AreEqual(0, change?.Replacements.Count);
        Assert.AreEqual(Range(2), change?.Selection);
        // 别的行：照常（Tab 是制表符）
        Assert.IsNull(NoteTasks.Indent("普通的一行", 0, outdent: false));
        Assert.IsNull(NoteTasks.Indent(string.Empty, 0, outdent: true));
    }

    [TestMethod]
    public void ShorthandBecomesABox()
    {
        var change = NoteTasks.Shorthand("- [ ]", 5);
        Assert.AreEqual("☐ ", Applied(change, "- [ ]"));
        Assert.AreEqual(Range(2), change?.Selection);
        Assert.AreEqual("☐ ", Applied(NoteTasks.Shorthand("* [ ]", 5), "* [ ]"));
        Assert.AreEqual("☑ ", Applied(NoteTasks.Shorthand("- [x]", 5), "- [x]"));
        Assert.AreEqual("☑ ", Applied(NoteTasks.Shorthand("+ [X]", 5), "+ [X]"));
        // 保留缩进；后面已经有字也行
        change = NoteTasks.Shorthand("  - [ ]周报", 7);
        Assert.AreEqual("  ☐ 周报", Applied(change, "  - [ ]周报"));
        Assert.AreEqual(Range(4), change?.Selection);
        // 不在行首、光标不紧跟在后面、括号里是别的：不转
        Assert.IsNull(NoteTasks.Shorthand("a - [ ]", 7));
        Assert.IsNull(NoteTasks.Shorthand("- [ ]", 4));
        Assert.IsNull(NoteTasks.Shorthand("- [y]", 5));
        Assert.IsNull(NoteTasks.Shorthand("-[ ] ", 5));
        Assert.IsNull(NoteTasks.Shorthand(string.Empty, 0));
    }

    // ---- Markdown ----

    [TestMethod]
    public void MarkdownRoundTrips()
    {
        const string body = "周五前交的东西\n☐ 周报\n  ☑ 订会议室\r\n\t☐\n记得 ☐ 不算\n☐后面没空格\n";
        var markdown = NoteTasks.MarkdownFromBody(body);
        Assert.AreEqual("周五前交的东西\n- [ ] 周报\n  - [x] 订会议室\r\n\t- [ ]\n记得 ☐ 不算\n☐后面没空格\n", markdown);
        Assert.AreEqual(body, NoteTasks.BodyFromMarkdown(markdown));
        // 别的写法的 Markdown 任务也认；不是任务的不动
        const string foreign = "* [ ] 甲\n+ [X] 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  - [x]";
        var converted = NoteTasks.BodyFromMarkdown(foreign);
        Assert.AreEqual("☐ 甲\n☑ 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  ☑", converted);
        // 再转回去是规整过的写法，之后往返不变
        var canonical = NoteTasks.MarkdownFromBody(converted);
        Assert.AreEqual("- [ ] 甲\n- [x] 乙\n- [ ]丙\n- [] 丁\n- 普通列表\n  - [x]", canonical);
        Assert.AreEqual(canonical, NoteTasks.MarkdownFromBody(NoteTasks.BodyFromMarkdown(canonical)));
        Assert.AreEqual(string.Empty, NoteTasks.MarkdownFromBody(string.Empty));
        Assert.AreEqual(string.Empty, NoteTasks.BodyFromMarkdown(string.Empty));
    }

    // ---- 进度 ----

    [TestMethod]
    public void ProgressCountsTasks()
    {
        Assert.IsNull(NoteTasks.Progress(string.Empty));
        Assert.IsNull(NoteTasks.Progress("没有任务\n- 列表"));
        const string body = "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n下午三点";
        Assert.AreEqual((1, 3), NoteTasks.Progress(body));
        // 缩进的算；行中间的、后面没空格的不算；方框在行尾、在文末都算；各种换行（U+2028 写成转义，原字符在 C# 源码里算换行）
        const string tricky = "  ☑ 一\r\n\t☑\n记得 ☐ 不算\n☐不算\r☐ 二\u2028☑";
        var progress = NoteTasks.Progress(tricky);
        Assert.AreEqual((3, 4), progress);
        // 和认标记的口径是同一个：逐行数出来一样
        var (done, total) = (0, 0);
        foreach (var (start, contentsEnd, _) in NoteText.Lines(tricky))
        {
            if (NoteTasks.PrefixOf(tricky[start..contentsEnd]) is { Lead.Kind: NoteTasks.LeadKind.Task } prefix)
            {
                total++;
                if (prefix.Lead.State == NoteTaskState.Done)
                {
                    done++;
                }
            }
        }

        Assert.AreEqual((done, total), progress);
        var note = new Note { Id = "n", Body = body };
        Assert.AreEqual((1, 3), note.TaskProgress);
        Assert.AreEqual("1 / 3", Note.ProgressText((1, 3)));
        Assert.AreEqual("任务完成 1 项，共 3 项", Note.ProgressSpoken((1, 3)));
    }

    // ---- 标题、摘要 ----

    /// <summary>标题和摘要不带方框（mac sampleNoteAndTitlesStillWork 后一半）。</summary>
    [TestMethod]
    public void TitlesSkipTheBoxes()
    {
        var note = new Note { Id = "n", Body = "☐ 周报\n☑ 订会议室\n下午三点" };
        Assert.AreEqual("周报", note.DisplayTitle);
        Assert.AreEqual("订会议室 下午三点", note.Preview);
    }
}
