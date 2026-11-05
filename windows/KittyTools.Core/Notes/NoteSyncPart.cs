// 便签接进同步的执行层（PLAN-v13 第 3 批，照 mac Notes/NoteSyncer.swift 的一轮 + NoteSyncDisk.swift 的读写；合并规则和文件格式在
// NoteSync / NoteSyncFolder，一字不差地和 mac 互通）。SyncRunner 一轮里多一步「便签」，先后照 NoteSyncFolder 末尾那张清单：
// 1. 一轮开始前仓库落盘（Flush）；
// 2. 线程池上读文件夹的便签那部分（Read）：每台的 notes/*.md、erased.json、共用的 images/ 的文件名；云盘还没下载的占位文件、
//    超过大小的、解不出来的算「读不出来」（便签文件记进 Unreadable，墓碑文件 = Tombstones.Unreadable）；
// 3. 标记读不出来、自己的 device.json 有却读不出来：这一部分停（「还没下载完」）——认清文件夹之前不换编号、不合；
// 4. 认库被退回去了（NoteSyncFolder.Regressed，加上整个 device 的 epoch 被退回去时和自己那份不一样的几条）：先换编号（SwitchDevice：
//    那几条去掉旧编号那一格、记一笔新编号的改动，先落盘再记新编号），**要在写出去之前做**；
// 5. Round → Stop 就停；刹车（Trashing 超过上次点「继续」时的条数）就停下来问；
// 6. 正在编辑的先不换（Editing：拿着焦点的编辑器里的、挂着没确认组字的），也先不写出去；
// 7. Apply（仓库 ApplySync + 落盘）；没落下去就停、不写；
// 8. Publish 出写的计划（图片两头补齐、共用 images/ 里满期没人引用的删：账在便签库的 note_meta）；
// 9. 写（线程池上）：便签文件、要删的、erased.json、图片——都先写临时名再改名；device.json 由 SyncRunner 最后写；
// 10. 写成了的告诉仓库（Published）；拿下来的图告诉编辑器（ImagesArrived）。
// **只写自己的子文件夹**（notes/、erased.json）和共用的 images/（只加不改；删只删满期没人引用的，宁可少删），别的电脑的一个字节都不碰。
// 线程：委托回调都在调用方（UI）线程上；读写文件在线程池。
using System.Text;
using KittyTools.Core.Sync;

namespace KittyTools.Core.Notes;

/// <summary>仓库那一侧交给同步的几样（App 的 NoteStore 接上；单测接内存里的 NoteBook）。</summary>
public sealed class NoteSyncPart
{
    /// <summary>现在就落盘；返回成没成。</summary>
    public required Func<bool> Flush { get; init; }

    /// <summary>本机全部便签（含最近删除里的）。</summary>
    public required Func<IReadOnlyList<Note>> Notes { get; init; }

    /// <summary>本机的墓碑。</summary>
    public required Func<IReadOnlyDictionary<string, NoteSync.Tombstone>> Erased { get; init; }

    /// <summary>正在编辑的便签（这一轮先不换、不写出去）。</summary>
    public required Func<IReadOnlySet<string>> Editing { get; init; }

    /// <summary>认出库被退回去了：这几条换编号（旧编号、新编号），先落盘、成了再把电脑编号记成新的。返回成没成。</summary>
    public required Func<IReadOnlySet<string>, string, string, bool> SwitchDevice { get; init; }

    /// <summary>落合并结果（ApplySync + 落盘）；返回落没落下去。</summary>
    public required Func<IReadOnlyDictionary<string, NoteSync.Merge>, IReadOnlyDictionary<string, NoteSync.Tombstone>, bool> Apply { get; init; }

    /// <summary>这几条写进同步文件夹了。</summary>
    public Action<IReadOnlyCollection<string>>? Published { get; init; }

    /// <summary>这几张图从同步文件夹拿下来了。</summary>
    public Action<IReadOnlySet<Guid>>? ImagesArrived { get; init; }

    /// <summary>本机的图片目录（notes-images）；null = 图片不两头补齐、共用的不删。</summary>
    public string? ImagesDirectory { get; init; }

    /// <summary>共用 images/ 没人引用的那本账（便签库 note_meta 里 NoteSyncFolder.ImageLedgerKey 那一项）：读、写。读不出来抛错。</summary>
    public Func<string?>? ReadLedger { get; init; }

    public Action<string>? WriteLedger { get; init; }

    /// <summary>便签文件头里的时间按哪个时区写（只给人看，合并不看它）。</summary>
    public TimeZoneInfo Zone { get; init; } = TimeZoneInfo.Local;
}

/// <summary>一轮里便签那部分读到的样子。</summary>
public sealed class NoteSyncSnapshot
{
    public NoteSyncFolder.Folder Folder { get; } = new();

    /// <summary>有占位文件（还没下载完的）、列不出来的目录：这一轮共用的图一张不删。</summary>
    public bool Pending { get; set; }

    /// <summary>标记文件有、却读不出来。</summary>
    public bool MarkerUnreadable { get; set; }
}

public static class NoteSyncDisk
{
    private const int MaxErasedBytes = 32 << 20;

    private static string NotesFolder(string device) => Path.Combine(NoteSyncFolder.DevicesName, device, NoteSyncFolder.NotesName);

    private static string ErasedPath(string device) => Path.Combine(NoteSyncFolder.DevicesName, device, NoteSyncFolder.ErasedName);

    /// <summary>读一个文件的字节：不在、占位文件、超过 limit、读不了都给 null；pending 记下是不是占位文件。</summary>
    private static byte[]? Bytes(string path, long limit, ref bool pending)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            if (SyncDisk.IsPlaceholder(path))
            {
                pending = true;
                return null;
            }

            return new FileInfo(path).Length > limit ? null : File.ReadAllBytes(path);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>线程池上读：标记、这几台的便签 / 墓碑、images/ 的文件名。</summary>
    public static NoteSyncSnapshot Read(SyncDisk disk, IEnumerable<string> devices)
    {
        var snapshot = new NoteSyncSnapshot();
        var pending = false;
        var markerPath = Path.Combine(disk.Root, NoteSyncFolder.MarkerName);
        if (Bytes(markerPath, 1 << 20, ref pending) is { } marker)
        {
            snapshot.Folder.Marker = NoteSyncFolder.MarkerFrom(marker);
            snapshot.MarkerUnreadable = snapshot.Folder.Marker is null;
        }
        else if (File.Exists(markerPath))
        {
            snapshot.MarkerUnreadable = true;
        }

        foreach (var id in devices)
        {
            var device = new NoteSyncFolder.Device();
            var erasedPath = Path.Combine(disk.Root, ErasedPath(id));
            if (File.Exists(erasedPath))
            {
                device.Erased = Bytes(erasedPath, MaxErasedBytes, ref pending) is { } erased
                    ? NoteSyncFolder.TombstonesFrom(erased)
                    : NoteSyncFolder.Tombstones.Unreadable;
            }

            var folder = Path.Combine(disk.Root, NotesFolder(id));
            try
            {
                if (Directory.Exists(folder))
                {
                    foreach (var path in Directory.EnumerateFiles(folder))
                    {
                        var name = Path.GetFileName(path);
                        if (NoteSyncFolder.NoteId(name) is not { } noteId)
                        {
                            continue;
                        }

                        var text = Bytes(path, NoteSyncFolder.MaxNoteFileBytes, ref pending) is { } bytes
                            ? NoteFileHeader.Decode(bytes)
                            : null;
                        if (text is not null && NoteSyncFolder.Parse(text, noteId) is { } parsed)
                        {
                            device.Notes[noteId] = parsed.Note;
                            device.Hashes[noteId] = parsed.Hash;
                        }
                        else
                        {
                            device.Unreadable.Add(noteId);
                        }
                    }
                }
            }
            catch
            {
                pending = true;
            }

            snapshot.Folder.Devices[id] = device;
        }

        try
        {
            var images = Path.Combine(disk.Root, NoteSyncFolder.ImagesName);
            if (Directory.Exists(images))
            {
                foreach (var path in Directory.EnumerateFiles(images))
                {
                    var name = Path.GetFileName(path);
                    if (NoteSyncFolder.ImageId(name) is not null)
                    {
                        snapshot.Folder.Images.Add(name);
                    }
                }
            }
        }
        catch
        {
            pending = true;
        }

        snapshot.Pending = pending;
        return snapshot;
    }

    /// <summary>本机图片目录里的文件名（认得出来的）。</summary>
    public static HashSet<string> LocalImages(string? directory)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            if (directory is not null && Directory.Exists(directory))
            {
                foreach (var path in Directory.EnumerateFiles(directory))
                {
                    var name = Path.GetFileName(path);
                    if (NoteImageRules.Identifier(name) is not null)
                    {
                        names.Add(name);
                    }
                }
            }
        }
        catch
        {
            // 列不出来当没有：不传、不删
        }

        return names;
    }

    /// <summary>线程池上写这一轮的计划；返回写成了的便签编号、拿下来的图、删成了的共用图。哪一步没成整个算没成（Ok = false），已经写成的照留。</summary>
    public static (bool Ok, List<string> Written, HashSet<Guid> Downloaded, List<string> Purged) Write(
        SyncDisk disk, string me, NoteSyncFolder.PublishPlan plan, string? imagesDirectory, TimeZoneInfo zone)
    {
        var written = new List<string>();
        var downloaded = new HashSet<Guid>();
        var purged = new List<string>();
        var ok = true;
        foreach (var note in plan.Writes)
        {
            if (disk.WriteText(Path.Combine(NotesFolder(me), NoteSyncFolder.FileName(note.Id)), NoteSyncFolder.Text(note, zone)))
            {
                written.Add(note.Id);
            }
            else
            {
                ok = false;
            }
        }

        foreach (var id in plan.Deletes)
        {
            try
            {
                File.Delete(Path.Combine(disk.Root, NotesFolder(me), NoteSyncFolder.FileName(id)));
            }
            catch
            {
                ok = false;
            }
        }

        if (plan.Erased is { } erased)
        {
            ok &= WriteBytes(Path.Combine(disk.Root, ErasedPath(me)), NoteSyncFolder.ErasedData(erased));
        }

        if (imagesDirectory is not null)
        {
            var shared = Path.Combine(disk.Root, NoteSyncFolder.ImagesName);
            foreach (var image in plan.Uploads)
            {
                ok &= CopyIn(Path.Combine(imagesDirectory, image.FileName), Path.Combine(shared, image.FileName));
            }

            foreach (var image in plan.Downloads)
            {
                // 还没下载下来的（占位）、读完之后又没了的、比一张图的上限还大的：这一轮跳过，不算没写成（同 mac：只拿「在这儿」的）
                var source = Path.Combine(shared, image.FileName);
                if (!IsHere(source))
                {
                    continue;
                }

                if (CopyIn(source, Path.Combine(imagesDirectory, image.FileName)))
                {
                    downloaded.Add(image.Id);
                }
                else
                {
                    ok = false;
                }
            }

            foreach (var name in plan.ImageDeletes)
            {
                try
                {
                    File.Delete(Path.Combine(shared, name));
                    purged.Add(name);
                }
                catch
                {
                    // 删不成只少删一张，不算这一轮没成
                }
            }
        }

        return (ok, written, downloaded, purged);
    }

    private static bool WriteBytes(string path, byte[] bytes)
    {
        var temporary = path + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>共用文件夹里的这张图真在这儿：是文件、不是云盘占位、不超过一张图的上限。</summary>
    private static bool IsHere(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists && !SyncDisk.IsPlaceholder(path) && info.Length <= NoteImageRules.MaxFileBytes;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>拷一张图：目标已经有了就不动（同名就是同一张）；先拷成临时名再改名（传到一半的那份不能被当成「已经有了」）。</summary>
    private static bool CopyIn(string from, string to)
    {
        try
        {
            if (File.Exists(to))
            {
                return true;
            }

            if (!File.Exists(from) || SyncDisk.IsPlaceholder(from))
            {
                return false;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(to)!);
            var temporary = to + ".tmp";
            File.Copy(from, temporary, overwrite: true);
            File.Move(temporary, to, overwrite: false);
            return true;
        }
        catch
        {
            return File.Exists(to);
        }
    }

    /// <summary>便签那部分的指纹（加进 SyncDisk.Fingerprint 那一份：没变就不用整轮跑）：每台的 notes/ 和 erased.json、images/ 的名字、时刻、大小。</summary>
    public static void AddFingerprint(SyncDisk disk, StringBuilder builder, IEnumerable<string> devices)
    {
        void Entry(string path)
        {
            var info = new FileInfo(path);
            builder.Append(Path.GetRelativePath(disk.Root, path)).Append('=')
                .Append(info.Exists ? $"{info.LastWriteTimeUtc.Ticks}:{info.Length}" : "-").Append('\n');
        }

        void Folder(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    foreach (var file in Directory.EnumerateFiles(path).Order(StringComparer.Ordinal))
                    {
                        Entry(file);
                    }
                }
            }
            catch
            {
                builder.Append(path).Append("=?\n");
            }
        }

        foreach (var device in devices.Order(StringComparer.Ordinal))
        {
            Entry(Path.Combine(disk.Root, ErasedPath(device)));
            Folder(Path.Combine(disk.Root, NotesFolder(device)));
        }

        Folder(Path.Combine(disk.Root, NoteSyncFolder.ImagesName));
    }
}
