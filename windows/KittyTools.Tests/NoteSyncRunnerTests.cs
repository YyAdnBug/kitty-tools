// PLAN-v13 第 3 批：便签接进同步执行层（SyncRunner 多的那一步）的整轮测试。两台「电脑」各一个内存里的 NoteBook，共用一个临时文件夹，
// 照 mac NoteSyncerTests 的几个主场景：新建传过去、一边改另一边跟上、两边各改（后改的赢、输的进最近删除）、永久删除传过去、一轮要删太多先刹车、
// 认出便签库被退回去了换编号。合并规则和文件格式本身由 NoteSyncTests 的 golden 锁住，这里只看执行层的先后对不对。
using KittyTools.Core.Notes;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class NoteSyncRunnerTests
{
    private const long T0 = 1_760_000_000_123;

    private sealed class Node
    {
        public Node(string name)
        {
            Device.Id = name;
            Name = name;
            Book = new NoteBook(() => Device.Id);
        }

        public string Name { get; }

        public MemoryDevice Device { get; } = new();

        public NoteBook Book { get; }

        public HashSet<string> Editing { get; } = new(StringComparer.Ordinal);

        public NoteSyncPart Part => new()
        {
            Flush = () =>
            {
                Book.Saved();
                return true;
            },
            Notes = () => Book.All.ToList(),
            Erased = () => new Dictionary<string, NoteSync.Tombstone>(Book.Erased, StringComparer.Ordinal),
            Editing = () => Editing,
            SwitchDevice = (ids, old, fresh) =>
            {
                Book.SwitchDevice(ids, old, fresh);
                Device.Id = fresh;
                return true;
            },
            Apply = (merges, tombstones) =>
            {
                Book.ApplySync(merges, tombstones);
                return true;
            },
            Published = ids => Book.Published(ids),
            Zone = TimeZoneInfo.Utc,
        };

        public SyncRoundResult Round(string folder, long now, IReadOnlyDictionary<string, int>? allowance = null)
            => new SyncRunner(Device, Array.Empty<ISyncSource>(), Name, notes: Part)
                .RunAsync(folder, allowance ?? new Dictionary<string, int>(), now).GetAwaiter().GetResult();
    }

    private static string NewFolder()
    {
        var folder = Path.Combine(Path.GetTempPath(), "kitty-notes-sync-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    private static void Settle(string folder, long now, params Node[] nodes)
    {
        for (var pass = 0; pass < 3; pass++)
        {
            foreach (var node in nodes)
            {
                Assert.AreNotEqual("stopped", node.Round(folder, now + pass).State);
            }
        }
    }

    private static string Contents(NoteBook book)
        => string.Join("\n", book.All.OrderBy(note => note.Id, StringComparer.Ordinal)
            .Select(note => $"{note.Id}|{note.Title}|{note.Body}|{note.Color}|{note.DeletedAt}|{note.IsArchived}"));

    [TestMethod]
    public void NewNotesAndEditsTravelBothWays()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var b = new Node("MAC-B");
            var note = a.Book.Create(T0, "第一条\n正文");
            Settle(folder, T0 + 10, a, b);
            Assert.AreEqual("第一条\n正文", b.Book.Find(note.Id)?.Body);
            // 自己那份写成了 mac 的便签文件：读回来就是这一条
            var file = Path.Combine(folder, "devices", "WIN-A", "notes", note.Id + ".md");
            Assert.IsTrue(File.Exists(file));
            Assert.AreEqual(note.Body, NoteSyncFolder.Parse(File.ReadAllText(file), note.Id)?.Note.Body);

            b.Book.SetBody(note.Id, "第一条\n在 B 上改过", T0 + 100);
            Settle(folder, T0 + 200, b, a);
            Assert.AreEqual("第一条\n在 B 上改过", a.Book.Find(note.Id)?.Body);
            Assert.AreEqual(0, a.Book.Trashed.Count, "只有一边改过：直接换，不留旧版");
            Assert.AreEqual(Contents(a.Book), Contents(b.Book));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void BothEditedKeepsTheLaterAndTrashesTheOther()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var b = new Node("MAC-B");
            var note = a.Book.Create(T0, "原文");
            Settle(folder, T0 + 10, a, b);
            a.Book.SetBody(note.Id, "A 的", T0 + 100);
            b.Book.SetBody(note.Id, "B 的（后改）", T0 + 200);
            Settle(folder, T0 + 300, a, b);
            Assert.AreEqual("B 的（后改）", a.Book.Find(note.Id)?.Body);
            Assert.AreEqual("B 的（后改）", b.Book.Find(note.Id)?.Body);
            CollectionAssert.AreEqual(new[] { "A 的" }, a.Book.Trashed.Select(item => item.Body).ToArray());
            Assert.AreEqual(Contents(a.Book), Contents(b.Book), "几台各自另存的是同一条（编号由那一版推出来）");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void ErasedNotesStayErased()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var b = new Node("MAC-B");
            var note = a.Book.Create(T0, "要删的");
            Settle(folder, T0 + 10, a, b);
            a.Book.Erase(new[] { note.Id });
            Settle(folder, T0 + 100, a, b);
            Assert.IsNull(b.Book.Find(note.Id));
            Assert.IsTrue(b.Book.Erased.ContainsKey(note.Id));
            Assert.IsFalse(File.Exists(Path.Combine(folder, "devices", "WIN-A", "notes", note.Id + ".md")));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void DeletingTooManyBrakesUntilConfirmed()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var b = new Node("MAC-B");
            var ids = Enumerable.Range(0, 25).Select(index => a.Book.Create(T0 + index, $"第 {index} 条").Id).ToList();
            Settle(folder, T0 + 100, a, b);
            Assert.AreEqual(25, b.Book.Active.Count);
            foreach (var id in ids)
            {
                a.Book.Delete(id, T0 + 200);
            }

            Assert.AreNotEqual("stopped", a.Round(folder, T0 + 300).State);
            var braked = b.Round(folder, T0 + 400);
            Assert.AreEqual("confirm", braked.State);
            Assert.AreEqual(25, braked.Waiting[NoteSyncFolder.NotesPart]);
            Assert.AreEqual(25, b.Book.Active.Count, "刹车时一条都不动");
            var confirmed = b.Round(folder, T0 + 500, braked.Waiting);
            Assert.AreNotEqual("confirm", confirmed.State);
            Assert.AreEqual(25, b.Book.Trashed.Count, "放行之后进最近删除");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void EditingNotesWaitForTheNextRound()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var b = new Node("MAC-B");
            var note = a.Book.Create(T0, "原文");
            Settle(folder, T0 + 10, a, b);
            a.Book.SetBody(note.Id, "A 改的", T0 + 100);
            a.Round(folder, T0 + 110);
            b.Editing.Add(note.Id);
            b.Round(folder, T0 + 120);
            Assert.AreEqual("原文", b.Book.Find(note.Id)?.Body, "正在编辑的先不换");
            b.Editing.Clear();
            b.Round(folder, T0 + 130);
            Assert.AreEqual("A 改的", b.Book.Find(note.Id)?.Body);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void RestoredNotesSwitchTheDeviceBeforeWriting()
    {
        var folder = NewFolder();
        try
        {
            var a = new Node("WIN-A");
            var note = a.Book.Create(T0, "原文");
            Settle(folder, T0 + 10, a);
            // 便签库被恢复成旧的：钟退回到 0（文件夹里本机那一格是 1）
            var restored = new Node("WIN-A");
            restored.Book.Load(note with { Clock = new Dictionary<string, long>(StringComparer.Ordinal) }, note.Revision, false);
            restored.Book.Saved();
            restored.Round(folder, T0 + 100);
            Assert.AreNotEqual("WIN-A", restored.Device.Id, "认出退回去了：换了编号");
            Assert.IsTrue(restored.Book.Find(note.Id)!.Clock.ContainsKey(restored.Device.Id));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
