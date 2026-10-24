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

    public List<HotKeySetting> HotKeys { get; set; } = new();
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
