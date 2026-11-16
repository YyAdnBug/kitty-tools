// 一份导出文件 mac 读不读得了（REVIEW R80）：照 mac origin/macos 9acd4306 的解码规则逐项查——
// Storage/SettingsArchive.swift（根上 app / format / version / exportedAt 必填，Clip、Word、Sealed 的字段）、
// Translate/TranslateService.swift（id / kind / name / isEnabled 必填，kind 和 aiProtocol 是枚举）、
// Launcher/WebSearch.swift（SearchEngine 五个字段都必填）、Shell/HotKeyCenter.swift（HotKey = {keyCode, modifiers}）。
// 时间用 .iso8601：只认到秒、带时区的写法，小数秒不认。mac 那边任何一处不对整份读不出，所以这里只要有一条就算读不了。
// 单测拿它查 Windows 写出去的文件，--settings-probe 拿它查真的 Build() 出来的那份。
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class ArchiveMacCheck
{
    /// <summary>mac TranslateService.Kind 的全部值。</summary>
    public static readonly IReadOnlySet<string> ServiceKinds = new HashSet<string>
    {
        "zhipu", "baidu", "youdao", "google", "deepl", "microsoft", "volcengine", "tencent", "apple", "youdaoDict", "ai",
    };

    /// <summary>mac TranslateService.AIProtocol 的全部值。</summary>
    public static readonly IReadOnlySet<string> AiProtocols = new HashSet<string> { "openai", "azure", "anthropic" };

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$")]
    private static partial Regex IsoSeconds();

    /// <summary>mac 读这份文件会卡在哪（空 = 读得了）。</summary>
    public static List<string> Problems(string json)
    {
        var problems = new List<string>();
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        void Need(bool ok, string what)
        {
            if (!ok)
            {
                problems.Add(what);
            }
        }

        bool Is(JsonElement element, string name, JsonValueKind kind)
            => element.TryGetProperty(name, out var value) && value.ValueKind == kind;

        bool IsBool(JsonElement element, string name)
            => element.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False;

        bool IsInt(JsonElement element, string name)
            => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _);

        bool IsDate(JsonElement element, string name)
            => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && IsoSeconds().IsMatch(value.GetString()!);

        // 可选的字段：没有、null 都行；有就得是这种类型
        bool Optional(JsonElement element, string name, JsonValueKind kind)
            => !element.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null || value.ValueKind == kind;

        bool OptionalBool(JsonElement element, string name)
            => !element.TryGetProperty(name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False;

        Need(root.TryGetProperty("app", out var app) && app.ValueKind == JsonValueKind.String && app.GetString() == SettingsArchive.Marker, "app");
        Need(IsInt(root, "format"), "format");
        Need(Is(root, "version", JsonValueKind.String), "version");
        Need(IsDate(root, "exportedAt"), "exportedAt（ISO 8601 到秒）");

        if (root.TryGetProperty("preferences", out var preferences))
        {
            Need(preferences.ValueKind == JsonValueKind.Object, "preferences 是对象");
        }

        if (root.TryGetProperty("hotkeys", out var hotkeys))
        {
            Need(hotkeys.ValueKind == JsonValueKind.Object, "hotkeys 是对象");
            if (hotkeys.ValueKind == JsonValueKind.Object)
            {
                foreach (var hotkey in hotkeys.EnumerateObject())
                {
                    Need(hotkey.Value.ValueKind == JsonValueKind.Null ||
                         hotkey.Value.ValueKind == JsonValueKind.Object && IsInt(hotkey.Value, "keyCode") && IsInt(hotkey.Value, "modifiers"),
                        $"hotkeys.{hotkey.Name} 是 {{keyCode, modifiers}} 或 null");
                }
            }
        }

        foreach (var (index, service) in Items(root, "translateServices", problems))
        {
            var at = $"translateServices[{index}]";
            Need(Is(service, "id", JsonValueKind.String), at + ".id");
            Need(service.TryGetProperty("kind", out var kind) && kind.ValueKind == JsonValueKind.String && ServiceKinds.Contains(kind.GetString()!), at + ".kind");
            Need(Is(service, "name", JsonValueKind.String), at + ".name");
            Need(IsBool(service, "isEnabled"), at + ".isEnabled");
            Need(Optional(service, "model", JsonValueKind.String) && Optional(service, "baseURL", JsonValueKind.String) &&
                 Optional(service, "region", JsonValueKind.String) && OptionalBool(service, "usesDeepLX"), at + " 的可选字段");
            Need(!service.TryGetProperty("aiProtocol", out var protocol) || protocol.ValueKind == JsonValueKind.Null ||
                 protocol.ValueKind == JsonValueKind.String && AiProtocols.Contains(protocol.GetString()!), at + ".aiProtocol");
        }

        foreach (var (index, engine) in Items(root, "searchEngines", problems))
        {
            var at = $"searchEngines[{index}]";
            foreach (var name in new[] { "id", "name", "keyword", "urlTemplate" })
            {
                Need(Is(engine, name, JsonValueKind.String), $"{at}.{name}");
            }

            Need(IsBool(engine, "enabled"), at + ".enabled");
        }

        foreach (var (index, clip) in Items(root, "clips", problems))
        {
            var at = $"clips[{index}]";
            Need(Is(clip, "text", JsonValueKind.String), at + ".text");
            Need(IsBool(clip, "favorite") && IsBool(clip, "snippet"), at + ".favorite / snippet");
            Need(IsDate(clip, "copiedAt"), at + ".copiedAt");
            Need(Optional(clip, "note", JsonValueKind.String) && Optional(clip, "group", JsonValueKind.String), at + " 的可选字段");
        }

        if (root.TryGetProperty("clipGroups", out var groups))
        {
            Need(groups.ValueKind == JsonValueKind.Array && groups.EnumerateArray().All(group => group.ValueKind == JsonValueKind.String), "clipGroups");
        }

        foreach (var (index, word) in Items(root, "vocabulary", problems))
        {
            var at = $"vocabulary[{index}]";
            foreach (var name in new[] { "source", "target", "result", "service" })
            {
                Need(Is(word, name, JsonValueKind.String), $"{at}.{name}");
            }

            Need(IsDate(word, "createdAt"), at + ".createdAt");
        }

        if (root.TryGetProperty("secrets", out var secrets) && secrets.ValueKind != JsonValueKind.Null)
        {
            Need(Is(secrets, "kdf", JsonValueKind.String) && IsInt(secrets, "rounds") && Is(secrets, "salt", JsonValueKind.String) &&
                 Is(secrets, "sealed", JsonValueKind.String), "secrets");
        }

        // 便签 mac 解得宽松（坏的那一条丢掉），这里照样查，免得悄悄丢
        foreach (var (index, note) in Items(root, "notes", problems))
        {
            var at = $"notes[{index}]";
            Need(Is(note, "id", JsonValueKind.String) && Is(note, "title", JsonValueKind.String) && Is(note, "body", JsonValueKind.String) &&
                 IsInt(note, "color") && IsInt(note, "createdAt") && IsInt(note, "modifiedAt") && IsInt(note, "revision") &&
                 IsBool(note, "archived") && IsBool(note, "pinned") && Is(note, "order", JsonValueKind.Number), at);
        }

        return problems;
    }

    private static IEnumerable<(int Index, JsonElement Item)> Items(JsonElement root, string name, List<string> problems)
    {
        if (!root.TryGetProperty(name, out var list))
        {
            yield break;
        }

        if (list.ValueKind != JsonValueKind.Array)
        {
            problems.Add(name + " 是数组");
            yield break;
        }

        var index = 0;
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object)
            {
                problems.Add($"{name}[{index}] 是对象");
            }
            else
            {
                yield return (index, item);
            }

            index++;
        }
    }
}
