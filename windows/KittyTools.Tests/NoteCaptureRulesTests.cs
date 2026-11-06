// PLAN-v13 第 5 批：快速记一条（NoteCaptureRules）和全部便签窗口（NotesWindowRules）的纯函数——草稿读写、记到哪、
// 接在后面、Esc 后恢复、存之前的检查、拿走一条之后选谁、拖动落点、相对时间、字数（照 mac NoteCaptureTests / NotesWindowTests 的口径）。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteCaptureRulesTests
{
    private const long T0 = 1_760_000_000_123;

    private static Note Note(string id, long modified, string body = "x")
        => new() { Id = id, Body = body, CreatedAt = T0, ModifiedAt = modified };

    [TestMethod]
    public void DraftRoundTripsAndRejectsJunk()
    {
        var draft = new NoteCaptureRules.Draft("标题", "第一行\n\"引号\"", "ABC");
        Assert.AreEqual(draft, NoteCaptureRules.Draft.Read(draft.Json()));
        Assert.IsNull(NoteCaptureRules.Draft.Read(new NoteCaptureRules.Draft(" ", "\n").Json()), "空草稿不留");
        Assert.IsNull(NoteCaptureRules.Draft.Read("{坏的"));
        Assert.IsNull(NoteCaptureRules.Draft.Read("[1]"));
        Assert.IsNull(NoteCaptureRules.Draft.Read(null));
    }

    [TestMethod]
    public void DestinationsAreTheEightLatest()
    {
        var notes = Enumerable.Range(0, 10).Select(index => Note($"N{index}", T0 + index)).ToList();
        var destinations = NoteCaptureRules.Destinations(notes);
        Assert.AreEqual(NoteCaptureRules.DestinationLimit, destinations.Count);
        Assert.AreEqual("N9", destinations[0].Id);
        Assert.AreEqual("N2", destinations[^1].Id);
    }

    [TestMethod]
    public void AppendingAndRestoring()
    {
        Assert.AreEqual("新", NoteCaptureRules.Appending("新", null));
        Assert.AreEqual("旧\n新", NoteCaptureRules.Appending("新", "旧"));
        Assert.AreEqual("旧\n新", NoteCaptureRules.Appending("新", "旧\n"));
        var restored = NoteCaptureRules.Restored(new NoteCaptureRules.Draft(string.Empty, "后来", null), new NoteCaptureRules.Draft("T", "原来", "D"));
        Assert.AreEqual(new NoteCaptureRules.Draft("T", "原来\n后来", "D"), restored);
    }

    [TestMethod]
    public void CheckRefusesEmptyAndOversize()
    {
        Assert.AreEqual(NoteCaptureRules.Outcome.Empty, NoteCaptureRules.Check(" \n", string.Empty, null).Outcome);
        Assert.AreEqual(NoteCaptureRules.Outcome.Saved, NoteCaptureRules.Check(string.Empty, "只有标题", null).Outcome, "新便签有标题就能存");
        Assert.AreEqual(NoteCaptureRules.Outcome.Empty, NoteCaptureRules.Check(string.Empty, "标题", Note("A", T0)).Outcome,
            "接在已有便签后面时标题不算");
        var (outcome, body, _) = NoteCaptureRules.Check(" 新的 ", string.Empty, Note("A", T0, "旧的"));
        Assert.AreEqual(NoteCaptureRules.Outcome.Saved, outcome);
        Assert.AreEqual("旧的\n新的", body);
        var big = new string('字', KittyTools.Core.Notes.Note.MaxBodyBytes / 3 + 1);
        Assert.AreEqual(NoteCaptureRules.Outcome.TooLong, NoteCaptureRules.Check(big, string.Empty, null).Outcome);
    }

    [TestMethod]
    public void WindowSelectionAndDragLanding()
    {
        var ids = new[] { "A", "B", "C" };
        Assert.AreEqual("B", NotesWindowRules.SelectionAfterRemoving("A", ids));
        Assert.AreEqual("B", NotesWindowRules.SelectionAfterRemoving("C", ids));
        Assert.IsNull(NotesWindowRules.SelectionAfterRemoving("A", new[] { "A" }));
        Assert.IsNull(NotesWindowRules.SelectionAfterRemoving("Z", ids));
        Assert.AreEqual("A", NotesWindowRules.SelectionKeeping("Z", ids));
        Assert.AreEqual("C", NotesWindowRules.SelectionKeeping("C", ids));
        Assert.IsNull(NotesWindowRules.SelectionKeeping("A", Array.Empty<string>()));
        Assert.AreEqual(2, NotesWindowRules.LandingIndex(0, 3));
        Assert.AreEqual(0, NotesWindowRules.LandingIndex(2, 0));
    }

    [TestMethod]
    public void AgoAndCharacterCount()
    {
        var zone = TimeZoneInfo.Utc;
        var now = T0 + 10 * 86_400_000L;
        Assert.AreEqual("现在", NotesWindowRules.Ago(Note("A", now - 5_000), now, zone));
        Assert.AreEqual("3 分钟前", NotesWindowRules.Ago(Note("A", now - 180_000), now, zone));
        Assert.AreEqual("3 天前", NotesWindowRules.Ago(Note("A", now - 3 * 86_400_000L), now, zone));
        Assert.AreEqual(3, NotesWindowRules.CharacterCount("a b\nc"));
        Assert.AreEqual(1, NotesWindowRules.CharacterCount("👍🏽"), "一个字形算一个字");
        Assert.AreEqual(
            1, NotesWindowRules.CharacterCount("x" + NoteImages.Token(new NoteImages.Image(Guid.Empty, "png", null))), "图片令牌不算");
    }
}
