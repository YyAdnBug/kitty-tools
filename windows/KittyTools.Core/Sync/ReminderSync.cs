// 提醒列表接进同步（PLAN-v12 N6，照 mac Reminders/ReminderSync.swift，格式一字不差）：一条提醒一条记录（编号 = Reminder.Id；三条示例每台都是
// 同一个编号），内容是 mac SyncRecords.encoder 编出来的那一行（键排好序、时刻是 2001 起的秒数，Reminders.Canonical）；顺序单独一条（~order）。
// 第一次合时标题和时间规则都一样的只留文件夹里那条（JoinKey = 标题 + 换行 + 时间规则那一段）。
// 设置里没存过列表（null）时交出去的是空的（不是示例：没碰过提醒的那台不该把三条示例当成自己的交出去）。
// 落地：改了的换掉、新来的加上、别处删了的拿掉，按顺序那条排；有一条解不出来（或者编回去和原来的字节不一样）整个不落。
// 只同步列表：处理到哪一刻、推到几点、暂停到几点是这台电脑自己的（Settings.RemindersState）。
using System.Text.Json;

namespace KittyTools.Core.Sync;

public static class ReminderSync
{
    public const string Kind = "reminders";

    /// <summary>stored：设置里存着的（null = 没存过，交出去的是空的）。</summary>
    public static Dictionary<string, string> Values(IReadOnlyList<Reminder>? stored)
    {
        var reminders = stored is null ? new List<Reminder>() : Reminders.Sanitized(stored);
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var reminder in reminders)
        {
            values.TryAdd(reminder.Id, Reminders.Canonical(reminder));
        }

        values[SyncEngine.OrderID] = SyncEngine.OrderValue(reminders.Select(reminder => reminder.Id));
        return values;
    }

    /// <summary>第一次合：标题和时间规则都一样的算同一条（mac：title + "\n" + schedule 编出来的那一段）。</summary>
    public static string? JoinKey(string value)
        => Decode(value) is { } reminder ? reminder.Title + "\n" + Reminders.CanonicalSchedule(reminder.Schedule) : null;

    /// <summary>解一条（mac 的宽松解码），再编回去必须和原来的字节一样（decodeExact）。</summary>
    public static Reminder? Decode(string value)
    {
        try
        {
            using var document = JsonDocument.Parse(value);
            var reminder = Reminders.Read(document.RootElement);
            return reminder is not null && Reminders.Canonical(reminder) == value ? reminder : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>当前列表 + 改动 → 落地后的列表（收拾过）；解不开返回 null。</summary>
    public static List<Reminder>? Plan(
        IReadOnlyDictionary<string, string?> changes, IReadOnlyList<Reminder>? stored, out string? failure)
    {
        failure = null;
        var current = stored is null ? new List<Reminder>() : Reminders.Sanitized(stored);
        var reminders = new Dictionary<string, Reminder>(StringComparer.Ordinal);
        foreach (var reminder in current)
        {
            reminders.TryAdd(reminder.Id, reminder);
        }

        IReadOnlyList<string> order = current.Select(reminder => reminder.Id).ToList();
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
                reminders.Remove(id);
                continue;
            }

            if (Decode(value) is not { } reminder || reminder.Id != id)
            {
                failure = ClipSync.Unreadable;
                return null;
            }

            reminders[id] = reminder;
        }

        return Reminders.Sanitized(SyncEngine.Arranged(reminders.Keys, order).Select(id => reminders[id]));
    }
}
