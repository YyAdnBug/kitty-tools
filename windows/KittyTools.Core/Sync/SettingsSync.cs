// 设置接进同步的算法（PLAN-v21 第 1 批；照 mac Storage/SettingsSync.swift，文件头那几条规矩原样）。纯函数：App 的
// SettingsSource 交进来本机各项的值、存过哪些、透传、改的时刻，拿回要发的那份和要落的改动。两类共用：
// - settings（和 mac 互认，SettingsSyncMap.Shared）：mac 不认识的 / 这一版不认识的编号、落不下的值原样透传。
// - windows-settings（只在 Windows 之间，Shared + WindowsOnly + 快捷键）：PLAN-v21 D3——文件夹里有了 Mac 的 settings 之后，
//   这一类里的 Shared 编号只发不落（以 settings 一类为准）；Shared 编号的删除一律不落（见 Plan）。
// mac 的几条：
// - **只同步存过的**（PLAN-v21 D4）：mac 看持久域里有没有这个键；Windows 的 settings.json 每项都写，所以另记一份「存过的」
//   （SyncStoredKeys）：值和本机默认不一样的就算存过、之后一直算（改回默认值也还是存过，mac 也是）；同步落下来的算存过，
//   同步删掉的（对面改回默认 = 删了这一条）回到本机默认、不再算存过。
// - **透传**：透传着的那几项交出去的是透传的那份；本机自己又改了它才换成本机的、透传的扔掉。
// - **一项一项后改的赢**：比上次看到的本机那份，变了的记成现在改的；同步落下去的那几项清掉它们的时刻。
namespace KittyTools.Core.Sync;

/// <summary>本机一项：对照表里的那一项、现在的值（null = 没有这一项，比如没选过的源语言）、本机默认值。</summary>
public readonly record struct SettingReading(SettingKey Key, SettingValue? Value, SettingValue? Default);

/// <summary>要落的一项：Value = null 是回到本机默认。</summary>
public readonly record struct SettingWrite(SettingKey Key, SettingValue? Value);

/// <summary>落一轮的规划：Writes 写进设置；Passthrough 是新的透传。</summary>
public sealed record SettingsPlan(IReadOnlyList<SettingWrite> Writes, Dictionary<string, string> Passthrough);

public static class SettingsSync
{
    public const string Kind = "settings";
    public const string WindowsKind = "windows-settings";

    /// <summary>本机该发的那份（不含透传）：存过的才发（stored 里没有、值又和默认不一样的顺手记进 stored）；发不出去的（对面落不下）不发。</summary>
    public static Dictionary<string, string> Own(IEnumerable<SettingReading> readings, ISet<string> stored)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value, fallback) in readings)
        {
            if (value is null)
            {
                continue;
            }

            if (!value.Equals(fallback))
            {
                stored.Add(key.Field);
            }

            if (stored.Contains(key.Field) && key.Outgoing(value) is { } text)
            {
                values[key.Id] = text;
            }
        }

        return values;
    }

    /// <summary>交给引擎的那份：本机的，透传着的那几项换成透传的那份。</summary>
    public static Dictionary<string, string> Values(IReadOnlyDictionary<string, string> own, IReadOnlyDictionary<string, string> passthrough)
    {
        var values = new Dictionary<string, string>(own, StringComparer.Ordinal);
        foreach (var (id, text) in passthrough)
        {
            values[id] = text;
        }

        return values;
    }

    /// <summary>和上次看到的本机那份比（mac recordChanges）：变了的记成 now 改的、它们的透传扔掉（本机的作数）；
    /// 本机和透传里都没有了的不再记时刻。返回有没有变。</summary>
    public static bool Record(
        IReadOnlyDictionary<string, string> known, IReadOnlyDictionary<string, string> own,
        Dictionary<string, string> passthrough, Dictionary<string, long> times, long now)
    {
        var changed = own.Keys.Union(known.Keys, StringComparer.Ordinal)
            .Where(id => !string.Equals(own.GetValueOrDefault(id), known.GetValueOrDefault(id), StringComparison.Ordinal))
            .ToList();
        if (changed.Count == 0)
        {
            return false;
        }

        foreach (var id in changed)
        {
            passthrough.Remove(id);
            times[id] = now;
        }

        foreach (var id in times.Keys.ToList())
        {
            if (!own.ContainsKey(id) && !passthrough.ContainsKey(id))
            {
                times.Remove(id);
            }
        }

        return true;
    }

    /// <summary>合出来的改动 → 要写进设置的、新的透传。find：这一类认得的编号；accept：App 再核一遍（快捷键能不能当全局热键用）。
    /// sharedFrozen：windows-settings 里、文件夹里已经有 Mac 的 settings 时，Shared 编号的值不落（settings 一类为准）、也不透传。
    /// windows-settings 里 Shared 编号的**删除**一律不落：Windows 本机从不删一项设置（存过的一直发），这一类里出现它的删除只会是
    /// 「有了 Mac、这一项不再从这一类走」那一刻留下的墓碑，落下去就把它改回默认了。</summary>
    public static SettingsPlan Plan(
        IReadOnlyDictionary<string, string?> changes, Func<string, SettingKey?> find,
        IReadOnlyDictionary<string, string> passthrough, bool windowsKind, bool sharedFrozen,
        Func<SettingKey, SettingValue, bool>? accept = null)
    {
        var writes = new List<SettingWrite>();
        var passed = new Dictionary<string, string>(passthrough, StringComparer.Ordinal);
        foreach (var (id, text) in changes.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            var key = find(id);
            if (key is not null && windowsKind && key.Shared && (sharedFrozen || text is null))
            {
                passed.Remove(id);
                continue;
            }

            if (key is not null && text is null)
            {
                writes.Add(new(key, null));
                passed.Remove(id);
                continue;
            }

            if (key is not null && key.Incoming(text!) is { } value && (accept?.Invoke(key, value) ?? true))
            {
                writes.Add(new(key, value));
                passed.Remove(id);
                continue;
            }

            // 这一版不认识的编号、落不下的值：原样存着，下一轮原样交回去（删了的也跟着删）
            if (text is null)
            {
                passed.Remove(id);
            }
            else
            {
                passed[id] = text;
            }
        }

        return new SettingsPlan(writes, passed);
    }

    /// <summary>落下去之后：落了的那几项不再算本机改的，清掉它们记着的时刻（mac applySync）。</summary>
    public static void Landed(IReadOnlyDictionary<string, string?> changes, Dictionary<string, long> times)
    {
        foreach (var id in changes.Keys)
        {
            times.Remove(id);
        }
    }

    /// <summary>两个快捷键撞了同一个组合：说哪两个（只说第一对），没有给 null。bindings：动作 → 写法（空 = 没设）。</summary>
    public static (string First, string Second)? Clash(IEnumerable<KeyValuePair<string, string>> bindings)
    {
        var owners = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (action, text) in bindings)
        {
            if (string.IsNullOrEmpty(text))
            {
                continue;
            }

            if (owners.TryGetValue(text, out var first))
            {
                return (first, action);
            }

            owners[text] = action;
        }

        return null;
    }
}
