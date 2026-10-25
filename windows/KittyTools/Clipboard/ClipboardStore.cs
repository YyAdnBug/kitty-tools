// 剪贴板历史：内存列表（复制时间新→旧）+ clips 表。所有改动先改列表，再写库。
// 同样内容再复制 = 把原条目挪到最前（保留 id 和收藏）；删除可以 Ctrl+Z 撤销，面板收起时才真的删库。
// 保留天数和图片上限在启动时、每次收起面板时、每次入库后执行。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

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
        Images.CleanupOrphans(_items.Select(item => item.Id).ToHashSet());
    }

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
    {
        var added = 0;
        var updated = 0;
        foreach (var clip in clips)
        {
            if (string.IsNullOrEmpty(clip.Text))
            {
                continue;
            }

            var existing = _items.FirstOrDefault(item =>
                item.Kind == ClipKind.Text && string.Equals(item.Text, clip.Text, StringComparison.Ordinal));
            if (existing is not null)
            {
                if (clip.Favorite && !existing.Favorite)
                {
                    existing.Favorite = true;
                    _database.SetFavorite(existing.Id, true);
                    updated++;
                }

                continue;
            }

            var entry = new ClipEntry
            {
                Kind = ClipKind.Text,
                Text = clip.Text,
                Favorite = clip.Favorite,
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
    {
        var tokens = Search.Tokens(query);
        var foldedTokens = Search.FoldTokens(tokens);
        var result = new List<ClipEntry>();
        foreach (var entry in _items)
        {
            if (favoritesOnly && !entry.Favorite)
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
