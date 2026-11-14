// PLAN-v19：连 WebDAV 服务器同步的整轮测试（Core 的 SyncServer.RoundAsync + SyncRunner + 内存里的 NoteBook / 几类仓库），
// 服务器是 FakeDav（临时文件夹真读真写）。照 mac NoteSyncServerTests 的十条：便签来回传、和同步文件夹混用（另一台直接拿
// FakeDav 的那个文件夹当同步文件夹，六类各走一遍）、图片、永久删除、没变的不再 GET、请求数分几轮、退避、密码不对 / 断网、
// 不往放着东西的文件夹里撒、测试连接、停止同步清镜像；再加 Windows 那几处（W1 占位、W2 账不在镜像根上、W3 只认规范写法、
// W4 标记没了就停、W7 太大的放长期占位）。最后一个是真服务器（设了 KITTY_WEBDAV="地址|用户名|密码" 才跑，用测试账号）。
// 占位靠 FileAttributes.Offline：只在 Windows 上设得上，别的系统上那几句断言跳过。
using System.Net;
using System.Net.Http.Headers;
using KittyTools.Core.Notes;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncServerTests
{
    private const long T0 = 1_760_000_000_123;

    /// <summary>一个临时目录，用完整个删掉。</summary>
    private sealed class Temp : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-server-" + Guid.NewGuid().ToString("N"));

        public Temp() => Directory.CreateDirectory(Path);

        public string Folder(string name)
        {
            var folder = System.IO.Path.Combine(Path, name);
            Directory.CreateDirectory(folder);
            return folder;
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch (IOException)
            {
                // 留给系统清
            }
        }
    }

    /// <summary>一台电脑：设备 + 便签本 + 几类仓库 + 自己的镜像和图片目录。</summary>
    private sealed class Node
    {
        public Node(string name, Temp temp, bool kinds = false)
        {
            Name = name;
            Device.Id = name;
            Book = new NoteBook(() => Device.Id);
            Mirror = Path.Combine(temp.Folder("mirrors-" + name), Guid.NewGuid().ToString("D").ToUpperInvariant());
            Images = temp.Folder("images-" + name);
            if (kinds)
            {
                Sources.Add(new MemoryValueSource(ClipSync.Kind, ClipSync.JoinKey));
                Sources.Add(new MemoryValueSource(VocabularySync.Kind, VocabularySync.JoinKey));
                Sources.Add(new MemoryValueSource(EngineSync.Kind, EngineSync.JoinKey));
                Sources.Add(new MemoryValueSource(ServiceSync.Kind, ServiceSync.JoinKey));
                Sources.Add(new MemoryValueSource(StatusPresetSync.Kind, StatusPresetSync.JoinKey));
                Sources.Add(new MemoryValueSource(ReminderSync.Kind, ReminderSync.JoinKey));
            }
        }

        public string Name { get; }

        public MemoryDevice Device { get; } = new();

        public NoteBook Book { get; }

        public string Mirror { get; }

        public string Images { get; }

        public List<MemorySource> Sources { get; } = new();

        public int Merges { get; private set; }

        public Dictionary<string, string> Map(string kind)
            => Sources.OfType<MemoryValueSource>().Single(source => source.Kind == kind).Map;

        private NoteSyncPart Part => new()
        {
            Flush = () =>
            {
                Book.Saved();
                return true;
            },
            Notes = () => Book.All.ToList(),
            Erased = () => new Dictionary<string, NoteSync.Tombstone>(Book.Erased, StringComparer.Ordinal),
            Editing = () => new HashSet<string>(StringComparer.Ordinal),
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
            ImagesDirectory = Images,
            Zone = TimeZoneInfo.Utc,
        };

        /// <summary>连服务器合一轮。</summary>
        public ServerRound Round(WebDav dav, long now, int budget = SyncServer.Budget)
            => SyncServer.RoundAsync(
                dav, Mirror, Device, Images,
                async incomplete =>
                {
                    Merges++;
                    return await new SyncRunner(Device, Sources, Name, notes: Part)
                        .RunAsync(Mirror, new Dictionary<string, int>(), now, incomplete);
                },
                () => true, budget).GetAwaiter().GetResult();

        public ServerRound Round(FakeDav server, long now, int budget = SyncServer.Budget, string password = FakeDav.Password)
            => Round(server.Dav(password), now, budget);

        /// <summary>直接拿一个文件夹当同步文件夹合一轮（混用：另一台用网盘客户端的样子）。</summary>
        public SyncRoundResult Folder(string folder, long now)
            => new SyncRunner(Device, Sources, Name, notes: Part)
                .RunAsync(folder, new Dictionary<string, int>(), now).GetAwaiter().GetResult();
    }

    private static void Connect(WebDav dav, Node node)
        => Assert.IsNull(SyncServer.ConnectAsync(dav, node.Device.Id).GetAwaiter().GetResult());

    private static void Settle(WebDav dav, long now, params Node[] nodes)
    {
        for (var pass = 0; pass < 3; pass++)
        {
            foreach (var node in nodes)
            {
                var round = node.Round(dav, now + pass);
                Assert.IsNull(round.Failure, round.Failure?.Message ?? string.Empty);
                Assert.IsFalse(round.Missing);
                Assert.IsFalse(round.MarkerGone);
                Assert.AreNotEqual("stopped", round.Merged?.State ?? "idle", round.Merged?.Message ?? string.Empty);
            }
        }
    }

    private static string NotePath(string root, string device, string id)
        => Path.Combine(root, "devices", device, "notes", id + ".md");

    private static int Alive(Node node) => node.Book.All.Count(note => note.DeletedAt is null);

    [TestMethod]
    public void NotesTravelThroughServer()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        var note = a.Book.Create(T0, "第一条\n正文");
        Settle(server.Dav(), T0 + 10, a, b);
        Assert.AreEqual("第一条\n正文", b.Book.Find(note.Id)?.Body);
        Assert.IsTrue(File.Exists(NotePath(server.Root, "WIN-A", note.Id)), "服务器上的写法和同步文件夹一样");

        b.Book.SetBody(note.Id, "第一条\n在 B 上改过", T0 + 100);
        Settle(server.Dav(), T0 + 200, b, a);
        Assert.AreEqual("第一条\n在 B 上改过", a.Book.Find(note.Id)?.Body);
        Assert.AreEqual(0, a.Book.Trashed.Count);
    }

    [TestMethod]
    public void ServerAndFolderMix()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp, kinds: true);
        var c = new Node("MAC-C", temp, kinds: true);
        Connect(server.Dav(), a);
        var kinds = new[] { ClipSync.Kind, VocabularySync.Kind, EngineSync.Kind, ServiceSync.Kind, StatusPresetSync.Kind, ReminderSync.Kind };
        foreach (var kind in kinds)
        {
            a.Map(kind)[MemoryClipSource.NewUid()] = $"{{\"from\":\"A\",\"kind\":\"{kind}\"}}";
            c.Map(kind)[MemoryClipSource.NewUid()] = $"{{\"from\":\"C\",\"kind\":\"{kind}\"}}";
        }

        var fromA = a.Book.Create(T0, "A 连着服务器写的");
        var fromC = c.Book.Create(T0 + 1, "C 在同步盘里写的");
        for (var pass = 0; pass < 3; pass++)
        {
            Assert.IsNull(a.Round(server, T0 + 10 + pass).Failure);
            // C 直接读写服务器后面那个文件夹：就是用网盘客户端同步到本机的样子
            Assert.AreNotEqual("stopped", c.Folder(server.Root, T0 + 10 + pass).State);
        }

        Assert.AreEqual("A 连着服务器写的", c.Book.Find(fromA.Id)?.Body);
        Assert.AreEqual("C 在同步盘里写的", a.Book.Find(fromC.Id)?.Body);
        foreach (var kind in kinds)
        {
            CollectionAssert.AreEquivalent(a.Map(kind).Values.ToList(), c.Map(kind).Values.ToList(), kind);
            Assert.AreEqual(2, a.Map(kind).Count, kind);
        }
    }

    [TestMethod]
    public void ImagesTravelThroughServer()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        var image = new NoteImages.Image(Guid.NewGuid(), "png", null);
        var bytes = new byte[] { 0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4 };
        File.WriteAllBytes(Path.Combine(a.Images, image.FileName), bytes);
        a.Book.Create(T0, "有图\n" + NoteImages.Token(image));
        Settle(server.Dav(), T0 + 10, a, b);

        var shared = Path.Combine(server.Root, "images");
        CollectionAssert.AreEqual(bytes, File.ReadAllBytes(Path.Combine(shared, image.FileName)));
        CollectionAssert.AreEqual(bytes, File.ReadAllBytes(Path.Combine(b.Images, image.FileName)));
        Assert.IsFalse(
            Directory.EnumerateFiles(shared).Any(path => Path.GetFileName(path).StartsWith('.')),
            "服务器的 images/ 里只有正式名字的图（临时名 MOVE 掉了）");

        // 不支持 MOVE 的服务器：直接 PUT 正式名
        server.SupportsMove = false;
        var second = new NoteImages.Image(Guid.NewGuid(), "jpg", null);
        File.WriteAllBytes(Path.Combine(a.Images, second.FileName), bytes);
        a.Book.Create(T0 + 100, "第二张\n" + NoteImages.Token(second));
        Settle(server.Dav(), T0 + 110, a, b);
        Assert.IsTrue(File.Exists(Path.Combine(b.Images, second.FileName)));
        Assert.IsFalse(Directory.EnumerateFiles(shared).Any(path => Path.GetFileName(path).StartsWith('.')));
    }

    [TestMethod]
    public void ErasedNotesLeaveTheServer()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        var note = a.Book.Create(T0, "要删的");
        Settle(server.Dav(), T0 + 10, a, b);
        Assert.IsNotNull(b.Book.Find(note.Id));

        a.Book.Erase(new[] { note.Id });
        Settle(server.Dav(), T0 + 100, a, b);
        Assert.IsNull(b.Book.Find(note.Id));
        Assert.IsTrue(b.Book.Erased.ContainsKey(note.Id));
        Assert.IsFalse(File.Exists(NotePath(server.Root, "WIN-A", note.Id)));
        Assert.IsFalse(File.Exists(NotePath(server.Root, "WIN-B", note.Id)));
        Assert.IsFalse(File.Exists(NotePath(b.Mirror, "WIN-A", note.Id)), "镜像里别人的那份也跟着没了");
    }

    [TestMethod]
    public void UnchangedFilesAreNotFetchedAgain()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        a.Book.Create(T0, "一条");
        b.Book.Create(T0 + 1, "另一条");
        Settle(server.Dav(), T0 + 10, a, b);
        a.Round(server, T0 + 20);
        b.Round(server, T0 + 20);

        server.ClearLog();
        Assert.IsNull(a.Round(server, T0 + 30).Failure);
        var log = server.Requests();
        Assert.IsTrue(log.All(entry => entry.StartsWith("PROPFIND ", StringComparison.Ordinal)), string.Join("\n", log));
        Assert.IsTrue(log.Count <= 3 + 2 * 2, $"空闲一轮只列目录：3 + 2 × 电脑数个以内\n{string.Join("\n", log)}");
    }

    [TestMethod]
    public void BudgetSpreadsOverRounds()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        for (var index = 0; index < 30; index++)
        {
            a.Book.Create(T0 + index, $"第 {index} 条");
        }

        var first = a.Round(server, T0 + 100, budget: 8);
        Assert.IsNull(first.Failure);
        Assert.IsTrue(first.Uploading > 0, "一轮 8 个请求传不完 30 条");
        var downloading = false;
        for (var pass = 0; pass < 30; pass++)
        {
            var left = a.Round(server, T0 + 200 + pass, budget: 8);
            var right = b.Round(server, T0 + 200 + pass, budget: 8);
            Assert.IsNull(left.Failure);
            Assert.IsNull(right.Failure);
            downloading |= right.Downloading > 0;
            Assert.AreEqual(0, b.Book.Trashed.Count, "没拿下来的那几条不当成删了");
            if (!left.Unsettled && !right.Unsettled && Alive(b) == 30)
            {
                break;
            }
        }

        Assert.IsTrue(downloading, "B 那边也分了几轮拿");
        Assert.AreEqual(30, Alive(b));
        Assert.AreEqual(0, server.Requests().Count(entry => entry.StartsWith("DELETE ", StringComparison.Ordinal)));
    }

    [TestMethod]
    public void BusyServerBacksOff()
    {
        Assert.AreEqual(TimeSpan.FromMinutes(5), SyncServer.Backoff(null, 0));
        Assert.AreEqual(TimeSpan.FromMinutes(10), SyncServer.Backoff(null, 1));
        Assert.AreEqual(TimeSpan.FromMinutes(20), SyncServer.Backoff(null, 2));
        Assert.AreEqual(TimeSpan.FromMinutes(30), SyncServer.Backoff(null, 3));
        Assert.AreEqual(TimeSpan.FromMinutes(30), SyncServer.Backoff(null, 9));
        Assert.AreEqual(TimeSpan.FromHours(2), SyncServer.Backoff(TimeSpan.FromHours(2), 0), "服务器说了等多久，至少等它说的");
        Assert.AreEqual(TimeSpan.FromMinutes(5), SyncServer.Backoff(TimeSpan.FromSeconds(30), 0));

        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        Connect(server.Dav(), a);
        server.Intercept = (_, _) =>
        {
            var busy = new HttpResponseMessage((HttpStatusCode)429);
            busy.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(1200));
            return busy;
        };
        var round = a.Round(server, T0);
        Assert.AreEqual(WebDavError.Busy, round.Failure?.Error);
        Assert.AreEqual(TimeSpan.FromSeconds(1200), round.Failure?.RetryAfter);
        Assert.AreEqual(0, a.Merges, "拿的时候就被拒了：这一轮不合");
    }

    [TestMethod]
    public void WrongPasswordAndOffline()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        Assert.AreEqual(WebDavError.Unauthorized, a.Round(server, T0, password: "nope").Failure?.Error);

        server.Offline = true;
        var note = a.Book.Create(T0 + 10, "断网时写的");
        Assert.AreEqual(WebDavError.Offline, a.Round(server, T0 + 20).Failure?.Error);

        server.Offline = false;
        Settle(server.Dav(), T0 + 30, a, b);
        Assert.AreEqual("断网时写的", b.Book.Find(note.Id)?.Body);
    }

    [TestMethod]
    public void RefusesFolderWithOtherThings()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        File.WriteAllText(Path.Combine(server.Root, "notes.txt"), "别的东西");
        Assert.AreEqual(
            "这个文件夹里已经有别的东西了，换一个空文件夹来同步",
            SyncServer.ConnectAsync(server.Dav(), "WIN-A").GetAwaiter().GetResult());
        Assert.IsFalse(File.Exists(Path.Combine(server.Root, NoteSyncFolder.MarkerName)), "不往放着东西的文件夹里撒");

        var orphan = new FakeDav(temp.Folder("orphan"));
        Directory.CreateDirectory(Path.Combine(orphan.Root, "devices", "MAC-B"));
        Assert.AreEqual(
            "这个文件夹里有别的电脑同步过的数据，却找不到同步记录（可能还没下载完），稍后再试",
            SyncServer.ConnectAsync(orphan.Dav(), "WIN-A").GetAwaiter().GetResult());

        var dotted = new FakeDav(temp.Folder("dotted"));
        File.WriteAllText(Path.Combine(dotted.Root, ".DS_Store"), "x");
        Assert.IsNull(SyncServer.ConnectAsync(dotted.Dav(), "WIN-A").GetAwaiter().GetResult(), "点开头的不算东西");
        Assert.IsTrue(File.Exists(Path.Combine(dotted.Root, NoteSyncFolder.MarkerName)));

        // 标记已经有了：第二台照常连，不重写标记
        var marker = File.ReadAllText(Path.Combine(dotted.Root, NoteSyncFolder.MarkerName));
        Assert.IsNull(SyncServer.ConnectAsync(dotted.Dav(), "WIN-B").GetAwaiter().GetResult());
        Assert.AreEqual(marker, File.ReadAllText(Path.Combine(dotted.Root, NoteSyncFolder.MarkerName)));
    }

    [TestMethod]
    public void TestConnectionAndNestedFolder()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var (ready, none) = SyncServer.TestAsync(server.Dav()).GetAwaiter().GetResult();
        Assert.AreEqual(ServerTest.Ready, ready);
        Assert.IsNull(none);
        Assert.AreEqual(0, Directory.EnumerateFileSystemEntries(server.Root).Count(), "测试连接写的小文件删掉了");

        var (wrong, failure) = SyncServer.TestAsync(server.Dav(password: "nope")).GetAwaiter().GetResult();
        Assert.AreEqual(ServerTest.Failed, wrong);
        Assert.AreEqual(WebDavError.Unauthorized, failure?.Error);

        var nested = new WebDav(FakeDav.Account("a/b/c/"), server.Transport());
        Assert.AreEqual(ServerTest.Missing, SyncServer.TestAsync(nested).GetAwaiter().GetResult().Test);
        Assert.IsNull(SyncServer.ConnectAsync(nested, "WIN-A").GetAwaiter().GetResult(), "没有的上级一起建");
        Assert.IsTrue(File.Exists(Path.Combine(server.Root, "a", "b", "c", NoteSyncFolder.MarkerName)));
    }

    [TestMethod]
    public void RemoveMirrorsKeepsOnlyTheCurrentOne()
    {
        using var temp = new Temp();
        var parent = temp.Folder("sync-server");
        var keep = Path.Combine(parent, "KEEP");
        Directory.CreateDirectory(keep);
        File.WriteAllText(SyncServer.LedgerPath(keep), "{}");
        var old = Path.Combine(parent, "OLD");
        Directory.CreateDirectory(Path.Combine(old, "devices"));
        File.WriteAllText(SyncServer.LedgerPath(old), "{}");

        SyncServer.RemoveMirrors(parent, keep);
        Assert.IsTrue(Directory.Exists(keep));
        Assert.IsTrue(File.Exists(SyncServer.LedgerPath(keep)));
        Assert.IsFalse(Directory.Exists(old));
        Assert.IsFalse(File.Exists(SyncServer.LedgerPath(old)));

        SyncServer.RemoveMirrors(parent, null);
        Assert.AreEqual(0, Directory.EnumerateFileSystemEntries(parent).Count(), "停止同步：镜像和账都删掉");
    }

    // ---- Windows 上和 mac 不一样的地方（PLAN-v19 §3） ----

    [TestMethod]
    public void PlaceholdersForWhatIsNotFetchedYet()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        for (var index = 0; index < 12; index++)
        {
            a.Book.Create(T0 + index, $"第 {index} 条");
        }

        Settle(server.Dav(), T0 + 100, a);
        var round = b.Round(server, T0 + 200, budget: 3);
        Assert.IsNull(round.Failure);
        Assert.IsTrue(round.Downloading > 0);
        Assert.AreEqual(0, b.Book.Trashed.Count);
        var notes = Path.Combine(b.Mirror, "devices", "WIN-A", "notes");
        if (OperatingSystem.IsWindows())
        {
            // W1：空文件 + Offline，读的那层当成还没下载
            var waiting = Directory.EnumerateFiles(notes).Where(SyncDisk.IsPlaceholder).ToList();
            Assert.IsTrue(waiting.Count > 0);
            Assert.IsTrue(waiting.All(path => new FileInfo(path).Length == 0));
        }

        Settle(server.Dav(), T0 + 300, b, a);
        Assert.AreEqual(12, Alive(b));
        Assert.IsFalse(Directory.EnumerateFiles(notes).Any(SyncDisk.IsPlaceholder), "拿下来之后占位换成了真的");
        Assert.AreEqual(0, server.Requests().Count(entry => entry.StartsWith("DELETE devices/WIN-A/", StringComparison.Ordinal)));
    }

    [TestMethod]
    public void LedgerLivesBesideTheMirror()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        Connect(server.Dav(), a);
        a.Book.Create(T0, "一条");
        Settle(server.Dav(), T0 + 10, a);
        Assert.IsTrue(File.Exists(SyncServer.LedgerPath(a.Mirror)));
        var names = Directory.EnumerateFileSystemEntries(a.Mirror).Select(Path.GetFileName).ToList();
        Assert.IsTrue(
            names.All(name => name is NoteSyncFolder.MarkerName or NoteSyncFolder.DevicesName or NoteSyncFolder.ImagesName),
            "W2：镜像根上只有同步的文件（不然 SyncDisk.LooksForeign 当成放着别的东西）：" + string.Join(", ", names));
    }

    [TestMethod]
    public void OnlyCanonicalNamesAreKnown()
    {
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var lower = id.ToLowerInvariant();
        Assert.IsNotNull(SyncServer.Known(NoteSyncFolder.MarkerName));
        Assert.IsNotNull(SyncServer.Known($"devices/WIN-A/notes/{id}.md"));
        Assert.IsNotNull(SyncServer.Known("devices/WIN-A/device.json"));
        Assert.IsNotNull(SyncServer.Known("devices/WIN-A/erased.json"));
        Assert.IsNotNull(SyncServer.Known("devices/WIN-A/clips.json"));
        Assert.IsNotNull(SyncServer.Known($"images/{id}.png"));
        Assert.IsNull(SyncServer.Known($"devices/WIN-A/notes/{lower}.md"), "只差大小写的另一份");
        Assert.IsNull(SyncServer.Known("devices/win-a/device.json"));
        Assert.IsNull(SyncServer.Known("devices/CON/device.json"), "Windows 的保留名");
        Assert.IsNull(SyncServer.Known("devices/COM1/device.json"));
        Assert.IsNull(SyncServer.Known("devices/WIN-A/settings.json"), "Windows 不同步的类别不拿");
        Assert.IsNull(SyncServer.Known($"images/{id}.PNG"));
        Assert.IsNull(SyncServer.Known($"images/{lower}.png"));
        Assert.IsNull(SyncServer.Known(@"images/..\..\evil.png"));
        Assert.IsNull(SyncServer.Known(@"devices/..\..\X/device.json"));
        Assert.IsNull(SyncServer.Known("devices/WIN-A/notes/../../x.md"));
        Assert.IsNull(SyncServer.Known(".kitty-test-1"));

        // 服务器上多了一份小写编号的便签文件（别的程序写的）：不拿。FakeDav 后面是 NTFS，建不出和正经那份只差大小写的文件，
        // 就拿另一个编号的小写写法试
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        var note = a.Book.Create(T0, "一条");
        Settle(server.Dav(), T0 + 10, a);
        var stray = Guid.NewGuid().ToString("D");
        File.Copy(NotePath(server.Root, "WIN-A", note.Id), NotePath(server.Root, "WIN-A", stray));
        server.ClearLog();
        Assert.IsNull(b.Round(server, T0 + 20).Failure);
        Assert.IsFalse(server.Requests().Contains($"GET devices/WIN-A/notes/{stray}.md"));
        Assert.IsFalse(File.Exists(NotePath(b.Mirror, "WIN-A", stray)));
        Assert.AreEqual("一条", b.Book.Find(note.Id)?.Body);
    }

    [TestMethod]
    public void MissingMarkerStopsBeforeMerging()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        Connect(server.Dav(), a);
        a.Book.Create(T0, "一条");
        Settle(server.Dav(), T0 + 10, a);
        File.Delete(Path.Combine(server.Root, NoteSyncFolder.MarkerName));
        var merges = a.Merges;

        var round = a.Round(server, T0 + 20);
        Assert.IsTrue(round.MarkerGone);
        Assert.AreEqual(merges, a.Merges, "W4：不进 SyncRunner（它会自己建一个服务器上没有的库）");
        Assert.IsFalse(File.Exists(Path.Combine(a.Mirror, NoteSyncFolder.MarkerName)));
        Assert.IsFalse(File.Exists(Path.Combine(server.Root, NoteSyncFolder.MarkerName)));
    }

    [TestMethod]
    public void OversizedFilesGetALastingPlaceholder()
    {
        using var temp = new Temp();
        var server = new FakeDav(temp.Folder("server"));
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        Connect(server.Dav(), a);
        Connect(server.Dav(), b);
        var note = a.Book.Create(T0, "正常的");
        Settle(server.Dav(), T0 + 10, a);
        var big = Guid.NewGuid().ToString("D").ToUpperInvariant();
        File.WriteAllBytes(NotePath(server.Root, "WIN-A", big), new byte[NoteSyncFolder.MaxNoteFileBytes + 1]);

        server.ClearLog();
        var round = b.Round(server, T0 + 20);
        Assert.IsNull(round.Failure);
        Assert.AreEqual(0, round.Downloading, "W7：太大的不算「还没拿下来」");
        Assert.AreEqual("正常的", b.Book.Find(note.Id)?.Body);
        var local = NotePath(b.Mirror, "WIN-A", big);
        Assert.IsTrue(File.Exists(local));
        Assert.AreEqual(0L, new FileInfo(local).Length);
        if (OperatingSystem.IsWindows())
        {
            Assert.IsTrue(SyncDisk.IsPlaceholder(local));
        }

        Assert.IsFalse(server.Requests().Any(entry => entry == $"GET devices/WIN-A/notes/{big}.md"));
        server.ClearLog();
        Assert.IsNull(b.Round(server, T0 + 30).Failure);
        Assert.IsFalse(server.Requests().Any(entry => entry == $"GET devices/WIN-A/notes/{big}.md"), "下一轮也不拿");
    }

    /// <summary>真服务器（按需）：KITTY_WEBDAV="地址|用户名|密码"，用测试账号；在那下面建一个临时文件夹，两台来回传一条便签，最后整个删掉。</summary>
    [TestMethod]
    public void LiveServer()
    {
        if (Environment.GetEnvironmentVariable("KITTY_WEBDAV") is not { Length: > 0 } live)
        {
            return;
        }

        var parts = live.Split('|');
        var folder = WebDav.Folder(parts[0], "kitty-live-" + Guid.NewGuid().ToString("N")[..8]);
        Assert.IsNotNull(folder);
        var dav = new WebDav(new WebDavAccount(folder, parts[1], parts[2]), WebDavTransport.CreateDefault());
        using var temp = new Temp();
        var a = new Node("WIN-A", temp);
        var b = new Node("WIN-B", temp);
        try
        {
            var (test, _) = SyncServer.TestAsync(dav).GetAwaiter().GetResult();
            Assert.AreEqual(ServerTest.Missing, test);
            Connect(dav, a);
            Connect(dav, b);
            var note = a.Book.Create(T0, "真服务器上的一条");
            Settle(dav, T0 + 10, a, b);
            Assert.AreEqual("真服务器上的一条", b.Book.Find(note.Id)?.Body);
        }
        finally
        {
            try
            {
                dav.DeleteAsync(Array.Empty<string>()).GetAwaiter().GetResult();
            }
            catch (WebDavException)
            {
                // 删不掉就留在测试账号里
            }
        }
    }
}
