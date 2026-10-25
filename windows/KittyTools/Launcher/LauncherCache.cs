// 应用目录的磁盘缓存（第二版 §4.2「启动」）：启动时先读上次扫到的名字 / 目标 / 图标 PNG，
// 15 秒后再在后台低优先级刷新一次。省掉启动时那一次 PackageManager + 开始菜单扫描。
// 用 Utf8JsonWriter / JsonDocument 手写读写：AOT 下不用反射序列化。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class LauncherCache
{
    private const int Version = 1;

    private static string Path => System.IO.Path.Combine(Paths.DataDirectory, "launcher-cache.json");

    public static List<LauncherItem> Load()
    {
        var items = new List<LauncherItem>();
        try
        {
            if (!File.Exists(Path))
            {
                return items;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(Path));
            if (!document.RootElement.TryGetProperty("version", out var version) || version.GetInt32() != Version)
            {
                return items;
            }

            if (!document.RootElement.TryGetProperty("items", out var array) || array.ValueKind != JsonValueKind.Array)
            {
                return items;
            }

            foreach (var entry in array.EnumerateArray())
            {
                var target = String(entry, "target");
                var title = String(entry, "title");
                if (string.IsNullOrWhiteSpace(target) || string.IsNullOrWhiteSpace(title))
                {
                    continue;
                }

                items.Add(new LauncherItem
                {
                    Kind = Enum.TryParse<LauncherKind>(String(entry, "kind"), out var kind) ? kind : LauncherKind.App,
                    Target = target,
                    Title = title,
                    Subtitle = String(entry, "subtitle") ?? string.Empty,
                    Names = Strings(entry, "names"),
                    Initials = Strings(entry, "initials"),
                    IconPath = String(entry, "iconPath"),
                    IconData = Bytes(entry, "icon"),
                });
            }

            Log.Info($"launcher.cache-loaded count={items.Count}");
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.cache-load-failed {ex.GetType().Name}");
            items.Clear();
        }

        return items;
    }

    public static void Save(IReadOnlyList<LauncherItem> items)
    {
        try
        {
            Directory.CreateDirectory(Paths.DataDirectory);
            var temporary = Path + ".tmp";
            using (var stream = File.Create(temporary))
            using (var writer = new Utf8JsonWriter(stream))
            {
                writer.WriteStartObject();
                writer.WriteNumber("version", Version);
                writer.WriteStartArray("items");
                foreach (var item in items)
                {
                    if (string.IsNullOrWhiteSpace(item.Target) || string.IsNullOrWhiteSpace(item.Title))
                    {
                        continue;
                    }

                    writer.WriteStartObject();
                    writer.WriteString("kind", item.Kind.ToString());
                    writer.WriteString("target", item.Target);
                    writer.WriteString("title", item.Title);
                    writer.WriteString("subtitle", item.Subtitle);
                    writer.WriteString("iconPath", item.IconPath);
                    writer.WriteStartArray("names");
                    foreach (var name in item.Names)
                    {
                        writer.WriteStringValue(name);
                    }

                    writer.WriteEndArray();
                    writer.WriteStartArray("initials");
                    foreach (var initial in item.Initials)
                    {
                        writer.WriteStringValue(initial);
                    }

                    writer.WriteEndArray();
                    if (item.IconData is { Length: > 0 } icon)
                    {
                        writer.WriteBase64String("icon", icon);
                    }

                    writer.WriteEndObject();
                }

                writer.WriteEndArray();
                writer.WriteEndObject();
            }

            File.Move(temporary, Path, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"launcher.cache-save-failed {ex.GetType().Name}");
        }
    }

    private static string? String(JsonElement entry, string name)
        => entry.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static List<string> Strings(JsonElement entry, string name)
    {
        var list = new List<string>();
        if (entry.TryGetProperty(name, out var array) && array.ValueKind == JsonValueKind.Array)
        {
            foreach (var value in array.EnumerateArray())
            {
                if (value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text)
                {
                    list.Add(text);
                }
            }
        }

        return list;
    }

    private static byte[]? Bytes(JsonElement entry, string name)
    {
        if (!entry.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        try
        {
            return value.GetBytesFromBase64();
        }
        catch
        {
            return null;
        }
    }
}
