// 流式译文的累积与清洗（纯逻辑，配单测）：拼接增量；去掉开头的 <think>…</think>
// （开标签可能被拆在多个增量里，凑齐前先不显示）；最后去掉整段外面包的一层引号。
// 正文中间出现的同名标签原样保留。IsThinking：还在开头的 <think> 段里。
using System.Text;

namespace KittyTools.Core;

public sealed class StreamingText
{
    private readonly StringBuilder _raw = new();

    public string Raw => _raw.ToString();

    public void Append(string delta) => _raw.Append(delta);

    /// <summary>当前可显示的译文；还在思考段里时返回空。</summary>
    public string Visible
    {
        get
        {
            var text = _raw.ToString();
            var trimmedStart = text.TrimStart();
            if (trimmedStart.StartsWith("<think>", StringComparison.Ordinal))
            {
                var end = trimmedStart.IndexOf("</think>", StringComparison.Ordinal);
                if (end < 0)
                {
                    return string.Empty;
                }

                text = trimmedStart[(end + "</think>".Length)..];
            }
            else if (trimmedStart.Length > 0 && "<think>".StartsWith(trimmedStart, StringComparison.Ordinal))
            {
                return string.Empty; // 可能是被拆开的开标签，等下一段
            }

            return text.Trim();
        }
    }

    /// <summary>还在开头的 &lt;think&gt; 段里（开标签可能还没凑齐），没有可显示的正文。</summary>
    public bool IsThinking
    {
        get
        {
            var text = _raw.ToString().TrimStart();
            if (text.Length == 0)
            {
                return false;
            }

            if (text.StartsWith("<think>", StringComparison.Ordinal))
            {
                return text.IndexOf("</think>", StringComparison.Ordinal) < 0;
            }

            return "<think>".StartsWith(text, StringComparison.Ordinal);
        }
    }

    /// <summary>完成后的最终译文：再去掉外层引号。</summary>
    public string Final
    {
        get
        {
            var text = Visible;
            (string Open, string Close)[] pairs =
            {
                ("\"", "\""),
                ("“", "”"),
                ("「", "」"),
            };
            foreach (var (open, close) in pairs)
            {
                if (text.Length >= 2 && text.StartsWith(open, StringComparison.Ordinal) &&
                    text.EndsWith(close, StringComparison.Ordinal) &&
                    !text[1..^1].Contains(close, StringComparison.Ordinal))
                {
                    return text[1..^1].Trim();
                }
            }

            return text;
        }
    }
}
