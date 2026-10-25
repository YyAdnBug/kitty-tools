// 设置与数据的导出 / 导入（第三版 §2.2，格式跟 mac 的 Storage/SettingsArchive.swift 的 format 2 通用）：
// 一个 JSON 文件，按类别分开（设置 / 快捷键 / 翻译服务 / 网页搜索 / 片段与收藏 / 生词本）。
// - Windows 导出的文件多写一个 "platform": "windows"；导入时没有这个字段（Mac 导出的）或值不是 windows 的，
//   跳过「设置」「快捷键」两类，其余照导（两边的设置和快捷键含义不一样）。
// - 片段、收藏、生词本是**合并**：同样的正文不重复加，只补标记；不删本机已有的。
// - 密钥默认不带；要带就设密码：PBKDF2-HMAC-SHA256（600000 轮，16 字节盐）→ AES-256-GCM，
//   附加校验数据是各服务的「id、种类、协议、地址、走不走 DeepLX」，参数和 mac 一字不差，两边的文件才能互相解开。
// 读文件当成不可信输入：不认识的、类型不对的、超出范围的项都丢掉；条数有上限（同 mac：收藏夹 200、条目 5000）。
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KittyTools.Core;

public sealed class SettingsArchive
{
    public const string Marker = "Kitty Tools";

    /// <summary>mac format 2（加了便签那一版；Windows 没有便签，只是写同一个格式号）。</summary>
    public const int CurrentFormat = 2;

    public const string WindowsPlatform = "windows";

    public const int MaxClips = 5000;

    public const int MaxGroups = 200;

    public const int MaxWords = 20_000;

    public const int MinPasswordLength = 8;

    public const int MaxFileBytes = 32 << 20;

    [JsonPropertyName("app")]
    public string App { get; set; } = Marker;

    [JsonPropertyName("format")]
    public int Format { get; set; } = CurrentFormat;

    /// <summary>Windows 导出的文件带这个字段；Mac 的文件没有。</summary>
    [JsonPropertyName("platform")]
    public string? Platform { get; set; }

    [JsonPropertyName("preferences")]
    public Dictionary<string, JsonElement>? Preferences { get; set; }

    [JsonPropertyName("hotkeys")]
    public Dictionary<string, string?>? Hotkeys { get; set; }

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

    /// <summary>「设置」「快捷键」只有 Windows 导出的文件才导（mac 那边的含义不一样）。</summary>
    public bool AppliesWindowsSettings
        => string.Equals(Platform, WindowsPlatform, StringComparison.OrdinalIgnoreCase);

    public sealed class ArchiveService
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("kind")]
        public string? Kind { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

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
    }

    public sealed class ArchiveEngine
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("name")]
        public string? Name { get; set; }

        [JsonPropertyName("keyword")]
        public string? Keyword { get; set; }

        [JsonPropertyName("url")]
        public string? Url { get; set; }

        [JsonPropertyName("fallback")]
        public bool? Fallback { get; set; }
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
            Platform = Platform,
            Preferences = Preferences,
            Hotkeys = Hotkeys is null
                ? null
                : Hotkeys
                    .Where(pair => pair.Key.Length is > 0 and < 200 &&
                                   (pair.Value is null || pair.Value.Length < 200))
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

        if (SearchEngines is not null)
        {
            copy.SearchEngines = SearchEngines
                .Where(engine => !string.IsNullOrWhiteSpace(engine.Id) &&
                                 engine.Id.Length <= 100 &&
                                 engine.Url is { Length: > 0 and <= 4000 } &&
                                 engine.Url.Contains("{query}", StringComparison.Ordinal))
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
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.Unspecified,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(SettingsArchive))]
public sealed partial class ArchiveJsonContext : JsonSerializerContext
{
}
