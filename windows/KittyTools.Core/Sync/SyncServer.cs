// 连 WebDAV 服务器同步时，本机和服务器之间怎么搬文件（PLAN-v19 V2 V3，issue #18；照 mac Notes/NoteSyncServer.swift）。
// 服务器上那个文件夹和同步文件夹的写法一模一样（标记、devices/<电脑编号>/…、共用的 images/），所以一台连服务器、一台走同步盘也能
// 合在一起。做法是在数据目录里留一份镜像（sync-server/<编号>/），一轮（RoundAsync）：
//   pull（服务器上变了的拿下来）→ 照文件夹同步合一轮（App 传进来的 merge：SyncRunner 读写的就是这份镜像，合并、刹车、退回、
//   图片清理都不改）→ push（本机写进镜像的送上去）。
// - **镜像就是同步盘在本机的那一份**：本机写了还没传上去的（自己子文件夹里改过的、images/ 里新放的）留着、下一轮接着传；
//   服务器上变了的（按 ETag；没给 ETag 的按改动时间 + 大小）才 GET，没变的不碰。服务器上没了的：别人的、标记直接删；自己子文件夹
//   和 images/ 里账上记过（传上去过）的也删，账上没有的是还没传上去的、留着。镜像里文件的改动时间设成服务器上的（R49 的指纹、
//   「其他电脑上次有改动」按它算）。
// - **这一轮没拿下来的**（超了每轮的请求数）：镜像里有旧的一版就留着（同步盘慢了一样，合并本来就经得起旧的），没有的放一个占位：
//   空文件 + FileAttributes.Offline（PLAN-v19 W1：SyncDisk.IsPlaceholder 认的就是它，SyncDisk / NoteSyncDisk 当成「还没下载」）。
//   有没拿下来的，merge 收到 incomplete = true（共用的图一张不删、这一轮不算合完）。比上限还大的（W7）放一个长期的占位、
//   不算进「还有几个没拿下来」。
// - **只写自己的**：自己子文件夹里本机改过的（改动时刻、大小和账上记的不一样，W6）PUT，账上有、镜像里没了的 DELETE；共用 images/
//   里镜像有、账上没有的上传（先传成点开头的临时名再 MOVE 成正式的，不覆盖：同名就是同一张），账上有、镜像里没了的删（便签那部分
//   的图片清理定的）。先后同写文件夹：便签、墓碑、图片、一类一类的，**device.json 最后**，前面的都传完了才传。传完重新列一下写过的
//   文件夹，记下服务器给的 ETag（下一轮不再拿回来）。
// - **图片不重复下载**：服务器上有、本机图片目录里也有的同名图（同名就是同一张），从本机拷进镜像（ponytail: NTFS 没有克隆，镜像里的
//   图和本机图片目录各占一份，W5；嫌占地方再换硬链接）。
// - **请求数**：每轮 GET / PUT / DELETE / MKCOL / MOVE 合起来最多 Budget 个（列目录不算，一轮 3 + 2 × 电脑数个），先拿标记、
//   device.json、墓碑、一类一类的，再便签、图片；剩下的下一轮。服务器说请求太多（429 / 503）立刻停，App 退避（Backoff）。
//   ponytail: 按轮限，不按时间窗——各家限额不公开（坚果云网上说每半小时几百到一千多次），撞上了靠退避。
// - **服务器给的名字是信任边界**（W3）：先过 Known（只认规范写法、一字不差：编号大写、不带 \ 和 ..），过了才拼本机路径。
// - 账（服务器上每个文件的 ETag、改动时间、大小，和镜像里那份的改动时刻 + 大小）存在镜像旁边的 <镜像>.json（W2：不放镜像根上——
//   SyncDisk.LooksForeign 认点开头的文件）。
// - 标记只在连接时写（ConnectAsync）；一轮里 pull 完镜像里没有标记就停（W4：SyncRunner 读到没有标记会自己建库，push 又不传标记）。
// 网络和镜像的读写都在线程池上（RoundAsync 用 Task.Run 包着 pull / push），merge 回到调用方的线程（SyncRunner 的仓库只在 UI 线程上用）。
using System.Text.Json.Serialization;
using KittyTools.Core.Notes;

namespace KittyTools.Core.Sync;

/// <summary>镜像里一个文件的样子（改动时刻 + 大小）：和账上记的一样 = 本机没动过。</summary>
public sealed record ServerLocal(long Ticks, long Size);

/// <summary>账上的一个文件：服务器上的样子（刚传上去、还没重新列到的，ETag 和改动时间是 null），和拿下来 / 传上去时镜像里那份的样子。</summary>
public sealed class ServerEntry
{
    public string? ETag { get; set; }

    public DateTimeOffset? Modified { get; set; }

    public long Size { get; set; }

    public ServerLocal? Local { get; set; }
}

public sealed class ServerLedger
{
    /// <summary>服务器上的文件夹 + 用户名：换了就从头记。</summary>
    public string Server { get; set; } = string.Empty;

    /// <summary>路径（「devices/编号/notes/编号.md」）→ 那个文件。</summary>
    public Dictionary<string, ServerEntry> Files { get; set; } = new(StringComparer.Ordinal);
}

[JsonSerializable(typeof(ServerLedger))]
internal sealed partial class ServerLedgerJson : JsonSerializerContext
{
}

/// <summary>pull 的结果。</summary>
public sealed class ServerPulled
{
    public WebDavFailure? Failure { get; set; }

    /// <summary>服务器上同步的那个文件夹不在了。</summary>
    public bool Missing { get; set; }

    /// <summary>这一轮还能发几个请求（push 用）。</summary>
    public int Left { get; set; }

    /// <summary>服务器上变了、这一轮没拿下来的（状态行「还有几个没从服务器拿下来」）。</summary>
    public int Waiting { get; set; }

    /// <summary>服务器上已经有的文件夹（路径，根是 ""）：push 只建没有的。</summary>
    public HashSet<string> Folders { get; } = new(StringComparer.Ordinal);
}

/// <summary>push 的结果。</summary>
public sealed class ServerPushed
{
    public WebDavFailure? Failure { get; set; }

    /// <summary>这一轮没传上去的（状态行「还有几个等着传上去」）。</summary>
    public int Waiting { get; set; }
}

/// <summary>一轮（pull → merge → push）的结果。</summary>
public sealed class ServerRound
{
    /// <summary>pull 或 push 出的错（Busy 时 App 退避）。</summary>
    public WebDavFailure? Failure { get; set; }

    /// <summary>服务器上同步的那个文件夹不在了。</summary>
    public bool Missing { get; set; }

    /// <summary>镜像里没有标记（服务器上的被删了 / 换了）：没合（W4）。</summary>
    public bool MarkerGone { get; set; }

    /// <summary>merge 的结果；没走到 merge、或者 merge 跳过了这一轮（指纹没变）是 null。</summary>
    public SyncRoundResult? Merged { get; set; }

    /// <summary>还有几个没从服务器拿下来 / 没传上去。</summary>
    public int Downloading { get; set; }

    public int Uploading { get; set; }

    /// <summary>有没拿下来、没传上去的：下一轮不能当成「没变」跳过。</summary>
    public bool Unsettled => Downloading > 0 || Uploading > 0;
}

/// <summary>连接之前看一眼服务器上那个文件夹（同选文件夹时看的那几样）。</summary>
public sealed class ServerInspection
{
    public WebDavFailure? Failure { get; set; }

    public bool Exists { get; set; }

    /// <summary>里面没东西（点开头的不算）。</summary>
    public bool Empty { get; set; }

    public NoteSyncFolder.Marker? Marker { get; set; }

    /// <summary>标记文件有、却读不出来。</summary>
    public bool MarkerUnreadable { get; set; }

    /// <summary>别的电脑（不算自己）有几台、它们一共有多少条便签（含最近删除里的）。</summary>
    public int Devices { get; set; }

    public int Notes { get; set; }
}

public enum ServerTest
{
    /// <summary>能读能写。</summary>
    Ready,

    /// <summary>连上了，服务器上还没有这个文件夹（连接时建好）。</summary>
    Missing,

    Failed,
}

public static class SyncServer
{
    /// <summary>每轮最多几个 GET / PUT / DELETE / MKCOL / MOVE（文件头）。</summary>
    public const int Budget = 40;

    /// <summary>标记、device.json 最多多大（再大就是坏的）。</summary>
    public const int SmallBytes = 1 << 20;

    private const string Devices = NoteSyncFolder.DevicesName;
    private const string Images = NoteSyncFolder.ImagesName;

    // ---- 认得的文件（W3） ----

    /// <summary>
    /// 镜像里认得的文件：大小上限、拿的先后（小的先）。认不出的（别人的临时文件、Windows 不同步的类别、写法不规范的名字）不拿、不删。
    /// 只认规范写法、一字不差：电脑编号不带小写字母，便签文件名是大写编号 + .md，图片是大写编号 + 小写扩展名——镜像在不分大小写的
    /// NTFS 上，服务器上只差大小写的两个名字只能认一个；带 \、..、保留名的都过不了。
    /// </summary>
    public static (long Limit, int Order)? Known(string path)
    {
        var parts = path.Split('/');
        switch (parts.Length)
        {
            case 1 when parts[0] == NoteSyncFolder.MarkerName:
                return (SmallBytes, 0);
            case 2 when parts[0] == Images:
                return IsImageName(parts[1]) ? (NoteImageRules.MaxFileBytes, 5) : null;
            case 3 when parts[0] == Devices && IsDevice(parts[1]):
                if (parts[2] == NoteSyncFolder.DeviceInfoName)
                {
                    return (SmallBytes, 1);
                }

                if (parts[2] == NoteSyncFolder.ErasedName)
                {
                    return (SyncFile.MaxBytes, 2);
                }

                return parts[2].EndsWith(".json", StringComparison.Ordinal) &&
                       SyncFolderRules.IsSyncedKind(parts[2][..^5])
                    ? (SyncFile.MaxBytes, 3)
                    : null;
            case 4 when parts[0] == Devices && IsDevice(parts[1]) && parts[2] == NoteSyncFolder.NotesName:
                return IsNoteName(parts[3]) ? (NoteSyncFolder.MaxNoteFileBytes, 4) : null;
            default:
                return null;
        }
    }

    /// <summary>电脑编号的规范写法：不带小写字母，也不是 Windows 的保留名（CON、NUL、COM1……：建不出这个文件夹）。</summary>
    public static bool IsDevice(string name)
        => SyncFolderRules.IsDeviceName(name) && !name.Any(char.IsAsciiLetterLower) &&
           name is not ("CON" or "PRN" or "AUX" or "NUL") &&
           !(name.Length == 4 && (name.StartsWith("COM", StringComparison.Ordinal) || name.StartsWith("LPT", StringComparison.Ordinal)) &&
             char.IsAsciiDigit(name[3]));

    private static bool IsNoteName(string name)
        => NoteSyncFolder.NoteId(name) is { } id && name == NoteSyncFolder.FileName(id);

    private static bool IsImageName(string name)
        => NoteSyncFolder.ImageId(name) is { } id &&
           name.StartsWith(NoteImages.IdText(id) + ".", StringComparison.Ordinal);

    /// <summary>服务器上的这个文件和账上记的是不是同一版。</summary>
    public static bool Matches(ServerEntry entry, WebDavItem item)
    {
        if (item.ETag is { } etag && entry.ETag is { } known)
        {
            return etag == known;
        }

        return item.Modified is not null && entry.Modified == item.Modified && entry.Size == item.Size;
    }

    private static bool IsOwn(string path, string me) => path.StartsWith($"{Devices}/{me}/", StringComparison.Ordinal);

    private static bool IsImage(string path) => path.StartsWith(Images + "/", StringComparison.Ordinal);

    private static string[] Split(string path) => path.Split('/');

    private static string LocalPath(string mirror, string path)
        => Path.Combine(mirror, path.Replace('/', Path.DirectorySeparatorChar));

    /// <summary>账放在镜像旁边：sync-server/&lt;编号&gt;.json（W2）。</summary>
    public static string LedgerPath(string mirror) => Path.TrimEndingDirectorySeparator(mirror) + ".json";

    // ---- 一轮 ----

    /// <summary>
    /// 一轮（V3）：pull → 出错 / 文件夹不在了 / 镜像里没有标记就停 → merge（incomplete = 有没拿下来的）→ merge 认清了文件夹（或者
    /// 跳过了这一轮）才 push。current：这期间同步被关掉、换了服务器就是 false，不再往下走。
    /// </summary>
    public static async Task<ServerRound> RoundAsync(
        WebDav dav, string mirror, ISyncDevice device, string? images, Func<bool, Task<SyncRoundResult?>> merge,
        Func<bool> current, int budget = Budget)
    {
        var result = new ServerRound();
        var me = device.Id;
        var pulled = await Task.Run(() => PullAsync(dav, mirror, me, images, budget));
        result.Downloading = pulled.Waiting;
        if (pulled.Failure is not null)
        {
            result.Failure = pulled.Failure;
            return result;
        }

        if (pulled.Missing)
        {
            result.Missing = true;
            return result;
        }

        if (!File.Exists(Path.Combine(mirror, NoteSyncFolder.MarkerName)))
        {
            result.MarkerGone = true;
            return result;
        }

        if (!current())
        {
            return result;
        }

        var merged = await merge(pulled.Waiting > 0);
        result.Merged = merged;
        if (!current() || merged is { FolderOk: false })
        {
            return result;
        }

        // 合的时候可能换了编号（库被退回去了）：送的是新编号的子文件夹
        me = device.Id;
        var pushed = await Task.Run(() => PushAsync(dav, mirror, me, pulled.Left, pulled.Folders));
        result.Uploading = pushed.Waiting;
        result.Failure = pushed.Failure;
        return result;
    }

    /// <summary>服务器说请求太多：等多久（5、10、20、30 分钟；服务器说了等多久，至少等它说的）。count：连着第几回（从 0 起）。</summary>
    public static TimeSpan Backoff(TimeSpan? retryAfter, int count)
    {
        var minutes = Math.Min(5 * (1 << Math.Min(count, 3)), 30);
        var wait = TimeSpan.FromMinutes(minutes);
        return retryAfter is { } asked && asked > wait ? asked : wait;
    }

    // ---- 拿下来 ----

    public static async Task<ServerPulled> PullAsync(WebDav dav, string mirror, string me, string? images, int budget)
    {
        var result = new ServerPulled { Left = budget };
        var ledgerPath = LedgerPath(mirror);
        var ledger = ReadLedger(ledgerPath, dav.Identity);
        try
        {
            Directory.CreateDirectory(mirror);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            result.Failure = new WebDavFailure(WebDavError.Disk);
            return result;
        }

        // 1. 列：标记、devices/ 下每台的子文件夹和它的 notes/、images/
        var remote = new Dictionary<string, WebDavItem>(StringComparer.Ordinal);
        void Add(WebDavItem item, string folder)
        {
            var path = folder.Length == 0 ? item.Name : folder + "/" + item.Name;
            if (!item.IsFolder && Known(path) is not null)
            {
                remote[path] = item;
            }
        }

        try
        {
            var top = await dav.ListAsync(Array.Empty<string>());
            if (top is null)
            {
                result.Missing = true;
                return result;
            }

            result.Folders.Add(string.Empty);
            foreach (var item in top)
            {
                Add(item, string.Empty);
            }

            if (top.Any(item => item.IsFolder && item.Name == Devices))
            {
                result.Folders.Add(Devices);
                foreach (var device in await dav.ListAsync(new[] { Devices }) ?? new List<WebDavItem>())
                {
                    if (!device.IsFolder || !IsDevice(device.Name))
                    {
                        continue;
                    }

                    var folder = Devices + "/" + device.Name;
                    var items = await dav.ListAsync(new[] { Devices, device.Name });
                    if (items is null)
                    {
                        continue;
                    }

                    result.Folders.Add(folder);
                    foreach (var item in items)
                    {
                        Add(item, folder);
                    }

                    if (items.Any(item => item.IsFolder && item.Name == NoteSyncFolder.NotesName))
                    {
                        var notes = folder + "/" + NoteSyncFolder.NotesName;
                        result.Folders.Add(notes);
                        foreach (var item in await dav.ListAsync(new[] { Devices, device.Name, NoteSyncFolder.NotesName }) ??
                                             new List<WebDavItem>())
                        {
                            Add(item, notes);
                        }
                    }
                }
            }

            if (top.Any(item => item.IsFolder && item.Name == Images))
            {
                result.Folders.Add(Images);
                foreach (var item in await dav.ListAsync(new[] { Images }) ?? new List<WebDavItem>())
                {
                    Add(item, Images);
                }
            }
        }
        catch (WebDavException ex)
        {
            result.Failure = ex.Failure;
            return result;
        }

        // 2. 服务器上没了的：别人的直接删；自己的、图片，账上记过（传上去过）的删，没记过的是还没传上去的
        var (files, placeholders) = MirrorFiles(mirror);
        foreach (var path in files)
        {
            if (remote.ContainsKey(path))
            {
                continue;
            }

            var pending = (IsOwn(path, me) || IsImage(path)) && !ledger.Files.ContainsKey(path);
            if (!pending)
            {
                TryDelete(LocalPath(mirror, path));
                ledger.Files.Remove(path);
            }
        }

        foreach (var path in placeholders)
        {
            if (!remote.ContainsKey(path))
            {
                TryDelete(LocalPath(mirror, path));
            }
        }

        foreach (var path in ledger.Files.Keys.ToList())
        {
            if (!remote.ContainsKey(path) && !files.Contains(path))
            {
                ledger.Files.Remove(path);
            }
        }

        // 3. 服务器上变了的：要拿的排好队（太大的放长期占位，本机有的图拷进来）
        var wanted = new List<(string Path, WebDavItem Item, long Limit, int Order)>();
        foreach (var (path, item) in remote)
        {
            if (Known(path) is not { } known)
            {
                continue;
            }

            var local = LocalPath(mirror, path);
            var here = IsHere(local);
            if (ledger.Files.TryGetValue(path, out var entry) && Matches(entry, item) &&
                (here || IsOwn(path, me) || IsImage(path) || item.Size > known.Limit))
            {
                // 没变：镜像里有（本机可能改过、等着传）、本机删了等着删（自己的、图片）、太大放着长期占位，都不动
                continue;
            }

            if (item.Size > known.Limit)
            {
                Mark(local);
                ledger.Files[path] = new ServerEntry { ETag = item.ETag, Modified = item.Modified, Size = item.Size };
                continue;
            }

            // 图片同名就是同一张：镜像里已经有（本机刚放进去、还没传上去）就认下，本机图片目录里有就拷进来
            if (IsImage(path) &&
                (here || (images is not null && CopyLocal(Path.Combine(images, Path.GetFileName(local)), local, item.Modified))))
            {
                ledger.Files[path] = new ServerEntry
                {
                    ETag = item.ETag,
                    Modified = item.Modified,
                    Size = item.Size,
                    Local = LocalOf(local),
                };
                continue;
            }

            wanted.Add((path, item, known.Limit, known.Order));
        }

        wanted.Sort((a, b) => a.Order != b.Order ? a.Order.CompareTo(b.Order) : string.CompareOrdinal(a.Path, b.Path));

        // 4. 拿，到这一轮的请求数为止；剩下的有旧的留旧的，没有的放占位
        for (var index = 0; index < wanted.Count; index++)
        {
            var want = wanted[index];
            var local = LocalPath(mirror, want.Path);
            if (result.Left <= 0)
            {
                result.Waiting = wanted.Count - index;
                foreach (var rest in wanted.Skip(index))
                {
                    var path = LocalPath(mirror, rest.Path);
                    if (!File.Exists(path))
                    {
                        Mark(path);
                    }
                }

                break;
            }

            result.Left--;
            try
            {
                // 列完到拿之间被删了：下一轮再说
                if (await dav.GetAsync(Split(want.Path)) is not { } data)
                {
                    continue;
                }

                if (data.Length > want.Limit)
                {
                    Mark(local);
                    ledger.Files[want.Path] = new ServerEntry { ETag = want.Item.ETag, Modified = want.Item.Modified, Size = data.Length };
                    continue;
                }

                Save(data, local, want.Item.Modified);
                ledger.Files[want.Path] = new ServerEntry
                {
                    ETag = want.Item.ETag,
                    Modified = want.Item.Modified,
                    Size = data.Length,
                    Local = LocalOf(local),
                };
            }
            catch (WebDavException ex)
            {
                result.Failure = ex.Failure;
                result.Waiting = wanted.Count - index;
                break;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 镜像写不进去（盘满了）：当这一轮没连上一样停，说原因
                result.Failure = new WebDavFailure(WebDavError.Disk);
                result.Waiting = wanted.Count - index;
                break;
            }
        }

        WriteLedger(ledger, ledgerPath);
        return result;
    }

    // ---- 送上去 ----

    private enum Step
    {
        Put,
        Delete,
        Upload,
    }

    public static async Task<ServerPushed> PushAsync(
        WebDav dav, string mirror, string me, int budget, IReadOnlySet<string> existing)
    {
        var ledgerPath = LedgerPath(mirror);
        var ledger = ReadLedger(ledgerPath, dav.Identity);
        var folders = new HashSet<string>(existing, StringComparer.Ordinal);
        var result = new ServerPushed();
        var left = budget;
        var touched = new SortedSet<string>(StringComparer.Ordinal);
        var (files, placeholders) = MirrorFiles(mirror);

        // 要做的：自己子文件夹里改过的 PUT、没了的 DELETE；images/ 里新的上传、没了的删。先后同写文件夹，device.json 最后
        static int Rank(string path)
        {
            var name = path[(path.LastIndexOf('/') + 1)..];
            if (path.StartsWith(Images + "/", StringComparison.Ordinal))
            {
                return 2;
            }

            if (name == NoteSyncFolder.DeviceInfoName)
            {
                return 4;
            }

            if (name == NoteSyncFolder.ErasedName)
            {
                return 1;
            }

            return Known(path)?.Order == 4 ? 0 : 3;
        }

        var steps = new List<(int Rank, string Path, Step Step)>();
        foreach (var path in files)
        {
            ledger.Files.TryGetValue(path, out var entry);
            if (IsOwn(path, me))
            {
                if (entry is null || entry.Local != LocalOf(LocalPath(mirror, path)))
                {
                    steps.Add((Rank(path), path, Step.Put));
                }
            }
            else if (IsImage(path) && entry is null)
            {
                steps.Add((Rank(path), path, Step.Upload));
            }
        }

        foreach (var path in ledger.Files.Keys)
        {
            if ((IsOwn(path, me) || IsImage(path)) && !files.Contains(path) && !placeholders.Contains(path))
            {
                steps.Add((Rank(path), path, Step.Delete));
            }
        }

        steps.Sort((a, b) => a.Rank != b.Rank ? a.Rank.CompareTo(b.Rank) : string.CompareOrdinal(a.Path, b.Path));

        // 建好放它的文件夹（devices/、devices/编号/、…/notes/、images/：服务器上没有的才建）；没钱了是 false
        async Task<bool> PrepareAsync(string path)
        {
            var parts = Split(path);
            for (var depth = 1; depth < parts.Length; depth++)
            {
                var folder = string.Join('/', parts.Take(depth));
                if (folders.Contains(folder))
                {
                    continue;
                }

                if (left <= 0)
                {
                    return false;
                }

                left--;
                await dav.MakeFolderAsync(parts.Take(depth).ToArray());
                folders.Add(folder);
            }

            return true;
        }

        // 排好的先后走，哪一步没钱了、出错了就停：device.json 排在最后，到得了它就是前面的都传完了
        for (var index = 0; index < steps.Count; index++)
        {
            var (_, path, step) = steps[index];
            var parts = Split(path);
            var local = LocalPath(mirror, path);
            var cost = step == Step.Upload ? 2 : 1;
            try
            {
                if (!await PrepareAsync(path) || left < cost)
                {
                    result.Waiting = steps.Count - index;
                    break;
                }

                left -= cost;
                switch (step)
                {
                    case Step.Put:
                    {
                        var sent = LocalOf(local);
                        await dav.PutAsync(parts, File.ReadAllBytes(local));
                        ledger.Files[path] = new ServerEntry { Size = sent?.Size ?? 0, Local = sent };
                        touched.Add(string.Join('/', parts[..^1]));
                        break;
                    }

                    case Step.Delete:
                        await dav.DeleteAsync(parts);
                        ledger.Files.Remove(path);
                        break;
                    case Step.Upload:
                    {
                        var sent = LocalOf(local);
                        await UploadAsync(dav, parts, File.ReadAllBytes(local));
                        ledger.Files[path] = new ServerEntry { Size = sent?.Size ?? 0, Local = sent };
                        touched.Add(Images);
                        break;
                    }
                }
            }
            catch (WebDavException ex)
            {
                result.Failure = ex.Failure;
                result.Waiting = steps.Count - index;
                break;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                result.Failure = new WebDavFailure(WebDavError.Disk);
                result.Waiting = steps.Count - index;
                break;
            }
        }

        // 传过的文件夹重新列一下，记下服务器上的 ETag、改动时间（下一轮认得是自己传的这一版，不再拿回来）
        foreach (var folder in touched)
        {
            List<WebDavItem>? items;
            try
            {
                items = await dav.ListAsync(Split(folder));
            }
            catch (WebDavException)
            {
                continue;
            }

            foreach (var item in items ?? new List<WebDavItem>())
            {
                var path = folder + "/" + item.Name;
                if (item.IsFolder || !ledger.Files.TryGetValue(path, out var entry) || entry.ETag is not null ||
                    entry.Modified is not null)
                {
                    continue;
                }

                entry.ETag = item.ETag;
                entry.Modified = item.Modified;
                entry.Size = item.Size;
            }
        }

        WriteLedger(ledger, ledgerPath);
        return result;
    }

    /// <summary>
    /// 传一张图：先传成点开头的临时名，再 MOVE 成正式的名字、不覆盖（已经有了：同名就是同一张，删掉临时的）。
    /// ponytail: 服务器不支持 MOVE（405 / 501）时直接 PUT 正式的名字（传到一半断了会留下半张，别的电脑当它是好的）；传了临时名后整个
    /// App 退了，临时文件（点开头，没人认）留在 images/ 里。
    /// </summary>
    private static async Task UploadAsync(WebDav dav, string[] parts, byte[] data)
    {
        var temporary = parts[..^1].Append($".kitty-{Guid.NewGuid():N}.partial").ToArray();
        await dav.PutAsync(temporary, data);
        try
        {
            await dav.MoveAsync(temporary, parts);
        }
        catch (WebDavException ex) when (ex.Failure.Error == WebDavError.Exists)
        {
            await dav.DeleteAsync(temporary);
        }
        catch (WebDavException ex) when (ex.Failure is { Error: WebDavError.Status, Status: 405 or 501 })
        {
            await dav.DeleteAsync(temporary);
            try
            {
                await dav.PutAsync(parts, data, ifAbsent: true);
            }
            catch (WebDavException exists) when (exists.Failure.Error == WebDavError.Exists)
            {
                // 同名就是同一张
            }
        }
    }

    // ---- 连接时 ----

    /// <summary>连服务器、开同步之前看一眼（同选文件夹时看的）：文件夹在不在、空不空、有没有标记、几台别的电脑、多少条便签。</summary>
    public static async Task<ServerInspection> InspectAsync(WebDav dav, string device)
    {
        var result = new ServerInspection();
        try
        {
            if (await dav.ListAsync(Array.Empty<string>()) is not { } top)
            {
                return result;
            }

            result.Exists = true;
            result.Empty = top.All(item => item.Name.StartsWith('.'));
            if (top.Any(item => !item.IsFolder && item.Name == NoteSyncFolder.MarkerName))
            {
                var data = await dav.GetAsync(new[] { NoteSyncFolder.MarkerName });
                if (data is not null && data.Length <= SmallBytes && NoteSyncFolder.MarkerFrom(data) is { } marker)
                {
                    result.Marker = marker;
                }
                else
                {
                    result.MarkerUnreadable = data is not null;
                }
            }

            if (!top.Any(item => item.IsFolder && item.Name == Devices))
            {
                return result;
            }

            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var other in await dav.ListAsync(new[] { Devices }) ?? new List<WebDavItem>())
            {
                if (!other.IsFolder || !IsDevice(other.Name) || other.Name == device)
                {
                    continue;
                }

                result.Devices++;
                foreach (var file in await dav.ListAsync(new[] { Devices, other.Name, NoteSyncFolder.NotesName }) ??
                                     new List<WebDavItem>())
                {
                    if (NoteSyncFolder.NoteId(file.Name) is { } id)
                    {
                        ids.Add(id);
                    }
                }
            }

            result.Notes = ids.Count;
        }
        catch (WebDavException ex)
        {
            result.Failure = ex.Failure;
        }

        return result;
    }

    /// <summary>这个文件夹能不能拿来同步：不能的话说为什么（话同 mac NoteSyncer.refusal）。</summary>
    public static string? Refusal(ServerInspection inspection)
    {
        if (inspection.MarkerUnreadable)
        {
            return "这个文件夹里的同步记录还没下载完（或者读不出来），稍后再试";
        }

        if (inspection.Marker is { } marker && marker.Format > NoteSyncFolder.Format)
        {
            return "这个文件夹是更新版本的 Kitty Tools 用的，先更新再同步";
        }

        if (inspection.Marker is null && inspection.Devices > 0)
        {
            return "这个文件夹里有别的电脑同步过的数据，却找不到同步记录（可能还没下载完），稍后再试";
        }

        // 没同步过的文件夹要是空的：不往放着别的东西的文件夹里撒子文件夹
        if (inspection.Marker is null && !inspection.Empty)
        {
            return "这个文件夹里已经有别的东西了，换一个空文件夹来同步";
        }

        return null;
    }

    /// <summary>
    /// 连接（照 mac NoteSyncer.enable(server:) 的前半）：服务器上没有这个文件夹的建好（连同上级）、拿不来同步的说为什么、没有标记的写一个
    /// （不覆盖：别的电脑刚写了一个就让用户再连一次）。有别的电脑在用要不要合在一起，由调用方先问（InspectAsync）。返回没连成的原因。
    /// </summary>
    public static async Task<string?> ConnectAsync(WebDav dav, string device)
    {
        var inspection = await InspectAsync(dav, device);
        if (inspection.Failure is { } failure)
        {
            return failure.Message;
        }

        if (!inspection.Exists)
        {
            try
            {
                await dav.MakeFoldersAsync();
            }
            catch (WebDavException ex)
            {
                return ex.Failure.Message;
            }

            inspection = new ServerInspection { Exists = true, Empty = true };
        }

        if (Refusal(inspection) is { } refusal)
        {
            return refusal;
        }

        if (inspection.Marker is null)
        {
            var library = Guid.NewGuid().ToString("D").ToUpperInvariant();
            try
            {
                await dav.PutAsync(
                    new[] { NoteSyncFolder.MarkerName },
                    System.Text.Encoding.UTF8.GetBytes(SyncFolderRules.Marker(library)),
                    ifAbsent: true);
            }
            catch (WebDavException ex) when (ex.Failure.Error == WebDavError.Exists)
            {
                return "这个文件夹里刚有别的电脑开始同步，再连接一次";
            }
            catch (WebDavException ex)
            {
                return ex.Failure.Message;
            }
        }

        return null;
    }

    /// <summary>设置里「测试连接」：连得上、账号对、文件夹在的话写一个点开头的小文件再删掉。</summary>
    public static async Task<(ServerTest Test, WebDavFailure? Failure)> TestAsync(WebDav dav)
    {
        try
        {
            if (await dav.ListAsync(Array.Empty<string>()) is null)
            {
                return (ServerTest.Missing, null);
            }

            var probe = new[] { $".kitty-test-{Guid.NewGuid():N}" };
            await dav.PutAsync(probe, System.Text.Encoding.UTF8.GetBytes("Kitty Tools"));
            await dav.DeleteAsync(probe);
            return (ServerTest.Ready, null);
        }
        catch (WebDavException ex)
        {
            return (ServerTest.Failed, ex.Failure);
        }
    }

    /// <summary>不用了的镜像（停止同步、换了服务器）：连同它的账整个删掉，keeping 那个（和它的账）留着。</summary>
    public static void RemoveMirrors(string parent, string? keeping)
    {
        var keep = keeping is null ? null : Path.GetFileName(Path.TrimEndingDirectorySeparator(keeping));
        try
        {
            if (!Directory.Exists(parent))
            {
                return;
            }

            foreach (var entry in Directory.EnumerateFileSystemEntries(parent).ToList())
            {
                var name = Path.GetFileName(entry);
                if (keep is not null && (name == keep || name == keep + ".json"))
                {
                    continue;
                }

                if (Directory.Exists(entry))
                {
                    Directory.Delete(entry, recursive: true);
                }
                else
                {
                    File.Delete(entry);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 删不掉的下次停止 / 连接时再删
        }
    }

    // ---- 镜像 ----

    /// <summary>镜像里认得的文件：真的、占位的（都按路径）。</summary>
    private static (HashSet<string> Files, HashSet<string> Placeholders) MirrorFiles(string mirror)
    {
        var files = new HashSet<string>(StringComparer.Ordinal);
        var placeholders = new HashSet<string>(StringComparer.Ordinal);
        List<string> Scan(string folder)
        {
            var names = new List<string>();
            var directory = folder.Length == 0 ? mirror : LocalPath(mirror, folder);
            try
            {
                if (!Directory.Exists(directory))
                {
                    return names;
                }

                foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
                {
                    var name = Path.GetFileName(entry);
                    names.Add(name);
                    var path = folder.Length == 0 ? name : folder + "/" + name;
                    if (!File.Exists(entry) || Known(path) is null)
                    {
                        continue;
                    }

                    if (SyncDisk.IsPlaceholder(entry))
                    {
                        placeholders.Add(path);
                    }
                    else
                    {
                        files.Add(path);
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 列不出来当没有：不传、不删（下一轮再看）
            }

            return names;
        }

        Scan(string.Empty);
        Scan(Images);
        foreach (var device in Scan(Devices))
        {
            if (IsDevice(device))
            {
                Scan(Devices + "/" + device);
                Scan(Devices + "/" + device + "/" + NoteSyncFolder.NotesName);
            }
        }

        return (files, placeholders);
    }

    /// <summary>镜像里这个文件的样子（W6）：不在、是占位都是 null。</summary>
    public static ServerLocal? LocalOf(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && !SyncDisk.IsPlaceholder(path) ? new ServerLocal(info.LastWriteTimeUtc.Ticks, info.Length) : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static bool IsHere(string path) => File.Exists(path) && !SyncDisk.IsPlaceholder(path);

    /// <summary>还没拿下来：放个占位（W1：空文件 + Offline，SyncDisk.IsPlaceholder 当成同步盘还没下载的那种）。</summary>
    private static void Mark(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (!File.Exists(path))
            {
                File.WriteAllBytes(path, Array.Empty<byte>());
            }

            File.SetAttributes(path, FileAttributes.Offline);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 放不上占位：那一版这一轮当没有（合并经得起）
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 删不掉下一轮再删
        }
    }

    /// <summary>拿下来的写进镜像：先写临时名再换掉（占位也一起换掉，属性跟着新文件走），改动时间设成服务器上的。</summary>
    private static void Save(byte[] data, string path, DateTimeOffset? modified)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, data);
        File.Move(temporary, path, overwrite: true);
        if (modified is { } time)
        {
            File.SetLastWriteTimeUtc(path, time.UtcDateTime);
        }
    }

    /// <summary>本机图片目录里有这张：拷进镜像（拷不成返回 false，照常去拿）。</summary>
    private static bool CopyLocal(string source, string path, DateTimeOffset? modified)
    {
        try
        {
            if (!File.Exists(source))
            {
                return false;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".tmp";
            File.Copy(source, temporary, overwrite: true);
            File.Move(temporary, path, overwrite: true);
            if (modified is { } time)
            {
                File.SetLastWriteTimeUtc(path, time.UtcDateTime);
            }

            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static ServerLedger ReadLedger(string path, string server)
    {
        try
        {
            if (File.Exists(path) &&
                System.Text.Json.JsonSerializer.Deserialize(File.ReadAllText(path), ServerLedgerJson.Default.ServerLedger) is { } ledger &&
                ledger.Server == server)
            {
                // 写坏了的项（null）扔掉：多拿一遍那几个
                ledger.Files = (ledger.Files ?? new()).Where(pair => pair.Value is not null)
                    .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
                return ledger;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            // 读不出来从头记：多拿一遍，不丢东西
        }

        return new ServerLedger { Server = server };
    }

    private static void WriteLedger(ServerLedger ledger, string path)
    {
        try
        {
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, System.Text.Json.JsonSerializer.Serialize(ledger, ServerLedgerJson.Default.ServerLedger));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 账没写成：下一轮按旧账多拿 / 多传一遍，不丢东西
        }
    }
}
