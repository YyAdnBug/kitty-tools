// 往便签里粘网页、文稿（PLAN-v26 N1，照 mac 0.10.0 8ce9274d / 09c70e9d 的 NoteRichPaste）：剪贴板里的 HTML（CF_HTML「HTML Format」，
// 浏览器、Word、WPS、谷歌文档复制时都带）转成便签正文认的 Markdown：链接、粗体、斜体、删除线、行内代码、标题、列表、代码块留着。
// 只在设置里的 Markdown 开着、光标不在代码块里时这么粘（NoteEditor.PasteAsync）；一个标记都没转出来就照旧粘纯文本。
// Ctrl+Alt+Shift+V「粘贴为纯文本」总是粘纯文本。
// mac 交给系统把 HTML 解析成富文本再看字体；Windows 没有 AOT 能用的同款，这里自己扫标签（容错，不建 DOM）：
// - 块：p / div / li / h1–h6 / pre / tr / blockquote / br 各起一行；li 按外面套了几层 ul / ol 缩进（每层两格），ol 写「1. 」；
// - 行内：b / strong、i / em、s / strike / del、code / kbd / samp、a href，加上 style 里的 font-weight / font-style / text-decoration /
//   font-family（谷歌文档整段包在 <b style="font-weight:normal"> 里、Word 用 span 的 style 标粗体，都按 style 算）；
// - 整段等宽（pre，或整行都在 code / 等宽字体里）：一行的写成行内代码，连着几行包成代码块（中间的空行留在块里）；
// - 表格的单元格之间是制表符、一行一行；img / script / style / link / iframe 这类整个去掉；实体按 HTML 解码；pre 外面的空白并成一个。
// ponytail: 字里本来就有的 * _ ` [ 不转义（同 mac）；引用、图片不转；嵌套表格、CSS 类里的样式（<style> 里定义的）不认。
using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace KittyTools.Core.Notes;

public static partial class NoteRichPaste
{
    /// <summary>剪贴板 CF_HTML（带「Version:… StartFragment:…」头）里复制的那一段；没有头的当整段 HTML。</summary>
    public static string Fragment(string clipboardHtml)
    {
        var start = clipboardHtml.IndexOf("<!--StartFragment-->", StringComparison.OrdinalIgnoreCase);
        var end = clipboardHtml.IndexOf("<!--EndFragment-->", StringComparison.OrdinalIgnoreCase);
        if (start >= 0 && end > start)
        {
            return clipboardHtml[(start + "<!--StartFragment-->".Length)..end];
        }

        // 头里只有偏移、没写注释的（少见）：从 <body> 或第一个 < 起
        var body = clipboardHtml.IndexOf("<body", StringComparison.OrdinalIgnoreCase);
        var from = body >= 0 ? clipboardHtml.IndexOf('>', body) + 1 : clipboardHtml.IndexOf('<');
        return from > 0 ? clipboardHtml[from..] : clipboardHtml;
    }

    /// <summary>HTML → Markdown；一个标记都没转出来（没有格式）、或者转出来是空的，返回 null（照常粘纯文本）。</summary>
    public static string? Markdown(string html)
    {
        var (text, marked) = Convert(html);
        return marked && text.Length > 0 ? text : null;
    }

    /// <summary>粘进去的地方前后：围栏得独占一行，前面不是行首就先换行、后面不是行尾就补换行（同 mac fitting）。</summary>
    public static string Fitting(string markdown, char? previous, char? next)
    {
        var text = markdown;
        if (text.StartsWith("```", StringComparison.Ordinal) && previous is { } before && before != '\n' && before != '\r')
        {
            text = "\n" + text;
        }

        if (text.EndsWith("```", StringComparison.Ordinal) && next is { } after && after != '\n' && after != '\r')
        {
            text += "\n";
        }

        return text;
    }

    private sealed record Look(bool Bold, bool Italic, bool Strike, bool Code, string? Link);

    /// <summary>一个开着的标签对字的影响：null = 不改。</summary>
    private sealed record Effect(string Tag, bool? Bold, bool? Italic, bool? Strike, bool? Code, string? Link);

    private enum Kind
    {
        Text,
        Heading,
        Item,
        Code,
        Blank,
    }

    private sealed class Line
    {
        public Kind Kind;
        public int Level;
        public string Marker = string.Empty;
        public readonly List<(Look Look, string Text)> Runs = new();
        public readonly StringBuilder Raw = new();
    }

    public static (string Text, bool Marked) Convert(string html)
    {
        var source = Cleaned(html);
        var lines = new List<Line>();
        var effects = new List<Effect>();
        var lists = new List<bool>();
        var pre = 0;
        var heading = 0;
        Line? line = null;
        var cellOpen = false;

        Look Current()
        {
            bool bold = false, italic = false, strike = false, code = false;
            string? link = null;
            foreach (var effect in effects)
            {
                bold = effect.Bold ?? bold;
                italic = effect.Italic ?? italic;
                strike = effect.Strike ?? strike;
                code = effect.Code ?? code;
                link = effect.Link ?? link;
            }

            return new Look(bold, italic, strike, code, link);
        }

        void Break()
        {
            if (line is not null)
            {
                lines.Add(line);
            }

            line = null;
            cellOpen = false;
        }

        Line Open()
        {
            line ??= new Line { Kind = pre > 0 ? Kind.Code : heading > 0 ? Kind.Heading : Kind.Text, Level = heading };
            return line;
        }

        void AddText(string text)
        {
            if (pre > 0)
            {
                // pre 里的换行就是换行，原样
                // 紧跟在 <pre> 后面的那一个换行不算（同浏览器）
                var normalized = text.Replace("\r\n", "\n");
                if (line is null && normalized.StartsWith('\n'))
                {
                    normalized = normalized[1..];
                }

                var parts = normalized.Split('\n');
                for (var index = 0; index < parts.Length; index++)
                {
                    if (index > 0)
                    {
                        Break();
                        Open();
                    }

                    Open().Raw.Append(parts[index]);
                }

                return;
            }

            // 块和块之间的换行、缩进（只有空白）不开新行
            var collapsed = Whitespace().Replace(text, " ");
            if (line is null || line.Runs.All(run => run.Text.Trim(' ').Length == 0))
            {
                collapsed = collapsed.TrimStart(' ');
            }

            if (collapsed.Length == 0)
            {
                return;
            }

            var current = Open();
            // 跨标签的连着几个空白也并成一个（同浏览器：「前 <b> 粗 </b> 后」只有一个空格）
            if (current.Runs.Count > 0 && current.Runs[^1].Text.EndsWith(' ') && collapsed.StartsWith(' '))
            {
                collapsed = collapsed[1..];
                if (collapsed.Length == 0)
                {
                    return;
                }
            }

            var look = Current();
            if (current.Runs.Count > 0 && current.Runs[^1].Look == look)
            {
                current.Runs[^1] = (look, current.Runs[^1].Text + collapsed);
            }
            else
            {
                current.Runs.Add((look, collapsed));
            }
        }

        var position = 0;
        foreach (Match match in Tag().Matches(source))
        {
            if (match.Index > position)
            {
                AddText(WebUtility.HtmlDecode(source[position..match.Index]));
            }

            position = match.Index + match.Length;
            var closing = match.Groups[1].Value == "/";
            var name = match.Groups[2].Value.ToLowerInvariant();
            var attributes = match.Groups[3].Value;
            switch (name)
            {
                case "br":
                    if (pre > 0)
                    {
                        AddText("\n");
                    }
                    else
                    {
                        Open();
                        Break();
                    }

                    continue;
                case "p" or "div" or "blockquote" or "section" or "article" or "header" or "footer" or "dt" or "dd" or "figcaption" or "hr":
                    // 列表项里套着的段落（谷歌文档、Word 的 <li><p>…）：还没字时不断开，不然丢了列表符号
                    if (!closing && line is { Kind: Kind.Item } open && open.Runs.Count == 0)
                    {
                        continue;
                    }

                    Break();
                    continue;
                case "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                    Break();
                    heading = closing ? 0 : Math.Min(3, name[1] - '0');
                    continue;
                case "ul" or "ol":
                    Break();
                    if (closing)
                    {
                        if (lists.Count > 0)
                        {
                            lists.RemoveAt(lists.Count - 1);
                        }
                    }
                    else
                    {
                        lists.Add(name == "ol");
                    }

                    continue;
                case "li":
                    Break();
                    if (!closing)
                    {
                        var item = Open();
                        item.Kind = Kind.Item;
                        item.Marker = new string(' ', 2 * Math.Max(0, lists.Count - 1)) + (lists.Count > 0 && lists[^1] ? "1. " : "- ");
                    }

                    continue;
                case "pre":
                    Break();
                    pre = Math.Max(0, pre + (closing ? -1 : 1));
                    continue;
                case "tr":
                    Break();
                    continue;
                case "td" or "th":
                    if (!closing)
                    {
                        // 单元格之间一个制表符（同 mac：表格按系统给的制表符原样）
                        if (cellOpen && line is { } row && row.Runs.Count > 0)
                        {
                            row.Runs[^1] = (row.Runs[^1].Look, row.Runs[^1].Text + "\t");
                        }

                        cellOpen = true;
                    }

                    continue;
            }

            if (closing)
            {
                var index = effects.FindLastIndex(effect => effect.Tag == name);
                if (index >= 0)
                {
                    effects.RemoveAt(index);
                }

                continue;
            }

            if (EffectOf(name, attributes) is { } added && !attributes.TrimEnd().EndsWith('/'))
            {
                effects.Add(added);
            }
        }

        if (position < source.Length)
        {
            AddText(WebUtility.HtmlDecode(source[position..]));
        }

        Break();
        return Assemble(lines);
    }

    /// <summary>去掉注释、会去外面取东西的标签（同 mac withoutRemoteResources）、head 里的东西。</summary>
    private static string Cleaned(string html)
    {
        var text = Comments().Replace(html, string.Empty);
        text = ScriptOrStyle().Replace(text, string.Empty);
        return Remote().Replace(text, string.Empty);
    }

    private static Effect? EffectOf(string name, string attributes)
    {
        bool? bold = name is "b" or "strong" ? true : null;
        bool? italic = name is "i" or "em" ? true : null;
        bool? strike = name is "s" or "strike" or "del" ? true : null;
        bool? code = name is "code" or "kbd" or "samp" or "tt" ? true : null;
        string? link = null;
        if (name == "a" && Href().Match(attributes) is { Success: true } href)
        {
            var value = WebUtility.HtmlDecode(href.Groups[2].Value.Length > 0 ? href.Groups[2].Value : href.Groups[3].Value).Trim();
            if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto")
            {
                link = value;
            }
        }

        if (StyleOf(attributes) is { } style)
        {
            if (Property(style, "font-weight") is { } weight)
            {
                bold = weight is "bold" or "bolder" || (int.TryParse(weight, out var number) && number >= 600)
                    ? true
                    : weight is "normal" or "lighter" || (int.TryParse(weight, out var light) && light < 600) ? false : bold;
            }

            if (Property(style, "font-style") is { } fontStyle)
            {
                italic = fontStyle is "italic" or "oblique" ? true : fontStyle == "normal" ? false : italic;
            }

            if ((Property(style, "text-decoration") ?? Property(style, "text-decoration-line")) is { } decoration)
            {
                strike = decoration.Contains("line-through", StringComparison.Ordinal) ? true : strike;
            }

            if (Property(style, "font-family") is { } family)
            {
                code = Monospace().IsMatch(family) ? true : code;
            }
        }

        return bold is null && italic is null && strike is null && code is null && link is null
            ? new Effect(name, null, null, null, null, null)
            : new Effect(name, bold, italic, strike, code, link);
    }

    private static string? StyleOf(string attributes)
        => Style().Match(attributes) is { Success: true } match
            ? WebUtility.HtmlDecode(match.Groups[2].Value.Length > 0 ? match.Groups[2].Value : match.Groups[3].Value).ToLowerInvariant()
            : null;

    private static string? Property(string style, string name)
    {
        foreach (var part in style.Split(';'))
        {
            var colon = part.IndexOf(':');
            if (colon > 0 && part[..colon].Trim() == name)
            {
                return part[(colon + 1)..].Replace("!important", string.Empty, StringComparison.Ordinal).Trim();
            }
        }

        return null;
    }

    /// <summary>把行拼起来（同 mac assemble）：连着的代码行（中间的空行算在块里）两行以上包围栏、一行的写成行内代码；空行最多留一行、去掉首尾的。</summary>
    private static (string Text, bool Marked) Assemble(List<Line> lines)
    {
        // 整行都是等宽字的普通行也算代码行
        foreach (var line in lines.Where(line => line.Kind == Kind.Text && line.Runs.Count > 0))
        {
            var visible = line.Runs.Where(run => run.Text.Trim().Length > 0).ToList();
            if (visible.Count > 0 && visible.All(run => run.Look.Code && run.Look.Link is null))
            {
                line.Kind = Kind.Code;
                line.Raw.Append(string.Concat(line.Runs.Select(run => run.Text)).Trim());
            }
        }

        var output = new List<string>();
        var marked = false;
        void Blank()
        {
            if (output.Count > 0 && output[^1].Length > 0)
            {
                output.Add(string.Empty);
            }
        }

        bool IsBlank(Line line) => line.Kind == Kind.Blank ||
                                   (line.Kind is Kind.Text or Kind.Heading && line.Runs.All(run => run.Text.Trim().Length == 0));

        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            if (line.Kind == Kind.Code)
            {
                var end = index;
                var codeLines = 0;
                for (var cursor = index; cursor < lines.Count; cursor++)
                {
                    if (lines[cursor].Kind == Kind.Code)
                    {
                        end = cursor;
                        codeLines++;
                    }
                    else if (!IsBlank(lines[cursor]))
                    {
                        break;
                    }
                }

                var block = lines.Skip(index).Take(end - index + 1).Select(item => item.Kind == Kind.Code ? item.Raw.ToString() : string.Empty).ToList();
                marked = true;
                if (codeLines == 1)
                {
                    output.Add(InlineCode(block[0]));
                }
                else
                {
                    output.Add("```");
                    output.AddRange(block);
                    output.Add("```");
                }

                index = end;
                continue;
            }

            if (IsBlank(line))
            {
                Blank();
                continue;
            }

            var (text, hasMarkup) = Inline(line.Runs, heading: line.Kind == Kind.Heading);
            text = text.TrimEnd(' ');
            switch (line.Kind)
            {
                case Kind.Heading:
                    output.Add(new string('#', line.Level) + " " + text);
                    marked = true;
                    break;
                case Kind.Item:
                    output.Add(line.Marker + text);
                    marked = true;
                    break;
                default:
                    output.Add(text);
                    marked |= hasMarkup;
                    break;
            }
        }

        while (output.Count > 0 && output[^1].Length == 0)
        {
            output.RemoveAt(output.Count - 1);
        }

        while (output.Count > 0 && output[0].Length == 0)
        {
            output.RemoveAt(0);
        }

        return (string.Join("\n", output).Replace((char)0x2028, '\n').Replace((char)0x2029, '\n'), marked);
    }

    /// <summary>行内代码：字里有反引号就用两个包、两头留空格。</summary>
    private static string InlineCode(string code) => code.Contains('`') ? "`` " + code + " ``" : "`" + code + "`";

    /// <summary>行内：一样的连成一段再包标记，首尾的空白留在外面（同 mac inline；不间断空格、全角空格也留着）；标题里不加粗。</summary>
    private static (string Text, bool Marked) Inline(List<(Look Look, string Text)> runs, bool heading)
    {
        var marked = false;
        var builder = new StringBuilder();
        foreach (var (look, text) in runs)
        {
            static bool IsSpace(char c) => char.IsWhiteSpace(c) && c != '\n' && c != '\r';
            var leading = new string(text.TakeWhile(IsSpace).ToArray());
            var rest = text[leading.Length..];
            var trailing = new string(rest.Reverse().TakeWhile(IsSpace).Reverse().ToArray());
            var core = rest[..(rest.Length - trailing.Length)];
            if (core.Length == 0)
            {
                builder.Append(text);
                continue;
            }

            var wrapped = core;
            if (look.Code)
            {
                wrapped = InlineCode(wrapped);
            }
            else
            {
                if (look.Strike)
                {
                    wrapped = "~~" + wrapped + "~~";
                }

                if (look.Italic)
                {
                    wrapped = "*" + wrapped + "*";
                }

                if (look.Bold && !heading)
                {
                    wrapped = "**" + wrapped + "**";
                }
            }

            if (look.Link is { } link)
            {
                // 地址里的括号、空白转义：不然 ) 把链接截断
                wrapped = "[" + wrapped + "](" + link.Replace("(", "%28").Replace(")", "%29").Replace(" ", "%20") + ")";
            }

            marked |= wrapped != core;
            builder.Append(leading).Append(wrapped).Append(trailing);
        }

        return (builder.ToString(), marked);
    }

    [GeneratedRegex(@"<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:[^>""']|""[^""]*""|'[^']*')*)>")]
    private static partial Regex Tag();

    [GeneratedRegex(@"<!--.*?-->", RegexOptions.Singleline)]
    private static partial Regex Comments();

    [GeneratedRegex(@"<(script|style|head|title)\b.*?</\1\s*>", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex ScriptOrStyle();

    [GeneratedRegex(@"<(img|link|iframe|video|audio|source|object|embed|meta)\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex Remote();

    [GeneratedRegex(@"\bhref\s*=\s*(""([^""]*)""|'([^']*)')", RegexOptions.IgnoreCase)]
    private static partial Regex Href();

    [GeneratedRegex(@"\bstyle\s*=\s*(""([^""]*)""|'([^']*)')", RegexOptions.IgnoreCase)]
    private static partial Regex Style();

    [GeneratedRegex(@"monospace|consolas|courier|menlo|monaco|cascadia|sfmono|sf mono|source code|jetbrains", RegexOptions.IgnoreCase)]
    private static partial Regex Monospace();

    [GeneratedRegex(@"[ \t\r\n\f]+")]
    private static partial Regex Whitespace();
}
