// 剪贴板历史：内存列表（复制时间新→旧）+ clips 表。所有改动先改列表，再写库。
// 同样内容再复制 = 把原条目挪到最前（保留 id 和收藏）；删除可以 Ctrl+Z 撤销，面板收起时才真的删库。
// 保留天数和图片上限在启动时、每次收起面板时、每次入库后执行。
using KittyTools.Core;
using KittyTools.Core.Sync;
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
    private readonly List<UndoBatch> _undo = new();

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

    /// <summary>同步：面板里还有能撤销的删除（还没落库）时这一轮先不合（mac syncBusy）。</summary>
    public bool SyncBusy => _undo.Count > 0;

    /// <summary>同步要的本机文字条目（留着的先补上 uid）。</summary>
    public List<SyncClipRow> SyncRows()
    {
        var rows = new List<SyncClipRow>();
        foreach (var entry in _items.Where(item => item.Kind == ClipKind.Text && item.Text is not null))
        {
            if (IsRetained(entry))
            {
                EnsureUid(entry);
            }

            rows.Add(new SyncClipRow(
                entry.Id, entry.Uid, entry.Text!, entry.Favorite, entry.Snippet, entry.Note, entry.GroupId,
                entry.CopiedAt));
        }

        return rows;
    }

    public List<SyncClipGroup> SyncGroups()
        => Groups.OrderBy(group => group.Position).Select(group => new SyncClipGroup(group.Id, group.Name, group.CreatedAt))
            .ToList();

    /// <summary>同步落地（照 mac applySync）：规划（Core 的 ClipSync.Plan）先写进库、和账本同一个事务（saveLedger 在事务里调），
    /// 成了才换进内存；没成回滚、抛出去，内存不动。</summary>
    public void ApplySyncPlan(ClipSyncPlan plan, Action saveLedger)
    {
        var inserted = new Dictionary<SyncClipWrite, long>();
        _database.BeginTransaction();
        try
        {
            _database.ReplaceGroups(plan.Groups.Select((group, index) => new ClipGroup
            {
                Id = group.Id, Name = group.Name, Position = index, CreatedAt = group.Created,
            }).ToList());
            _database.DeleteRows(plan.Deletes);
            foreach (var write in plan.Writes)
            {
                if (write.Row is { } row)
                {
                    _database.SetSynced(row, write);
                }
                else
                {
                    inserted[write] = _database.Insert(new ClipEntry
                    {
                        Kind = ClipKind.Text, Text = write.Text, Uid = write.Uid, Favorite = write.Favorite,
                        Snippet = write.Snippet, Note = write.Note, GroupId = write.Group, CopiedAt = write.CopiedAt,
                    });
                }
            }

            saveLedger();
            _database.Commit();
        }
        catch
        {
            _database.Rollback();
            throw;
        }

        var deleted = plan.Deletes.ToHashSet();
        _items.RemoveAll(item => deleted.Contains(item.Id));
        foreach (var write in plan.Writes)
        {
            var entry = write.Row is { } row ? _items.FirstOrDefault(item => item.Id == row) : null;
            if (entry is null)
            {
                entry = new ClipEntry { Kind = ClipKind.Text, Id = write.Row ?? inserted[write] };
                _items.Add(entry);
            }

            entry.Uid = write.Uid ?? entry.Uid;
            entry.Text = write.Text;
            entry.Favorite = write.Favorite;
            entry.Snippet = write.Snippet;
            entry.Note = write.Note;
            entry.GroupId = write.Group;
            entry.CopiedAt = write.CopiedAt;
            entry.Folded = null;
        }

        _items.Sort((a, b) => b.CopiedAt != a.CopiedAt ? b.CopiedAt.CompareTo(a.CopiedAt) : b.Id.CompareTo(a.Id));
        Groups = _database.LoadGroups();
        Changed?.Invoke();
    }

    /// <summary>
    /// 用户明确留下的（收藏 ∨ 片段；收藏夹里的都是收藏，同 mac isRetained）：保留天数、图片占用、清空都不动它们。
    /// 改这里要连 <see cref="BackupPlan"/> 里库的写法（<c>ClipRetainedSql</c>）一起改。
    /// </summary>
    public static bool IsRetained(ClipEntry entry) => entry.Favorite || entry.Snippet || entry.GroupId is not null;

    /// <summary>
    /// 存为 / 移出片段（片段和收藏各管各的，同 mac：收藏、收藏夹、备注都不动）。
    /// 返回移出后已经超过保留天数、压进撤销栈的条数（见 <see cref="ChangeRetention"/>）。
    /// </summary>
    public int ToggleSnippet(long id)
    {
        var entry = _items.FirstOrDefault(item => item.Id == id);
        if (entry is null)
        {
            return 0;
        }

        return SetSnippet(new[] { id }, !entry.Snippet);
    }

    public int SetSnippet(IReadOnlyCollection<long> ids, bool snippet)
        => ChangeRetention(ids, entry =>
        {
            if (entry.Kind != ClipKind.Text || entry.Snippet == snippet)
            {
                return;
            }

            entry.Snippet = snippet;
            _database.SetSnippet(entry.Id, snippet);
        });

    /// <summary>
    /// 改收藏 / 片段这类决定保留的字段（照 mac changeRetention）：改完不再留下、又已超过保留天数的条目，
    /// 把改动前的样子压进撤销栈——面板收起前不清理、Ctrl+Z 能改回来。返回这样的条数（底栏据此提示「超过 N 天…」）。
    /// </summary>
    private int ChangeRetention(IReadOnlyCollection<long> ids, Action<ClipEntry> change)
    {
        var targets = _items.Where(item => ids.Contains(item.Id)).ToList();
        if (targets.Count == 0)
        {
            return 0;
        }

        var before = targets.Select(entry => new RetentionSnapshot(entry, entry.Favorite, entry.Snippet, entry.GroupId)).ToList();
        foreach (var entry in targets)
        {
            change(entry);
            if (IsRetained(entry))
            {
                EnsureUid(entry);
            }
        }

        var limits = CurrentLimits();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var expired = before
            .Where(old => (old.Favorite || old.Snippet || old.GroupId is not null) && !IsRetained(old.Entry) &&
                          Retention.IsExpired(old.Entry.CopiedAt, limits, now))
            .ToList();
        if (expired.Count > 0)
        {
            _undo.Add(new UndoBatch { Unretained = expired });
        }

        Changed?.Invoke();
        return expired.Count;
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

        // 不变式：有收藏夹的一定是收藏（mac assign）；片段不动。
        entry.GroupId = groupId;
        if (groupId is not null)
        {
            entry.Favorite = true;
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

    /// <summary>删除收藏夹：只解除归属，条目留在默认收藏里；不确认，进撤销栈（Ctrl+Z 连位置和归属一起回来，同 mac）。</summary>
    public void DeleteGroup(string id)
    {
        var ordered = Groups.OrderBy(group => group.Position).ToList();
        var index = ordered.FindIndex(group => group.Id == id);
        if (index < 0)
        {
            return;
        }

        var members = _items.Where(item => item.GroupId == id).Select(item => item.Id).ToList();
        _database.DeleteGroup(id);
        foreach (var entry in _items.Where(item => item.GroupId == id))
        {
            entry.GroupId = null;
        }

        _undo.Add(new UndoBatch { Group = ordered[index], GroupIndex = index, GroupMembers = members });
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

    /// <summary>旧的导入入口（只有正文和收藏）：样例数据、旧版迁移用。</summary>
    public (int Added, int Updated) AdoptTextClips(
        IReadOnlyList<(string Text, bool Favorite, DateTimeOffset? CopiedAt)> clips)
        => AdoptClips(clips.Select(clip =>
            (clip.Text, clip.Favorite, clip.CopiedAt, (string?)null, false, (string?)null)).ToList());

    /// <summary>
    /// 导入片段 / 文字收藏 / 收藏夹（照 mac ClipboardStore.adopt，mac-clipboard §1「导入片段和文字收藏」）：合并，不删本机已有的。
    /// 收藏夹按名字对，没有的新建在最后（groupNames 里空的也建）；条目按正文对，已有的只补标记——收藏、片段取并集，
    /// 原来没备注、没归收藏夹的才用文件里的，时间和位置不动；没有的新建，时间用文件里的但不晚于现在，按时间插到该在的位置
    /// （同一时刻的几条保持文件里的顺序）。先提交撤销栈：删了还没提交的同文条目不该被导入变成两条；导入本身不进撤销栈。
    /// </summary>
    public (int Added, int Updated) AdoptClips(
        IReadOnlyList<(string Text, bool Favorite, DateTimeOffset? CopiedAt, string? Note, bool Snippet, string? Group)>
            clips,
        IReadOnlyList<string>? groupNames = null)
    {
        CommitDeletion();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        // 文件里正文重复的并成一条（标记取并集，备注 / 收藏夹取第一个有的）。
        var merged = new List<(string Text, bool Favorite, long CopiedAt, string? Note, bool Snippet, string? Group)>();
        var byText = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var clip in clips)
        {
            if (string.IsNullOrEmpty(clip.Text))
            {
                continue;
            }

            var note = string.IsNullOrWhiteSpace(clip.Note) ? null : clip.Note.Trim();
            var group = ClipGroups.Normalize(clip.Group ?? string.Empty);
            var time = Math.Min(clip.CopiedAt?.ToUnixTimeMilliseconds() ?? now, now);
            if (byText.TryGetValue(clip.Text, out var at))
            {
                var old = merged[at];
                merged[at] = (old.Text, old.Favorite || clip.Favorite, old.CopiedAt, old.Note ?? note, old.Snippet || clip.Snippet,
                    old.Group ?? group);
                continue;
            }

            byText[clip.Text] = merged.Count;
            merged.Add((clip.Text, clip.Favorite, time, note, clip.Snippet, group));
        }

        var added = 0;
        var updated = 0;
        var groupsChanged = false;
        var fresh = new List<ClipEntry>();
        _database.BeginTransaction();
        try
        {
            var groups = Groups.OrderBy(item => item.Position).ToList();
            string? GroupFor(string? name)
            {
                if (name is null)
                {
                    return null;
                }

                var found = groups.FirstOrDefault(item => string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase));
                if (found is null)
                {
                    if (groups.Count >= ClipGroups.MaxCount)
                    {
                        return null;
                    }

                    found = new ClipGroup
                    {
                        Id = Guid.NewGuid().ToString("D").ToUpperInvariant(),
                        Name = name,
                        Position = groups.Count == 0 ? 0 : groups.Max(item => item.Position) + 1,
                        CreatedAt = now,
                    };
                    _database.InsertGroup(found.Id, found.Name, found.Position, found.CreatedAt);
                    groups.Add(found);
                    groupsChanged = true;
                }

                return found.Id;
            }

            foreach (var name in groupNames ?? Array.Empty<string>())
            {
                GroupFor(ClipGroups.Normalize(name));
            }

            foreach (var clip in merged)
            {
                var groupId = GroupFor(clip.Group);
                var existing = _items.FirstOrDefault(item =>
                    item.Kind == ClipKind.Text && string.Equals(item.Text, clip.Text, StringComparison.Ordinal));
                if (existing is null)
                {
                    fresh.Add(new ClipEntry
                    {
                        Kind = ClipKind.Text,
                        Text = clip.Text,
                        Favorite = clip.Favorite || groupId is not null,
                        Snippet = clip.Snippet,
                        Note = clip.Note,
                        GroupId = groupId,
                        Uid = clip.Favorite || clip.Snippet || groupId is not null
                            ? Guid.NewGuid().ToString("D").ToUpperInvariant()
                            : null,
                        CopiedAt = clip.CopiedAt,
                    });
                    continue;
                }

                var changed = false;
                if (clip.Favorite && !existing.Favorite)
                {
                    existing.Favorite = true;
                    _database.SetFavorite(existing.Id, true);
                    changed = true;
                }

                if (clip.Snippet && !existing.Snippet)
                {
                    existing.Snippet = true;
                    _database.SetSnippet(existing.Id, true);
                    changed = true;
                }

                if (clip.Note is not null && existing.Note is null)
                {
                    existing.Note = clip.Note;
                    existing.Folded = null;
                    _database.SetNote(existing.Id, existing.Note);
                    changed = true;
                }

                if (groupId is not null && existing.GroupId is null)
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
            }

            // 从旧到新插（同一时刻的倒着按文件顺序插）：rowid 大的排在前面，读回来就是文件里的顺序。
            foreach (var entry in fresh.AsEnumerable().Reverse().OrderBy(item => item.CopiedAt))
            {
                entry.Id = _database.Insert(entry);
                _items.Insert(ClipOrder.InsertIndex(_items, item => item.CopiedAt, item => item.Id, entry.CopiedAt, entry.Id), entry);
                added++;
            }

            _database.Commit();
        }
        catch
        {
            _database.Rollback();
            Load();
            throw;
        }

        if (groupsChanged)
        {
            Groups = _database.LoadGroups();
        }

        if (added + updated > 0 || groupsChanged)
        {
            Changed?.Invoke();
        }

        Log.Info($"clipboard.adopt added={added} updated={updated}");
        return (added, updated);
    }

    /// <summary>
    /// 全部已收藏 → 全部取消（同时移出收藏夹，片段和备注不动），否则全部收藏（同 mac toggleFavorite）。
    /// 返回取消后已超期、压进撤销栈的条数。
    /// </summary>
    public int ToggleFavorite(IReadOnlyCollection<long> ids)
    {
        var targets = _items.Where(item => ids.Contains(item.Id)).ToList();
        if (targets.Count == 0)
        {
            return 0;
        }

        var favorite = !targets.All(item => item.Favorite);
        Log.Info($"clipboard.favorite count={targets.Count} value={favorite}");
        return ChangeRetention(ids, entry =>
        {
            if (entry.Favorite == favorite && (favorite || entry.GroupId is null))
            {
                return;
            }

            entry.Favorite = favorite;
            if (!favorite)
            {
                entry.GroupId = null;
            }

            // 取消收藏时库里顺带清掉 group_id（SetFavorite 里）。
            _database.SetFavorite(entry.Id, favorite);
        });
    }

    public int ToggleFavorite(long id) => ToggleFavorite(new[] { id });

    /// <summary>可撤销的删除：先从列表拿掉、压进撤销栈，收起面板时才真的删库删图片。</summary>
    public void DeleteWithUndo(IReadOnlyCollection<long> ids)
    {
        var doomed = ids.ToHashSet();
        var batch = _items.Where(item => doomed.Contains(item.Id)).ToList();
        if (batch.Count == 0)
        {
            return;
        }

        _undo.Add(new UndoBatch { Deleted = batch });
        _items.RemoveAll(item => doomed.Contains(item.Id));
        Changed?.Invoke();
    }

    public bool CanUndo => _undo.Count > 0;

    /// <summary>撤销最近一批（删除 / 删收藏夹 / 取消留下）；面板据此挪选中、出提示。撤销栈空时 null。</summary>
    public ClipUndoResult? Undo()
    {
        if (_undo.Count == 0)
        {
            return null;
        }

        var batch = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        ClipUndoResult result;
        if (batch.Deleted is { } deleted)
        {
            foreach (var entry in deleted.OrderBy(item => item.CopiedAt).ThenBy(item => item.Id))
            {
                _items.Insert(ClipOrder.InsertIndex(_items, item => item.CopiedAt, item => item.Id, entry.CopiedAt, entry.Id), entry);
            }

            result = new ClipUndoResult(ClipUndoKind.Deleted, deleted, null);
        }
        else if (batch.Group is { } group)
        {
            // 收藏夹回到原来的位置，原来的条目（还在、还是收藏的）重新归进去。
            var ordered = Groups.OrderBy(item => item.Position).ToList();
            ordered.Insert(Math.Clamp(batch.GroupIndex, 0, ordered.Count), group);
            _database.BeginTransaction();
            try
            {
                _database.InsertGroup(group.Id, group.Name, batch.GroupIndex, group.CreatedAt);
                for (var position = 0; position < ordered.Count; position++)
                {
                    _database.MoveGroup(ordered[position].Id, position);
                }

                foreach (var entry in _items.Where(item => batch.GroupMembers!.Contains(item.Id) && item.GroupId is null))
                {
                    entry.GroupId = group.Id;
                    entry.Favorite = true;
                    _database.SetGroup(entry.Id, group.Id);
                }

                _database.Commit();
            }
            catch
            {
                _database.Rollback();
                throw;
            }

            Groups = _database.LoadGroups();
            var members = _items.Where(item => item.GroupId == group.Id).ToList();
            result = new ClipUndoResult(ClipUndoKind.Group, members, group.Name);
        }
        else
        {
            var restored = new List<ClipEntry>();
            foreach (var old in batch.Unretained!)
            {
                var entry = old.Entry;
                if (!_items.Contains(entry))
                {
                    continue;
                }

                entry.Favorite = old.Favorite;
                entry.Snippet = old.Snippet;
                entry.GroupId = old.GroupId;
                _database.SetFavorite(entry.Id, old.Favorite);
                _database.SetSnippet(entry.Id, old.Snippet);
                if (old.GroupId is not null)
                {
                    _database.SetGroup(entry.Id, old.GroupId);
                }

                restored.Add(entry);
            }

            result = new ClipUndoResult(ClipUndoKind.Unretained, restored, null);
        }

        Changed?.Invoke();
        return result;
    }

    /// <summary>面板收起 / 退出：撤销栈里删掉的真正删库删图片；删收藏夹、取消留下的那几批就此不能撤了。</summary>
    public void CommitDeletion()
    {
        if (_undo.Count == 0)
        {
            return;
        }

        var ids = new List<long>();
        foreach (var batch in _undo)
        {
            foreach (var entry in batch.Deleted ?? new List<ClipEntry>())
            {
                ids.Add(entry.Id);
                if (entry.Kind == ClipKind.Image)
                {
                    Images.Delete(entry.Id);
                }
            }
        }

        _undo.Clear();
        if (ids.Count == 0)
        {
            return;
        }

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

    private static RetentionLimits CurrentLimits() => new(
        SettingsService.Current.ClipboardRetentionDays,
        (long)SettingsService.Current.ClipboardImageBudgetMB * 1_048_576);

    /// <summary>按保留天数 / 图片额度清理普通条目；还能撤销的（刚取消收藏、已超期的）这一轮不清。返回删了几条。</summary>
    public int EnforceLimits()
    {
        var undoable = _undo.SelectMany(batch => batch.Unretained ?? new List<RetentionSnapshot>())
            .Select(old => old.Entry.Id)
            .ToHashSet();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var doomed = Retention.Plan(
            _items.Where(item => !undoable.Contains(item.Id)).Select(item => item.ToRetentionItem()).ToList(),
            CurrentLimits(),
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

    /// <summary>清空普通历史（收藏、片段、收藏夹里的不动）：设置里「立即清空」、退出 / 锁屏清空时用。先提交撤销栈。</summary>
    public int ClearOrdinary()
    {
        CommitDeletion();
        var ids = _items.Where(item => !IsRetained(item)).Select(item => item.Id).ToList();
        Purge(ids);
        return ids.Count;
    }

    public long OrdinaryImageBytes => _items.Where(item => !IsRetained(item)).Sum(item => (long)item.ImageBytes);

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
    private ClipEntry? Reclaim(ClipEntry probe)
    {
        var deleted = _undo.Where(batch => batch.Deleted is not null).Select(batch => batch.Deleted!).ToList();
        var taken = UndoStack.Take(deleted, item => item.HasSameContent(probe));
        _undo.RemoveAll(batch => batch.Deleted is { Count: 0 });
        return taken;
    }

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

/// <summary>撤销栈里的一批（照 mac 的 undoStack）：删掉的条目、删掉的收藏夹、取消留下后已超期的条目，三样只有一样。</summary>
internal sealed class UndoBatch
{
    public List<ClipEntry>? Deleted { get; init; }

    public ClipGroup? Group { get; init; }

    public int GroupIndex { get; init; }

    public List<long>? GroupMembers { get; init; }

    public List<RetentionSnapshot>? Unretained { get; init; }
}

/// <summary>取消收藏 / 移出片段之前的样子。</summary>
internal sealed record RetentionSnapshot(ClipEntry Entry, bool Favorite, bool Snippet, string? GroupId);

internal enum ClipUndoKind
{
    Deleted,
    Group,
    Unretained,
}

/// <summary>撤销了什么：面板据此挪选中（Entries 第一条）、出提示。</summary>
internal sealed record ClipUndoResult(ClipUndoKind Kind, IReadOnlyList<ClipEntry> Entries, string? GroupName);
