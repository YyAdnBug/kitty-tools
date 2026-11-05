// 启动器计算器里的汇率换算（PLAN-v12 N1，照 mac Launcher/ExchangeRates.swift：ab0fab4a、cf621790；纯函数配单测）：
// 「100 usd」「100 美元 转 人民币」「$100 in jpy」「100刀」：左边一个数加货币（ISO 代码；简体 / 繁体 / 英文名，159 种都有；
// 下面一张表里的口语叫法和符号），右边货币，连接词和单位换算的一样（另加「兑」）；只写左边时换成本机地区的货币（左边就是它时换成美元）。
// 结果大字「723.45 CNY」（分组，小数位按币种：日元 0 位、人民币 2 位，不到 1 的按 4 位有效数字；金额是 1 时是在看汇率，按汇率的精度 6.6714），
// Enter 粘贴 / Tab 写回的不分组；右侧小字「人民币 · 11-03 汇率」；Ctrl+K 另有「复制原始数字」「复制汇率」（1 USD = 6.6714 CNY）。
// 输「汇率」（huilv、currency）出一行用法提示，Enter / Tab 把示例「100 美元 转 日元」填进搜索框。
// 货币打到一半（「100 美元 转 英」「100 usd to gb」，或「转」后面还没打）列候选：中文名 + 代码 · 英文名，Enter / Tab 补全；用过的货币排最前。
// 也认：金额带倍数（100万日元、1.5k usd、2w 人民币）或写成算式（(100+50) 美元）；货币写在前面（usd 100、US$100、JP¥100）；
// 不写金额只问汇率（美元兑人民币、USD/CNY、usd cny、美元汇率，按 1 算）；口语问法（是多少、等于多少、能换多少、多少钱、对）、繁体、结尾的「？」「汇率」。
// 货币名表（Resources/currencies.txt）在 Mac 上用系统的 Locale 生成（windows/tools/currency-table.swift），两边一字不差。
// 汇率：jsDelivr 上的 fawazahmed0/currency-api（CC0、不要密钥），连不上换它自己的备用地址；只留表里的 ISO 货币。
// 这里只有解析、换算、候选和表的编解码；什么时候取、存在哪在 App 的 LauncherModel / ExchangeRateStore（停 0.3 s 再取，同 ip）。
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KittyTools.Core;

public static partial class ExchangeRates
{
    /// <summary>一天的汇率：1 美元换 Rates[代码] 那么多（大写 ISO 4217）；Date 是数据源那天（yyyy-MM-dd），FetchedAt 是取到的时刻（Unix 毫秒）。</summary>
    public sealed record Table(string Date, long FetchedAt, IReadOnlyDictionary<string, double> Rates);

    /// <summary>一次换算：多少、从哪种换成哪种（To 是 null = 没写，换成本机地区的货币）。</summary>
    public sealed record Request(double Amount, string From, string? To);

    /// <summary>一种货币：代码、小数位、简体 / 繁体 / 英文名、简体名的全拼。</summary>
    private sealed record Currency(string Code, int Digits, string Chinese, string Traditional, string English, string Pinyin);

    /// <summary>输到汇率换算之后等多久才联网取。</summary>
    public const int FetchDelayMs = 300;

    /// <summary>存着的表过了多久，下次用到时再取一份（数据源一天一更）。</summary>
    public const long MaxAgeMs = 6 * 3600 * 1000L;

    /// <summary>用法提示那一行的 Target（面板按它取色块和右侧「汇率」）。</summary>
    public const string PromptTarget = "currency";

    /// <summary>候选行的 Target 前缀（面板按它取色块和右侧「货币」）。</summary>
    public const string SuggestionPrefix = "currency-";

    /// <summary>记几种用过的货币。</summary>
    public const int RecentLimit = 8;

    /// <summary>数据源：1 美元换多少别的货币（键是小写代码）；jsDelivr 连不上换项目自己的备用地址。</summary>
    public static readonly IReadOnlyList<string> Sources = new[]
    {
        "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json",
        "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json",
    };

    private static readonly Lazy<Dictionary<string, Currency>> CurrencyTable = new(LoadCurrencies);
    private static readonly Lazy<Dictionary<string, string>> NameTable = new(BuildNames);
    private static readonly Lazy<List<(string Code, List<string> Keys)>> SearchKeyTable = new(BuildSearchKeys);

    private static Dictionary<string, Currency> Currencies => CurrencyTable.Value;

    /// <summary>表里认的 ISO 货币代码（159 种）。</summary>
    public static IReadOnlyCollection<string> IsoCodes => Currencies.Keys;

    /// <summary>该取新的了：过了 MaxAgeMs，或者取的时刻比现在还晚（系统时钟往回调过）。</summary>
    public static bool IsStale(Table table, long nowMs)
    {
        var age = nowMs - table.FetchedAt;
        return age < 0 || age >= MaxAgeMs;
    }

    /// <summary>本机地区的货币（只写左边时换成它）：系统给的不在表里时按人民币。</summary>
    public static string HomeOr(string? iso)
        => iso is { Length: 3 } && Currencies.ContainsKey(iso.ToUpperInvariant()) ? iso.ToUpperInvariant() : "CNY";

    // MARK: 解析

    /// <summary>
    /// 两种货币之间的说法：英文的前后要有空格；中文的口语（换多少、是多少、等于多少、对、合）、繁体、外汇的「USD/CNY」。
    /// 同一处先对上长的。拆的时候每一处都试（「100/3 usd to cny」在「/」拆不开，接着试「to」）。
    /// </summary>
    [GeneratedRegex(@"\s+(?:to|in|into|as)\s+|换算成|換算成|转换成|轉換成|兑换成|兌換成|换成|換成|转成|轉成|兑换|兌換|换算|換算|折合|等于多少|等於多少|等于|等於|是多少|多少|对|對|换|換|转|轉|兑|兌|合|=|->|→|/", RegexOptions.IgnoreCase)]
    private static partial Regex Connector();

    [GeneratedRegex(@"^(?:汇率|匯率)\s*")]
    private static partial Regex LeadingRate();

    [GeneratedRegex(@"\s*(?:汇率|匯率|exchange\s*rates?|rates?)$", RegexOptions.IgnoreCase)]
    private static partial Regex TrailingRate();

    [GeneratedRegex(@"\s*(?:多少钱|是多少|等于多少|等於多少|多少|等于|等於|=)$")]
    private static partial Regex TrailingQuestion();

    [GeneratedRegex(@"^(?:多少|成)\s*")]
    private static partial Regex LeadingTarget();

    /// <summary>货币在前：「usd 100」「US$100」「JP¥(100+50)」。</summary>
    [GeneratedRegex(@"^(?<name>[^\d(]*[^\d\s(])\s*(?<value>[\d(].*)$")]
    private static partial Regex NameFirst();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}$")]
    private static partial Regex DateShape();

    private const string AmountCharacters = "0123456789. +-*/()%^";

    /// <summary>金额结尾的倍数：k / 千、w / 万、m（百万）、亿。</summary>
    private static readonly Dictionary<char, double> Multipliers = new()
    {
        ['k'] = 1e3, ['K'] = 1e3, ['千'] = 1e3, ['w'] = 1e4, ['W'] = 1e4, ['万'] = 1e4, ['m'] = 1e6, ['M'] = 1e6, ['亿'] = 1e8,
    };

    /// <summary>问法里不影响意思的字。</summary>
    private static readonly string[] Fillers = { "请问", "可以", "大概", "大约", "现在", "今天", "能", "的", "呢", "吗", "?" };

    /// <summary>
    /// 「100 usd」「100美元转人民币」「$100 in jpy」「美元兑人民币」「100万日元是多少人民币」；不是汇率换算就 null。
    /// 没写金额（只问汇率）按 1 算，但两边都要是确定的货币（见 Confident）。
    /// </summary>
    public static Request? RequestFor(string query)
    {
        var (text, asksRate) = Clean(query);
        if (text.Length == 0)
        {
            return null;
        }

        foreach (Match match in Connector().Matches(text))
        {
            var right = TrimmedTarget(text[(match.Index + match.Length)..]);
            if (Pair(text[..match.Index], right) is { } request)
            {
                return request;
            }
        }

        // 空格隔开的两种货币：「usd cny」「100 usd cny」
        var space = LastWhitespace(text);
        if (space >= 0 && Pair(text[..space], text[(space + 1)..]) is { } spaced)
        {
            return spaced;
        }

        if (Parse(text) is not { } side || (side.Amount is null && !(asksRate && Confident(text, side.Code))))
        {
            return null;
        }

        return new Request(side.Amount ?? 1, side.Code, null);
    }

    /// <summary>货币名（不分大小写）→ 代码：表里的 ISO 代码（三个字母），或者简体 / 繁体 / 英文名、口语叫法；不认识是 null。</summary>
    public static string? CurrencyCode(string name)
    {
        var key = name.Trim().ToLowerInvariant();
        if (key.Length == 3 && Currencies.ContainsKey(key.ToUpperInvariant()))
        {
            return key.ToUpperInvariant();
        }

        return NameTable.Value.TryGetValue(key, out var code) ? code : null;
    }

    /// <summary>货币的中文名（结果右侧小字写它）：「人民币」「新台币」「沙特里亚尔」；不认识的原样。</summary>
    public static string Name(string code) => Currencies.TryGetValue(code, out var currency) ? currency.Chinese : code;

    private sealed record Side(double? Amount, string Code);

    /// <summary>左边一个金额加货币（或只有货币）、右边一种货币。</summary>
    private static Request? Pair(string left, string right)
    {
        if (CurrencyCode(right) is not { } to || Parse(left) is not { } side)
        {
            return null;
        }

        if (side.Amount is null && (!Confident(left, side.Code) || !Confident(right, to)))
        {
            return null;
        }

        return new Request(side.Amount ?? 1, side.Code, to);
    }

    /// <summary>
    /// 没写金额时只认确定是货币的写法：中文名、符号、口语叫法、大写代码，小写代码只认常用的那些——「all to try」「pen cup」
    /// 是英文，不是阿尔巴尼亚列克换土耳其里拉。
    /// </summary>
    private static bool Confident(string token, string code)
    {
        token = token.Trim();
        if (!string.Equals(token, code, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return token == code || Common.Contains(code);
    }

    /// <summary>
    /// 问法里不影响意思的字去掉，开头的「汇率」、结尾的「汇率 / rate」和「多少钱 / 是多少 / 等于多少 / 多少 / 等于 / =」也去掉；
    /// 去掉过什么说明是在问汇率（没写金额也行）。
    /// </summary>
    private static (string Text, bool AsksRate) Clean(string query)
    {
        var text = Calculator.Normalize(query);
        foreach (var filler in Fillers)
        {
            text = text.Replace(filler, string.Empty, StringComparison.Ordinal);
        }

        text = text.Trim();
        var before = text;
        text = LeadingRate().Replace(text, string.Empty);
        text = TrailingRate().Replace(text, string.Empty);
        text = TrailingQuestion().Replace(text, string.Empty).Trim();
        return (text, text != before);
    }

    /// <summary>右边的货币前面的「多少」「成」（「换多少人民币」「转成日元」里连接词后面剩下的）。</summary>
    private static string TrimmedTarget(string text) => LeadingTarget().Replace(text.Trim(), string.Empty);

    /// <summary>一边：金额在前（「100 usd」「100万日元」「(100+50) 美元」）、货币在前（「usd 100」「US$100」），或者只有货币。</summary>
    private static Side? Parse(string text)
    {
        text = text.Trim();
        if (CurrencyCode(text) is { } only)
        {
            return new Side(null, only);
        }

        var match = NameFirst().Match(text);
        if (match.Success && CurrencyCode(match.Groups["name"].Value) is { } named &&
            Value(match.Groups["value"].Value) is { } namedValue)
        {
            return new Side(namedValue, named);
        }

        // 金额在前：金额后面紧跟的 k / m / w / 千 / 万 / 亿 先当货币名的一部分试（「1 mop」是澳门元），不是再当倍数（「5m usd」）
        var end = AmountEnd(text);
        if (end <= 0)
        {
            return null;
        }

        var name = text[end..];
        if (CurrencyCode(name) is { } code && Value(text[..end]) is { } value)
        {
            return new Side(value, code);
        }

        if (!Multipliers.ContainsKey(name[0]) || CurrencyCode(name[1..]) is not { } scaledCode ||
            Value(text[..(end + 1)]) is not { } scaled)
        {
            return null;
        }

        return new Side(scaled, scaledCode);
    }

    /// <summary>第一个不是金额字符的位置；全是金额字符时 -1。</summary>
    private static int AmountEnd(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            if (!AmountCharacters.Contains(text[index]))
            {
                return index;
            }
        }

        return -1;
    }

    private static int LastWhitespace(string text)
    {
        for (var index = text.Length - 1; index >= 0; index--)
        {
            if (char.IsWhiteSpace(text[index]))
            {
                return index;
            }
        }

        return -1;
    }

    /// <summary>金额：数字或算式（交给计算器算），结尾可以带倍数；要有数字。</summary>
    private static double? Value(string text)
    {
        var compact = new string(text.Where(character => !char.IsWhiteSpace(character)).ToArray());
        var scale = 1.0;
        if (compact.Length > 0 && Multipliers.TryGetValue(compact[^1], out var multiplier))
        {
            scale = multiplier;
            compact = compact[..^1];
        }

        if (!compact.Any(character => character is >= '0' and <= '9') || Calculator.Evaluate(compact) is not { } value)
        {
            return null;
        }

        return value * scale;
    }

    // MARK: 用法提示和候选

    /// <summary>搜索框里输这些（不分大小写、空格）出用法提示；打了开头也出（LauncherMatch.PromptMatch）。</summary>
    private static readonly string[] Keywords = { "currency", "汇率", "汇率换算", "huilv", "exchangerate" };

    /// <summary>
    /// 输「汇率」：一行用法提示（标题写做什么、副标题写怎么用），Enter / Tab 把示例填进搜索框。
    /// 整个打对了排在最前面，只打了开头（「curr」「汇」）排在本地结果后面。
    /// </summary>
    public static (List<LauncherItem> Exact, List<LauncherItem> Partial) PromptItems(string query)
    {
        var item = new LauncherItem
        {
            Kind = LauncherKind.Prompt,
            Target = PromptTarget,
            Title = "汇率换算…",
            Subtitle = "输入「100 美元 转 日元」，Enter 或 Tab 填进示例",
            Completion = "100 美元 转 日元",
        };
        return LauncherMatch.PromptMatch(query, Keywords) switch
        {
            PromptMatchKind.Exact => (new List<LauncherItem> { item }, new List<LauncherItem>()),
            PromptMatchKind.Partial => (new List<LauncherItem>(), new List<LauncherItem> { item }),
            _ => (new List<LauncherItem>(), new List<LauncherItem>()),
        };
    }

    /// <summary>常用的货币：候选同分时排前面，「转」后面还没打字时列前 6 种。</summary>
    private static readonly string[] Common =
    {
        "CNY", "USD", "EUR", "JPY", "GBP", "HKD", "TWD", "KRW", "AUD", "CAD", "SGD", "CHF", "MOP", "THB",
        "MYR", "RUB", "INR", "NZD", "VND", "PHP", "IDR",
    };

    /// <summary>
    /// 打货币打到一半时的候选：「100 美元 转 英」「100 usd to gb」「100 美」「100万日」「美元兑英」，和「100 美元 转」后面还没打字
    /// （先列用过的，再列常用的）。每行中文名 + 代码 · 英文名，Enter / Tab 把打了的那一截换成它（打的是字母就换成代码，否则换成中文名）。
    /// 已经是一种货币了不出（那时出结果）；左边打的正好是单位名（「10 km」「100 g」「5 m」，是在换算单位）不出，别的打 1 个字母就出。
    /// recents：用过的货币，排在同一档的最前面。调用方只在没有计算结果时用它。
    /// </summary>
    public static List<LauncherItem> Suggestions(string query, IReadOnlyList<string>? recents = null)
    {
        // 设置文件里的用过的货币按不可信的读（mac loadRecents 也只留认得的）：不认得的代码后面 Currencies[code] 会抛。
        var used = recents?.Where(code => code is not null && Currencies.ContainsKey(code)).ToList() ?? new List<string>();
        var raw = query.Trim();
        var text = Calculator.Normalize(raw);
        string? partial = null;
        string? exclude = null;
        // 连接词后面：从最后一处往前试，左边要是一个（确定的）金额加货币
        foreach (var match in Connector().Matches(text).Reverse())
        {
            var left = Clean(text[..match.Index]).Text;
            if (Parse(left) is not { } side || (side.Amount is null && !Confident(left, side.Code)))
            {
                continue;
            }

            partial = TrimmedTarget(text[(match.Index + match.Length)..]);
            exclude = side.Code;
            break;
        }

        // 金额后面：「100 u」「100万日」（倍数后面跟着空格或汉字才当倍数，「1 mo」是在打澳门元）
        if (partial is null)
        {
            var end = AmountEnd(text);
            if (end > 0 && Value(text[..end]) is not null)
            {
                var rest = text[end..];
                // 带了倍数就是在说钱：「100万日」的「日」不当成天
                var scaled = false;
                if (rest.Length > 1 && Multipliers.ContainsKey(rest[0]) && (char.IsWhiteSpace(rest[1]) || rest[1] > 0x7F))
                {
                    rest = rest[1..];
                    scaled = true;
                }

                var name = rest.Trim();
                if (name.Length == 0 || (!scaled && Calculator.IsUnit(name)))
                {
                    return new List<LauncherItem>();
                }

                partial = name;
            }
        }

        if (partial is null || CurrencyCode(partial) is not null)
        {
            return new List<LauncherItem>();
        }

        var key = new string(partial.ToLowerInvariant().Where(character => !char.IsWhiteSpace(character)).ToArray());
        int Recent(string code) => used.IndexOf(code) is var at and >= 0 ? at : used.Count;
        int Usual(string code) => Array.IndexOf(Common, code) is var at and >= 0 ? at : Common.Length;
        List<string> codes;
        if (key.Length == 0)
        {
            var seen = new HashSet<string> { exclude ?? string.Empty };
            codes = used.Concat(Common).Where(seen.Add).Take(6).ToList();
        }
        else
        {
            var ascii = key.All(character => character < 0x80);
            codes = SearchKeyTable.Value
                .Select(entry =>
                {
                    var best = int.MaxValue;
                    foreach (var name in entry.Keys)
                    {
                        var rank = name == key ? 0
                            : name.StartsWith(key, StringComparison.Ordinal) ? 1
                            : !ascii && name.Contains(key, StringComparison.Ordinal) ? 2
                            : int.MaxValue;
                        best = Math.Min(best, rank);
                    }

                    return (Rank: best, entry.Code);
                })
                .Where(entry => entry.Rank != int.MaxValue)
                .OrderBy(entry => entry.Rank)
                .ThenBy(entry => Recent(entry.Code))
                .ThenBy(entry => Usual(entry.Code))
                .ThenBy(entry => entry.Code, StringComparer.Ordinal)
                .Select(entry => entry.Code)
                .Take(6)
                .ToList();
        }

        var before = partial.Length <= raw.Length ? raw[..^partial.Length] : string.Empty;
        var prefix = before.Trim();
        var joiner = partial.Length == 0 || (before.Length > 0 && char.IsWhiteSpace(before[^1])) ? " " : string.Empty;
        var typedLetters = key.Length > 0 && key.All(character => character < 0x80);
        return codes.Select(code => new LauncherItem
        {
            Kind = LauncherKind.Prompt,
            Target = SuggestionPrefix + code,
            Title = Name(code),
            Subtitle = $"{code} · {Currencies[code].English}",
            Completion = prefix + joiner + (typedLetters ? code : Name(code)),
        }).ToList();
    }

    /// <summary>用了一次换算（Enter 粘贴、复制）：它的两种货币挪到最前面（目标在前），最多留 RecentLimit 种。</summary>
    public static List<string> Remembering(string query, IReadOnlyList<string> recents, string home)
    {
        if (RequestFor(query) is not { } request)
        {
            return recents.ToList();
        }

        var seen = new HashSet<string>();
        return new[] { Target(request, home), request.From }.Concat(recents)
            .Where(code => Currencies.ContainsKey(code) && seen.Add(code))
            .Take(RecentLimit)
            .ToList();
    }

    // MARK: 换算

    /// <summary>换成哪种：写了就是它；只写了一种时是本机地区的货币，左边就是它时换成美元（美国是欧元）。</summary>
    public static string Target(Request request, string home)
        => request.To ?? (request.From != home ? home : home == "USD" ? "EUR" : "USD");

    /// <summary>按表换算；表里没有这两种货币就 null。</summary>
    public static Calculator.Result? Result(Request request, Table table, string home)
    {
        var to = Target(request, home);
        if (!table.Rates.TryGetValue(request.From, out var fromRate) || !table.Rates.TryGetValue(to, out var toRate) ||
            fromRate <= 0)
        {
            return null;
        }

        var rate = toRate / fromRate;
        var value = request.Amount * rate;
        if (!double.IsFinite(value))
        {
            return null;
        }

        // 1 个（「美元兑人民币」「1 usd」）是在看汇率：按汇率的精度（6.6714、0.149893），不按币种的小数位（6.67）
        string Format(bool grouped) => request.Amount == 1 ? Calculator.Quantity(value, grouped) : Amount(value, to, grouped);
        var plain = Format(false);
        var date = table.Date.Length >= 5 ? table.Date[^5..] : table.Date;
        return new Calculator.Result(
            Format(true) + " " + to,
            plain + " " + to,
            new[]
            {
                new CalcCopy("复制原始数字", plain),
                new CalcCopy("复制汇率", $"1 {request.From} = {Calculator.Quantity(rate, grouped: false)} {to}"),
            },
            $"{Name(to)} · {date} 汇率");
    }

    /// <summary>
    /// 金额：小数位按币种（日元 0 位、人民币 2 位、科威特第纳尔 3 位）；不到 1 的按 4 位有效数字（100 韩元 = 0.07459 美元，
    /// 按 2 位小数就成了 0.07，1 印尼盾成了 0.00）。
    /// </summary>
    public static string Amount(double value, string code, bool grouped)
    {
        if (value != 0 && Math.Abs(value) < 1)
        {
            return Calculator.Digits(value, 4, significant: true, grouped: grouped, scientific: false);
        }

        var digits = Currencies.TryGetValue(code, out var currency) ? currency.Digits : 2;
        var text = Calculator.Digits(value, digits, significant: false, grouped: grouped, scientific: false);
        if (digits == 0)
        {
            return text;
        }

        var point = text.IndexOf('.');
        var have = point < 0 ? 0 : text.Length - point - 1;
        return (point < 0 ? text + "." : text) + new string('0', Math.Max(0, digits - have));
    }

    /// <summary>还没有汇率时那一行（不能粘贴、不能补全，同 ip 的占位行）：正在取 / 没取到。</summary>
    public static LauncherItem Placeholder(string query, bool failed) => new()
    {
        Kind = LauncherKind.Calculation,
        Target = query,
        Title = failed ? "没取到汇率，检查一下网络" : "正在取汇率…",
        Subtitle = "汇率",
        Note = "汇率",
    };

    // MARK: 表的编解码

    /// <summary>
    /// 数据源回的 JSON（{"date":"2026-11-03","usd":{"cny":7.1,…}}）→ 表：只留表里的 ISO 货币、正的有限数；
    /// 日期不像 yyyy-MM-dd、没有美元、不到 20 种的不要（被劫持到登录页、格式变了）。
    /// </summary>
    public static Table? FromReply(string json, long fetchedAt)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("date", out var date) || date.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("usd", out var usd) || usd.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            return Validated(date.GetString() ?? string.Empty, fetchedAt, usd);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>存进数据目录的样子：{"date":…,"fetchedAt":毫秒,"rates":{"CNY":7.1,…}}。</summary>
    public static string Encode(Table table)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("date", table.Date);
            writer.WriteNumber("fetchedAt", table.FetchedAt);
            writer.WriteStartObject("rates");
            foreach (var (code, rate) in table.Rates.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                writer.WriteNumber(code, rate);
            }

            writer.WriteEndObject();
            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>读回存着的表；坏的、不像样的是 null（照数据源回的那样验一遍）。</summary>
    public static Table? Decode(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("date", out var date) || date.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("fetchedAt", out var fetched) || fetched.ValueKind != JsonValueKind.Number ||
                !fetched.TryGetInt64(out var fetchedAt) ||
                !root.TryGetProperty("rates", out var rates) || rates.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            return Validated(date.GetString() ?? string.Empty, fetchedAt, rates);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static Table? Validated(string date, long fetchedAt, JsonElement rates)
    {
        if (!DateShape().IsMatch(date))
        {
            return null;
        }

        var result = new Dictionary<string, double>();
        foreach (var property in rates.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.Number && property.Value.TryGetDouble(out var rate) &&
                rate > 0 && double.IsFinite(rate) && Currencies.ContainsKey(property.Name.ToUpperInvariant()))
            {
                result[property.Name.ToUpperInvariant()] = rate;
            }
        }

        return result.ContainsKey("USD") && result.Count >= 20 ? new Table(date, fetchedAt, result) : null;
    }

    // MARK: 货币表

    /// <summary>Resources/currencies.txt：代码 \t 小数位 \t 简体名 \t 繁体名 \t 英文名 \t 简体名的全拼。</summary>
    private static Dictionary<string, Currency> LoadCurrencies()
    {
        var map = new Dictionary<string, Currency>(StringComparer.Ordinal);
        using var stream = typeof(ExchangeRates).Assembly.GetManifestResourceStream("KittyTools.Core.Resources.currencies.txt");
        if (stream is null)
        {
            return map;
        }

        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            var parts = line.Split('\t');
            if (parts.Length >= 6 && parts[0].Length == 3 && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var digits))
            {
                map[parts[0]] = new Currency(parts[0], digits, parts[2], parts[3], parts[4], parts[5]);
            }
        }

        return map;
    }

    /// <summary>
    /// 先是表里的简体 / 繁体 / 英文名，再是下面这张口语叫法：
    /// ponytail: 常用的二十几种货币的口语叫法、简称和符号；¥ 当人民币（日元写 jpy / 日元 / 円），「比索」「克朗」这类几国同名的
    /// 要写全；缺了往表里加一行（mac 那张一起加）。pound 不收（和磅撞，「1 pound to kg」是单位换算）。
    /// </summary>
    private static Dictionary<string, string> BuildNames()
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var currency in Currencies.Values)
        {
            names[currency.Chinese.ToLowerInvariant()] = currency.Code;
        }

        foreach (var currency in Currencies.Values.Where(currency => currency.Traditional.Length > 0))
        {
            names[currency.Traditional.ToLowerInvariant()] = currency.Code;
        }

        foreach (var currency in Currencies.Values.Where(currency => currency.English.Length > 0))
        {
            names[currency.English.ToLowerInvariant()] = currency.Code;
        }

        (string Code, string[] Aliases)[] table =
        {
            ("CNY", new[] { "人民币", "元", "块", "块钱", "rmb", "yuan", "¥", "cn¥", "rmb¥" }),
            ("USD", new[] { "美元", "美金", "刀", "美刀", "$", "us$", "dollar", "dollars", "buck", "bucks" }),
            ("EUR", new[] { "欧元", "欧", "€", "euro", "euros" }),
            ("JPY", new[] { "日元", "日币", "円", "yen", "jp¥" }),
            ("GBP", new[] { "英镑", "£", "quid" }),
            ("HKD", new[] { "港币", "港元", "港纸", "hk$" }),
            ("TWD", new[] { "台币", "新台币", "nt$" }),
            ("MOP", new[] { "澳门元", "澳门币", "葡币" }),
            ("KRW", new[] { "韩元", "韩币", "₩", "won" }),
            ("AUD", new[] { "澳元", "澳币", "a$" }),
            ("CAD", new[] { "加元", "加币", "c$" }),
            ("SGD", new[] { "新加坡元", "新币", "坡币", "s$" }),
            ("CHF", new[] { "瑞士法郎", "瑞郎" }),
            ("RUB", new[] { "卢布", "₽" }),
            ("INR", new[] { "卢比", "印度卢比", "₹" }),
            ("THB", new[] { "泰铢", "฿" }),
            ("MYR", new[] { "林吉特", "马币", "令吉" }),
            ("VND", new[] { "越南盾", "₫" }),
            ("PHP", new[] { "菲律宾比索", "₱" }),
            ("IDR", new[] { "印尼盾" }),
            ("NZD", new[] { "新西兰元", "纽币" }),
            ("SEK", new[] { "瑞典克朗" }),
            ("NOK", new[] { "挪威克朗" }),
            ("DKK", new[] { "丹麦克朗" }),
            ("TRY", new[] { "土耳其里拉", "₺" }),
            ("AED", new[] { "迪拉姆" }),
            ("BRL", new[] { "雷亚尔", "r$" }),
            ("MXN", new[] { "墨西哥比索" }),
            ("ZAR", new[] { "兰特" }),
            ("ILS", new[] { "₪", "谢克尔", "新谢克尔" }),
            ("UAH", new[] { "₴", "格里夫纳" }),
        };
        foreach (var (code, aliases) in table)
        {
            foreach (var alias in aliases)
            {
                names[alias.ToLowerInvariant()] = code;
            }
        }

        return names;
    }

    /// <summary>每种货币能用来搜的叫法（小写、去空格）：代码、各种名字、英文名里的每个词、简体名的全拼、口语叫法。</summary>
    private static List<(string Code, List<string> Keys)> BuildSearchKeys()
    {
        var aliases = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var (name, code) in NameTable.Value)
        {
            if (!aliases.TryGetValue(code, out var list))
            {
                aliases[code] = list = new List<string>();
            }

            list.Add(name);
        }

        return Currencies.Keys.OrderBy(code => code, StringComparer.Ordinal).Select(code =>
        {
            var currency = Currencies[code];
            var keys = new List<string> { code.ToLowerInvariant() };
            if (aliases.TryGetValue(code, out var named))
            {
                keys.AddRange(named);
            }

            keys.Add(currency.Chinese);
            if (currency.Pinyin.Length > 0)
            {
                keys.Add(currency.Pinyin);
            }

            var words = currency.English.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            keys.Add(string.Concat(words));
            keys.AddRange(words);
            return (Code: code, Keys: keys.Select(key => key.Replace(" ", string.Empty, StringComparison.Ordinal)).ToList());
        }).ToList();
    }
}
