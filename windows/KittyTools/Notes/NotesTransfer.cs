// 便签的 Markdown 导出 / 导入（PLAN-v13 第 7 批，照 mac Notes/NoteMarkdownFiles.swift 的读写那一半 + Settings/NotesTab.swift 的两个按钮；
// 纯函数——文件名、文件头、三种换法、读文件的解码、导入完怎么说——在 Core 的 NoteMarkdownFiles，单测在 NoteMarkdownFilesTests）：
// - 导出全部（设置 › 便签「导出…」）：选一个文件夹，在里面**新建**「Kitty Tools 便签 日期」（重名加「 2」「 3」，绝不往已有的文件夹里混写），
//   没删的便签每条一个 .md，图片从 notes-images\ 原样拷进旁边的 attachments\（同一张只拷一份）。写坏一个文件就停，已经写出去的留着。
// - 单条导出（操作菜单 / 右键的「导出为 Markdown…」）：存一个 .md，图片拷进同一个文件夹的 attachments\（已经有了跳过、不覆盖）。
//   全文和整个文件夹导出时一字不差（同一份 FileText）。
// - 导入（「导入…」：选文件，或者选一个文件夹读第一层的 .md / .markdown）：自家文件按编号合并（仓库的 Adopt：改得更晚的才换），在别处改过
//   正文的（文件头的正文哈希对不上）只取内容；别处的文件每个变一条新便签。图片路径相对那个 .md 的文件夹，必须还在那个文件夹里
//   （不跟符号链接、不联网）。一次最多 2000 个文件，单个超过 4 MB、不是 UTF-8、换完超过一条便签上限的跳过。
// 读写文件、拷图片、存图片都在线程池上（文件夹可能在网络盘上）；合并进仓库、提示在 UI 线程。
// Windows 的选择框不能同时选文件和文件夹（mac 能），所以「导入…」是一个两项的小菜单：选择文件… / 选择文件夹…。
using System.Text;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace KittyTools;

internal static class NotesTransfer
{
    private static bool _busy;

    private sealed record ExportResult(string? Folder, int Count, int MissingImages, string? Failure);

    private sealed record SingleResult(int Images, int MissingImages, string? Failure);

    private enum CopyResult
    {
        Copied,
        AlreadyThere,
        Missing,
    }

    // ---- 导出全部 ----

    /// <summary>设置 › 便签「导出…」。</summary>
    public static async Task ExportAllAsync(Window owner)
    {
        if (NoteStore.Instance is not { } store || _busy)
        {
            return;
        }

        _busy = true;
        try
        {
            var picker = new FolderPicker(owner.AppWindow.Id);
            var picked = await picker.PickSingleFolderAsync();
            if (picked is null || string.IsNullOrEmpty(picked.Path))
            {
                return;
            }

            // 先把攒着的改动落下去再取（导出的是现在的样子）
            store.Flush();
            var notes = store.Book.Active.Concat(store.Book.Archived).ToList();
            var images = store.Images?.Directory;
            var parent = picked.Path;
            var today = DateTime.Now.Date;
            var zone = TimeZoneInfo.Local;
            var result = await Task.Run(() => Export(notes, images, parent, today, zone));
            if (result.Failure is { } failure)
            {
                NoticeHost.Show(result.Count > 0 ? "导出到一半" : "导出没成", failure, NoticeTone.Error);
                return;
            }

            var detail = $"「{Path.GetFileName(result.Folder)}」";
            if (result.MissingImages > 0)
            {
                detail += $" · {result.MissingImages} 张图片不在，没导出";
            }

            NoticeHost.Show($"已导出 {result.Count} 条便签", detail, NoticeTone.Normal, NoticeActions.Reveal(result.Folder!));
        }
        catch (Exception ex)
        {
            Log.Error("notes.export-failed", ex);
            NoticeHost.Show("导出没成", ex.GetType().Name, NoticeTone.Error);
        }
        finally
        {
            _busy = false;
        }
    }

    private static ExportResult Export(List<Note> notes, string? imageDirectory, string parent, DateTime day, TimeZoneInfo zone)
    {
        string? folder = null;
        try
        {
            foreach (var name in NoteMarkdownFiles.FolderNames(day))
            {
                var path = Path.Combine(parent, name);
                if (!Directory.Exists(path) && !File.Exists(path))
                {
                    Directory.CreateDirectory(path);
                    folder = path;
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            return new ExportResult(null, 0, 0, $"没能新建导出文件夹（{ex.GetType().Name}）");
        }

        if (folder is null)
        {
            return new ExportResult(null, 0, 0, "没能新建导出文件夹");
        }

        var names = NoteMarkdownFiles.FileNames(notes);
        var attachments = Path.Combine(folder, NoteMarkdownFiles.AttachmentsName);
        var copied = new HashSet<string>(StringComparer.Ordinal);
        var count = 0;
        var missing = 0;
        for (var index = 0; index < notes.Count; index++)
        {
            var (text, images) = NoteMarkdownFiles.FileText(notes[index], zone);
            try
            {
                File.WriteAllText(Path.Combine(folder, names[index] + ".md"), text, new UTF8Encoding(false));
                count++;
            }
            catch (Exception ex)
            {
                return new ExportResult(folder, count, missing, $"「{names[index]}.md」写不进去（{ex.GetType().Name}）");
            }

            foreach (var image in images)
            {
                if (imageDirectory is null)
                {
                    missing++;
                }
                else if (copied.Add(Key(image)) && Copy(image, imageDirectory, attachments) == CopyResult.Missing)
                {
                    missing++;
                }
            }
        }

        return new ExportResult(folder, count, missing, null);
    }

    private static string Key(NoteImages.Image image) => $"{NoteImages.IdText(image.Id)}.{image.Ext}";

    /// <summary>把一张图从图片目录拷进 attachments\（已经有了就跳过，绝不覆盖；有图要拷时才建 attachments\）。</summary>
    private static CopyResult Copy(NoteImages.Image image, string imageDirectory, string attachments)
    {
        var source = Path.Combine(imageDirectory, Key(image));
        if (!File.Exists(source))
        {
            return CopyResult.Missing;
        }

        var destination = Path.Combine(attachments, Key(image));
        if (File.Exists(destination))
        {
            return CopyResult.AlreadyThere;
        }

        try
        {
            Directory.CreateDirectory(attachments);
            File.Copy(source, destination, overwrite: false);
            return CopyResult.Copied;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.export-image-failed {ex.GetType().Name}");
            return CopyResult.Missing;
        }
    }

    // ---- 单条导出 ----

    /// <summary>「导出为 Markdown…」（打开的便签的操作菜单、全部便签窗口的右键）：选好之后在后台写，写完说一句。</summary>
    public static async Task ExportOneAsync(string id, XamlRoot? root)
    {
        if (NoteStore.Instance is not { } store || store.Book.Find(id) is not { } note)
        {
            return;
        }

        try
        {
            var owner = root?.ContentIslandEnvironment?.AppWindowId ?? default;
            var picker = new FileSavePicker(owner)
            {
                SuggestedFileName = NoteMarkdownFiles.FileName(note),
                DefaultFileExtension = ".md",
            };
            picker.FileTypeChoices.Add("Markdown", new List<string> { ".md" });
            var picked = await picker.PickSaveFileAsync();
            if (picked is null || string.IsNullOrEmpty(picked.Path))
            {
                return;
            }

            store.Flush();
            note = store.Book.Find(id) ?? note;
            var path = picked.Path;
            var images = store.Images?.Directory;
            var zone = TimeZoneInfo.Local;
            var result = await Task.Run(() => ExportOne(note, images, path, zone));
            var name = Path.GetFileName(path);
            if (result.Failure is { } failure)
            {
                NoticeHost.Show("导出没成", failure, NoticeTone.Error);
                return;
            }

            var parts = new List<string>();
            if (result.Images > 0)
            {
                parts.Add($"{result.Images} 张图片在旁边的 attachments 文件夹");
            }

            if (result.MissingImages > 0)
            {
                parts.Add($"{result.MissingImages} 张图片不在，没导出");
            }

            NoticeHost.Show($"已导出「{name}」", string.Join(" · ", parts), NoticeTone.Normal, NoticeActions.Reveal(path));
        }
        catch (Exception ex)
        {
            Log.Error("notes.export-one-failed", ex);
            NoticeHost.Show("导出没成", ex.GetType().Name, NoticeTone.Error);
        }
    }

    private static SingleResult ExportOne(Note note, string? imageDirectory, string path, TimeZoneInfo zone)
    {
        var (text, images) = NoteMarkdownFiles.FileText(note, zone);
        try
        {
            var temporary = path + ".kitty-tmp";
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception ex)
        {
            return new SingleResult(0, 0, $"「{Path.GetFileName(path)}」写不进去（{ex.GetType().Name}）");
        }

        if (imageDirectory is null)
        {
            return new SingleResult(0, images.Select(Key).Distinct().Count(), null);
        }

        var attachments = Path.Combine(Path.GetDirectoryName(path) ?? string.Empty, NoteMarkdownFiles.AttachmentsName);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var exported = 0;
        var missing = 0;
        foreach (var image in images)
        {
            if (!seen.Add(Key(image)))
            {
                continue;
            }

            if (Copy(image, imageDirectory, attachments) == CopyResult.Missing)
            {
                missing++;
            }
            else
            {
                exported++;
            }
        }

        return new SingleResult(exported, missing, null);
    }

    // ---- 导入 ----

    /// <summary>设置 › 便签「导入…」的小菜单：选择文件… / 选择文件夹…</summary>
    public static MenuFlyout ImportMenu(Window owner)
    {
        var menu = new MenuFlyout();
        var files = new MenuFlyoutItem { Text = "选择文件…" };
        files.Click += (_, _) => _ = ImportAsync(owner, folder: false);
        var folder = new MenuFlyoutItem { Text = "选择文件夹…" };
        folder.Click += (_, _) => _ = ImportAsync(owner, folder: true);
        menu.Items.Add(files);
        menu.Items.Add(folder);
        return menu;
    }

    private static async Task ImportAsync(Window owner, bool folder)
    {
        if (NoteStore.Instance is not { } store || _busy)
        {
            return;
        }

        _busy = true;
        try
        {
            var sources = new List<(string Path, string Root)>();
            if (folder)
            {
                var picker = new FolderPicker(owner.AppWindow.Id);
                var picked = await picker.PickSingleFolderAsync();
                if (picked is null || string.IsNullOrEmpty(picked.Path))
                {
                    return;
                }

                var root = picked.Path;
                sources.AddRange(await Task.Run(() => MarkdownFiles(root).Select(path => (path, root)).ToList()));
            }
            else
            {
                var picker = new FileOpenPicker(owner.AppWindow.Id);
                foreach (var extension in new[] { ".md", ".markdown", ".txt" })
                {
                    picker.FileTypeFilter.Add(extension);
                }

                var picked = await picker.PickMultipleFilesAsync();
                if (picked is null || picked.Count == 0)
                {
                    return;
                }

                foreach (var file in picked)
                {
                    if (!string.IsNullOrEmpty(file.Path))
                    {
                        sources.Add((file.Path, Path.GetDirectoryName(file.Path) ?? string.Empty));
                    }
                }
            }

            var images = store.Images?.Directory;
            var now = NoteStore.Now;
            var result = await Task.Run(() => ImportFilesAsync(sources, images, now));
            // 读出来的都是没删的：和设置导出文件同一个换法（自定义纸色拆成预设 + 色值）；在别处改过的那几条只取内容
            var entries = result.Notes.Select(NoteEntry.From).OfType<NoteEntry>().ToList();
            var (added, updated, saved) = entries.Count == 0 ? (0, 0, true) : store.Adopt(entries, result.EditedElsewhere);
            var (title, detail, warning) = NoteMarkdownFiles.ImportMessage(sources.Count, result, added, updated);
            if (!saved)
            {
                NoticeHost.Show("便签没存上", "导入的内容在内存里，稍后会自动再试", NoticeTone.Warning);
            }
            else
            {
                NoticeHost.Show(title, detail ?? string.Empty, warning ? NoticeTone.Warning : NoticeTone.Normal);
            }

            Log.Info($"notes.imported files={sources.Count} added={added} updated={updated} skipped={result.Skipped}");
        }
        catch (Exception ex)
        {
            Log.Error("notes.import-failed", ex);
            NoticeHost.Show("没有导入", ex.GetType().Name, NoticeTone.Error);
        }
        finally
        {
            _busy = false;
        }
    }

    /// <summary>文件夹第一层的 .md / .markdown（跳过隐藏文件、不进子文件夹），按文件名排。</summary>
    private static List<string> MarkdownFiles(string folder)
    {
        try
        {
            return Directory.EnumerateFiles(folder)
                .Where(path =>
                {
                    var name = Path.GetFileName(path);
                    var extension = Path.GetExtension(path).ToLowerInvariant();
                    return !name.StartsWith('.') && extension is ".md" or ".markdown";
                })
                .OrderBy(path => Path.GetFileName(path), StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.import-list-failed {ex.GetType().Name}");
            return new List<string>();
        }
    }

    /// <summary>读文件、换成便签（线程池上）。自家的头按编号、别处的每个一条新便签。</summary>
    // ponytail: 按文件名排序用当前区域的不区分大小写比较，不是 mac 的「自然顺序」（文件 2 排在文件 10 前面）；只影响超过 2000 个时截掉哪些、
    // 别处文件的先后。
    private static async Task<NoteMarkdownFiles.ImportResult> ImportFilesAsync(
        List<(string Path, string Root)> sources, string? imageDirectory, long now)
    {
        var result = new NoteMarkdownFiles.ImportResult { LimitHit = sources.Count > NoteMarkdownFiles.MaxFiles };
        var files = sources.OrderBy(source => Path.GetFileName(source.Path), StringComparer.CurrentCultureIgnoreCase)
            .Take(NoteMarkdownFiles.MaxFiles).ToList();
        result.Add(NoteMarkdownFiles.Skip.OverLimit, Math.Max(0, sources.Count - NoteMarkdownFiles.MaxFiles));
        for (var index = 0; index < files.Count; index++)
        {
            var (path, root) = files[index];
            long size;
            long fileModified;
            byte[] data;
            try
            {
                var info = new FileInfo(path);
                size = info.Length;
                fileModified = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds();
                if (size > NoteMarkdownFiles.MaxFileBytes)
                {
                    result.Add(NoteMarkdownFiles.Skip.TooLarge);
                    continue;
                }

                data = await File.ReadAllBytesAsync(path);
            }
            catch (Exception)
            {
                result.Add(NoteMarkdownFiles.Skip.Unreadable);
                continue;
            }

            if (NoteMarkdownFiles.Decode(data) is not { } raw)
            {
                result.Add(NoteMarkdownFiles.Skip.NotText);
                continue;
            }

            // 同步文件夹里的文件：读不全它的删除时刻、正文也不是 Markdown，跳过
            if (NoteSyncFolder.IsSyncFile(raw))
            {
                result.Add(NoteMarkdownFiles.Skip.SyncFile);
                continue;
            }

            if (NoteMarkdownFiles.ParseHeader(raw, fileModified) is { } header)
            {
                var (_, body) = NoteMarkdownFiles.BodyFromMarkdown(header.Text);
                var (converted, failures) = await ConvertAsync(body, root, imageDirectory);
                result.MissingImages += failures;
                if (Encoding.UTF8.GetByteCount(converted) > Note.MaxBodyBytes)
                {
                    result.Add(NoteMarkdownFiles.Skip.TooLong);
                    continue;
                }

                result.Notes.Add(NoteMarkdownFiles.OwnNote(header, converted, fileModified, now, out var edited));
                if (edited)
                {
                    result.EditedElsewhere.Add(header.Id);
                }
            }
            else
            {
                var (prefix, body) = NoteMarkdownFiles.BodyFromMarkdown(raw, NoteMarkdownFiles.ForeignHeaderEnd(raw));
                var (converted, failures) = await ConvertAsync(body, root, imageDirectory);
                result.MissingImages += failures;
                if (Encoding.UTF8.GetByteCount(converted) > Note.MaxBodyBytes)
                {
                    result.Add(NoteMarkdownFiles.Skip.TooLong);
                    continue;
                }

                result.Notes.Add(NoteMarkdownFiles.ForeignNote(
                    prefix + converted, Path.GetFileNameWithoutExtension(path), index, fileModified, now, NoteBook.NewId()));
            }
        }

        return result;
    }

    /// <summary>正文里的 Markdown 图片换成令牌（没有图片目录时原样留着、不算失败，同 mac）。</summary>
    private static Task<(string Body, int Failures)> ConvertAsync(string body, string root, string? imageDirectory)
        => imageDirectory is null || !body.Contains("![", StringComparison.Ordinal)
            ? Task.FromResult((body, 0))
            : NoteMarkdownFiles.ConvertImagesAsync(body, image => StoreAsync(image, root, imageDirectory));

    private static bool SameBytes(byte[] a, byte[] b) => a.AsSpan().SequenceEqual(b);

    /// <summary>一张图 → 令牌：认得出是仓库里已有的那张、字节也一样就沿用编号；否则存一份新的。路径不合法、不在、存不进去给 null。</summary>
    private static async Task<string?> StoreAsync(NoteMarkdownFiles.MarkdownImage image, string root, string directory)
    {
        if (ImagePath(image.Path, root) is not { } path)
        {
            return null;
        }

        try
        {
            if (NoteImageRules.Identifier(Path.GetFileName(path)) is { } id)
            {
                var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
                var existing = Path.Combine(directory, $"{NoteImages.IdText(id)}.{ext}");
                if (File.Exists(existing) && new FileInfo(existing).Length == new FileInfo(path).Length
                    && SameBytes(await File.ReadAllBytesAsync(existing), await File.ReadAllBytesAsync(path)))
                {
                    return NoteImages.Token(new NoteImages.Image(id, ext, image.Width));
                }
            }

            var stored = await NoteImageStore.StoreFileAsync(path, directory);
            return stored.Stored is { } value ? NoteImages.Token(new NoteImages.Image(value.Image.Id, value.Image.Ext, image.Width)) : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.import-image-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>图片路径（相对那个 .md 的文件夹）→ 文件的完整路径；绝对路径、网址、跑出文件夹的、不是普通文件的、符号链接给 null。</summary>
    // ponytail: 只看最后那个文件是不是符号链接，不逐级查路径上的目录联接（mac 是整条路径解析完再比）；要更严再逐级 ResolveLinkTarget。
    private static string? ImagePath(string raw, string root)
    {
        string decoded;
        try
        {
            decoded = Uri.UnescapeDataString(raw);
        }
        catch (UriFormatException)
        {
            decoded = raw;
        }

        var lower = decoded.ToLowerInvariant();
        if (decoded.Length == 0 || decoded[0] is '/' or '\\' or '~' || Path.IsPathRooted(decoded)
            || lower.StartsWith("http://", StringComparison.Ordinal) || lower.StartsWith("https://", StringComparison.Ordinal)
            || lower.StartsWith("file:", StringComparison.Ordinal) || decoded.Contains(':'))
        {
            return null;
        }

        try
        {
            var bas = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var full = Path.GetFullPath(Path.Combine(bas, decoded));
            if (!full.StartsWith(bas, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            var info = new FileInfo(full);
            return info.Exists && info.LinkTarget is null ? full : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
