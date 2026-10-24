// 设置：settings.json，带 version，源生成 JSON；写入走临时文件 + File.Replace；
// 读不出来时改名成 settings.broken-<时间>.json，再用默认值启动。
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KittyTools.Infrastructure;

internal sealed class Settings
{
    public int Version { get; set; } = 1;

    public bool StartWithWindows { get; set; } = true;

    public string Theme { get; set; } = "system";

    public string Accent { get; set; } = "brand";

    public bool AutoCheckUpdates { get; set; } = true;

    public bool CopyTranslate { get; set; }

    /// <summary>保留天数：1 / 7 / 30 / 90 / 365 / 0（永久）。</summary>
    public int ClipboardRetentionDays { get; set; } = 7;

    /// <summary>普通图片总占用上限（MB），0 = 不限。</summary>
    public int ClipboardImageBudgetMB { get; set; } = 512;

    public bool ClipboardBlockSensitive { get; set; } = true;

    public List<string> ClipboardExcludedApps { get; set; } = new()
    {
        "KeePass.exe",
        "KeePassXC.exe",
        "1Password.exe",
        "Bitwarden.exe",
    };

    // 翻译：语言、浮窗、服务列表。服务列表 null = 从没存过（默认只有智谱）；空列表 = 用户全删了。
    public string? TranslateFirstLanguage { get; set; } = "zh-Hans";

    public string? TranslateSecondLanguage { get; set; } = "en";

    /// <summary>浮窗上固定的源语言，null = 自动。</summary>
    public string? TranslateSource { get; set; }

    /// <summary>浮窗上固定的目标语言，null = 自动（第一 ⇄ 第二语言）。</summary>
    public string? TranslateTarget { get; set; }

    public bool TranslateAutoCopy { get; set; }

    /// <summary>浮窗位置：pointer = 跟随鼠标；last = 上次位置。</summary>
    public string TranslateWindowPosition { get; set; } = "pointer";

    public double TranslateWindowX { get; set; }

    public double TranslateWindowY { get; set; }

    public double TranslateWindowWidth { get; set; } = 460;

    public bool TranslatePinned { get; set; }

    /// <summary>截图快速保存的文件夹；空 = 系统的「屏幕截图」文件夹。</summary>
    public string? ScreenshotSaveFolder { get; set; }

    public List<TranslateServiceConfig>? TranslateServices { get; set; }

    /// <summary>启动器的网页搜索列表；null = 从没存过（默认前 8 个，Bing 兜底）。</summary>
    public List<KittyTools.Core.SearchEngine>? LauncherSearchEngines { get; set; }

    public List<HotKeySetting> HotKeys { get; set; } = new();
}

/// <summary>一个翻译服务的非密钥配置（密钥在凭据管理器，字段名见 SecretField）。</summary>
internal sealed class TranslateServiceConfig
{
    public string Id { get; set; } = string.Empty;

    /// <summary>zhipu / google / deepl / microsoft / ai。</summary>
    public string Kind { get; set; } = "ai";

    public string Name { get; set; } = string.Empty;

    public bool Enabled { get; set; } = true;

    public string? Model { get; set; }

    public string? BaseUrl { get; set; }

    /// <summary>openai / azure / anthropic。</summary>
    public string? Protocol { get; set; } = "openai";

    /// <summary>微软翻译填了 key 时的区域。</summary>
    public string? Region { get; set; }

    /// <summary>DeepL 走自建 DeepLX。</summary>
    public bool UsesDeepLX { get; set; }
}

internal sealed class HotKeySetting
{
    public string Action { get; set; } = string.Empty;

    public uint Modifiers { get; set; }

    public uint VirtualKey { get; set; }
}

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    ReadCommentHandling = JsonCommentHandling.Skip,
    AllowTrailingCommas = true)]
[JsonSerializable(typeof(Settings))]
internal partial class SettingsJsonContext : JsonSerializerContext
{
}

internal static class SettingsService
{
    private static readonly object Gate = new();
    private static Settings _current = new();

    public static Settings Current => _current;

    public static bool IsNew { get; private set; }

    public static event Action? Changed;

    public static void Load()
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.DataDirectory);
                if (!File.Exists(Paths.SettingsFile))
                {
                    _current = new Settings();
                    IsNew = true;
                    SettingsDefaults.Apply(_current);
                    return;
                }

                var json = File.ReadAllText(Paths.SettingsFile);
                var loaded = JsonSerializer.Deserialize(json, SettingsJsonContext.Default.Settings);
                if (loaded is null)
                {
                    throw new JsonException("settings.json 反序列化结果是 null");
                }

                _current = loaded;
                SettingsDefaults.Apply(_current);
                IsNew = false;
                if (_current.Version < 1)
                {
                    _current.Version = 1;
                }
            }
            catch (Exception ex)
            {
                IsNew = true;
                _current = new Settings();
                SettingsDefaults.Apply(_current);
                Log.Error("settings.load-failed", ex);
                QuarantineBrokenFile();
            }
        }
    }

    public static void Save()
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.DataDirectory);
                var json = JsonSerializer.Serialize(_current, SettingsJsonContext.Default.Settings);
                var temporary = Paths.SettingsFile + ".tmp";
                File.WriteAllText(temporary, json);
                if (File.Exists(Paths.SettingsFile))
                {
                    File.Replace(temporary, Paths.SettingsFile, null);
                }
                else
                {
                    File.Move(temporary, Paths.SettingsFile);
                }

                IsNew = false;
            }
            catch (Exception ex)
            {
                Log.Error("settings.save-failed", ex);
            }
        }

        Changed?.Invoke();
    }

    public static void MarkStarted()
    {
        if (IsNew)
        {
            IsNew = false;
            Save();
        }
    }

    private static void QuarantineBrokenFile()
    {
        try
        {
            if (!File.Exists(Paths.SettingsFile))
            {
                return;
            }

            var broken = Path.Combine(Paths.DataDirectory, $"settings.broken-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Move(Paths.SettingsFile, broken, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Error("settings.quarantine-failed", ex);
        }
    }
}
