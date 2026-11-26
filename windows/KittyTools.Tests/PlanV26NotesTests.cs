// PLAN-v26 第 10 批便签那一半的纯函数：「全部」按最近修改排（N4）。
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV26NotesTests
{
    /// <summary>N2：快速记一条贴的图，记下时每张一行接在正文后面；草稿带着图、读回来令牌还在（同 mac captureAppendsImagesAsLines）。</summary>
    [TestMethod]
    public void CaptureImagesFollowDraft()
    {
        var token = NoteImages.Token(new NoteImages.Image(Guid.Parse("0B9A7B1E-5F64-4C5B-9C3B-0123456789AB"), "png", null));
        Assert.AreEqual("记一下\n" + token, NoteCaptureRules.WithImages("记一下\n", new[] { token }));
        Assert.AreEqual(token + "\n" + token, NoteCaptureRules.WithImages("  ", new[] { token, token }));
        Assert.AreEqual("只有字", NoteCaptureRules.WithImages("只有字", null));

        var draft = new NoteCaptureRules.Draft(Images: new[] { token });
        Assert.IsFalse(draft.IsEmpty, "只有图也不是空的");
        Assert.AreEqual(draft, NoteCaptureRules.Draft.Read(draft.Json()));
        Assert.IsTrue(draft.Json().Contains("\"images\":[", StringComparison.Ordinal));
        Assert.IsFalse(new NoteCaptureRules.Draft(Body: "x").Json().Contains("images", StringComparison.Ordinal), "没图不写这个键");
        Assert.IsNull(NoteCaptureRules.Draft.Read("{\"body\":\"\",\"images\":[\"不是令牌\"],\"title\":\"\"}"), "认不出的令牌不收");

        var restored = NoteCaptureRules.Restored(new NoteCaptureRules.Draft(Body: "后来"), new NoteCaptureRules.Draft(Body: "原来", Images: new[] { token }));
        CollectionAssert.AreEqual(new[] { token }, restored.Images!.ToArray(), "恢复时图也带回来");
    }

    [TestMethod]
    public void ByModifiedKeepsPinnedFirst()
    {
        var notes = new[]
        {
            new Note { Id = "A", ModifiedAt = 100 },
            new Note { Id = "B", ModifiedAt = 300 },
            new Note { Id = "P", ModifiedAt = 50, IsPinned = true },
            new Note { Id = "C", ModifiedAt = 300 },
            new Note { Id = "Q", ModifiedAt = 500, IsPinned = true },
        };
        CollectionAssert.AreEqual(new[] { "Q", "P", "B", "C", "A" }, NotesWindowRules.ByModified(notes).Select(note => note.Id).ToArray(),
            "固定的在前；同一刻按原来的顺序");
    }
}
