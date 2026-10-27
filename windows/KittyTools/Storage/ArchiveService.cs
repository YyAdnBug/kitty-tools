// 导出 / 导入的执行层（第三版 §2.2）：把设置、翻译服务、网页搜索、片段与收藏、生词本装进 SettingsArchive，
// 以及反过来把文件合并回本机。读文件当成不可信输入（Core 里 Sanitized 过一遍），密钥走 Core 的 ArchiveCrypto。
// 自动备份：每天一份「Kitty Tools 自动备份 日期.json」（留 7 份），导入前另存一份（留 3 份）——和 mac 的
// Storage/SettingsBackup 同一个规矩，放在数据目录的 backups\ 里（和数据库备份同一个文件夹，文件名不同）。
using System.Text;
using System.Text.Json;
using KittyTools.Core;
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
}

internal static class ArchiveService
{
    public const int DailyKeep = 7;

    public const int BeforeImportKeep = 3;

    /// <summary>导出文件所在的地方（自动备份也在这里）。</summary>
    public static string Folder => Path.Combine(Paths.DataDirectory, BackupPlan.FolderName);

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
                .Where(entry => entry.Kind == ClipKind.Text && entry.Favorite)
                .Take(SettingsArchive.MaxClips)
                .Select(entry => new SettingsArchive.ArchiveClip
                {
                    Text = entry.Text,
                    Note = entry.Note,
                    Favorite = true,
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
                        clip.Group)).ToList());
                outcome.ClipsAdded = added;
                outcome.ClipsUpdated = updated;
            }

            if (archive.Vocabulary is { Count: > 0 } words && TranslationHistory.Instance is { } vocabulary)
            {
                outcome.WordsAdded = vocabulary.AdoptFavorites(words);
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
        var written = WriteFile(path, archive);
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
        var written = WriteFile(path, Build(Enum.GetValues<ArchiveSection>(), password: null));
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
            writer.WriteString("translateFirstLanguage", settings.TranslateFirstLanguage);
            writer.WriteString("translateSecondLanguage", settings.TranslateSecondLanguage);
            writer.WriteBoolean("translateAutoCopy", settings.TranslateAutoCopy);
            writer.WriteBoolean("ocrJoinLines", settings.OcrJoinLines);
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

/// <summary>能分开勾选的六类（Windows 这边只有六类，没有便签）。</summary>
internal enum ArchiveSection
{
    Preferences,
    Hotkeys,
    Services,
    Engines,
    Clips,
    Vocabulary,
}
