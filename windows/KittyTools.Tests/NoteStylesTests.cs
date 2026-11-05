// 便签正文样式里纯函数的单测（PLAN-v13 第 4 批的 Core 部分）：照 mac NoteTasksTests.swift 里测 NoteStyles 的三条移植，期望值原样
// （一行要哪些样式、编辑过的区间要重排哪几行、攒着的编辑区间怎么并）；另加 NeighborLines / Merged / BlockSpans / ShapeOf，和
// 移植时改写成纯函数的 RoleChanges 的自检（mac 那边它读文本存储，测试在编辑器那一侧）。
// 跳过的：NoteTextViewTests.swift、NoteEditorFuzzTests.swift 的用例全都要一个真的 NSTextView（藏字形、光标行、输入法、
// 点链接、右键菜单、按键、随机编辑和整篇重排逐字比）——里面没有直接调 NoteStyles 纯函数的，到 WinUI 的编辑器那一批对着
// RichEditBox 重写。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Kind = KittyTools.Core.Notes.NoteStyles.Kind;
using Role = KittyTools.Core.Notes.NoteMarkdown.Role;
using Span = KittyTools.Core.Notes.NoteStyles.Span;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteStylesTests
{
    private static NoteRange R(int location, int length = 0) => new(location, length);

    /// <summary>任务的样式（Markdown 关着时一行的全部样式；开着时多出来的在 NoteMarkdownTests）。</summary>
    [TestMethod]
    public void SpansOfALine()
    {
        static List<Span> Spans(string line) => NoteStyles.Spans(line, markdown: false);

        // 没做完的：只有方框那一个字
        CollectionAssert.AreEqual(new[] { new Span(R(0, 1), Kind.Box(NoteTaskState.Todo)) }, Spans("☐ 周报"));
        // 做完的：方框 + 内容（划线、变淡），缩进不算
        CollectionAssert.AreEqual(
            new[] { new Span(R(2, 1), Kind.Box(NoteTaskState.Done)), new Span(R(4, 7), Kind.Done) }, Spans("  ☑ 订会议室 🙂"));
        // 做完的空任务没有内容
        CollectionAssert.AreEqual(new[] { new Span(R(0, 1), Kind.Box(NoteTaskState.Done)) }, Spans("☑ "));
        CollectionAssert.AreEqual(new[] { new Span(R(0, 1), Kind.Box(NoteTaskState.Done)) }, Spans("☑"));
        // 不是任务的行没有样式
        foreach (var line in new[] { "普通的一行", "- 列表", "记得 ☑ 不算", "" })
        {
            Assert.AreEqual(0, Spans(line).Count, line);
        }
    }

    [TestMethod]
    public void DirtyLinesCoverTheEdit()
    {
        const string text = "第一行\n🙂 表情\n☐ 任务\n";
        Assert.AreEqual(15, text.Length);
        // 改一个字：只排这一行（连行尾的换行）
        Assert.AreEqual(R(4, 6), NoteStyles.LinesCovering(R(5, 1), text));
        // 表情是两个 UTF-16：区间落在它中间也不越界、扩到整行
        Assert.AreEqual(R(4, 6), NoteStyles.LinesCovering(R(5, 0), text));
        // 行首的编辑带上前一行（插入、删除换行时两头都要重排）
        Assert.AreEqual(R(0, 10), NoteStyles.LinesCovering(R(4, 1), text));
        // 刚插入的换行：前后两行
        Assert.AreEqual(R(0, 10), NoteStyles.LinesCovering(R(3, 1), text));
        // 文末的空行：带上最后一行，不越界
        Assert.AreEqual(R(10, 5), NoteStyles.LinesCovering(R(15, 0), text));
        // 区间比正文还长（攒着的时候正文变短了）：夹回来
        Assert.AreEqual(R(10, 5), NoteStyles.LinesCovering(R(12, 99), text));
        Assert.AreEqual(R(15, 0), NoteStyles.LinesCovering(R(99, 5), text));
        Assert.AreEqual(R(0, 0), NoteStyles.LinesCovering(R(0, 0), string.Empty));
        Assert.AreEqual(R(0, 4), NoteStyles.LinesCovering(R(0, 0), text));
    }

    [TestMethod]
    public void PendingMergesEdits()
    {
        var pending = new NoteStyles.Pending();
        Assert.IsNull(pending.Take());
        // 组字：同一个地方连着改（「p」→「pi」→「pin」→「拼」）
        pending.Record(R(5, 1), delta: 1);
        pending.Record(R(5, 2), delta: 1);
        pending.Record(R(5, 3), delta: 1);
        pending.Record(R(5, 1), delta: -2);
        Assert.AreEqual<NoteRange?>(R(5, 1), pending.Take());
        Assert.IsNull(pending.Range);
        // 后面记着一段，前面又插了字：后面那段跟着往后挪
        pending.Record(R(20, 4), delta: 4);
        pending.Record(R(2, 3), delta: 3);
        Assert.AreEqual<NoteRange?>(R(2, 25), pending.Take());
        // 前面记着一段，后面又改：并成一段
        pending.Record(R(2, 3), delta: 3);
        pending.Record(R(30, 2), delta: -5);
        Assert.AreEqual<NoteRange?>(R(2, 30), pending.Take());
        // 删到比记下的还靠前
        pending.Record(R(10, 5), delta: 5);
        pending.Record(R(4, 0), delta: -8);
        Assert.AreEqual<NoteRange?>(R(4, 3), pending.Take());
    }

    /// <summary>（移植时补的）上下各带一行、区间并成段。</summary>
    [TestMethod]
    public void NeighborLinesAndMerged()
    {
        const string text = "a\nb\nc\nd";
        Assert.AreEqual(R(0, 6), NoteStyles.NeighborLines(R(2, 2), text));
        Assert.AreEqual(R(0, 4), NoteStyles.NeighborLines(R(0, 2), text));
        Assert.AreEqual(R(4, 3), NoteStyles.NeighborLines(R(6, 1), text));
        CollectionAssert.AreEqual(
            new[] { R(0, 7), R(10, 1) }, NoteStyles.Merged(new[] { R(5, 2), R(0, 3), R(3, 2), R(10, 1) }));
    }

    /// <summary>（移植时补的）代码块里的行整行一种样式；一行在段落上是哪种（任务行不是标题、不是引用；Markdown 关着时都是正文）。</summary>
    [TestMethod]
    public void BlockSpansAndShapes()
    {
        CollectionAssert.AreEqual(new[] { new Span(R(0, 5), Kind.Fence) }, NoteStyles.BlockSpans("```js", Role.Open));
        CollectionAssert.AreEqual(new[] { new Span(R(0, 6), Kind.CodeBlock) }, NoteStyles.BlockSpans("☐ 不是任务", Role.Content));
        Assert.AreEqual(NoteStyles.Shape.Heading(1), NoteStyles.ShapeOf("# 标题", markdown: true, role: null));
        Assert.AreEqual(NoteStyles.Shape.Plain, NoteStyles.ShapeOf("# 标题", markdown: false, role: null));
        Assert.AreEqual(NoteStyles.Shape.Plain, NoteStyles.ShapeOf("☐ # 标题", markdown: true, role: null));
        Assert.AreEqual(NoteStyles.Shape.Quote, NoteStyles.ShapeOf("> 引用", markdown: true, role: null));
        Assert.AreEqual(NoteStyles.Shape.Code(Role.Content), NoteStyles.ShapeOf("# 标题", markdown: false, role: Role.Content));
    }

    /// <summary>（移植时补的）RoleChanges 的自检：围栏没变就什么都不排；收尾的围栏坏了，记着角色的三行都要排（挨着的并成一段）；
    /// 新配上的块里的行（还没记过角色）要排，没排过的行不算。</summary>
    [TestMethod]
    public void RoleChangesFindLinesWhoseRoleMoved()
    {
        // a 0 换行 1 | ``` 2-4 换行 5 | b 6 换行 7 | ``` 8-10 换行 11 | c 12
        const string paired = "a\n```\nb\n```\nc";
        var stored = new List<(NoteRange Range, Role Role)> { (R(2, 4), Role.Open), (R(6, 2), Role.Content), (R(8, 4), Role.Close) };
        Assert.AreEqual(0, NoteStyles.RoleChanges(paired, stored, NoteMarkdown.CodeBlocks(paired)).Count);
        // 收尾的围栏改成「``x」（长度不变，记着的区间不用挪）：块拆开了
        const string broken = "a\n```\nb\n``x\nc";
        Assert.AreEqual(0, NoteMarkdown.CodeBlocks(broken).Count);
        CollectionAssert.AreEqual(new[] { R(2, 10) }, NoteStyles.RoleChanges(broken, stored, NoteMarkdown.CodeBlocks(broken)));
        // 反过来：原来没有块、现在配上了，块里的三行都要排；第 6 个字以后的还没排过，不算
        var none = new List<(NoteRange Range, Role Role)>();
        CollectionAssert.AreEqual(new[] { R(2, 10) }, NoteStyles.RoleChanges(paired, none, NoteMarkdown.CodeBlocks(paired)));
        CollectionAssert.AreEqual(
            new[] { R(2, 4) }, NoteStyles.RoleChanges(paired, none, NoteMarkdown.CodeBlocks(paired), position => position < 6));
    }
}
