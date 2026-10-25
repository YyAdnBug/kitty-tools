// 剪贴板预览卡的判断规则（纯函数，配单测）：
//  - 像代码的正文用等宽字体（PLAN-v2 §3.5「像代码的用等宽字体」）；
//  - 正文就是一个颜色值时显示色块（#RGB / #RRGGBB / #AARRGGBB / rgb(...) / rgba(...)）。
namespace KittyTools.Core;

public static class PreviewRules
{
    /// <summary>像一段代码：多行 + 缩进 / 括号 / 常见关键字，且几乎没有中文。</summary>
    public static bool LooksLikeCode(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var value = text.Trim();
        if (value.Length > 20_000)
        {
            return false;
        }

        // 中文正文（一段话、一条笔记）基本不按代码处理。
        var cjk = value.Count(ch => ch >= 0x4E00 && ch <= 0x9FFF);
        if (cjk > value.Length / 6)
        {
            return false;
        }

        var lines = value.Split('\n');
        var indented = lines.Count(line => line.Length > 0 && (line.StartsWith("    ", StringComparison.Ordinal) || line.StartsWith('\t')));
        var braces = value.Contains('{') && value.Contains('}');
        var tokens = new[]
        {
            "=>", "==", "!=", ";\n", ";\r", "();", "function ", "def ", "class ", "import ", "using ",
            "const ", "let ", "var ", "public ", "private ", "return ", "</", "#include", "SELECT ",
            "INSERT ", "UPDATE ", "CREATE TABLE", "```",
        };
        var hits = tokens.Count(token => value.Contains(token, StringComparison.Ordinal));
        return hits >= 2 ||
               (hits >= 1 && (indented >= 1 || lines.Length >= 2)) ||
               braces && lines.Length >= 2 ||
               indented >= 2 && lines.Length >= 3;
    }

    /// <summary>整条正文就是一个颜色值：给出 RGB（#RGB 会展开）。</summary>
    public static bool TryParseColor(string? text, out byte r, out byte g, out byte b)
    {
        r = g = b = 0;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var value = text.Trim();
        if (value.Length is < 4 or > 32)
        {
            return false;
        }

        if (value.StartsWith('#'))
        {
            var hex = value[1..];
            if (hex.Length == 3 && hex.All(Uri.IsHexDigit))
            {
                r = (byte)(Convert.ToInt32(new string(hex[0], 2), 16));
                g = (byte)(Convert.ToInt32(new string(hex[1], 2), 16));
                b = (byte)(Convert.ToInt32(new string(hex[2], 2), 16));
                return true;
            }

            if (hex.Length is 6 or 8 && hex.All(Uri.IsHexDigit))
            {
                var offset = hex.Length == 8 ? 2 : 0; // 8 位是 AARRGGBB，忽略 alpha
                r = Convert.ToByte(hex.Substring(offset, 2), 16);
                g = Convert.ToByte(hex.Substring(offset + 2, 2), 16);
                b = Convert.ToByte(hex.Substring(offset + 4, 2), 16);
                return true;
            }

            return false;
        }

        var open = value.IndexOf('(');
        if (open <= 0 || !value.EndsWith(')'))
        {
            return false;
        }

        var name = value[..open].Trim().ToLowerInvariant();
        if (name is not ("rgb" or "rgba"))
        {
            return false;
        }

        var parts = value[(open + 1)..^1].Split(',', StringSplitOptions.TrimEntries);
        if (parts.Length is < 3 or > 4)
        {
            return false;
        }

        var channels = new byte[3];
        for (var index = 0; index < 3; index++)
        {
            if (!byte.TryParse(parts[index], out channels[index]))
            {
                return false;
            }
        }

        (r, g, b) = (channels[0], channels[1], channels[2]);
        return true;
    }

    /// <summary>「来源 · 多久前」右栏文字；来源为空时只写时间。</summary>
    public static string SourceAndAge(string? source, string age)
        => string.IsNullOrWhiteSpace(source) ? age : $"{source.Trim()} · {age}";
}
