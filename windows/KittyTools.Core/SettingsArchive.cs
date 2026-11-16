// 设置与数据的导出 / 导入（第三版 §2.2，格式跟 mac 的 Storage/SettingsArchive.swift 的 format 2 通用）：
// 一个 JSON 文件，按类别分开（设置 / 快捷键 / 翻译服务 / 网页搜索 / 片段与收藏 / 生词本 / 便签）。
// 便签（PLAN-v13，mac 第七类 NoteEntry）：一条一个对象，读的时候宽松（只丢写坏的那一条，Notes.NoteEntry.Sanitized），所以存成原样的 JsonElement。
// 两边互相读得了（REVIEW R80–R82、R85，2026-11-15）：
// - 写 mac 的必填字段：version、exportedAt（ISO 8601、到秒、带 Z）；服务写 isEnabled，搜索写 urlTemplate / enabled；
//   片段、生词的时间同样到秒带 Z（mac 的 .iso8601 不认小数秒）。读的时候新旧两种名字都认（旧的 Windows 文件写 enabled、url / fallback）。
// - Windows 的设置和快捷键写进 windowsPreferences / windowsHotkeys：mac 不认识这两个键、整个忽略，不会出「设置」「快捷键」的勾
//   （mac 导这两类是整类替换，Windows 的写进 preferences / hotkeys 会清掉 Mac 独有的设置和全部自定义快捷键）。
//   旧的 Windows 文件（platform = windows、只有 preferences / hotkeys）照旧当 Windows 的读。
// - mac 的 preferences 只拿 statusScreenPresets、reminders 两个键（按 id 合并进本机），别的 mac 设置照旧不导；
//   mac 的 hotkeys（{keyCode, modifiers} 对象）读得进来但不导（两边的键和默认不一样，同 PLAN-v21 快捷键只在 Windows 之间同步）。
// - 片段、收藏、生词本是**合并**：同样的正文不重复加，只补标记；不删本机已有的。
// - 密钥默认不带；要带就设密码：PBKDF2-HMAC-SHA256（600000 轮，16 字节盐）→ AES-256-GCM，
//   附加校验数据是各服务的「id、种类、协议、地址、走不走 DeepLX」，参数和 mac 一字不差，两边的文件才能互相解开。
// 读文件当成不可信输入：不认识的、类型不对的、超出范围的项都丢掉；条数有上限（同 mac：收藏夹 200、条目 5000）。
using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KittyTools.Core;

public sealed class SettingsArchive
{
    public const string Marker = "Kitty Tools";

    /// <summary>mac format 2（加了便签那一版）。</summary>
    public const int CurrentFormat = 2;

    public const string WindowsPlatform = "windows";

    public const int MaxClips = 5000;

    public const int MaxGroups = 200;

    public const int MaxWords = 20_000;

    public const int MinPasswordLength = 8;

    public const int MaxFileBytes = 32 << 20;

    /// <summary>mac 的偏好里 Windows 也认的两个键（R82）：按 id 合并的状态列表、提醒列表。</summary>
    public static readonly IReadOnlyList<string> MacListKeys = new[] { "statusScreenPresets", "reminders" };

    [JsonPropertyName("app")]
    public string App { get; set; } = Marker;

    [JsonPropertyName("format")]
    public int Format { get; set; } = CurrentFormat;

    /// <summary>导出时的 App 版本（mac 必填，只给人看）。</summary>
    [JsonPropertyName("version")]
    public string? Version { get; set; }

    /// <summary>导出的时刻（mac 必填，ISO 8601 到秒带 Z）。</summary>
    [JsonPropertyName("exportedAt")]
    [JsonConverter(typeof(ArchiveDateConverter))]
    public DateTimeOffset? ExportedAt { get; set; }

    /// <summary>Windows 导出的文件带这个字段；Mac 的文件没有。</summary>
    [JsonPropertyName("platform")]
    public string? Platform { get; set; }

    /// <summary>mac 的设置（只认 <see cref="MacListKeys"/>）；旧的 Windows 文件也写在这里。</summary>
    [JsonPropertyName("preferences")]
    public Dictionary<string, JsonElement>? Preferences { get; set; }

    /// <summary>mac 的快捷键（{keyCode, modifiers} 对象或 null）；旧的 Windows 文件写的是「Alt+C」字符串。</summary>
    [JsonPropertyName("hotkeys")]
    public Dictionary<string, JsonElement>? Hotkeys { get; set; }

    /// <summary>Windows 的设置（R80：mac 不认识这个键，导入 Mac 时不碰 Mac 的设置）。</summary>
    [JsonPropertyName("windowsPreferences")]
    public Dictionary<string, JsonElement>? WindowsPreferences { get; set; }

    /// <summary>Windows 的快捷键：动作 → 「Alt+C」，null / 空 = 清除了。</summary>
    [JsonPropertyName("windowsHotkeys")]
    public Dictionary<string, string?>? WindowsHotkeys { get; set; }

    [JsonPropertyName("translateServices")]
    public List<ArchiveService>? TranslateServices { get; set; }

    [JsonPropertyName("searchEngines")]
    public List<ArchiveEngine>? SearchEngines { get; set; }

    [JsonPropertyName("clips")]
    public List<ArchiveClip>? Clips { get; set; }

    [JsonPropertyName("clipGroups")]
    public List<string>? ClipGroups { get; set; }

    [JsonPropertyName("vocabulary")]
    public List<ArchiveWord>? Vocabulary { get; set; }

    [JsonPropertyName("secrets")]
    public ArchiveSecrets? Secrets { get; set; }

    /// <summary>便签（没删的，含归档）：null = 这一类不在文件里（便签这次用不了时也是 null，不写一份空的把带着便签的备份顶掉）。</summary>
    [JsonPropertyName("notes")]
    public List<JsonElement>? Notes { get; set; }

    private bool IsWindowsFile => string.Equals(Platform, WindowsPlatform, StringComparison.OrdinalIgnoreCase);

    /// <summary>要导的 Windows 设置：windowsPreferences；旧的 Windows 文件是 preferences。Mac 的文件没有。</summary>
    [JsonIgnore]
    public Dictionary<string, JsonElement>? WindowsSettings => WindowsPreferences ?? (IsWindowsFile ? Preferences : null);

    /// <summary>要导的 Windows 快捷键：windowsHotkeys；旧的 Windows 文件是 hotkeys 里的字符串。Mac 的文件没有。</summary>
    [JsonIgnore]
    public Dictionary<string, string?>? WindowsKeys
        => WindowsHotkeys ?? (IsWindowsFile && Hotkeys is { } legacy
            ? legacy.Where(pair => pair.Value.ValueKind is JsonValueKind.String or JsonValueKind.Null)
                .ToDictionary(pair => pair.Key, pair => pair.Value.ValueKind == JsonValueKind.String ? pair.Value.GetString() : null)
            : null);

    /// <summary>Mac 文件里的状态列表、提醒列表（R82）；Windows 的文件不走这里（在 <see cref="WindowsSettings"/> 里）。</summary>
    [JsonIgnore]
    public Dictionary<string, JsonElement>? MacLists
        => !IsWindowsFile && Preferences is { } preferences && preferences.Keys.Intersect(MacListKeys).Any()
            ? preferences.Where(pair => MacListKeys.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value)
            : null;

    /// <summary>「设置」「快捷键」两类有没有要导的 Windows 的那份。</summary>
    [JsonIgnore]
    public bool AppliesWindowsSettings => WindowsSettings is not null || WindowsKeys is not null;

    public sealed class ArchiveService
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("kind")]
        public string? Kind { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        /// <summary>开没开（mac 的键名，mac 必填）。</summary>
        [JsonPropertyName("isEnabled")]
        public bool? IsEnabled { get; set; }

        /// <summary>旧的 Windows 文件写的键名，只读。</summary>
        [JsonPropertyName("enabled")]
        public bool? Enabled { get; set; }

        [JsonPropertyName("model")]
        public string? Model { get; set; }

        [JsonPropertyName("baseURL")]
        public string? BaseUrl { get; set; }

        [JsonPropertyName("aiProtocol")]
        public string? AiProtocol { get; set; }

        [JsonPropertyName("region")]
        public string? Region { get; set; }

        [JsonPropertyName("usesDeepLX")]
        public bool? UsesDeepLX { get; set; }

        /// <summary>文件里写的开关（isEnabled，没有退回 enabled；都没有 = null）。</summary>
        [JsonIgnore]
        public bool? On => IsEnabled ?? Enabled;
    }

    public sealed class ArchiveEngine
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("keyword")]
        public string? Keyword { get; set; }

        /// <summary>网址（mac 的键名）：有 {query} 是搜索，没有是快捷链接。</summary>
        [JsonPropertyName("urlTemplate")]
        public string? UrlTemplate { get; set; }

        /// <summary>没有本地结果时兜底（mac 的键名）。</summary>
        [JsonPropertyName("enabled")]
        public bool? Enabled { get; set; }

        /// <summary>旧的 Windows 文件写的键名，只读。</summary>
        [JsonPropertyName("url")]
        public string? Url { get; set; }

        /// <summary>旧的 Windows 文件写的键名，只读。</summary>
        [JsonPropertyName("fallback")]
        public bool? Fallback { get; set; }

        [JsonIgnore]
        public string? Template => UrlTemplate ?? Url;

        [JsonIgnore]
        public bool? IsFallback => Enabled ?? Fallback;
    }

    public sealed class ArchiveClip
    {
        [JsonPropertyName("text")]
        public string? Text { get; set; }

        [JsonPropertyName("note")]
        public string? Note { get; set; }

        [JsonPropertyName("favorite")]
        public bool? Favorite { get; set; }

        [JsonPropertyName("snippet")]
        public bool? Snippet { get; set; }

        /// <summary>所在收藏夹的名字（导出时用名字，导进来按名字对）。</summary>
        [JsonPropertyName("group")]
        public string? Group { get; set; }

        [JsonPropertyName("copiedAt")]
        [JsonConverter(typeof(ArchiveDateConverter))]
        public DateTimeOffset? CopiedAt { get; set; }
    }

    public sealed class ArchiveWord
    {
        [JsonPropertyName("source")]
        public string? Source { get; set; }

        [JsonPropertyName("target")]
        public string? Target { get; set; }

        [JsonPropertyName("result")]
        public string? Result { get; set; }

        [JsonPropertyName("service")]
        public string? Service { get; set; }

        [JsonPropertyName("createdAt")]
        [JsonConverter(typeof(ArchiveDateConverter))]
        public DateTimeOffset? CreatedAt { get; set; }
    }

    public sealed class ArchiveSecrets
    {
        [JsonPropertyName("kdf")]
        public string Kdf { get; set; } = "pbkdf2-hmac-sha256";

        [JsonPropertyName("rounds")]
        public int Rounds { get; set; }

        [JsonPropertyName("salt")]
        public string? Salt { get; set; }

        /// <summary>AES-256-GCM 的 combined（随机数 12 字节 + 密文 + 校验 16 字节），base64。</summary>
        [JsonPropertyName("sealed")]
        public string? Sealed { get; set; }
    }

    /// <summary>读文件时把不认识 / 超出范围的项丢掉（返回清理过的副本，不改原对象）。</summary>
    public SettingsArchive Sanitized()
    {
        var copy = new SettingsArchive
        {
            App = App,
            Format = Format,
            Version = Version,
            ExportedAt = ExportedAt,
            Platform = Platform,
            Preferences = Preferences,
            WindowsPreferences = WindowsPreferences,
            Notes = Notes,
            Hotkeys = Hotkeys?
                .Where(pair => pair.Key.Length is > 0 and < 200)
                .ToDictionary(pair => pair.Key, pair => pair.Value),
            WindowsHotkeys = WindowsHotkeys?
                .Where(pair => pair.Key.Length is > 0 and < 200 && (pair.Value is null || pair.Value.Length < 200))
                .ToDictionary(pair => pair.Key, pair => pair.Value),
            Secrets = Secrets,
        };

        if (TranslateServices is not null)
        {
            copy.TranslateServices = TranslateServices
                .Where(service => !string.IsNullOrWhiteSpace(service.Id) &&
                                  service.Id.Length <= 100 &&
                                  !string.IsNullOrWhiteSpace(service.Kind) &&
                                  service.Kind.Length <= 40)
                .Take(200)
                .ToList();
        }

        // 快捷链接（没有 {query}）也收（R82：原来要求必须有 {query}，连自己导出的快捷链接都筛掉了）
        if (SearchEngines is not null)
        {
            copy.SearchEngines = SearchEngines
                .Where(engine => !string.IsNullOrWhiteSpace(engine.Id) &&
                                 engine.Id.Length <= 100 &&
                                 engine.Template is { Length: > 0 and <= 4000 } template &&
                                 !string.IsNullOrWhiteSpace(template))
                .Take(MaxGroups)
                .ToList();
        }

        if (Clips is not null)
        {
            copy.Clips = Clips
                .Where(clip => clip.Text is { Length: > 0 and <= 5_000_000 })
                .Take(MaxClips)
                .ToList();
        }

        if (ClipGroups is not null)
        {
            copy.ClipGroups = ClipGroups
                .Where(name => !string.IsNullOrWhiteSpace(name) && name.Trim().Length <= 24)
                .Select(name => name.Trim())
                .Distinct(StringComparer.Ordinal)
                .Take(MaxGroups)
                .ToList();
        }

        if (Vocabulary is not null)
        {
            copy.Vocabulary = Vocabulary
                .Where(word => word.Source is { Length: > 0 and <= 100_000 } &&
                               word.Target is { Length: > 0 and <= 40 } &&
                               word.Result is { Length: > 0 and <= 5_000_000 })
                .Take(MaxWords)
                .ToList();
        }

        return copy;
    }

    /// <summary>为什么读不了（mac SettingsArchive.Failure 的三句）。</summary>
    public enum ReadFailure
    {
        None,
        NotArchive,
        Newer,
        Unreadable,
    }

    public static string FailureText(ReadFailure failure) => failure switch
    {
        ReadFailure.Newer => "这个文件来自更新版本的 Kitty Tools，先更新再导入",
        ReadFailure.Unreadable => "文件读不出来：可能被改动过，或者来自更新版本的 Kitty Tools",
        _ => "这不是 Kitty Tools 导出的设置文件",
    };

    /// <summary>读一份导出 / 备份文件（R85：格式比自己新时单独说「先更新」，同 mac）。读出来的已经 <see cref="Sanitized"/> 过。</summary>
    public static (SettingsArchive? Archive, ReadFailure Failure) Read(string text)
    {
        // 先只看标记和格式：格式更新的文件里可能有这一版解不了的东西，那时要说「先更新」而不是「读不出」
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("app", out var app) || app.ValueKind != JsonValueKind.String ||
                !string.Equals(app.GetString(), Marker, StringComparison.Ordinal))
            {
                return (null, ReadFailure.NotArchive);
            }

            if (root.TryGetProperty("format", out var format) && format.ValueKind == JsonValueKind.Number &&
                format.TryGetInt32(out var number) && number > CurrentFormat)
            {
                return (null, ReadFailure.Newer);
            }
        }
        catch (JsonException)
        {
            return (null, ReadFailure.NotArchive);
        }

        try
        {
            var archive = JsonSerializer.Deserialize(text, ArchiveJsonContext.Default.SettingsArchive);
            return archive is null || archive.Format < 1 ? (null, ReadFailure.Unreadable) : (archive.Sanitized(), ReadFailure.None);
        }
        catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException)
        {
            return (null, ReadFailure.Unreadable);
        }
    }

    /// <summary>写成文件的文字（R85：中文、表情原样写，不转成 \uXXXX）。</summary>
    public static string Write(SettingsArchive archive) => JsonSerializer.Serialize(archive, ArchiveJsonContext.Relaxed.SettingsArchive);
}

/// <summary>时刻写 ISO 8601、到秒、带 Z（同 mac 的 .iso8601；mac 不认小数秒）；读时什么写法都认。</summary>
public sealed class ArchiveDateConverter : JsonConverter<DateTimeOffset?>
{
    public static string Format(DateTimeOffset value)
        => value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return null;
        }

        if (reader.TokenType == JsonTokenType.String &&
            DateTimeOffset.TryParse(reader.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value))
        {
            return value;
        }

        throw new JsonException("时间的写法不对");
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is { } moment)
        {
            writer.WriteStringValue(Format(moment));
        }
        else
        {
            writer.WriteNullValue();
        }
    }
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.Unspecified,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(SettingsArchive))]
public sealed partial class ArchiveJsonContext : JsonSerializerContext
{
    private static ArchiveJsonContext? _relaxed;

    /// <summary>写文件用：中文、表情不转义（只用在写文件这一处，R85）。</summary>
    public static ArchiveJsonContext Relaxed => _relaxed ??= new ArchiveJsonContext(new JsonSerializerOptions
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    });
}
