// 状态屏的状态列表接进同步（PLAN-v12 第 7 批，照 mac StatusScreen/StatusPresetSync.swift，格式一字不差）：一个状态一条记录
// （编号 = StatusPreset.Id；自带的三个每台都是同一个编号），内容是 mac SyncRecords.encoder 编出来的那一行（StatusPresets.Canonical）；
// 顺序单独一条（~order）。第一次合时标题一样的只留文件夹里那个（JoinKey = 标题）。
// 和提醒不同：设置里没存过列表（null）时交出去的是自带的三个（mac StatusPreset.load 也是这样）。
// 落地：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排，再收拾一遍（最多 20 个……；收拾掉的下一轮当本机删了传出去，
// ponytail 同 mac：两台同时加满超过 20 个会删掉多出来的）；有一条解不出来（或者编回去和原来的字节不一样）整个不落。
using System.Text.Json;

namespace KittyTools.Core.Sync;

public static class StatusPresetSync
{
    public const string Kind = "statuses";

    /// <summary>stored：设置里存着的（null = 没存过，交出去的是自带的三个）。</summary>
    public static Dictionary<string, string> Values(IReadOnlyList<StatusPreset>? stored)
    {
        var presets = StatusPresets.Load(stored);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var preset in presets)
        {
            values.TryAdd(preset.Id, StatusPresets.Canonical(preset));
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(presets.Select(preset => preset.Id));
        return values;
    }

    /// <summary>第一次合：标题一样的算同一个（mac：宽松解出来的 title）。</summary>
    public static string? JoinKey(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            return StatusPresets.Read(document.RootElement)?.Title;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>解一条，再编回去必须和原来的字节一样（mac decodeExact）。</summary>
    public static StatusPreset? Decode(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var preset = StatusPresets.Read(document.RootElement);
            return preset is not null && StatusPresets.Canonical(preset) == value ? preset : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>当前列表 + 改动 → 落地后的列表（收拾过；可能是空的，读的时候退回自带的）；解不开返回 null。</summary>
    public static List<StatusPreset>? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<StatusPreset>? stored, out string? failure)
    {
        failure = null;
        var current = StatusPresets.Load(stored);
        var presets = new Dictionary<string, StatusPreset>(StringComparer.Ordinal);
        foreach (var preset in current)
        {
            presets.TryAdd(preset.Id, preset);
        }

        IReadOnlyList<string> order = current.Select(preset => preset.Id).ToList();
        foreach (var (id, value) in changes)
        {
            if (id == SyncEngine.OrderID)
            {
                if (value is null)
                {
                    continue;
                }

                if (SyncValues.DecodeOrder(value) is not { } ids)
                {
                    failure = ClipSync.Unreadable;
                    return null;
                }

                order = ids;
                continue;
            }

            if (value is null)
            {
                presets.Remove(id);
                continue;
            }

            if (Decode(value) is not { } preset || preset.Id != id)
            {
                failure = ClipSync.Unreadable;
                return null;
            }

            presets[id] = preset;
        }

        return StatusPresets.Sanitized(SyncEngine.Arranged(presets.Keys, order).Select(id => presets[id]));
    }
}
