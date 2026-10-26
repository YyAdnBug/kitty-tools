// 同步文件夹的规矩（PLAN-v5 §2.1 / §4.3，纯函数 + 单测）：标记、device.json、编号校验、刹车。
using System.Text.Json;

namespace KittyTools.Core.Sync;

public static class SyncFolderRules
{
    public const string MarkerFile = "kitty-notes-sync.json";

    public const string DevicesFolder = "devices";

    public const string DeviceFile = "device.json";

    public const int MarkerFormat = 1;

    public const int DeviceFormat = 1;

    public const int MaxDeletions = 20;

    public static bool IsDeviceName(string value)
        => value.Length is >= 1 and <= 64 && value.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-');

    public static string Marker(string library)
    {
        var builder = new System.Text.StringBuilder();
        builder.Append("{\"format\":").Append(MarkerFormat).Append(",\"kind\":");
        CanonicalJson.WriteString("kitty-notes-sync", builder);
        builder.Append(",\"library\":");
        CanonicalJson.WriteString(library, builder);
        builder.Append('}');
        return builder.ToString();
    }

    public static string? ParseMarker(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("format", out var format) || !format.TryGetInt32(out var value) ||
                value != MarkerFormat ||
                !root.TryGetProperty("kind", out var kind) || kind.GetString() != "kitty-notes-sync" ||
                !root.TryGetProperty("library", out var library) ||
                library.GetString() is not { } id || !IsDeviceName(id))
            {
                return null;
            }

            return id;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string DeviceJson(int epoch, string name)
    {
        var builder = new System.Text.StringBuilder();
        builder.Append("{\"epoch\":").Append(epoch).Append(",\"format\":").Append(DeviceFormat).Append(",\"name\":");
        CanonicalJson.WriteString(name, builder);
        builder.Append('}');
        return builder.ToString();
    }

    public static (int Epoch, string Name)? ParseDevice(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("epoch", out var epoch) || !epoch.TryGetInt32(out var value) || value < 0 ||
                !root.TryGetProperty("format", out var format) || !format.TryGetInt32(out var formatValue) ||
                formatValue != DeviceFormat ||
                !root.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String)
            {
                return null;
            }

            return (value, name.GetString() ?? string.Empty);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public const int MinDeletionsForShare = 5;

    /// <summary>刹车（照 mac NoteSyncFolder.brakes）：要删本机没删的条目超过 20 条，或者要删的至少 5 条、又超过三成。
    /// 「至少 5 条」说的是要删的条数（只有三四条时删一条就是三成，每次都问太吵），不是总数。</summary>
    public static bool ShouldBrake(int deletions, int total)
        => deletions > MaxDeletions || (deletions >= MinDeletionsForShare && deletions * 10 > total * 3);

    public static string FileName(string kind) => kind + ".json";

    public static bool IsSyncedKind(string kind) => kind is "clips" or "vocabulary" or "engines" or "services";
}
