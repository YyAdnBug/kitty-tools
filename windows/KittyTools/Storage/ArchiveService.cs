// 导出 / 导入的执行层（第三版 §2.2）：把设置、翻译服务、网页搜索、片段与收藏、生词本装进 SettingsArchive，
// 以及反过来把文件合并回本机。读文件当成不可信输入（Core 里 Sanitized 过一遍），密钥走 Core 的 ArchiveCrypto。
// 自动备份：每天一份「Kitty Tools 自动备份 日期.json」（留 7 份），导入前另存一份（留 3 份）——和 mac 的
// Storage/SettingsBackup 同一个规矩，放在数据目录的 backups\ 里（和数据库备份同一个文件夹，文件名不同）。
// PLAN-v9 G2：每天那份能关掉（Settings.DailyBackup）、能另存一份到别的文件夹（BackupCopyFolder，文件名末尾带这台电脑的编号，
// 几台电脑共用一个文件夹也不打架），没存过去的原因记在 CopyProblem 给设置页用橙字写出来；导入时能只导勾上的几类（Only）。
using System.Text;
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class ArchiveOutcome
{
    public int Secrets { get; set; }

    public int ClipsAdded { get; set; }

    public int ClipsUpdated { get; set; }

    public int WordsAdded { get; set; }

    public int ServicesAdded { get; set; }

    public int EnginesAdded { get; set; }

    public int NotesAdded { get; set; }

    public int NotesUpdated { get; set; }

    /// <summary>便签这次用不了，文件里的便签没导（mac notesSkipped）。</summary>
    public bool NotesSkipped { get; set; }

    /// <summary>便签并进去了、没落下盘（mac notesUnsaved：仓库自己会再试，但不能说「新增 N 条」）。</summary>
    public bool NotesUnsaved { get; set; }
}

internal static class ArchiveService
{
    public const int DailyKeep = 7;

    public const int BeforeImportKeep = 3;

    /// <summary>导出文件所在的地方（自动备份也在这里）。</summary>
    public static string Folder => Path.Combine(Paths.DataDirectory, BackupPlan.FolderName);

    /// <summary>今天那份没另存过去的原因（设置页橙字）；存过去了、换了文件夹就清掉。哪个线程写都行，只是一个字符串。</summary>
    public static volatile string? CopyProblem;

    /// <summary>
    /// 这台电脑的编号（另存的文件名末尾那 4 位）：机器名的 FNV-1a，每次启动都一样（string.GetHashCode 每个进程不一样，不能用）。
    /// </summary>
    public static string DeviceTag
    {
        get
        {
            var hash = 2166136261u;
            foreach (var character in Environment.MachineName.ToUpperInvariant())
            {
                hash = (hash ^ character) * 16777619u;
            }

            return (hash & 0xFFFF).ToString("X4", System.Globalization.CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// 把最新那份自动备份另存到 folder（文件名「Kitty Tools 自动备份 日期 编号.json」，那里也只留 7 份）。
    /// 可能是卡住的网络盘：在后台线程上调。返回 null = 存好了，否则是给人看的原因。
    /// </summary>
    public static string? CopyLatestDaily(string folder)
    {
        var latest = BackupFiles("Kitty Tools 自动备份 *.json").FirstOrDefault();
        if (latest is null)
        {
            return null;
        }

        try
        {
            if (!Directory.Exists(folder))
            {
                return "今天那份没存过去：找不到文件夹（没连上、被移走，或者没有访问权限）";
            }

            var name = $"{Path.GetFileNameWithoutExtension(latest)} {DeviceTag}.json";
            File.Copy(latest, Path.Combine(folder, name), overwrite: true);
            Rotate(folder, $"Kitty Tools 自动备份 * {DeviceTag}.json", DailyKeep, Path.Combine(folder, name));
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return "今天那份没存过去：没有写这个文件夹的权限";
        }
        catch (Exception ex)
        {
            Log.Warn($"archive.copy-failed {ex.GetType().Name}");
            return "今天那份没存过去：写不进这个文件夹（盘满了，或者文件被占着）";
        }
    }

    /// <summary>导入时只导勾上的几类（PLAN-v9 G3）：别的类在副本里清成空，Apply 就不碰它们。密钥跟着「翻译服务」走。</summary>
    public static SettingsArchive Only(SettingsArchive archive, IReadOnlyCollection<ArchiveSection> sections) => new()
    {
        App = archive.App,
        Format = archive.Format,
        Platform = archive.Platform,
        Preferences = sections.Contains(ArchiveSection.Preferences) ? archive.Preferences : null,
        Hotkeys = sections.Contains(ArchiveSection.Hotkeys) ? archive.Hotkeys : null,
        TranslateServices = sections.Contains(ArchiveSection.Services) ? archive.TranslateServices : null,
        SearchEngines = sections.Contains(ArchiveSection.Engines) ? archive.SearchEngines : null,
        Clips = sections.Contains(ArchiveSection.Clips) ? archive.Clips : null,
        ClipGroups = sections.Contains(ArchiveSection.Clips) ? archive.ClipGroups : null,
        Vocabulary = sections.Contains(ArchiveSection.Vocabulary) ? archive.Vocabulary : null,
        Secrets = sections.Contains(ArchiveSection.Services) ? archive.Secrets : null,
        Notes = sections.Contains(ArchiveSection.Notes) ? archive.Notes : null,
    };

    /// <summary>手动导出前先看能不能带便签（mac exportProblem 的便签那两句）；null = 没问题。</summary>
    public static string? ExportProblem(IReadOnlyCollection<ArchiveSection> sections)
    {
        if (!sections.Contains(ArchiveSection.Notes) || NoteStore.Instance is not { } notes)
        {
            return null;
        }

        var entries = notes.Book.Exportable.Select(NoteEntry.From).OfType<NoteEntry>().ToList();
        if (entries.Count > NoteEntry.MaxNotes)
        {
            return $"便签超过 {NoteEntry.MaxNotes} 条，先取消勾选「便签」";
        }

        return NoteEntry.Fit(entries) ? null : "有便签的正文超过 1 MB，先取消勾选「便签」";
    }

    public static string Encode(SettingsArchive archive)
        => JsonSerializer.Serialize(archive, ArchiveJsonContext.Default.SettingsArchive);

    public static SettingsArchive? Decode(string text)
    {
        try
        {
            var archive = JsonSerializer.Deserialize(text, ArchiveJsonContext.Default.SettingsArchive);
            if (archive is null ||
                !string.Equals(archive.App, SettingsArchive.Marker, StringComparison.Ordinal) ||
                archive.Format is < 1 or > SettingsArchive.CurrentFormat)
            {
                return null;
            }

            return archive.Sanitized();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>按勾选的类别从本机组一份文件；<paramref name="password"/> 不为空时把密钥加密带上。</summary>
    public static SettingsArchive Build(
        IReadOnlyCollection<ArchiveSection> sections,
        string? password = null)
    {
        var settings = SettingsService.Current;
        var archive = new SettingsArchive { Platform = SettingsArchive.WindowsPlatform };

        if (sections.Contains(ArchiveSection.Preferences))
        {
            archive.Preferences = PreferencesOf(settings);
        }

        if (sections.Contains(ArchiveSection.Hotkeys))
        {
            archive.Hotkeys = settings.HotKeys.ToDictionary(
                hotkey => hotkey.Action,
                hotkey => (string?)HotKeyRules.Format(hotkey.VirtualKey, (HotKeyModifiers)hotkey.Modifiers));
        }

        if (sections.Contains(ArchiveSection.Services) && TranslateServiceStore.Instance is { } store)
        {
            archive.TranslateServices = store.Services.Select(service => new SettingsArchive.ArchiveService
            {
                Id = service.Id,
                Kind = service.Kind,
                Name = service.Name,
                Enabled = service.Enabled,
                Model = service.Model,
                BaseUrl = service.BaseUrl,
                AiProtocol = service.Protocol,
                Region = service.Region,
                UsesDeepLX = service.UsesDeepLX,
            }).ToList();
        }

        if (sections.Contains(ArchiveSection.Engines))
        {
            archive.SearchEngines = (settings.LauncherSearchEngines ?? WebSearch.Defaults())
                .Select(engine => new SettingsArchive.ArchiveEngine
                {
                    Id = engine.Id,
                    Name = engine.Name,
                    Keyword = engine.Keyword,
                    Url = engine.UrlTemplate,
                    Fallback = engine.Fallback,
                })
                .ToList();
        }

        if (sections.Contains(ArchiveSection.Clips) && ClipboardService.Instance?.Store is { } clips)
        {
            archive.Clips = clips.Items
                .Where(entry => entry.Kind == ClipKind.Text && ClipboardStore.IsRetained(entry))
                .Take(SettingsArchive.MaxClips)
                .Select(entry => new SettingsArchive.ArchiveClip
                {
                    Text = entry.Text,
                    Note = entry.Note,
                    Favorite = entry.Favorite,
                    Snippet = entry.Snippet,
                    Group = clips.GroupName(entry.GroupId),
                    CopiedAt = DateTimeOffset.FromUnixTimeMilliseconds(entry.CopiedAt),
                })
                .ToList();
            archive.ClipGroups = clips.Groups
                .OrderBy(group => group.Position)
                .Select(group => group.Name)
                .Take(SettingsArchive.MaxGroups)
                .ToList();
        }

        // 生词本（第三版第 2 批）：收藏的翻译。
        if (sections.Contains(ArchiveSection.Vocabulary) && TranslationHistory.Instance is { } history)
        {
            archive.Vocabulary = history.Search(string.Empty, favoritesOnly: true, limit: 0)
                .Select(entry => new SettingsArchive.ArchiveWord
                {
                    Source = entry.Source,
                    Target = entry.TargetLang,
                    Result = entry.Result,
                    Service = entry.Service,
                    CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds(entry.CreatedAt),
                })
                .ToList();
        }

        // 便签（PLAN-v13）：这次用不了（库没开成）就不带这一类（null），不能写一份空的；条数、单条正文超了上限也不带
        // （手动导出时 ExportProblem 先拦下来说清楚）。
        if (sections.Contains(ArchiveSection.Notes) && NoteStore.Instance is { } notes)
        {
            var entries = notes.Book.Exportable.Select(NoteEntry.From).OfType<NoteEntry>().ToList();
            if (NoteEntry.Fit(entries))
            {
                archive.Notes = entries.Select(entry =>
                {
                    using var document = JsonDocument.Parse(entry.Json());
                    return document.RootElement.Clone();
                }).ToList();
            }
        }

        if (!string.IsNullOrEmpty(password) && archive.TranslateServices is { } services)
        {
            var secrets = SecretsOf(services);
            if (secrets.Count > 0)
            {
                archive.Secrets = ArchiveCrypto.Seal(secrets, password, services);
            }
        }

        return archive;
    }

    /// <summary>把文件合并回本机；<paramref name="password"/> 用来解密钥（文件不带密钥就不需要）。</summary>
    public static (ArchiveOutcome Outcome, string? Error) Apply(SettingsArchive archive, string? password)
    {
        var outcome = new ArchiveOutcome();
        try
        {
            if (archive.AppliesWindowsSettings)
            {
                ApplyPreferences(archive.Preferences);
                ApplyHotkeys(archive.Hotkeys);
            }

            if (archive.TranslateServices is { Count: > 0 } services && TranslateServiceStore.Instance is { } store)
            {
                foreach (var entry in services)
                {
                    var service = store.Services.FirstOrDefault(item => item.Id == entry.Id);
                    if (service is null)
                    {
                        service = new TranslateServiceConfig
                        {
                            Id = entry.Id!,
                            Kind = entry.Kind!,
                            Protocol = entry.AiProtocol ?? "openai",
                        };
                        store.Services.Add(service);
                        outcome.ServicesAdded++;
                    }

                    service.Name = entry.Name ?? service.Name;
                    service.Kind = entry.Kind ?? service.Kind;
                    service.Enabled = entry.Enabled ?? service.Enabled;
                    service.Model = entry.Model ?? service.Model;
                    service.BaseUrl = entry.BaseUrl ?? service.BaseUrl;
                    service.Protocol = entry.AiProtocol ?? service.Protocol;
                    service.Region = entry.Region ?? service.Region;
                    service.UsesDeepLX = entry.UsesDeepLX ?? service.UsesDeepLX;
                }

                store.Save();
            }

            if (archive.SearchEngines is { Count: > 0 } engines)
            {
                ApplyEngines(engines, outcome);
            }

            if (archive.Clips is { Count: > 0 } clips && ClipboardService.Instance?.Store is { } clipboard)
            {
                var (added, updated) = clipboard.AdoptClips(
                    clips.Select(clip => (
                        clip.Text!,
                        clip.Favorite == true,
                        clip.CopiedAt,
                        clip.Note,
                        clip.Snippet == true,
                        clip.Group)).ToList(),
                    archive.ClipGroups);
                outcome.ClipsAdded = added;
                outcome.ClipsUpdated = updated;
            }

            if (archive.Vocabulary is { Count: > 0 } words && TranslationHistory.Instance is { } vocabulary)
            {
                outcome.WordsAdded = vocabulary.AdoptFavorites(words);
            }

            // 便签：按编号并进便签库（mac NoteStore.adopt）；便签这次用不了时跳过、在结果里说。
            if (archive.Notes is { Count: > 0 } rawNotes)
            {
                if (NoteStore.Instance is { } noteStore)
                {
                    var adopted = noteStore.Adopt(NoteEntry.Sanitized(rawNotes));
                    outcome.NotesAdded = adopted.Added;
                    outcome.NotesUpdated = adopted.Updated;
                    outcome.NotesUnsaved = !adopted.Saved;
                }
                else
                {
                    outcome.NotesSkipped = true;
                }
            }

            if (archive.Secrets is { } sealedSecrets && archive.TranslateServices is { Count: > 0 } secretServices)
            {
                var secrets = ArchiveCrypto.Unseal(sealedSecrets, password ?? string.Empty, secretServices);
                if (secrets is null)
                {
                    return (outcome, "密码不对（也可能是文件里的翻译服务被改动过）");
                }

                ApplySecrets(secrets, secretServices);
                outcome.Secrets = secrets.Count;
            }

            return (outcome, null);
        }
        catch (Exception ex)
        {
            Log.Error("archive.apply-failed", ex);
            return (outcome, "导入的时候出错了：" + ex.GetType().Name);
        }
    }

    /// <summary>今天那份自动备份该写在哪；今天已经备过就返回 null。</summary>
    public static string? DailyPathIfMissing()
    {
        var path = Path.Combine(Folder, $"Kitty Tools 自动备份 {DateTime.Now:yyyy-MM-dd}.json");
        return File.Exists(path) ? null : path;
    }

    /// <summary>
    /// 每天一份自动备份（留 7 份），返回写好的路径。archive 要先在 UI 线程上 <see cref="Build"/> 好
    /// （REVIEW R47：剪贴板列表和翻译历史的库连接只许 UI 线程碰）；这里只序列化、写文件、轮换，可以在后台线程上调。
    /// </summary>
    public static string? WriteDaily(string path, SettingsArchive archive)
    {
        var written = WriteFile(path, Fitted(archive));
        if (written is not null)
        {
            Rotate(Folder, "Kitty Tools 自动备份 *.json", DailyKeep, written);
        }

        return written;
    }

    /// <summary>导入前另存一份（留 3 份）。</summary>
    public static string? BackupBeforeImport()
    {
        var path = Path.Combine(
            Folder, $"Kitty Tools 导入前 {DateTime.Now:yyyy-MM-dd HH.mm.ss}.json");
        var written = WriteFile(path, Fitted(Build(Enum.GetValues<ArchiveSection>(), password: null)));
        if (written is not null)
        {
            Rotate(Folder, "Kitty Tools 导入前 *.json", BeforeImportKeep, written);
        }

        return written;
    }

    /// <summary>自动备份的清单（新的在前）；pattern 是「Kitty Tools 自动备份 *.json」这类。</summary>
    public static List<string> BackupFiles(string pattern)
    {
        if (!Directory.Exists(Folder))
        {
            return new List<string>();
        }

        return Directory.EnumerateFiles(Folder, pattern)
            .OrderByDescending(path => Path.GetFileName(path), StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>轮换：留下最新的 keep 份（刚写的那份不删）。</summary>
    public static void Rotate(string folder, string pattern, int keep, string? written = null)
    {
        foreach (var file in ArchiveRotation.Expired(Directory.EnumerateFiles(folder, pattern), keep, written))
        {
            try
            {
                File.Delete(file);
            }
            catch (Exception ex)
            {
                Log.Warn($"archive.rotate-failed {ex.GetType().Name}");
            }
        }
    }

    /// <summary>备份用（每日一份、导入前一份）：整个文件超过上限时，先去掉编出来最大的那一类，还大再去掉次大的（同 mac「每天自动备份」；
    /// 便签加进来之后几千条长便签就可能超）。只记真去掉的（日志里只写类别名）。手动导出不走这里：超了由 ExportProblem 拦。</summary>
    public static SettingsArchive Fitted(SettingsArchive archive)
    {
        if (Encoding.UTF8.GetByteCount(Encode(archive)) <= SettingsArchive.MaxFileBytes)
        {
            return archive;
        }

        var parts = new List<(string Name, Func<int> Size, Action Drop)>
        {
            ("notes", () => archive.Notes is { Count: > 0 } notes ? notes.Sum(note => note.GetRawText().Length) : 0, () => archive.Notes = null),
            ("clips", () => archive.Clips is { Count: > 0 } clips ? clips.Sum(clip => (clip.Text?.Length ?? 0) + (clip.Note?.Length ?? 0)) : 0,
                () =>
                {
                    archive.Clips = null;
                    archive.ClipGroups = null;
                }),
            ("vocabulary", () => archive.Vocabulary is { Count: > 0 } words
                ? words.Sum(word => (word.Source?.Length ?? 0) + (word.Result?.Length ?? 0)) : 0, () => archive.Vocabulary = null),
        };
        foreach (var part in parts.OrderByDescending(part => part.Size()))
        {
            if (part.Size() == 0)
            {
                continue;
            }

            part.Drop();
            Log.Warn($"archive.backup-dropped kind={part.Name}");
            if (Encoding.UTF8.GetByteCount(Encode(archive)) <= SettingsArchive.MaxFileBytes)
            {
                break;
            }
        }

        return archive;
    }

    public static string? WriteFile(string path, SettingsArchive archive)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var text = Encode(archive);
            if (Encoding.UTF8.GetByteCount(text) > SettingsArchive.MaxFileBytes)
            {
                return null;
            }

            var temporary = path + ".tmp";
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            File.Move(temporary, path, overwrite: true);
            return path;
        }
        catch (Exception ex)
        {
            Log.Error("archive.write-failed", ex);
            return null;
        }
    }

    private static Dictionary<string, JsonElement> PreferencesOf(Settings settings)
    {
        // 只导用户能看懂、跨机器也说得通的那些（窗口位置、上次更新提示、登录项这些是这台机器的状态）。
        // 手写 JSON（AOT 下不用反射序列化）。
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("theme", settings.Theme);
            writer.WriteString("accent", settings.Accent);
            writer.WriteBoolean("autoCheckUpdates", settings.AutoCheckUpdates);
            writer.WriteBoolean("copyTranslate", settings.CopyTranslate);
            writer.WriteNumber("clipboardRetentionDays", settings.ClipboardRetentionDays);
            writer.WriteNumber("clipboardImageBudgetMB", settings.ClipboardImageBudgetMB);
            writer.WriteBoolean("clipboardBlockSensitive", settings.ClipboardBlockSensitive);
            writer.WriteStartArray("clipboardExcludedApps");
            foreach (var app in settings.ClipboardExcludedApps.Take(200))
            {
                writer.WriteStringValue(app);
            }

            writer.WriteEndArray();
            // PLAN-v17 H8：按应用停用快捷键。键名和 mac 的 hotKeyBlockedApps 分开（mac 存 bundle id，导进对方那边只会多出认不出的行）
            writer.WriteStartArray("hotKeyBlockedExes");
            foreach (var block in HotKeyBlock.List(settings.HotKeyBlockedApps))
            {
                writer.WriteStringValue(block.Entry);
            }

            writer.WriteEndArray();
            writer.WriteBoolean("hotKeyBlockFullscreen", settings.HotKeyBlockFullscreen);
            // PLAN-v18 S3：截图时的键（只存改过的；空串 = 清除了）。Windows 自己的键名，mac 的 shot.<名字> 认不出、照旧忽略
            // PLAN-v18 L2 L3：启动器「命令」表（只存改过的别名、关掉的、设了的快捷键）
            writer.WriteStartObject("launcherCommandAliases");
            foreach (var (id, alias) in settings.LauncherCommandAliases ?? new Dictionary<string, string>())
            {
                writer.WriteString(id, alias);
            }

            writer.WriteEndObject();
            writer.WriteStartArray("launcherCommandsOff");
            foreach (var id in settings.LauncherCommandsOff ?? new List<string>())
            {
                writer.WriteStringValue(id);
            }

            writer.WriteEndArray();
            // PLAN-v18 L5 / §6：应用别名、应用文件夹、隐藏的应用（「运行过的程序」开关只在本机，不导出）
            writer.WriteStartObject("launcherAppAliases");
            foreach (var (key, alias) in AppAliases.Sanitize(settings.LauncherAppAliases ?? new Dictionary<string, string>()))
            {
                writer.WriteString(key, alias);
            }

            writer.WriteEndObject();
            foreach (var (name, values) in new[] { ("launcherAppFolders", settings.LauncherAppFolders), ("launcherHiddenApps", settings.LauncherHiddenApps) })
            {
                writer.WriteStartArray(name);
                foreach (var value in (values ?? new List<string>()).Take(500))
                {
                    writer.WriteStringValue(value);
                }

                writer.WriteEndArray();
            }

            writer.WriteStartObject("launcherCommandHotKeys");
            foreach (var (id, text) in settings.LauncherCommandHotKeys ?? new Dictionary<string, string>())
            {
                writer.WriteString(id, text);
            }

            writer.WriteEndObject();
            writer.WriteStartObject("shotKeys");
            foreach (var (id, text) in ShotKeys.Sanitize(settings.ScreenshotKeys ?? new Dictionary<string, string>()))
            {
                writer.WriteString(id, text);
            }

            writer.WriteEndObject();
            writer.WriteString("translateFirstLanguage", settings.TranslateFirstLanguage);
            writer.WriteString("translateSecondLanguage", settings.TranslateSecondLanguage);
            writer.WriteBoolean("translateAutoCopy", settings.TranslateAutoCopy);
            // PLAN-v14 V8：朗读两项，键名和值同 mac Prefs（mac 注册了默认值，会导出）。
            writer.WriteBoolean("translateWordRecording", settings.TranslateWordRecording);
            writer.WriteString("translateWordAccent", settings.TranslateWordAccent == "uk" ? "uk" : "us");
            writer.WriteBoolean("ocrJoinLines", settings.OcrJoinLines);
            // PLAN-v12 N2 / N4：键名和值同 mac Prefs（clipboardPanelPosition、launcherPanelPosition、screenshotToolbarAlign）。
            writer.WriteString("clipboardPanelPosition", settings.ClipboardPanelPosition);
            writer.WriteString("launcherPanelPosition", settings.LauncherPanelPosition);
            writer.WriteBoolean("launcherShowsFrequent", settings.LauncherShowsFrequent); // PLAN-v16 L1，键名同 mac
            writer.WriteString("screenshotToolbarAlign", settings.ScreenshotToolbarAlign);
            writer.WriteString("screenshotCopyAs", settings.ScreenshotCopyAs); // PLAN-v15，键名和值同 mac
            // PLAN-v16 S1 / S2，键名同 mac
            writer.WriteBoolean("translateScreenshotOverlay", settings.TranslateScreenshotOverlay);
            writer.WriteBoolean("screenshotKeepsColors", settings.ScreenshotKeepsColors);
            // PLAN-v12 N5 状态屏：同 mac Prefs（状态列表是一组对象，导入时按 id 并进本机的、不删本机独有的）。
            writer.WriteBoolean("statusScreenExitHint", settings.StatusScreenExitHint);
            writer.WriteBoolean("statusScreenHotKeyEntersFirst", settings.StatusScreenHotKeyEntersFirst);
            writer.WriteBoolean("statusScreenAnimations", settings.StatusScreenAnimations);
            // PLAN-v20 K1 保持唤醒：键名和写法同 mac（定时是一段 JSON 文字）
            writer.WriteBoolean("keepAwakeDisplay", settings.KeepAwakeDisplay);
            writer.WriteString("keepAwakeSchedule", settings.KeepAwakeSchedule ?? string.Empty);
            if (settings.StatusScreenPresets is { } presets)
            {
                writer.WriteStartArray("statusScreenPresets");
                foreach (var preset in StatusPresets.Sanitized(presets))
                {
                    StatusPresets.Write(writer, preset);
                }

                writer.WriteEndArray();
            }

            // PLAN-v12 N6 提醒：同 mac Prefs.reminders（时刻写 ISO 8601，同 mac 导出的 .iso8601）、remindersSnoozeMinutes。
            // 处理到哪一刻、推到几点（RemindersState）是这台电脑自己的，不导出。
            writer.WriteNumber("remindersSnoozeMinutes", settings.RemindersSnoozeMinutes);
            if (settings.Reminders is { } reminders)
            {
                writer.WriteStartArray("reminders");
                foreach (var reminder in Reminders.Sanitized(reminders))
                {
                    Reminders.WriteArchive(writer, reminder);
                }

                writer.WriteEndArray();
            }

            writer.WriteEndObject();
        }

        using var document = JsonDocument.Parse(stream.ToArray());
        return document.RootElement.EnumerateObject()
            .ToDictionary(property => property.Name, property => property.Value.Clone());
    }

    private static void ApplyPreferences(Dictionary<string, JsonElement>? preferences)
    {
        if (preferences is null)
        {
            return;
        }

        var settings = SettingsService.Current;
        foreach (var (key, value) in preferences)
        {
            switch (key)
            {
                case "theme" when value.ValueKind == JsonValueKind.String:
                    settings.Theme = value.GetString() ?? settings.Theme;
                    break;
                case "accent" when value.ValueKind == JsonValueKind.String:
                    settings.Accent = value.GetString() ?? settings.Accent;
                    break;
                case "autoCheckUpdates" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.AutoCheckUpdates = value.GetBoolean();
                    break;
                case "copyTranslate" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.CopyTranslate = value.GetBoolean();
                    break;
                case "clipboardRetentionDays" when value.ValueKind == JsonValueKind.Number:
                    settings.ClipboardRetentionDays = value.GetInt32();
                    break;
                case "clipboardImageBudgetMB" when value.ValueKind == JsonValueKind.Number:
                    settings.ClipboardImageBudgetMB = value.GetInt32();
                    break;
                case "clipboardBlockSensitive" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.ClipboardBlockSensitive = value.GetBoolean();
                    break;
                case "clipboardExcludedApps" when value.ValueKind == JsonValueKind.Array:
                    settings.ClipboardExcludedApps = value.EnumerateArray()
                        .Where(item => item.ValueKind == JsonValueKind.String)
                        .Select(item => item.GetString()!)
                        .Take(200)
                        .ToList();
                    break;
                case "hotKeyBlockedExes" when value.ValueKind == JsonValueKind.Array:
                    settings.HotKeyBlockedApps = HotKeyBlock.List(value.EnumerateArray()
                            .Where(item => item.ValueKind == JsonValueKind.String)
                            .Select(item => item.GetString()!))
                        .Select(block => block.Entry)
                        .ToList();
                    break;
                case "hotKeyBlockFullscreen" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.HotKeyBlockFullscreen = value.GetBoolean();
                    break;
                case "launcherCommandAliases" when value.ValueKind == JsonValueKind.Object:
                    var aliases = value.EnumerateObject()
                        .Where(property => property.Value.ValueKind == JsonValueKind.String &&
                                           property.Value.GetString()!.Length <= LauncherCommandTable.AliasLimit)
                        .Take(500)
                        .ToDictionary(property => property.Name, property => property.Value.GetString()!);
                    settings.LauncherCommandAliases = aliases.Count == 0 ? null : aliases;
                    break;
                case "launcherCommandsOff" when value.ValueKind == JsonValueKind.Array:
                    var off = value.EnumerateArray()
                        .Where(item => item.ValueKind == JsonValueKind.String && item.GetString()!.Length is > 0 and < 600)
                        .Select(item => item.GetString()!)
                        .Take(500)
                        .ToList();
                    settings.LauncherCommandsOff = off.Count == 0 ? null : off;
                    break;
                case "launcherAppAliases" when value.ValueKind == JsonValueKind.Object:
                    var appAliases = AppAliases.Sanitize(value.EnumerateObject()
                        .Where(property => property.Value.ValueKind == JsonValueKind.String)
                        .Select(property => new KeyValuePair<string, string>(property.Name, property.Value.GetString()!)));
                    settings.LauncherAppAliases = appAliases.Count == 0 ? null : appAliases;
                    break;
                case "launcherAppFolders" or "launcherHiddenApps" when value.ValueKind == JsonValueKind.Array:
                    var paths = value.EnumerateArray()
                        .Where(item => item.ValueKind == JsonValueKind.String && item.GetString()!.Length is > 0 and < 1024)
                        .Select(item => item.GetString()!)
                        .Take(500)
                        .ToList();
                    if (key == "launcherAppFolders")
                    {
                        settings.LauncherAppFolders = paths.Count == 0 ? null : paths;
                    }
                    else
                    {
                        settings.LauncherHiddenApps = paths.Count == 0 ? null : paths;
                    }

                    break;
                case "launcherCommandHotKeys" when value.ValueKind == JsonValueKind.Object:
                    var commandKeys = value.EnumerateObject()
                        .Where(property => property.Value.ValueKind == JsonValueKind.String &&
                                           HotKeyRules.TryParse(property.Value.GetString()!, out var key, out var modifiers) &&
                                           HotKeyRules.Validate(key, modifiers).Ok && !HotKeyRules.IsDoubleTap(key, modifiers))
                        .Take(500)
                        .ToDictionary(property => property.Name, property => property.Value.GetString()!);
                    settings.LauncherCommandHotKeys = commandKeys.Count == 0 ? null : commandKeys;
                    break;
                case "shotKeys" when value.ValueKind == JsonValueKind.Object:
                    var shotKeys = ShotKeys.Sanitize(value.EnumerateObject()
                        .Where(property => property.Value.ValueKind == JsonValueKind.String)
                        .Select(property => new KeyValuePair<string, string>(property.Name, property.Value.GetString()!)));
                    settings.ScreenshotKeys = shotKeys.Count == 0 ? null : shotKeys;
                    break;
                case "translateFirstLanguage" when value.ValueKind == JsonValueKind.String:
                    settings.TranslateFirstLanguage = value.GetString();
                    break;
                case "translateSecondLanguage" when value.ValueKind == JsonValueKind.String:
                    settings.TranslateSecondLanguage = value.GetString();
                    break;
                case "translateAutoCopy" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.TranslateAutoCopy = value.GetBoolean();
                    break;
                case "ocrJoinLines" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.OcrJoinLines = value.GetBoolean();
                    break;
                case "translateWordRecording" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.TranslateWordRecording = value.GetBoolean();
                    break;
                case "translateWordAccent" when value.ValueKind == JsonValueKind.String && value.GetString() is "us" or "uk":
                    settings.TranslateWordAccent = value.GetString()!;
                    break;
                case "clipboardPanelPosition" when value.ValueKind == JsonValueKind.String && value.GetString() is "top" or "mouse" or "last":
                    settings.ClipboardPanelPosition = value.GetString()!;
                    break;
                case "launcherPanelPosition" when value.ValueKind == JsonValueKind.String && value.GetString() is "top" or "mouse" or "last":
                    settings.LauncherPanelPosition = value.GetString()!;
                    break;
                case "launcherShowsFrequent" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.LauncherShowsFrequent = value.GetBoolean();
                    break;
                case "screenshotToolbarAlign" when value.ValueKind == JsonValueKind.String && value.GetString() is "right" or "center":
                    settings.ScreenshotToolbarAlign = value.GetString()!;
                    break;
                case "screenshotCopyAs" when value.ValueKind == JsonValueKind.String && value.GetString() is "image" or "file":
                    settings.ScreenshotCopyAs = value.GetString()!;
                    break;
                case "translateScreenshotOverlay" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.TranslateScreenshotOverlay = value.GetBoolean();
                    break;
                case "screenshotKeepsColors" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.ScreenshotKeepsColors = value.GetBoolean();
                    break;
                case "statusScreenExitHint" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.StatusScreenExitHint = value.GetBoolean();
                    break;
                case "statusScreenHotKeyEntersFirst" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.StatusScreenHotKeyEntersFirst = value.GetBoolean();
                    break;
                case "statusScreenAnimations" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.StatusScreenAnimations = value.GetBoolean();
                    break;
                case "keepAwakeDisplay" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    settings.KeepAwakeDisplay = value.GetBoolean();
                    break;
                case "keepAwakeSchedule" when value.ValueKind == JsonValueKind.String:
                    // 读一遍再存规范的写法（越界的夹回来）；空的 = 默认
                    settings.KeepAwakeSchedule = value.GetString() is { Length: > 0 } schedule
                        ? KeepAwakeSchedule.Decode(schedule).Encode()
                        : null;
                    break;
                case "remindersSnoozeMinutes" when value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var snooze) &&
                                                   Reminders.SnoozeChoices.Contains(snooze):
                    settings.RemindersSnoozeMinutes = snooze;
                    break;
                case "reminders":
                    // 按 id 更新和添加、本机独有的不删；文件里本机没有、时间已经过了的一次性提醒不加（mac Reminder.merged）。
                    // 本机没存过（还是示例）时直接用文件里的，不把示例并进去（mac `list ?? incoming`）。
                    if (Reminders.ReadList(value) is { } incomingReminders && Reminders.Sanitized(incomingReminders).Count > 0)
                    {
                        settings.Reminders = settings.Reminders is { } localReminders
                            ? Reminders.Merged(incomingReminders, Reminders.Sanitized(localReminders), DateTime.UtcNow)
                            : Reminders.Sanitized(incomingReminders);
                    }

                    break;
                case "statusScreenPresets":
                    // 用户自己写的东西：按 id 更新和添加、本机独有的不删（mac StatusPreset.merged）；有一个解不出整组不导。
                    // 本机没存过（还是自带的三个）时直接用文件里的（mac `list ?? incoming`）。
                    if (StatusPresets.ReadList(value) is { } incoming && StatusPresets.Sanitized(incoming).Count > 0)
                    {
                        settings.StatusScreenPresets = settings.StatusScreenPresets is null
                            ? StatusPresets.Sanitized(incoming)
                            : StatusPresets.Merged(incoming, StatusPresets.Load(settings.StatusScreenPresets));
                    }

                    break;
            }
        }

        SettingsService.Save();
        Theme.ApplyAccent();
    }

    private static void ApplyHotkeys(Dictionary<string, string?>? hotkeys)
    {
        if (hotkeys is null)
        {
            return;
        }

        var settings = SettingsService.Current;
        foreach (var (action, text) in hotkeys)
        {
            if (SettingsDefaults.Find(action) is null)
            {
                continue;
            }

            if (string.IsNullOrWhiteSpace(text) ||
                !HotKeyRules.TryParse(text, out var key, out var modifiers))
            {
                SettingsDefaults.SetBinding(settings, action, new HotKeyBinding(0, HotKeyModifiers.None));
                continue;
            }

            SettingsDefaults.SetBinding(settings, action, new HotKeyBinding(key, modifiers));
        }

        SettingsService.Save();
        ShellRuntime.Instance?.HotKeys.RegisterAll(settings);
        // 导入的停用名单当场按此刻的前台生效
        HotKeyBlocker.Refresh();
    }

    private static void ApplyEngines(List<SettingsArchive.ArchiveEngine> engines, ArchiveOutcome outcome)
    {
        var settings = SettingsService.Current;
        var current = settings.LauncherSearchEngines ?? WebSearch.Defaults();
        foreach (var entry in engines)
        {
            var existing = current.FirstOrDefault(engine => engine.Id == entry.Id);
            if (existing is null)
            {
                current.Add(new SearchEngine
                {
                    Id = entry.Id!,
                    Name = entry.Name ?? entry.Id!,
                    Keyword = entry.Keyword ?? string.Empty,
                    UrlTemplate = entry.Url!,
                    Fallback = entry.Fallback == true,
                });
                outcome.EnginesAdded++;
            }
            else
            {
                existing.Name = entry.Name ?? existing.Name;
                existing.Keyword = entry.Keyword ?? existing.Keyword;
                existing.UrlTemplate = entry.Url ?? existing.UrlTemplate;
                existing.Fallback = entry.Fallback ?? existing.Fallback;
            }
        }

        settings.LauncherSearchEngines = current;
        SettingsService.Save();
    }

    private static Dictionary<string, string> SecretsOf(List<SettingsArchive.ArchiveService> services)
    {
        var secrets = new Dictionary<string, string>();
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            return secrets;
        }

        foreach (var entry in services)
        {
            if (store.Find(entry.Id!) is not { } service)
            {
                continue;
            }

            foreach (var field in TranslateKinds.SecretFields(service.Kind))
            {
                if (store.Secret(service, field) is { } value)
                {
                    secrets[$"{service.Id}.{field}"] = value;
                }
            }
        }

        return secrets;
    }

    private static void ApplySecrets(
        Dictionary<string, string> secrets, List<SettingsArchive.ArchiveService> services)
    {
        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            return;
        }

        foreach (var entry in services)
        {
            if (store.Find(entry.Id!) is not { } service)
            {
                continue;
            }

            foreach (var field in TranslateKinds.SecretFields(service.Kind))
            {
                if (secrets.TryGetValue($"{service.Id}.{field}", out var value) &&
                    !string.IsNullOrEmpty(value) && value.Length <= 4096)
                {
                    store.SetSecret(service, value, field);
                }
            }
        }
    }
}

/// <summary>能分开勾选的七类（PLAN-v13 加了便签）。</summary>
internal enum ArchiveSection
{
    Preferences,
    Hotkeys,
    Services,
    Engines,
    Clips,
    Vocabulary,
    Notes,
}
