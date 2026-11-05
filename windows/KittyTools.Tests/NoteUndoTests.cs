// PLAN-v13 第 4 批：便签正文自己的撤销栈（NoteUndo）的分组口径——连着打的字一组；停手超过 1 秒、打了空白之后又打字、光标跳走、
// 命令都另起一组；撤销进重做栈，新的改动清掉重做栈。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteUndoTests
{
    private static NoteUndo<string>.State State(string text, int caret)
        => new(text, Array.Empty<string>(), new NoteRange(caret, 0));

    /// <summary>在 text 末尾打 ch（时刻 now），返回打完的字。</summary>
    private static string Type(NoteUndo<string> undo, string text, char ch, long now)
    {
        undo.Typing(State(text, text.Length), text.Length, char.IsWhiteSpace(ch), now);
        var typed = text + ch;
        undo.TypedTo(typed.Length);
        return typed;
    }

    [TestMethod]
    public void ContinuousTypingIsOneStep()
    {
        var undo = new NoteUndo<string>();
        var text = string.Empty;
        foreach (var (ch, at) in new[] { ('a', 0L), ('b', 100L), ('c', 200L) })
        {
            text = Type(undo, text, ch, at);
        }

        var back = undo.Undo(State(text, text.Length));
        Assert.AreEqual(string.Empty, back?.Text);
        Assert.IsFalse(undo.CanUndo);
        Assert.AreEqual("abc", undo.Redo(State(string.Empty, 0))?.Text);
    }

    [TestMethod]
    public void PausesWordsAndJumpsStartNewSteps()
    {
        var undo = new NoteUndo<string>();
        var text = Type(undo, string.Empty, 'a', 0);
        text = Type(undo, text, 'b', 1500);
        Assert.AreEqual("a", undo.Undo(State(text, text.Length))?.Text, "停手超过 1 秒另起一组");

        undo = new NoteUndo<string>();
        text = Type(undo, string.Empty, 'a', 0);
        text = Type(undo, text, ' ', 100);
        text = Type(undo, text, 'b', 200);
        Assert.AreEqual("a ", undo.Undo(State(text, text.Length))?.Text, "空白之后再打字另起一组");

        undo = new NoteUndo<string>();
        text = Type(undo, string.Empty, 'a', 0);
        undo.Typing(State(text + "x", 0), 0, false, 100);
        Assert.AreEqual("ax", undo.Undo(State("bax", 1))?.Text, "光标跳走另起一组");
    }

    [TestMethod]
    public void SameTextDifferentImagesAreSeparateSteps()
    {
        // 审查方复查：改图片宽度 / 裁切时字一样、图片不一样，两次各是一步
        var undo = new NoteUndo<string>();
        undo.Command(new NoteUndo<string>.State("x", new[] { "a" }, new NoteRange(0, 0)));
        undo.Command(new NoteUndo<string>.State("x", new[] { "b" }, new NoteRange(0, 0)));
        var back = undo.Undo(new NoteUndo<string>.State("x", new[] { "c" }, new NoteRange(0, 0)));
        Assert.AreEqual("b", back?.Images[0]);
        Assert.IsTrue(undo.CanUndo);
    }

    [TestMethod]
    public void HugeStatesDropTheOldestFirst()
    {
        var undo = new NoteUndo<string>();
        var big = new string('字', (int)(NoteUndo<string>.MaxChars / 3) + 1);
        for (var step = 0; step < 4; step++)
        {
            undo.Command(new NoteUndo<string>.State(big + step, Array.Empty<string>(), new NoteRange(0, 0)));
        }

        var count = 0;
        while (undo.Undo(new NoteUndo<string>.State("now", Array.Empty<string>(), new NoteRange(0, 0))) is not null)
        {
            count++;
        }

        Assert.AreEqual(2, count, "一共不超过 MaxChars：只留最近两步");
    }

    [TestMethod]
    public void CommandsAreTheirOwnStepAndNewEditsClearRedo()
    {
        var undo = new NoteUndo<string>();
        var text = Type(undo, string.Empty, 'a', 0);
        undo.Command(State(text, 1));
        Assert.AreEqual("a", undo.Undo(State("☐ a", 3))?.Text);
        Assert.IsTrue(undo.CanRedo);
        Type(undo, "a", 'b', 5000);
        Assert.IsFalse(undo.CanRedo, "新的改动清掉重做栈");
        undo.Clear();
        Assert.IsFalse(undo.CanUndo);
        Assert.IsNull(undo.Undo(State("x", 1)));
    }
}
