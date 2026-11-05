// 状态屏的一个「状态」（PLAN-v12 N5，照 mac StatusScreen/StatusPreset.swift）：标题、说明、图标、样式、电源、自动结束六项，加一个不变的 id。
// 自带三个：清洁屏幕、请勿触碰、马上回来；用户改过的整张列表存在设置里（Settings.StatusScreenPresets，null = 自带的三个），
// 读出来和导入的都过 Sanitized：文件、设置里的值按不可信输入对待。图标是动画表情 id（清单在 StatusEmojiCatalog），
// 字段叫 Symbol、JSON 里的键 symbol 同 mac（mac 第 5 批之前存的是系统符号名，Emoji 里换过来）。
// 样式、电源存字符串（blackout / sign / dim、normal / awake / displayOn），和 mac 的 JSON 一字不差：设置导出文件、同步文件夹两边互读。
// 设置 › 状态屏改列表用的几个纯函数（加、删、挪、恢复自带的、详情改一个）和列表行的摘要也在这里。
using System.Globalization;
using System.Text.Json;

namespace KittyTools.Core;

public sealed class StatusPreset
{
    /// <summary>启动器使用记录按它认（改了会丢记录）：自带的固定 clean / busy / back。</summary>
    public string Id { get; set; } = string.Empty;

    public string Title { get; set; } = string.Empty;

    public string? Detail { get; set; }

    /// <summary>表情 id（StatusEmojiCatalog.Ids 里的一个）；空 = 不要图标。</summary>
    public string Symbol { get; set; } = string.Empty;

    /// <summary>blackout 熄屏（纯黑，什么都不显示）/ sign 告示（黑底大字）/ dim 透出（屏幕压暗 + 大字）。</summary>
    public string Style { get; set; } = StatusPresets.Sign;

    /// <summary>normal 照常 / awake 不睡眠（显示器照常熄）/ displayOn 屏幕常亮（电脑也不睡眠）。</summary>
    public string Power { get; set; } = StatusPresets.Awake;

    /// <summary>几分钟后自动结束（AutoEndChoices 里的一个）；0 = 不结束。</summary>
    public int AutoEndMinutes { get; set; }

    public StatusPreset Copy() => (StatusPreset)MemberwiseClone();

    /// <summary>六项加 id 都一样（mac 的 Hashable 相等）。</summary>
    public bool SameAs(StatusPreset other)
        => Id == other.Id && Title == other.Title && Detail == other.Detail && Symbol == other.Symbol &&
           Style == other.Style && Power == other.Power && AutoEndMinutes == other.AutoEndMinutes;
}

public static class StatusPresets
{
    public const string Blackout = "blackout";
    public const string Sign = "sign";
    public const string Dim = "dim";
    public const string Normal = "normal";
    public const string Awake = "awake";
    public const string DisplayOn = "displayOn";

    public static readonly string[] Styles = { Blackout, Sign, Dim };
    public static readonly string[] Powers = { Normal, Awake, DisplayOn };
    public static readonly int[] AutoEndChoices = { 0, 5, 15, 30, 60 };

    public const int MaxCount = 20;
    public const int MaxTitle = 30;
    public const int MaxDetail = 60;

    /// <summary>id 的长度上限（它会进启动器的使用记录）。</summary>
    public const int MaxId = 64;

    /// <summary>mac 第 5 批之前图标是系统符号：意思对得上的换成对应的表情，对不上的就是没选（hourglass、zzz 正好是现在的 id）。</summary>
    private static readonly Dictionary<string, string> LegacySymbols = new(StringComparer.Ordinal)
    {
        ["sparkles"] = "glowing-star",
        ["hand.raised.fill"] = "raised-hand",
        ["clock.fill"] = "alarm-clock",
        ["moon.fill"] = "sleeping-face",
        ["cup.and.saucer.fill"] = "hot-beverage",
        ["phone.fill"] = "telephone",
        ["person.2.fill"] = "busts",
        ["terminal.fill"] = "robot",
        ["bolt.fill"] = "high-voltage",
    };

    public static IReadOnlyList<StatusPreset> BuiltIn() => new[]
    {
        new StatusPreset
        {
            Id = "clean", Title = "清洁屏幕", Symbol = "glowing-star", Style = Blackout, Power = Normal, AutoEndMinutes = 5,
        },
        new StatusPreset
        {
            Id = "busy", Title = "请勿触碰", Detail = "电脑正在跑任务，别动键盘和鼠标", Symbol = "raised-hand", Style = Dim,
            Power = DisplayOn, AutoEndMinutes = 0,
        },
        new StatusPreset
        {
            Id = "back", Title = "马上回来", Symbol = "alarm-clock", Style = Sign, Power = Awake, AutoEndMinutes = 0,
        },
    };

    public static string StyleTitle(string style) => style switch
    {
        Blackout => "熄屏",
        Dim => "透出",
        _ => "告示",
    };

    /// <summary>设置里选中这一种样式时下面的一句话。</summary>
    public static string StyleExplanation(string style) => style switch
    {
        Blackout => "纯黑，什么都不显示，适合擦屏幕",
        Dim => "屏幕压暗，还看得见后面的窗口",
        _ => "黑底大字，看不到屏幕内容",
    };

    public static string PowerTitle(string power) => power switch
    {
        Normal => "照常",
        DisplayOn => "屏幕常亮",
        _ => "不睡眠",
    };

    /// <summary>存着的图标值 → 现在的表情 id：清单里的原样留着，旧的系统符号名换成对应的表情，其余不认识的置空。</summary>
    public static string Emoji(string? symbol)
        => symbol is null ? string.Empty
            : StatusEmojiCatalog.Ids.Contains(symbol) ? symbol
            : LegacySymbols.GetValueOrDefault(symbol, string.Empty);

    /// <summary>
    /// 把一张列表收拾成能用的：标题去首尾空白、换行当空格，空的整条丢掉、超过 30 个字截断；说明同样收拾、最多 60 个字、空了就是没有；
    /// 图标换成现在的表情 id；样式、电源认不出来的整条丢掉（mac 解不出的同样不要）；自动结束不是可选值的当「不结束」；
    /// id 为空、太长、重复的丢掉（留先出现的）；最多 20 个。结果可能是空的——用的地方（Load）退回自带的。不改传进来的。
    /// </summary>
    public static List<StatusPreset> Sanitized(IEnumerable<StatusPreset?> presets)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<StatusPreset>();
        foreach (var source in presets)
        {
            if (source is null)
            {
                continue;
            }

            var preset = source.Copy();
            preset.Title = Prefix(OneLine(preset.Title), MaxTitle);
            if (preset.Title.Length == 0 || string.IsNullOrEmpty(preset.Id) || preset.Id.Length > MaxId ||
                !Styles.Contains(preset.Style) || !Powers.Contains(preset.Power) || !seen.Add(preset.Id))
            {
                continue;
            }

            var detail = Prefix(OneLine(preset.Detail), MaxDetail);
            preset.Detail = detail.Length == 0 ? null : detail;
            preset.Symbol = Emoji(preset.Symbol);
            if (!AutoEndChoices.Contains(preset.AutoEndMinutes))
            {
                preset.AutoEndMinutes = 0;
            }

            result.Add(preset);
            if (result.Count == MaxCount)
            {
                break;
            }
        }

        return result;
    }

    /// <summary>设置里存的 → 列表：没存过、收拾完一个不剩，都用自带的。</summary>
    public static List<StatusPreset> Load(IEnumerable<StatusPreset?>? stored)
    {
        var presets = stored is null ? new List<StatusPreset>() : Sanitized(stored);
        return presets.Count == 0 ? BuiltIn().Select(preset => preset.Copy()).ToList() : presets;
    }

    /// <summary>
    /// 导入时并进本机的列表（mac merged）：按 id 更新和添加，顺序先照文件里的，本机独有的接在后面（不删：那是用户自己写的东西）；
    /// 超过 MaxCount 的由 Sanitized 截掉后面的。
    /// </summary>
    public static List<StatusPreset> Merged(IReadOnlyList<StatusPreset> incoming, IReadOnlyList<StatusPreset> local)
        => Sanitized(incoming.Concat(local.Where(kept => incoming.All(item => item.Id != kept.Id))));

    /// <summary>「几分钟后自动结束」的叫法：「不结束」「5 分钟」「1 小时」。</summary>
    public static string AutoEndTitle(int minutes)
        => minutes == 0 ? "不结束" : minutes % 60 == 0 ? $"{minutes / 60} 小时" : $"{minutes} 分钟";

    /// <summary>列表行的一行小字：样式 · 电源 · 自动结束，照常、不结束的那一段不写（「透出 · 屏幕常亮」「熄屏 · 5 分钟后结束」）。</summary>
    public static string Summary(StatusPreset preset)
    {
        var parts = new List<string> { StyleTitle(preset.Style) };
        if (preset.Power != Normal)
        {
            parts.Add(PowerTitle(preset.Power));
        }

        if (preset.AutoEndMinutes != 0)
        {
            parts.Add(AutoEndTitle(preset.AutoEndMinutes) + "后结束");
        }

        return string.Join(" · ", parts);
    }

    /// <summary>新加的状态：标题「新状态」、告示样式、不睡眠、不自动结束、不带图标。</summary>
    public static StatusPreset New(string? id = null) => new()
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
        Title = "新状态",
        Style = Sign,
        Power = Awake,
    };

    /// <summary>加到末尾；已经有 MaxCount 个就不加。</summary>
    public static List<StatusPreset> Adding(StatusPreset preset, IReadOnlyList<StatusPreset> list)
        => list.Count < MaxCount ? list.Append(preset).ToList() : list.ToList();

    /// <summary>删掉一个；至少留一个（只剩一个时不删）。</summary>
    public static List<StatusPreset> Removing(string id, IReadOnlyList<StatusPreset> list)
        => list.Count > 1 ? list.Where(preset => preset.Id != id).ToList() : list.ToList();

    /// <summary>上移（-1）/ 下移（+1）一格；到头了、找不到都原样返回。</summary>
    public static List<StatusPreset> Moving(string id, int offset, IReadOnlyList<StatusPreset> list)
    {
        var result = list.ToList();
        var index = result.FindIndex(preset => preset.Id == id);
        if (index < 0 || index + offset < 0 || index + offset >= result.Count)
        {
            return result;
        }

        (result[index], result[index + offset]) = (result[index + offset], result[index]);
        return result;
    }

    /// <summary>列表里缺的自带状态（按 id 认：改过标题的也算还在）。</summary>
    public static List<StatusPreset> MissingBuiltIns(IReadOnlyList<StatusPreset> list)
        => BuiltIn().Where(preset => list.All(item => item.Id != preset.Id)).ToList();

    /// <summary>恢复自带的状态：缺的补到末尾，已有的不动；补到 MaxCount 为止。</summary>
    public static List<StatusPreset> RestoringBuiltIns(IReadOnlyList<StatusPreset> list)
        => list.Concat(MissingBuiltIns(list)).Take(MaxCount).ToList();

    /// <summary>删之前要不要确认：和自带的一模一样的不用（「恢复自带的状态」能原样加回来），自己加的、改过的要。</summary>
    public static bool IsPristine(StatusPreset preset) => BuiltIn().Any(builtIn => builtIn.SameAs(preset));

    /// <summary>详情改了一个：按 id 换掉。标题只有空白时留着原来的标题（空标题存不下，输入框里删光了重打是常事）。</summary>
    public static List<StatusPreset> Updating(IReadOnlyList<StatusPreset> list, StatusPreset draft)
        => list.Select(stored =>
        {
            if (stored.Id != draft.Id)
            {
                return stored;
            }

            var next = draft.Copy();
            if (OneLine(draft.Title).Length == 0)
            {
                next.Title = stored.Title;
            }

            return next;
        }).ToList();

    /// <summary>详情里正在改的这一份有什么问题（橙字；null = 没问题）。不拦着改：存进去的是收拾过的。</summary>
    public static string? Problem(StatusPreset draft)
    {
        var title = OneLine(draft.Title);
        if (title.Length == 0)
        {
            return "还没填标题";
        }

        if (Length(title) > MaxTitle)
        {
            return $"标题最多 {MaxTitle} 个字，后面的不会保存";
        }

        return Length(OneLine(draft.Detail)) > MaxDetail ? $"说明最多 {MaxDetail} 个字，后面的不会保存" : null;
    }

    // ---- JSON（设置导出文件、同步文件夹；键名和 mac 的 Codable 一样，没有说明时不写 detail）

    public static void Write(Utf8JsonWriter writer, StatusPreset preset)
    {
        writer.WriteStartObject();
        writer.WriteString("id", preset.Id);
        writer.WriteString("title", preset.Title);
        if (preset.Detail is { } detail)
        {
            writer.WriteString("detail", detail);
        }

        writer.WriteString("symbol", preset.Symbol);
        writer.WriteString("style", preset.Style);
        writer.WriteString("power", preset.Power);
        writer.WriteNumber("autoEndMinutes", preset.AutoEndMinutes);
        writer.WriteEndObject();
    }

    /// <summary>读一个（同 mac 的 Codable：除 detail 外每个键都要有、类型要对；样式、电源认不出来也算解不出）。</summary>
    public static StatusPreset? Read(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !TryString(element, "id", out var id) || !TryString(element, "title", out var title) ||
            !TryString(element, "symbol", out var symbol) || !TryString(element, "style", out var style) ||
            !TryString(element, "power", out var power) || !Styles.Contains(style) || !Powers.Contains(power) ||
            !element.TryGetProperty("autoEndMinutes", out var minutes) || minutes.ValueKind != JsonValueKind.Number ||
            !minutes.TryGetInt32(out var autoEnd))
        {
            return null;
        }

        string? detail = null;
        if (element.TryGetProperty("detail", out var detailElement))
        {
            if (detailElement.ValueKind == JsonValueKind.String)
            {
                detail = detailElement.GetString();
            }
            else if (detailElement.ValueKind != JsonValueKind.Null)
            {
                return null;
            }
        }

        return new StatusPreset
        {
            Id = id, Title = title, Detail = detail, Symbol = symbol, Style = style, Power = power, AutoEndMinutes = autoEnd,
        };
    }

    /// <summary>一组（设置导出文件里的 statusScreenPresets）：有一个解不出整组算解不出（同 mac：不连累整个文件，只是这组不导）。</summary>
    public static List<StatusPreset>? ReadList(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var list = new List<StatusPreset>();
        foreach (var item in element.EnumerateArray())
        {
            if (Read(item) is not { } preset)
            {
                return null;
            }

            list.Add(preset);
        }

        return list;
    }

    private static bool TryString(JsonElement element, string name, out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return true;
    }

    // ---- 文字

    /// <summary>换行当空格、去首尾空白（mac oneLine）。</summary>
    public static string OneLine(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        var joined = text.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ')
            .Replace(' ', ' ').Replace(' ', ' ').Replace('\u0085', ' ');
        return joined.Trim();
    }

    /// <summary>按「字」（字形簇，emoji 和带声调的字母算一个）数长度，同 mac 的 String.count。</summary>
    public static int Length(string text) => new StringInfo(text).LengthInTextElements;

    private static string Prefix(string text, int count)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }
}

/// <summary>状态屏的动画表情清单（mac StatusEmoji 的 choices / eyes / dim / plated；素材在 App 的 Resources\StatusEmoji）。</summary>
public static class StatusEmojiCatalog
{
    /// <summary>可选的 16 个（设置里的图标格子按这个顺序）；Name 是读屏读的中文名。</summary>
    public static readonly (string Id, string Name)[] Choices =
    {
        ("raised-hand", "举手"), ("waving-hand", "挥手"), ("glowing-star", "发光的星"), ("alarm-clock", "闹钟"),
        ("hourglass", "沙漏"), ("hot-beverage", "热饮"), ("zzz", "Zzz"), ("sleeping-face", "睡觉"),
        ("shushing-face", "嘘"), ("busts", "开会"), ("telephone", "电话"), ("rocket", "火箭"), ("robot", "机器人"),
        ("fire", "火"), ("high-voltage", "闪电"), ("black-cat", "黑猫"),
    };

    public static readonly HashSet<string> Ids = new(Choices.Select(choice => choice.Id), StringComparer.Ordinal);

    /// <summary>有人碰键盘鼠标时从屏幕边冒出来的那双眼睛：不在可选的里面。</summary>
    public const string Eyes = "eyes";

    /// <summary>颜色很深、在黑底上几乎看不见的（「开会」的剪影）：告示上垫一团柔和的亮光。</summary>
    public static readonly HashSet<string> Dim = new(StringComparer.Ordinal) { "busts" };

    /// <summary>当小图标用时深色外观下几乎看不见的：垫一块浅底（白 0.88，表情缩到 84%）。</summary>
    public static readonly HashSet<string> Plated = new(StringComparer.Ordinal) { "busts", "black-cat" };

    public static string? Name(string id) => Choices.FirstOrDefault(choice => choice.Id == id).Name;

    public static bool NeedsPlate(string id, bool dark) => dark && Plated.Contains(id);
}
