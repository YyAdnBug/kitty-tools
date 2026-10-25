// 设置：settings.json，带 version，源生成 JSON；写入走临时文件 + File.Replace；
// 读不出来时改名成 settings.broken-<时间>.json，再用默认值启动。
// Save 和 Changed 只许在 UI 线程上用（热键注册、XAML 资源都只认 UI 线程）；Debug 下断言，Release 下自动转回 UI 线程。
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.UI.Dispatching;

namespace KittyTools.Infrastructure;

internal sealed class Settings
{
    public int Version { get; set; } = 2;

    public bool StartWithWindows { get; set; } = true;

    public string Theme { get; set; } = "system";

    public string Accent { get; set; } = "brand";

    public bool AutoCheckUpdates { get; set; } = true;

    /// <summary>已经轻提示过的版本；每个版本只提示一次。</summary>
    public string? NotifiedUpdateVersion { get; set; }

    public bool CopyTranslate { get; set; }

    /// <summary>保留天数：1 / 7 / 30 / 90 / 365 / 0（永久）。</summary>
    public int ClipboardRetentionDays { get; set; } = 7;

    /// <summary>普通图片总占用上限（MB），0 = 不限。</summary>
    public int ClipboardImageBudgetMB { get; set; } = 512;

    public bool ClipboardBlockSensitive { get; set; } = true;

    /// <summary>链接预览（第三版 §5）：选中「只有一个网址」的文本时取标题 / 描述 / 头图。</summary>
    public bool LinkPreviews { get; set; } = true;

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

    /// <summary>翻译历史开关（第三版 §3.1）。</summary>
    public bool TranslateHistoryEnabled { get; set; } = true;

    /// <summary>普通历史保留条数：1000 / 5000 / 0（不限）；收藏的不算、永不淘汰。</summary>
    public int TranslateHistoryLimit { get; set; } = 5000;

    /// <summary>查词（单词模式）开关（第三版 §3.4）。</summary>
    public bool TranslateWordLookup { get; set; } = true;

    /// <summary>「划词翻译并替换」的独立热键动作是否已在快捷键表里（第三版 §3.2，不设默认键）。</summary>
    public bool TranslateReplaceHotKeySeen { get; set; }

    // 同步（第五版）：用户选的同步文件夹、开关和四类。
    public bool SyncEnabled { get; set; }

    public string? SyncFolder { get; set; }

    public bool SyncClips { get; set; } = true;

    public bool SyncVocabulary { get; set; } = true;

    public bool SyncEngines { get; set; } = true;

    public bool SyncServices { get; set; } = true;

    /// <summary>截图快速保存的文件夹；空 = 系统的「屏幕截图」文件夹。</summary>
    public string? ScreenshotSaveFolder { get; set; }

    /// <summary>上一次截图的区域（物理像素，只在内存里，不进导出文件；第三版 §7）。</summary>
    public int ScreenshotLastX { get; set; }

    public int ScreenshotLastY { get; set; }

    public int ScreenshotLastWidth { get; set; }

    public int ScreenshotLastHeight { get; set; }

    // 录制（第四版）：帧率、保存目录、上次没写完的临时文件（闪退恢复用）。
    public int RecordFps { get; set; } = 15;

    public string? RecordDirectory { get; set; }

    public string? RecordingTempPath { get; set; }

    /// <summary>录制中显示点按圈（第四版第 3 批，默认关）。</summary>
    public bool RecordClicks { get; set; }

    /// <summary>录制中显示快捷键胶囊（默认关）。</summary>
    public bool RecordKeys { get; set; }

    /// <summary>停止后另存一份 H.264 MP4（R14 的中间步骤，默认开）。</summary>
    public bool RecordMp4 { get; set; } = true;

    /// <summary>录屏时录系统声音（默认开，PLAN-v6 第 2 批）。</summary>
    public bool RecordSystemSound { get; set; } = true;

    /// <summary>录屏时录麦克风（默认关）。</summary>
    public bool RecordMicrophone { get; set; }

    public List<TranslateServiceConfig>? TranslateServices { get; set; }

    /// <summary>启动器的网页搜索列表；null = 从没存过（默认前 8 个，Bing 兜底）。</summary>
    public List<KittyTools.Core.SearchEngine>? LauncherSearchEngines { get; set; }

    public List<HotKeySetting> HotKeys { get; set; } = new();

    /// <summary>
    /// 功能开关（第三版 §2.3）：clipboard / translate / launcher / screenshot → 开没开。
    /// 没存过的当开；关掉只停入口和后台工作，数据层照常。
    /// </summary>
    public Dictionary<string, bool>? Features { get; set; }
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
    private static DispatcherQueue? _dispatcher;

    public static Settings Current => _current;

    public static bool IsNew { get; private set; }

    public static event Action? Changed;

    /// <summary>当前在不在 UI 线程上（没有 dispatcher 时当作在：Load 之前的调用都发生在启动线程上）。</summary>
    public static bool OnUiThread => _dispatcher is null || _dispatcher.HasThreadAccess;

    public static void Load()
    {
        _dispatcher ??= DispatcherQueue.GetForCurrentThread();
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

                // 0.6.0 之前没有「录屏系统声音」这个字段；JSON 里缺了会解成 false，这里补回默认开。
                if (_current.Version < 2)
                {
                    _current.RecordSystemSound = true;
                    _current.Version = 2;
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
        // 第二版 §2 P0：Save 和 Changed 只许在 UI 线程上跑。更新检查的线程池回调以前直接 Save，
        // 结果热键从错的线程上重注册全部失效、改主题颜色还会跨线程访问 XAML 资源。
        if (!OnUiThread)
        {
            Log.Error("settings.save-off-ui-thread");
            Debug.Assert(false, "SettingsService.Save 只能在 UI 线程调用");
            _dispatcher?.TryEnqueue(Save);
            return;
        }

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
