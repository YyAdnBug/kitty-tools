// PLAN-v13 第 2 批：便签仓库的内存那一半（Core NoteBook）+ 导出文件的一条（NoteEntry）+ 图片孤儿账 + 备份轮换 + 示例便签。
// 用例照 mac macos/KittyToolsTests/NoteStoreTests.swift 的口径移植，期望值原样（mac 的 t0 = 1_760_000_000.1234 s，对齐到毫秒是
// …123 ms；at(s) = t0 + s 秒）。mac 那边要真库的（重新打开、落盘失败重试、读越界的行、拒绝新版本的库）在这里没有：落盘在 App 的
// NoteStore，不在 Core——跳过的：typingIsSavedOnFlush…、typingSavesItselfAfterTheQuietDelay、failedWritesAreKeptAndFlushedLater、
// flushBeforeQuitAsksOnlyWhenWritesFail、failedWritesRetryOnTheirOwn、refusesDatabasesFromNewerVersions、readsOutOfRangeRowsSafely、
// cachedViewsStillRegisterObservation、longBodiesSettleTheirCountsAfterAPause（Windows 没做推迟，NoteBook 文件头的 ponytail）。
using System.Text.Json;
using KittyTools.Core.Notes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteBookTests
{
    private const long T0 = 1_760_000_000_123;
    private const string Device = "DEVICE-A";

    private static long At(double seconds) => T0 + (long)Math.Round(seconds * 1000);

    private static NoteBook Book(string device = Device) => new(() => device);

    private static Note Plain(string body, string title = "")
        => new() { Id = "x", Title = title, Body = body, CreatedAt = T0, ModifiedAt = T0 };

    private static NoteEntry Entry(
        string id, string body, long modified, string title = "", int color = 0, long created = 1_700_000_000_000,
        int revision = 0, bool archived = false, bool pinned = false, double order = 0)
        => new()
        {
            Id = id, Title = title, Body = body, Color = color, CreatedAt = created, ModifiedAt = modified,
            Revision = revision, Archived = archived, Pinned = pinned, Order = order,
        };

    [TestMethod]
    public void DisplayTitleAndPreview()
    {
        Assert.AreEqual("未命名便签", Plain(string.Empty).DisplayTitle);
        Assert.AreEqual("未命名便签", Plain(" \n\n\t\n").DisplayTitle);
        Assert.AreEqual("买菜", Plain("买菜\n牛奶").DisplayTitle);
        Assert.AreEqual("买菜", Plain("\n\n  买菜  \n牛奶").DisplayTitle);
        Assert.AreEqual("周报", Plain("正文第一行", "  周报 ").DisplayTitle);
        Assert.AreEqual("正文第一行", Plain("正文第一行", "   ").DisplayTitle);
        Assert.AreEqual("计划", Plain("# 计划").DisplayTitle);
        Assert.AreEqual("三级标题", Plain("###   三级标题").DisplayTitle);
        Assert.AreEqual("#标签 你好", Plain("#标签 你好").DisplayTitle);
        Assert.AreEqual("####### 七个井号", Plain("####### 七个井号").DisplayTitle);
        Assert.AreEqual("买牛奶", Plain("☐ 买牛奶").DisplayTitle);
        Assert.AreEqual("买牛奶", Plain("☑买牛奶").DisplayTitle);
        Assert.AreEqual("待办", Plain("## ☐ 待办").DisplayTitle);
        Assert.AreEqual("真正的第一行", Plain("#\n☐\n真正的第一行").DisplayTitle);
        Assert.AreEqual("未命名便签", Plain("#\n☐").DisplayTitle);
        var sixty = new string('字', 60);
        Assert.AreEqual(sixty, Plain(sixty).DisplayTitle);
        Assert.AreEqual(sixty + "…", Plain(sixty + "多").DisplayTitle);
        Assert.AreEqual("第一行", Plain("第一行\r\n第二行").DisplayTitle);

        Assert.AreEqual(string.Empty, Plain(string.Empty).Preview);
        Assert.AreEqual(string.Empty, Plain("只有一行").Preview);
        Assert.AreEqual("牛奶 水果 鸡蛋", Plain("买菜\n\n☐ 牛奶\n  # 水果 \n鸡蛋").Preview);
        Assert.AreEqual("买菜 牛奶", Plain("买菜\n牛奶", "清单").Preview);
        var longBody = string.Join("\n", Enumerable.Range(0, 100).Select(index => $"第 {index} 行的内容"));
        var preview = Plain(longBody).Preview;
        Assert.AreEqual(121, NoteText.Count(preview));
        Assert.IsTrue(preview.EndsWith('…') && preview.StartsWith("第 1 行的内容 第 2 行", StringComparison.Ordinal));
        var exact = "标题\n" + new string('字', 120);
        Assert.AreEqual(new string('字', 120), Plain(exact).Preview);
        Assert.AreEqual(new string('字', 120) + "…", Plain(exact + "\n还有").Preview);
        var huge = "标题\n" + string.Concat(Enumerable.Repeat("一行\n", 200_000));
        Assert.AreEqual("标题", Plain(huge).DisplayTitle);
        Assert.AreEqual(121, NoteText.Count(Plain(huge).Preview));
    }

    [TestMethod]
    public void SanitizesTextTitlesColorsAndRevisions()
    {
        Assert.AreEqual("前后", Note.SanitizedText("前\0后\0"));
        Assert.AreEqual(string.Empty, Note.SanitizedText("\0"));
        Assert.AreEqual("没有 NUL 的\n原样", Note.SanitizedText("没有 NUL 的\n原样"));
        Assert.IsFalse(Note.SanitizedText("a\0\u0301b").Contains('\0'));

        Assert.AreEqual("周报", Note.SanitizedTitle("周\0报"));
        var plain = new string('字', Note.MaxTitleLength);
        Assert.AreEqual(plain, Note.SanitizedTitle(plain));
        Assert.AreEqual(plain, Note.SanitizedTitle(plain + "多出来的"));
        const string family = "👨\u200D👩\u200D👧\u200D👦";
        Assert.AreEqual(25, System.Text.Encoding.UTF8.GetByteCount(family));
        var families = Note.SanitizedTitle(string.Concat(Enumerable.Repeat(family, 100)));
        Assert.AreEqual(string.Concat(Enumerable.Repeat(family, Note.MaxTitleBytes / 25)), families);
        var monster = "a" + new string('\u0301', 2000);
        Assert.AreEqual(1, NoteText.Count(monster));
        Assert.AreEqual(string.Empty, Note.SanitizedTitle(monster));
        Assert.AreEqual("标题", Note.SanitizedTitle("标题" + monster + "后面"));

        Assert.AreEqual(0, Note.Clamped(-1));
        Assert.AreEqual(3, Note.Clamped(3));
        Assert.AreEqual(Note.ColorCount - 1, Note.Clamped(99));
        Assert.AreEqual(1, Note.NextRevision(0));
        Assert.AreEqual(42, Note.NextRevision(41));
        Assert.AreEqual(Note.MaxRevision, Note.NextRevision(Note.MaxRevision - 1));
        Assert.AreEqual(Note.MaxRevision, Note.NextRevision(Note.MaxRevision));
        Assert.AreEqual(Note.MaxRevision, Note.NextRevision(int.MaxValue));
        Assert.AreEqual(1, Note.NextRevision(-5));
    }

    [TestMethod]
    public void CreatePutsNewNotesFirstAndRotatesColors()
    {
        var book = Book();
        var first = book.Create(T0, "第一条");
        Assert.AreEqual(0, first.Color);
        Assert.AreEqual(0, first.Revision);
        Assert.AreEqual(T0, first.CreatedAt);
        Assert.AreEqual(first.CreatedAt, first.ModifiedAt);
        Assert.IsTrue(Guid.TryParse(first.Id, out _));
        Assert.AreEqual(1, first.Clock[Device]);
        var rest = Enumerable.Range(1, Note.ColorCount).Select(index => book.Create(T0, $"第 {index + 1} 条")).ToList();
        CollectionAssert.AreEqual(new[] { 1, 2, 3, 4, 5, 6, 7, 0 }, rest.Select(note => note.Color).ToArray());
        var expected = Enumerable.Reverse(rest).Append(first).Select(note => note.Id).ToArray();
        CollectionAssert.AreEqual(expected, book.Active.Select(note => note.Id).ToArray());
    }

    [TestMethod]
    public void EditsBumpRevisionAndTouchModifiedOnlyForContent()
    {
        var book = Book();
        var id = book.Create(T0, "原文").Id;
        var created = book.Find(id)!.CreatedAt;
        var (revision, clock) = (0, 0.0);

        void Expect(bool touches, Action<long> change)
        {
            clock += 60;
            var before = book.Find(id)!;
            change(At(clock));
            var after = book.Find(id)!;
            revision++;
            Assert.AreEqual(revision, after.Revision);
            Assert.AreEqual(created, after.CreatedAt);
            Assert.AreEqual(touches ? At(clock) : before.ModifiedAt, after.ModifiedAt);
        }

        Expect(true, now => book.SetBody(id, "改过的正文", now));
        Expect(true, now => book.SetTitle(id, "标题", now));
        Expect(true, now => book.SetColor(id, 3, now));
        Expect(false, now => book.SetPinned(id, true, now));
        Expect(false, now => book.SetArchived(id, true, now));
        Expect(false, now => book.SetArchived(id, false, now));
        Expect(false, now => book.Delete(id, now));
        Expect(false, now => book.Restore(id, now));
        var other = book.Create(At(clock), "另一条").Id;
        Expect(false, now => book.Move(id, 0, now));
        CollectionAssert.AreEqual(new[] { id, other }, book.Active.Select(note => note.Id).ToArray());
        // 内容改了三次：钟自己那一格到 4（建的时候 1）
        Assert.AreEqual(4, book.Find(id)!.Clock[Device]);

        var settled = book.Find(id)!;
        var later = At(clock + 60);
        Assert.IsFalse(book.SetBody(id, "改过的正文", later));
        Assert.IsFalse(book.SetTitle(id, "标题", later));
        Assert.IsFalse(book.SetColor(id, 3, later));
        Assert.IsFalse(book.SetPinned(id, true, later));
        Assert.IsFalse(book.SetArchived(id, false, later));
        Assert.IsFalse(book.Restore(id, later));
        Assert.IsFalse(book.Move(id, 0, later));
        Assert.AreEqual(settled, book.Find(id));
        book.SetColor(id, 99, later);
        Assert.AreEqual(Note.ColorCount - 1, book.Find(id)!.Color);
        book.SetColor(id, -5, later);
        Assert.AreEqual(0, book.Find(id)!.Color);
        Assert.IsFalse(book.SetBody("不存在", "没有这条", later));
        Assert.AreEqual(2, book.All.Count);
    }

    [TestMethod]
    public void StateAndOrderTimesOnlyMoveForward()
    {
        var book = Book();
        var id = book.Create(At(100), "x").Id;
        // 本机的钟往回拨了：状态时刻仍比上一次晚 1 毫秒
        book.SetPinned(id, true, At(10));
        Assert.AreEqual(At(100) + 1, book.Find(id)!.StateChangedAt);
        book.Move(id, 0, At(10));
        Assert.AreEqual(At(100), book.Find(id)!.OrderChangedAt);
    }

    [TestMethod]
    public void SoftDeleteRestoreAndPurge()
    {
        var book = Book();
        const double day = 86_400;
        var ids = Enumerable.Range(0, 4).Select(index => book.Create(T0, $"第 {index} 条").Id).ToList();
        CollectionAssert.AreEqual(Enumerable.Reverse(ids).ToArray(), book.Active.Select(note => note.Id).ToArray());
        book.Delete(ids[1], T0);
        book.Delete(ids[2], At(day));
        CollectionAssert.AreEqual(new[] { ids[3], ids[0] }, book.Active.Select(note => note.Id).ToArray());
        CollectionAssert.AreEqual(new[] { ids[2], ids[1] }, book.Trashed.Select(note => note.Id).ToArray());
        Assert.AreEqual(At(day), book.Trashed[0].DeletedAt);
        CollectionAssert.AreEqual(new[] { ids[3], ids[0] }, book.Exportable.Select(note => note.Id).ToArray());
        var deleted = book.Find(ids[1]);
        book.Delete(ids[1], At(day + 10));
        Assert.AreEqual(deleted, book.Find(ids[1]));

        book.Restore(ids[2], At(day + 20));
        CollectionAssert.AreEqual(new[] { ids[3], ids[2], ids[0] }, book.Active.Select(note => note.Id).ToArray());

        var deletedAt = book.Find(ids[1])!.DeletedAt!.Value;
        var thirty = deletedAt + NoteBook.TrashDays * 86_400_000L;
        Assert.AreEqual(0, book.PurgeExpired(deletedAt + 29 * 86_400_000L));
        Assert.AreEqual(0, book.PurgeExpired(thirty));
        Assert.AreEqual(1, book.PurgeExpired(thirty + 1));
        Assert.AreEqual(0, book.Trashed.Count);
        Assert.AreEqual(3, book.All.Count);
        // 到期清理留墓碑（同步时告诉别的电脑）
        Assert.IsTrue(book.Erased.ContainsKey(ids[1]));
        Assert.AreEqual(0, book.PurgeExpired(thirty + 86_400_000L));

        book.Erase(new[] { ids[3], "不存在" });
        CollectionAssert.AreEquivalent(new[] { ids[0], ids[2] }, book.All.Select(note => note.Id).ToArray());
        var pending = book.PendingWrites();
        CollectionAssert.Contains(pending.Deletes.ToList(), ids[3]);
        Assert.IsTrue(pending.Tombstones.Any(item => item.Id == ids[3] && item.Tombstone is not null));
    }

    [TestMethod]
    public void ArchivedNotesLeaveTheListAndComeBackOnTop()
    {
        var book = Book();
        var ids = Enumerable.Range(0, 3).Select(index => book.Create(T0, $"第 {index} 条").Id).ToList();
        book.SetBody(ids[0], "后改的", At(60));
        book.SetBody(ids[2], "最后改的", At(120));
        book.SetArchived(ids[0], true, At(130));
        book.SetArchived(ids[2], true, At(130));
        CollectionAssert.AreEqual(new[] { ids[1] }, book.Active.Select(note => note.Id).ToArray());
        CollectionAssert.AreEqual(new[] { ids[2], ids[0] }, book.Archived.Select(note => note.Id).ToArray());
        Assert.AreEqual(3, book.Exportable.Count);
        book.Delete(ids[2], At(180));
        CollectionAssert.AreEqual(new[] { ids[0] }, book.Archived.Select(note => note.Id).ToArray());
        book.SetArchived(ids[0], false, At(190));
        CollectionAssert.AreEqual(new[] { ids[0], ids[1] }, book.Active.Select(note => note.Id).ToArray());
    }

    [TestMethod]
    public void MoveReordersByChangingOneNote()
    {
        var book = Book();
        var ids = Enumerable.Range(0, 5).Select(index => book.Create(T0, $"第 {index} 条").Id).Reverse().ToList();
        CollectionAssert.AreEqual(ids.ToArray(), book.Active.Select(note => note.Id).ToArray());

        void ExpectOrder(params int[] indices)
            => CollectionAssert.AreEqual(indices.Select(index => ids[index]).ToArray(), book.Active.Select(note => note.Id).ToArray());

        book.Move(ids[4], 0, T0);
        ExpectOrder(4, 0, 1, 2, 3);
        book.Move(ids[4], 2, T0);
        ExpectOrder(0, 1, 4, 2, 3);
        book.Move(ids[0], 99, T0);
        ExpectOrder(1, 4, 2, 3, 0);
        book.Move(ids[3], -3, T0);
        ExpectOrder(3, 1, 4, 2, 0);
        book.Move(ids[1], 3, T0);
        ExpectOrder(3, 4, 2, 1, 0);
        Assert.AreEqual(5, book.All.Sum(note => note.Revision));
        book.SetArchived(ids[0], true, T0);
        book.Move(ids[0], 0, T0);
        book.Move("不存在", 0, T0);
        ExpectOrder(3, 4, 2, 1);

        for (var round = 0; round < 80; round++)
        {
            var moving = round % 2 == 0 ? ids[2] : ids[1];
            book.Move(moving, 1, T0);
            CollectionAssert.AreEqual(new[] { ids[3], moving }, book.Active.Take(2).Select(note => note.Id).ToArray());
        }

        Assert.AreEqual(4, book.Active.Select(note => note.Order).Distinct().Count());

        var twins = new[] { "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222" };
        book.Adopt(twins.Select(id => Entry(id, "一样的顺序", 1_700_000_000_000, order: 500)).ToList(), T0);
        var before = book.Active.Select(note => note.Id).ToList();
        CollectionAssert.AreEqual(twins, before.TakeLast(2).ToArray());
        book.Move(before[0], before.Count - 2, T0);
        var expected = before.Skip(1).Take(before.Count - 2).Append(before[0]).Append(twins[1]).ToArray();
        CollectionAssert.AreEqual(expected, book.Active.Select(note => note.Id).ToArray());
        Assert.AreEqual(before.Count, book.Active.Select(note => note.Order).Distinct().Count());
    }

    [TestMethod]
    public void SearchMatchesTitleAndBody()
    {
        var book = Book();
        var weekly = book.Create(At(0), "本周：发布 0.5.0\nReview 便签的数据层", "周报");
        var shopping = book.Create(At(1), "牛奶、鸡蛋\nＡＰＰＬＥ 两斤");
        var empty = book.Create(At(2));
        var all = book.Active;
        CollectionAssert.AreEqual(new[] { empty.Id, shopping.Id, weekly.Id }, all.Select(note => note.Id).ToArray());
        Assert.AreEqual(3, book.Search(string.Empty, all).Count);
        Assert.AreEqual(3, book.Search("   ", all).Count);
        CollectionAssert.AreEqual(new[] { weekly.Id }, book.Search("周报", all).Select(note => note.Id).ToArray());
        CollectionAssert.AreEqual(new[] { weekly.Id }, book.Search("review", all).Select(note => note.Id).ToArray());
        CollectionAssert.AreEqual(new[] { shopping.Id }, book.Search("apple", all).Select(note => note.Id).ToArray());
        CollectionAssert.AreEqual(new[] { shopping.Id }, book.Search("牛奶 两斤", all).Select(note => note.Id).ToArray());
        Assert.AreEqual(0, book.Search("牛奶 发布", all).Count);
        CollectionAssert.AreEqual(new[] { weekly.Id }, book.Search("0.5 周报", all).Select(note => note.Id).ToArray());
        Assert.AreEqual(0, book.Search("周报本周", all).Count);
        Assert.AreEqual(0, book.Search("牛奶", new[] { weekly }).Count);
    }

    [TestMethod]
    public void SearchIgnoresImageTokensAndColors()
    {
        var book = Book();
        var image = book.Create(T0, "看图\n![image](kitty-note-image://0D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F.png)");
        var colored = book.Create(T0, "[重要]{red} 的事");
        var all = book.Active;
        Assert.AreEqual(0, book.Search("image", all).Count);
        Assert.AreEqual(0, book.Search("png", all).Count);
        Assert.AreEqual(0, book.Search("0D8F2A11", all).Count);
        CollectionAssert.AreEqual(new[] { image.Id }, book.Search("看图", all).Select(note => note.Id).ToArray());
        Assert.AreEqual(0, book.Search("red", all).Count);
        CollectionAssert.AreEqual(new[] { colored.Id }, book.Search("重要", all).Select(note => note.Id).ToArray());
    }

    [TestMethod]
    public void AdoptMergesByID()
    {
        var book = Book();
        var local = book.Create(T0, "本机独有的");
        var older = book.Create(T0, "本机旧、文件新");
        var newer = book.Create(T0, "本机新、文件旧");
        var same = book.Create(T0, "一样新");
        var trashed = book.Create(T0, "本机删了的");
        book.SetPinned(older.Id, true, T0);
        book.Delete(trashed.Id, T0);
        const string fresh = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
        var before = book.All.ToDictionary(note => note.Id);
        var olderBefore = book.Find(older.Id)!;

        var entries = new List<NoteEntry>
        {
            Entry(fresh, "文件里才有的", T0 - 5_000, "新来的", 5, T0 - 9_000, 12, archived: true, pinned: true, order: 7.5),
            Entry(older.Id, "文件里更新的一版", T0 + 1, "换了标题", 2, 1, 40, archived: true, pinned: false, order: -20),
            Entry(newer.Id, "文件里更旧的一版", T0 - 1, color: 6, revision: 99),
            Entry(same.Id, "文件里一样新的一版", T0, color: 6, revision: 99),
            Entry(trashed.Id, "文件里改得更晚", T0 + 60_000, revision: 99),
        };
        var importedAt = At(120);
        var outcome = book.Adopt(entries, importedAt);
        Assert.AreEqual(new NoteBook.Adoption(1, 1), outcome);

        var added = book.Find(fresh)!;
        Assert.AreEqual(
            new Note
            {
                Id = fresh, Title = "新来的", Body = "文件里才有的", Color = 5, CreatedAt = T0 - 9_000, ModifiedAt = T0 - 5_000,
                Revision = 12, IsArchived = true, IsPinned = true, Order = 7.5, StateChangedAt = importedAt,
                OrderChangedAt = importedAt, Clock = new Dictionary<string, long> { [Device] = 1 },
            },
            added);
        var replaced = book.Find(older.Id)!;
        Assert.AreEqual("文件里更新的一版", replaced.Body);
        Assert.AreEqual("换了标题", replaced.Title);
        Assert.AreEqual(2, replaced.Color);
        Assert.AreEqual(T0 + 1, replaced.ModifiedAt);
        Assert.IsTrue(replaced.IsArchived && !replaced.IsPinned && replaced.Order == -20);
        Assert.AreEqual(olderBefore.CreatedAt, replaced.CreatedAt);
        Assert.AreEqual(41, replaced.Revision);
        foreach (var id in new[] { local.Id, newer.Id, same.Id, trashed.Id })
        {
            Assert.AreEqual(before[id], book.Find(id));
        }

        Assert.AreEqual(7, book.All.Count);
        Assert.AreEqual(2, book.Trashed.Count);

        var settled = book.All.OrderBy(note => note.Id, StringComparer.Ordinal).ToList();
        Assert.AreEqual(new NoteBook.Adoption(0, 0), book.Adopt(entries, At(240)));
        CollectionAssert.AreEqual(settled, book.All.OrderBy(note => note.Id, StringComparer.Ordinal).ToList());
    }

    [TestMethod]
    public void AdoptKeepsTheVersionItReplaces()
    {
        var book = Book();
        var mine = book.Create(T0, "本机写了很久的一版", "我的标题");
        var sameText = book.Create(T0, "两边文字一样");
        var blank = book.Create(T0);
        book.SetColor(mine.Id, 6, T0);
        book.SetPinned(mine.Id, true, T0);
        var old = book.Find(mine.Id)!;
        var importedAt = At(3_600);
        var outcome = book.Adopt(new List<NoteEntry>
        {
            Entry(mine.Id, "文件里的一版", T0 + 1_000, "文件的标题", 1),
            Entry(sameText.Id, "两边文字一样", T0 + 1_000, color: 4, archived: true),
            Entry(blank.Id, "文件里有字", T0 + 1_000),
        }, importedAt);
        Assert.AreEqual(new NoteBook.Adoption(0, 3), outcome);
        Assert.AreEqual(4, book.All.Count);
        Assert.AreEqual(1, book.Trashed.Count);
        var kept = book.Trashed[0];
        Assert.AreNotEqual(mine.Id, kept.Id);
        Assert.AreEqual("我的标题", kept.Title);
        Assert.AreEqual("本机写了很久的一版", kept.Body);
        Assert.AreEqual(6, kept.Color);
        Assert.AreEqual(importedAt, kept.DeletedAt);
        Assert.AreEqual(old.CreatedAt, kept.CreatedAt);
        Assert.AreEqual(old.ModifiedAt, kept.ModifiedAt);
    }

    [TestMethod]
    public void AdoptDoesNotLetFutureTimesWin()
    {
        var book = Book();
        var mine = book.Create(T0, "本机的");
        const string id = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB";
        var entries = new List<NoteEntry>
        {
            Entry(id, "钟快的电脑写的", T0 + 86_400_000, color: 42, created: T0 + 3_600_000),
            Entry(id, "重复的编号", T0 + 86_400_000, color: 1),
            Entry(mine.Id, "钟快的电脑上的一版", T0 + 86_400_000),
        };
        var importedAt = At(60);
        Assert.AreEqual(new NoteBook.Adoption(1, 0), book.Adopt(entries, importedAt));
        var note = book.Find(id)!;
        Assert.AreEqual("钟快的电脑写的", note.Body);
        Assert.AreEqual(Note.ColorCount - 1, note.Color);
        Assert.AreEqual(importedAt, note.CreatedAt);
        Assert.AreEqual(importedAt, note.ModifiedAt);
        Assert.AreEqual(mine, book.Find(mine.Id));

        foreach (var later in new[] { importedAt, At(3_600), At(7_200) })
        {
            Assert.AreEqual(new NoteBook.Adoption(0, 0), book.Adopt(entries, later));
        }

        Assert.AreEqual(0, book.Trashed.Count);
        Assert.AreEqual(new NoteBook.Adoption(0, 1), book.Adopt(entries, At(2 * 86_400)));
        Assert.AreEqual("钟快的电脑上的一版", book.Find(mine.Id)!.Body);
        CollectionAssert.AreEqual(new[] { "本机的" }, book.Trashed.Select(item => item.Body).ToArray());

        var exported = book.Exportable.Select(NoteEntry.From).OfType<NoteEntry>().ToList();
        Assert.AreEqual(new NoteBook.Adoption(0, 0), book.Adopt(exported, At(3 * 86_400)));
    }

    [TestMethod]
    public void AdoptKeepsTheNewestDuplicateAndContentOnly()
    {
        var book = Book();
        var note = book.Create(At(0), "本机的");
        book.SetPinned(note.Id, true, At(1));
        var stamp = At(10);
        var duplicates = new List<NoteEntry>
        {
            Entry(note.Id, "旧的一份", stamp),
            Entry(note.Id, "新的一份", stamp + 1_000, archived: true, order: 9),
            Entry(note.Id, "一样新的另一份", stamp + 1_000),
        };
        CollectionAssert.AreEqual(new[] { "新的一份" }, NoteBook.NewestEntries(duplicates).Select(entry => entry.Body).ToArray());
        Assert.AreEqual(1, book.Adopt(duplicates, At(60), new HashSet<string> { note.Id }).Updated);
        var after = book.Find(note.Id)!;
        Assert.IsTrue(after.Body == "新的一份" && after.IsPinned && !after.IsArchived && after.Order != 9);
        Assert.AreEqual(0, book.Adopt(new List<NoteEntry> { Entry(note.Id, "新的一份", stamp + 5_000, archived: true, order: 3) }, At(60)).Updated);
        Assert.AreEqual(after, book.Find(note.Id));
    }

    [TestMethod]
    public void AdoptAfterEraseContinuesTheTombstoneClock()
    {
        var book = Book();
        var note = book.Create(T0, "要删掉的");
        book.SetBody(note.Id, "改过", At(1));
        book.Erase(new[] { note.Id });
        Assert.AreEqual(2, book.Erased[note.Id].Clock[Device]);
        book.Adopt(new List<NoteEntry> { Entry(note.Id, "导回来", At(2)) }, At(3));
        Assert.AreEqual(3, book.Find(note.Id)!.Clock[Device]);
        Assert.IsFalse(book.Erased.ContainsKey(note.Id));
    }

    [TestMethod]
    public void BlankNotesCreatedThisRunAreDroppedWhenLeft()
    {
        var book = Book();
        var blank = book.Create(At(0));
        var typed = book.Create(At(1));
        book.SetBody(typed.Id, "写了字", At(2));
        var archived = book.Create(At(3));
        book.SetArchived(archived.Id, true, At(4));
        var held = book.Create(At(5));
        Assert.AreEqual(NoteBook.Drop.Dropped, book.DropIfBlank(blank.Id, At(6), isOpen: false, isComposing: false));
        Assert.IsNull(book.Find(blank.Id));
        Assert.IsFalse(book.Erased.ContainsKey(blank.Id), "没写进过同步文件夹：不留墓碑");
        Assert.AreEqual(NoteBook.Drop.Kept, book.DropIfBlank(typed.Id, At(6), false, false));
        Assert.AreEqual(NoteBook.Drop.Kept, book.DropIfBlank(archived.Id, At(6), false, false));
        Assert.AreEqual(NoteBook.Drop.Kept, book.DropIfBlank(held.Id, At(6), isOpen: true, isComposing: false));
        Assert.AreEqual(NoteBook.Drop.Composing, book.DropIfBlank(held.Id, At(6), isOpen: false, isComposing: true));
        book.Published(new[] { held.Id });
        Assert.AreEqual(NoteBook.Drop.Dropped, book.DropIfBlank(held.Id, At(6), false, false));
        Assert.IsTrue(book.Erased.ContainsKey(held.Id));

        // 下一次运行（新的 NoteBook，库里读出来的）：老的空便签不动
        var next = Book();
        next.Load(new Note { Id = "OLD", CreatedAt = T0, ModifiedAt = T0, Clock = new Dictionary<string, long> { [Device] = 1 } }, 0, false);
        Assert.AreEqual(NoteBook.Drop.Kept, next.DropIfBlank("OLD", At(7), false, false));
    }

    [TestMethod]
    public void BlankOrNewOnlyReusesLocalBlanks()
    {
        var here = Book("这台");
        here.Load(new Note { Id = "MINE", CreatedAt = T0, ModifiedAt = T0, Clock = new Dictionary<string, long> { ["这台"] = 1 } }, 0, false);
        Assert.AreEqual("MINE", here.BlankOrNew(At(1)).Id, "本机以前建的照用");
        var elsewhere = Book("那台");
        elsewhere.Load(new Note { Id = "MINE", CreatedAt = T0, ModifiedAt = T0, Clock = new Dictionary<string, long> { ["这台"] = 1 } }, 0, false);
        var fresh = elsewhere.BlankOrNew(At(2));
        Assert.AreNotEqual("MINE", fresh.Id, "那台建的不用");
        Assert.AreEqual(2, elsewhere.Active.Count);
    }

    [TestMethod]
    public void BlankOrNewReusesAnyBlankAndMovesItToTheFront()
    {
        var book = Book();
        var blank = book.Create(At(0));
        var archivedBlank = book.Create(At(1));
        book.SetArchived(archivedBlank.Id, true, At(2));
        var typed = book.Create(At(3), "有字");
        var reused = book.BlankOrNew(At(4));
        Assert.AreEqual(blank.Id, reused.Id);
        Assert.AreEqual(blank.Id, book.Active[0].Id);
        Assert.AreEqual(2, book.Active.Count);
        Assert.AreEqual(typed.Id, book.Active[1].Id);
    }

    [TestMethod]
    public void LoadTouchesRowsWrittenByOthers()
    {
        var book = Book();
        var note = new Note { Id = "A", Body = "x", CreatedAt = T0, ModifiedAt = T0, Revision = 3, StateChangedAt = T0 };
        book.Load(note, writtenRevision: 3, tinted: false);
        Assert.IsFalse(book.HasUnsaved);
        var other = Book();
        other.Load(note, writtenRevision: 2, tinted: false);
        var touched = other.Find("A")!;
        Assert.AreEqual(1, touched.Clock[Device]);
        Assert.AreEqual(4, touched.Revision);
        Assert.AreEqual(T0 + 1, touched.StateChangedAt);
        Assert.IsTrue(other.HasUnsaved);
    }

    [TestMethod]
    public void ApplySyncSkipsNotesEditedSinceTheMerge()
    {
        var book = Book();
        var note = book.Create(T0, "本机的");
        var remote = note with { Body = "别处改的", Clock = new Dictionary<string, long> { [Device] = 1, ["B"] = 1 }, ModifiedAt = At(5) };
        // 合的时候本机是修订号 0；落之前本机又打了字（修订号 1）：这一条不落
        book.SetBody(note.Id, "本机又改了", At(6));
        book.ApplySync(
            new Dictionary<string, NoteSync.Merge> { [note.Id] = new(remote, Array.Empty<Note>(), false, 0) },
            new Dictionary<string, NoteSync.Tombstone>());
        Assert.AreEqual("本机又改了", book.Find(note.Id)!.Body);
        // 修订号对得上：换上
        book.ApplySync(
            new Dictionary<string, NoteSync.Merge> { [note.Id] = new(remote, Array.Empty<Note>(), false, 1) },
            new Dictionary<string, NoteSync.Tombstone>());
        Assert.AreEqual("别处改的", book.Find(note.Id)!.Body);
        // 合出来是 null：真删、留墓碑
        var current = book.Find(note.Id)!.Revision;
        book.ApplySync(
            new Dictionary<string, NoteSync.Merge> { [note.Id] = new(null, Array.Empty<Note>(), false, current) },
            new Dictionary<string, NoteSync.Tombstone>());
        Assert.IsNull(book.Find(note.Id));
        Assert.IsTrue(book.Erased.ContainsKey(note.Id));
    }

    [TestMethod]
    public void SwitchDeviceDropsTheOldCellAndAddsANewOne()
    {
        var book = Book("OLD");
        var note = book.Create(T0, "x");
        book.SwitchDevice(new HashSet<string> { note.Id }, "OLD", "NEW");
        var after = book.Find(note.Id)!;
        Assert.IsFalse(after.Clock.ContainsKey("OLD"));
        Assert.AreEqual(1, after.Clock["NEW"]);
        Assert.AreEqual(note.Revision + 1, after.Revision);
    }

    [TestMethod]
    public void EntriesAreReadLeniently()
    {
        var json = """
            [
              {"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"t","body":"b\u0000c","color":99,"createdAt":-5,"modifiedAt":10,
               "revision":2000000000,"archived":false,"pinned":true,"order":1e12,"tint":"#a0b0c0"},
              {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"重复","body":"","color":0,"createdAt":0,"modifiedAt":0,
               "revision":0,"archived":false,"pinned":false,"order":0},
              {"id":"不是 UUID","title":"","body":"","color":0,"createdAt":0,"modifiedAt":0,"revision":0,"archived":false,"pinned":false,"order":0},
              {"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"缺字段"},
              "不是对象",
              {"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","title":"","body":"x","color":3,"createdAt":0,"modifiedAt":0,
               "revision":0,"archived":true,"pinned":false,"order":2,"tint":"red"}
            ]
            """;
        using var document = JsonDocument.Parse(json);
        var entries = NoteEntry.Sanitized(document.RootElement.EnumerateArray().Select(element => element.Clone()).ToList());
        Assert.AreEqual(2, entries.Count);
        var first = entries[0];
        Assert.AreEqual("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", first.Id);
        Assert.AreEqual("bc", first.Body);
        Assert.AreEqual(Note.ColorCount - 1, first.Color);
        Assert.AreEqual(0, first.CreatedAt);
        Assert.AreEqual(Note.MaxRevision, first.Revision);
        Assert.AreEqual(1e9, first.Order);
        Assert.AreEqual("#A0B0C0", first.Tint);
        Assert.AreEqual(Note.Custom(0xA0B0C0), first.NoteColor);
        Assert.IsNull(entries[1].Tint);
        Assert.AreEqual(3, entries[1].NoteColor);

        // 写出去再读回来一样
        var round = NoteEntry.Sanitized(new[] { JsonDocument.Parse(first.Json()).RootElement.Clone() });
        Assert.AreEqual(first, round[0]);
    }

    [TestMethod]
    public void OrphanImagesWaitThirtyDaysFromWhenFirstSeen()
    {
        var a = Guid.Parse("0D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F");
        var b = Guid.Parse("1D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F");
        var c = Guid.Parse("2D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F");
        var day = 86_400_000L;
        var ledger = new Dictionary<Guid, long> { [b] = T0 - 29 * day, [c] = T0 - 31 * day, [Guid.NewGuid()] = T0 };
        var plan = NoteImageRules.Plan(new[] { a, b, c }, new HashSet<Guid>(), ledger, T0);
        CollectionAssert.AreEqual(new[] { c }, plan.Remove.ToArray());
        Assert.AreEqual(T0, plan.Ledger[a]);
        Assert.AreEqual(T0 - 29 * day, plan.Ledger[b]);
        Assert.AreEqual(2, plan.Ledger.Count, "文件已经不在的条目去掉");
        var referenced = NoteImageRules.Plan(new[] { a, c }, new HashSet<Guid> { c }, ledger, T0);
        Assert.AreEqual(0, referenced.Remove.Count);
        Assert.IsFalse(referenced.Ledger.ContainsKey(c), "又被引用了：从账上去掉");

        var text = NoteImageRules.WriteLedger(plan.Ledger);
        CollectionAssert.AreEquivalent(plan.Ledger.ToList(), NoteImageRules.ReadLedger(text).ToList());
        Assert.AreEqual(0, NoteImageRules.ReadLedger("{坏了").Count);
        Assert.AreEqual(a, NoteImageRules.Identifier("0D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F.png"));
        Assert.IsNull(NoteImageRules.Identifier(".orphans.json"));
        Assert.IsNull(NoteImageRules.Identifier("0D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F.PNG"));
        Assert.IsNull(NoteImageRules.Identifier("0D8F2A11-1B7C-4F26-9C41-2E3B4C5D6E7F.png.tmp"));
    }

    [TestMethod]
    public void BackupsKeepSevenAndSampleOnlyOnce()
    {
        Assert.AreEqual("notes-2026-10-12", NotesBackupPlan.Name(new DateTime(2026, 10, 12)));
        Assert.AreEqual(new DateTime(2026, 10, 12), NotesBackupPlan.DayOf("notes-2026-10-12"));
        Assert.IsNull(NotesBackupPlan.DayOf("notes.partial"));
        var now = new DateTime(2026, 11, 5, 10, 0, 0);
        var copies = Enumerable.Range(0, 9).Select(index => ($"d{index}", now.Date.AddDays(-index))).ToList();
        copies.Add(("future", now.Date.AddDays(3)));
        var expired = NotesBackupPlan.Expired(copies, "d0", now);
        CollectionAssert.AreEqual(new[] { "future", "d8", "d7" }, expired.ToArray());

        Assert.AreEqual(NoteSample.Step.Skip, NoteSample.Next(wasAdded: true, isDeckEnabled: true, count: 0));
        Assert.AreEqual(NoteSample.Step.Mark, NoteSample.Next(false, true, 3));
        Assert.AreEqual(NoteSample.Step.Add, NoteSample.Next(false, true, 0));
        Assert.AreEqual(NoteSample.Step.Skip, NoteSample.Next(false, false, 0));
        StringAssert.StartsWith(NoteSample.Body("右", "Alt + N"), "欢迎使用便签\n鼠标靠到屏幕右边缘");
    }
}
