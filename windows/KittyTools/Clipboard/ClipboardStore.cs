// 剪贴板历史：内存列表（复制时间新→旧）+ clips 表。所有改动先改列表，再写库。
// 同样内容再复制 = 把原条目挪到最前（保留 id 和收藏）；删除可以 Ctrl+Z 撤销，面板收起时才真的删库。
// 保留天数和图片上限在启动时、每次收起面板时、每次入库后执行。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

/// <summary>剪贴板面板的范围（第三版 §4）。</summary>
internal enum ClipScope
{
    All,
    Favorites,
    Snippets,
}

internal sealed class ClipboardStore
{
    private readonly Database _database;
    private readonly List<ClipEntry> _items = new();
    private readonly List<List<ClipEntry>> _undo = new();

    public ClipboardStore(Database database, ImageStore images)
    {
        _database = database;
        Images = images;
    }

    public event Action? Changed;

    public IReadOnlyList<ClipEntry> Items => _items;

    public ImageStore Images { get; }

    public int Count => _items.Count;

    public void Load()
    {
        _items.Clear();
        _items.AddRange(_database.LoadClips());
        Groups = _database.LoadGroups();
        Images.CleanupOrphans(_items.Select(item => item.Id).ToHashSet());
    }

    /// <summary>收藏夹（按位置）。</summary>
    public IReadOnlyList<ClipGroup> Groups { get; private set; } = Array.Empty<ClipGroup>();

    /// <summary>收藏 / 片段 / 收藏夹一定带 uid；公开给同步用（没有就补一个）。</summary>
    public void EnsureUid(ClipEntry entry)
    {
        if (!string.IsNullOrEmpty(entry.Uid))
        {
            return;
        }

        entry.Uid = Guid.NewGuid().ToString("D").ToUpperInvariant();
        _database.SetUid(entry.Id, entry.Uid);
    }

    /// <summary>同步用：按 uid 找一条（正文跟着同步来的走）；没有就找同样正文、还没留着的普通条目接过来；再没有就新建。
    /// 已经留着（收藏 / 片段 / 收藏夹）的另一条不抢它的 uid：抢了那条的 uid 就从本机消失，下一轮成了删除，
    /// 和 mac「编号小的留下」挑的不一样时两条都会被删光。</summary>
    public ClipEntry EnsureClip(string uid, string text)
    {
        var existing = _items.FirstOrDefault(item => item.Uid == uid) ??
                       _items.FirstOrDefault(item => item.Kind == ClipKind.Text &&
                                                     (item.Uid is null || !IsRetained(item)) &&
                                                     string.Equals(item.Text, text, StringComparison.Ordinal));
        if (existing is not null)
        {
            if (existing.Uid != uid)
            {
                existing.Uid = uid;
                _database.SetUid(existing.Id, uid);
            }

            if (!string.Equals(existing.Text, text, StringComparison.Ordinal))
            {
                existing.Text = text;
                _database.SetText(existing.Id, text);
            }

            return existing;
        }

        var entry = new ClipEntry
        {
            Kind = ClipKind.Text,
            Text = text,
            Uid = uid,
            Favorite = true,
            CopiedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
        entry.Id = _database.Insert(entry);
        _items.Insert(0, entry);
        Changed?.Invoke();
        return entry;
    }

    /// <summary>同步落地：收藏、片段、备注、收藏夹一起写（收藏夹编号可能来自别的电脑）。</summary>
    public void ApplySynced(long id, bool favorite, bool snippet, string? note, string? groupId)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        // 照 mac：在收藏夹里的就是收藏；备注原样存（改成 null 的话编回去和同步来的那版对不上，两台来回改）。
        entry.Favorite = favorite || groupId is not null;
        entry.Snippet = snippet;
        entry.Note = note;
        entry.GroupId = groupId;
        entry.Folded = null;
        _database.SetFavorite(id, entry.Favorite);
        _database.SetSnippet(id, snippet);
        _database.SetNote(id, entry.Note);
        _database.SetGroup(id, entry.GroupId);
        Changed?.Invoke();
    }

    /// <summary>同步落地收藏夹（照 mac applySync）：整张表换成 groups（已按顺序排好）；同名的编号小的留下，
    /// 另一个的条目归过去；被删的收藏夹还有同名的，条目也归过去。返回「条目的收藏夹编号 → 落地后归进哪个」。</summary>
    public Func<string?, string?> ReplaceSyncedGroups(IReadOnlyList<ClipGroup> groups)
    {
        var remap = new Dictionary<string, string>(StringComparer.Ordinal);
        var final = new List<ClipGroup>();
        foreach (var same in groups.GroupBy(group => group.Name, StringComparer.Ordinal))
        {
            var winner = same.MinBy(group => group.Id, StringComparer.Ordinal)!;
            foreach (var loser in same.Where(group => group.Id != winner.Id))
            {
                remap[loser.Id] = winner.Id;
            }
        }

        foreach (var group in groups.Where(group => !remap.ContainsKey(group.Id)))
        {
            final.Add(new ClipGroup
            {
                Id = group.Id, Name = group.Name, Position = final.Count, CreatedAt = group.CreatedAt,
            });
        }

        var ids = final.Select(group => group.Id).ToHashSet(StringComparer.Ordinal);
        foreach (var old in Groups.Where(group => !ids.Contains(group.Id) && !remap.ContainsKey(group.Id)))
        {
            if (final.FirstOrDefault(group => group.Name == old.Name) is { } same)
            {
                remap[old.Id] = same.Id;
            }
        }

        string? Resolve(string? id)
        {
            if (id is null)
            {
                return null;
            }

            var target = remap.TryGetValue(id, out var mapped) ? mapped : id;
            return ids.Contains(target) ? target : null;
        }

        _database.ReplaceGroups(final);
        foreach (var entry in _items.Where(item => item.GroupId is not null && !ids.Contains(item.GroupId)))
        {
            entry.GroupId = Resolve(entry.GroupId);
            _database.SetGroup(entry.Id, entry.GroupId);
        }

        Groups = _database.LoadGroups();
        Changed?.Invoke();
        return Resolve;
    }

    private static bool IsRetained(ClipEntry entry) => entry.Favorite || entry.Snippet || entry.GroupId is not null;

    /// <summary>同步：别处不再保留的条目只取消收藏、移出片段和收藏夹，不删行。</summary>
    public void UnfavoriteMissing(HashSet<string> keepUids)
    {
        foreach (var entry in _items.Where(item =>
                     IsRetained(item) && item.Uid is not null && !keepUids.Contains(item.Uid) &&
                     // 带 NUL 的本来就不同步（SyncSources.ClipRecords），不在文件里不等于别处不要了。
                     item.Text?.Contains('\0') != true && item.Note?.Contains('\0') != true))
        {
            entry.Favorite = false;
            entry.Snippet = false;
            entry.GroupId = null;
            _database.SetFavorite(entry.Id, false);
            _database.SetSnippet(entry.Id, false);
            _database.SetGroup(entry.Id, null);
        }

        Changed?.Invoke();
    }

    public void ToggleSnippet(long id)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        entry.Snippet = !entry.Snippet;
        if (entry.Snippet)
        {
            entry.Favorite = true;
            _database.SetFavorite(id, true);
            EnsureUid(entry);
        }

        _database.SetSnippet(id, entry.Snippet);
        Changed?.Invoke();
    }

    public void SetNote(long id, string? note)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        entry.Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        entry.Folded = null;
        _database.SetNote(id, entry.Note);
        Changed?.Invoke();
    }

    public void MoveToGroup(long id, string? groupId)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        entry.GroupId = groupId;
        if (groupId is not null)
        {
            entry.Favorite = true;
            entry.Snippet = false;
            _database.SetSnippet(id, false);
            EnsureUid(entry);
        }

        _database.SetGroup(id, groupId);
        Changed?.Invoke();
    }

    public void SetOcrText(long id, string? text)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        // 空字符串 = 识别过、图里没有字（不再排队）；null = 没识别过。
        entry.OcrText = text is null ? null : OcrHit.Clean(text);
        entry.Folded = null;
        _database.SetOcr(id, entry.OcrText);
        Changed?.Invoke();
    }

    /// <summary>还没识字的图片（新的先来），后台排队用。</summary>
    public List<ClipEntry> PendingOcr(int limit = 4)
        => _items
            .Where(item => item.Kind == ClipKind.Image && item.OcrText is null)
            .OrderByDescending(item => item.CopiedAt)
            .Take(limit)
            .ToList();

    /// <summary>靠识字命中时行标题显示的那一段（不命中返回 null）。</summary>
    public static string? OcrSnippet(ClipEntry entry, string query)
        => entry.Kind == ClipKind.Image
            ? OcrHit.Snippet(entry.OcrText, Search.Tokens(query))
            : null;

    /// <summary>新建片段（第三版 §4）：正文 + 可选名称（存成备注），一定是收藏并带 uid。</summary>
    public ClipEntry? AddSnippet(string text, string? note)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var entry = new ClipEntry
        {
            Kind = ClipKind.Text,
            Text = text,
            Favorite = true,
            Snippet = true,
            Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim(),
            Uid = Guid.NewGuid().ToString("D").ToUpperInvariant(),
            CopiedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            SourceName = "片段",
        };
        entry.Id = _database.Insert(entry);
        _items.Insert(0, entry);
        Changed?.Invoke();
        return entry;
    }

    /// <summary>改正文（编辑片段用）。</summary>
    public void UpdateText(long id, string text)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null || entry.Kind != ClipKind.Text || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        entry.Text = text;
        entry.Folded = null;
        _database.SetText(id, text);
        Changed?.Invoke();
    }

    /// <summary>新建收藏夹；名字不合法 / 重名返回 null（规则在 Core 的 ClipGroups）。</summary>
    public ClipGroup? CreateGroup(string name)
    {
        var normalized = ClipGroups.Normalize(name);
        if (normalized is null || Groups.Count >= ClipGroups.MaxCount ||
            !ClipGroups.IsUnique(normalized, Groups.Select(group => group.Name)))
        {
            return null;
        }

        var group = new ClipGroup
        {
            Id = Guid.NewGuid().ToString("D").ToUpperInvariant(),
            Name = normalized,
            Position = Groups.Count == 0 ? 0 : Groups.Max(item => item.Position) + 1,
            CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
        _database.InsertGroup(group.Id, group.Name, group.Position, group.CreatedAt);
        Groups = _database.LoadGroups();
        Changed?.Invoke();
        return group;
    }

    public bool RenameGroup(string id, string name)
    {
        var normalized = ClipGroups.Normalize(name);
        var current = Groups.FirstOrDefault(group => group.Id == id);
        if (normalized is null || current is null ||
            !ClipGroups.IsUnique(normalized, Groups.Select(group => group.Name), current.Name))
        {
            return false;
        }

        _database.RenameGroup(id, normalized);
        Groups = _database.LoadGroups();
        Changed?.Invoke();
        return true;
    }

    public void MoveGroup(string id, int delta)
    {
        var ordered = Groups.OrderBy(group => group.Position).ToList();
        var index = ordered.FindIndex(group => group.Id == id);
        if (index < 0)
        {
            return;
        }

        var target = Math.Clamp(index + delta, 0, ordered.Count - 1);
        if (target == index)
        {
            return;
        }

        var moved = ordered[index];
        ordered.RemoveAt(index);
        ordered.Insert(target, moved);
        for (var position = 0; position < ordered.Count; position++)
        {
            _database.MoveGroup(ordered[position].Id, position);
        }

        Groups = _database.LoadGroups();
        Changed?.Invoke();
    }

    /// <summary>删除收藏夹：只解除归属，条目留在默认收藏里。</summary>
    public void DeleteGroup(string id)
    {
        _database.DeleteGroup(id);
        foreach (var entry in _items.Where(item => item.GroupId == id))
        {
            entry.GroupId = null;
        }

        Groups = _database.LoadGroups();
        Changed?.Invoke();
    }

    public string? GroupName(string? id) => Groups.FirstOrDefault(group => group.Id == id)?.Name;

    /// <summary>新采集的文本 / 文件。敏感过滤由调用方先做；这里只负责去重、落库和上限。</summary>
    public void Record(ClipEntry entry, string? html = null, string? rtf = null)
    {
        var existing = _items.FirstOrDefault(item => item.HasSameContent(entry)) ?? Reclaim(entry);
        if (existing is not null)
        {
            _items.Remove(existing);
            existing.CopiedAt = entry.CopiedAt;
            existing.SourceExe = entry.SourceExe;
            existing.SourceName = entry.SourceName;
            existing.Folded = null;
            _database.UpdateForRerecord(existing, html, rtf);
            _items.Insert(0, existing);
            if (entry.Kind == ClipKind.Image && entry.Id != existing.Id)
            {
                Images.Delete(entry.Id);
            }
        }
        else
        {
            entry.Id = _database.Insert(entry, html, rtf);
            _items.Insert(0, entry);
        }

        EnforceLimits();
        Changed?.Invoke();
    }

    /// <summary>新采集的图片（PNG 已在后台编好）。返回 false 表示 PNG 存不下来。</summary>
    public bool RecordImage(byte[] png, int width, int height, string? sourceExe, string? sourceName)
    {
        var hash = ImageStore.Hash(png);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var probe = new ClipEntry
        {
            Kind = ClipKind.Image,
            ImageHash = hash,
            CopiedAt = now,
        };
        var existing = _items.FirstOrDefault(item => item.HasSameContent(probe)) ?? Reclaim(probe);
        if (existing is not null)
        {
            // 可能在列表里（同内容又复制了一次），也可能是刚从撤销栈拿回来的（已经不在列表里）。
            // 两种都按「最新」挪到最前面：只靠 Bump 的话，撤销栈里拿回来的那条找不到就丢了，
            // 结果列表和撤销栈里都没有、库里却还在（第二版 §2 第 8 条）。
            _items.Remove(existing);
            existing.CopiedAt = now;
            _items.Insert(0, existing);
            _database.Touch(existing.Id, existing.CopiedAt);
            EnforceLimits();
            Changed?.Invoke();
            return true;
        }

        var entry = new ClipEntry
        {
            Kind = ClipKind.Image,
            ImageHash = hash,
            Width = width,
            Height = height,
            ImageBytes = png.Length,
            SourceExe = sourceExe,
            SourceName = sourceName,
            CopiedAt = now,
        };
        entry.Id = _database.Insert(entry);
        try
        {
            Images.Save(entry.Id, png);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.image-save-failed", ex);
            _database.Delete(new[] { entry.Id });
            return false;
        }

        _items.Insert(0, entry);
        EnforceLimits();
        Changed?.Invoke();
        return true;
    }

    /// <summary>本 App 自己写进剪贴板、要进历史的内容（截图、译文、识出的字、计算结果）。</summary>
    public bool RecordOwnText(string text)
    {
        if (SettingsService.Current.ClipboardBlockSensitive && SensitiveText.LooksSensitive(text))
        {
            return false;
        }

        var existing = _items.FirstOrDefault(item => item.Kind == ClipKind.Text && item.Text == text);
        if (existing is not null)
        {
            Bump(existing.Id);
            return true;
        }

        Record(new ClipEntry
        {
            Kind = ClipKind.Text,
            Text = text,
            CopiedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        });
        return true;
    }

    public void Bump(long id)
    {
        var index = _items.FindIndex(item => item.Id == id);
        if (index < 0)
        {
            return;
        }

        var entry = _items[index];
        _items.RemoveAt(index);
        entry.CopiedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        _items.Insert(0, entry);
        _database.Touch(entry.Id, entry.CopiedAt);
        Changed?.Invoke();
    }

    /// <summary>
    /// 导入文件里的片段 / 收藏（第三版 §2.2）：同样的正文不重复加，只把收藏标记补上；不删本机已有的。
    /// 片段 / 备注 / 收藏夹第三版第 3 批有了列之后再补（现在只合并正文和收藏）。
    /// </summary>
    public (int Added, int Updated) AdoptTextClips(
        IReadOnlyList<(string Text, bool Favorite, DateTimeOffset? CopiedAt)> clips)
        => AdoptClips(clips.Select(clip =>
            (clip.Text, clip.Favorite, clip.CopiedAt, (string?)null, false, (string?)null)).ToList());

    /// <summary>
    /// 导入片段 / 收藏 / 收藏夹（第三版 §2.2 / §4）：同样的正文不重复加，只补收藏、备注、片段和收藏夹；
    /// 收藏夹按名字找，没有就建；不删本机已有的。
    /// </summary>
    public (int Added, int Updated) AdoptClips(
        IReadOnlyList<(string Text, bool Favorite, DateTimeOffset? CopiedAt, string? Note, bool Snippet, string? Group)>
            clips)
    {
        var added = 0;
        var updated = 0;
        foreach (var clip in clips)
        {
            if (string.IsNullOrEmpty(clip.Text))
            {
                continue;
            }

            string? groupId = null;
            if (!string.IsNullOrWhiteSpace(clip.Group))
            {
                var name = ClipGroups.Normalize(clip.Group);
                var group = Groups.FirstOrDefault(item =>
                    string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase));
                group ??= name is null ? null : CreateGroup(name);
                groupId = group?.Id;
            }

            var existing = _items.FirstOrDefault(item =>
                item.Kind == ClipKind.Text && string.Equals(item.Text, clip.Text, StringComparison.Ordinal));
            if (existing is not null)
            {
                var changed = false;
                if ((clip.Favorite || clip.Snippet) && !existing.Favorite)
                {
                    existing.Favorite = true;
                    _database.SetFavorite(existing.Id, true);
                    changed = true;
                }

                if (!string.IsNullOrWhiteSpace(clip.Note) && existing.Note != clip.Note)
                {
                    existing.Note = clip.Note!.Trim();
                    existing.Folded = null;
                    _database.SetNote(existing.Id, existing.Note);
                    changed = true;
                }

                if (clip.Snippet && !existing.Snippet)
                {
                    existing.Snippet = true;
                    _database.SetSnippet(existing.Id, true);
                    changed = true;
                }

                if (groupId is not null && existing.GroupId != groupId)
                {
                    existing.GroupId = groupId;
                    existing.Favorite = true;
                    _database.SetGroup(existing.Id, groupId);
                    changed = true;
                }

                if (changed)
                {
                    EnsureUid(existing);
                    updated++;
                }

                continue;
            }

            var entry = new ClipEntry
            {
                Kind = ClipKind.Text,
                Text = clip.Text,
                Favorite = clip.Favorite || clip.Snippet || groupId is not null,
                Snippet = clip.Snippet,
                Note = string.IsNullOrWhiteSpace(clip.Note) ? null : clip.Note!.Trim(),
                GroupId = groupId,
                Uid = clip.Favorite || clip.Snippet || groupId is not null
                    ? Guid.NewGuid().ToString("D").ToUpperInvariant()
                    : null,
                CopiedAt = clip.CopiedAt?.ToUnixTimeMilliseconds()
                           ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            };
            entry.Id = _database.Insert(entry);
            _items.Insert(0, entry);
            added++;
        }

        if (added + updated > 0)
        {
            Changed?.Invoke();
        }

        Log.Info($"clipboard.adopt added={added} updated={updated}");
        return (added, updated);
    }

    public void ToggleFavorite(long id)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return;
        }

        entry.Favorite = !entry.Favorite;
        _database.SetFavorite(id, entry.Favorite);
        if (entry.Favorite)
        {
            EnsureUid(entry);
        }
        else
        {
            // 不变式：片段也是收藏；取消收藏同时不再是片段、也不再属于收藏夹（SetFavorite 已清 group_id）。
            if (entry.Snippet)
            {
                entry.Snippet = false;
                _database.SetSnippet(id, false);
            }

            entry.GroupId = null;
        }

        Log.Info($"clipboard.favorite id={id} value={entry.Favorite}");
        Changed?.Invoke();
    }

    /// <summary>可撤销的删除：先从列表拿掉、压进撤销栈，收起面板时才真的删库删图片。</summary>
    public void DeleteWithUndo(IReadOnlyCollection<long> ids)
    {
        var doomed = ids.ToHashSet();
        var batch = _items.Where(item => doomed.Contains(item.Id)).ToList();
        if (batch.Count == 0)
        {
            return;
        }

        _undo.Add(batch);
        _items.RemoveAll(item => doomed.Contains(item.Id));
        Changed?.Invoke();
    }

    public bool CanUndo => _undo.Count > 0;

    /// <summary>撤销最近一批删除；返回恢复的条目（面板据此把选中挪回去）。</summary>
    public IReadOnlyList<ClipEntry>? Undo()
    {
        if (_undo.Count == 0)
        {
            return null;
        }

        var batch = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        foreach (var entry in batch)
        {
            var index = _items.FindIndex(item => item.CopiedAt < entry.CopiedAt);
            _items.Insert(index < 0 ? _items.Count : index, entry);
        }

        Changed?.Invoke();
        return batch;
    }

    /// <summary>面板收起 / 退出：撤销栈里的真正删库删图片。</summary>
    public void CommitDeletion()
    {
        if (_undo.Count == 0)
        {
            return;
        }

        var ids = new List<long>();
        foreach (var batch in _undo)
        {
            foreach (var entry in batch)
            {
                ids.Add(entry.Id);
                if (entry.Kind == ClipKind.Image)
                {
                    Images.Delete(entry.Id);
                }
            }
        }

        _undo.Clear();
        try
        {
            _database.Delete(ids);
            Log.Info($"clipboard.delete-committed count={ids.Count}");
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.delete-failed", ex);
        }
    }

    /// <summary>按保留天数 / 图片额度清理普通条目；返回删了几条。</summary>
    public int EnforceLimits()
    {
        var limits = new RetentionLimits(
            SettingsService.Current.ClipboardRetentionDays,
            (long)SettingsService.Current.ClipboardImageBudgetMB * 1_048_576);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var doomed = Retention.Plan(
            _items.Select(item => item.ToRetentionItem()).ToList(),
            limits,
            now);
        if (doomed.Count == 0)
        {
            return 0;
        }

        var ids = _items.Where(item => doomed.Contains(item.Id.ToString()))
            .Select(item => item.Id)
            .ToList();
        Purge(ids);
        Log.Info($"clipboard.retention count={ids.Count}");
        return ids.Count;
    }

    /// <summary>清空普通历史（收藏不动）：设置里「立即清空」时用。</summary>
    public int ClearOrdinary()
    {
        CommitDeletion();
        var ids = _items.Where(item => !item.Favorite).Select(item => item.Id).ToList();
        Purge(ids);
        return ids.Count;
    }

    public long OrdinaryImageBytes => _items.Where(item => !item.Favorite).Sum(item => (long)item.ImageBytes);

    public List<ClipEntry> Filter(string query, bool favoritesOnly)
        => Filter(query, favoritesOnly ? ClipScope.Favorites : ClipScope.All, groupId: null);

    /// <summary>范围：全部 / 收藏 / 片段；选了收藏时还可以只看某个收藏夹。</summary>
    public List<ClipEntry> Filter(string query, ClipScope scope, string? groupId)
    {
        var tokens = Search.Tokens(query);
        var foldedTokens = Search.FoldTokens(tokens);
        var result = new List<ClipEntry>();
        foreach (var entry in _items)
        {
            if (scope == ClipScope.Favorites && !entry.Favorite)
            {
                continue;
            }

            if (scope == ClipScope.Snippets && !entry.Snippet)
            {
                continue;
            }

            if (groupId is not null && !string.Equals(entry.GroupId, groupId, StringComparison.Ordinal))
            {
                continue;
            }

            if (tokens.Length > 0)
            {
                entry.Folded ??= Search.FoldBytes(entry.SearchSource);
                if (!Search.Matches(entry.Folded, foldedTokens))
                {
                    continue;
                }
            }

            result.Add(entry);
        }

        return result;
    }

    /// <summary>删了还没提交的同内容条目：再复制一次等于自动撤销，不新建一条。</summary>
    private ClipEntry? Reclaim(ClipEntry probe) => UndoStack.Take(_undo, item => item.HasSameContent(probe));

    private void Purge(IReadOnlyCollection<long> ids)
    {
        if (ids.Count == 0)
        {
            return;
        }

        var doomed = ids.ToHashSet();
        foreach (var id in doomed)
        {
            var entry = _items.FirstOrDefault(item => item.Id == id);
            if (entry?.Kind == ClipKind.Image)
            {
                Images.Delete(id);
            }
        }

        _items.RemoveAll(item => doomed.Contains(item.Id));
        try
        {
            _database.Delete(doomed);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.purge-failed", ex);
        }

        Changed?.Invoke();
    }
}
