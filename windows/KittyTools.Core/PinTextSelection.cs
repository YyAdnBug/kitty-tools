// PLAN-v26 S8：钉图上的字能直接拖选（同 mac 0.10.0 b85c6d4e、19180341）。识字给的词框按读的顺序排成一串（行从上到下、
// 行里从左到右），选区是这串里从 anchor 到 focus 的一段：指针点在哪个词、拖到哪个词，选中的字怎么接（行内中文不加空格、
// 西文加空格，换行接 \n），每行选中的那几块框并成一块高亮。坐标都是钉图原图的像素。
namespace KittyTools.Core;

public static class PinTextSelection
{
    /// <summary>串里第 index 个词：在第几行、它的字和框。行没有词框时整行当一个词。</summary>
    public static List<(int Line, OcrWord Word)> Flatten(IReadOnlyList<OcrLine> lines)
    {
        var words = new List<(int, OcrWord)>();
        for (var line = 0; line < lines.Count; line++)
        {
            if (lines[line].Words is { Count: > 0 } inside)
            {
                words.AddRange(inside.Where(word => word.Text.Length > 0).Select(word => (line, word)));
            }
            else if (lines[line].Text.Length > 0)
            {
                words.Add((line, new OcrWord(lines[line].Text, lines[line].Box)));
            }
        }

        return words;
    }

    /// <summary>指针正点在字上（词框外扩 slack 像素也算）：哪个词；不在字上是 null（那里按下就是挪钉图）。</summary>
    public static int? Hit(IReadOnlyList<(int Line, OcrWord Word)> words, double x, double y, double slack)
    {
        for (var index = 0; index < words.Count; index++)
        {
            var box = words[index].Word.Box;
            if (x >= box.X - slack && x <= box.Right + slack && y >= box.Y - slack && y <= box.Bottom + slack)
            {
                return index;
            }
        }

        return null;
    }

    /// <summary>
    /// 拖着走时指针离字最近的那个词（拖到行外、两行之间、图的空白处也接着选）：先挑竖直方向最近的一行（指针在行的上下沿之间就是它），
    /// 再在那一行里挑横向最近的词。没有词是 null。
    /// </summary>
    public static int? Nearest(IReadOnlyList<(int Line, OcrWord Word)> words, double x, double y)
    {
        if (words.Count == 0)
        {
            return null;
        }

        static double Gap(double value, double low, double high) => value < low ? low - value : value > high ? value - high : 0;
        var line = words
            .GroupBy(word => word.Line)
            .Select(group => (group.Key, Distance: Gap(y, group.Min(word => word.Word.Box.Y), group.Max(word => word.Word.Box.Bottom))))
            .OrderBy(candidate => candidate.Distance)
            .ThenBy(candidate => candidate.Key)
            .First().Key;
        var best = -1;
        var bestDistance = double.MaxValue;
        for (var index = 0; index < words.Count; index++)
        {
            if (words[index].Line != line)
            {
                continue;
            }

            var distance = Gap(x, words[index].Word.Box.X, words[index].Word.Box.Right);
            if (distance < bestDistance)
            {
                best = index;
                bestDistance = distance;
            }
        }

        return best;
    }

    /// <summary>from 到 to（两头都含，先后不论）选中的字：行内照识字的接法（中文之间不加空格），换行接 \n。</summary>
    public static string Text(IReadOnlyList<(int Line, OcrWord Word)> words, int from, int to)
    {
        var (start, end) = Ordered(words, from, to);
        if (start > end)
        {
            return string.Empty;
        }

        return string.Join("\n", words.Skip(start).Take(end - start + 1)
            .GroupBy(word => word.Line)
            .Select(group => OcrText.RemoveCjkSpaces(string.Join(" ", group.Select(word => word.Word.Text)))));
    }

    /// <summary>from 到 to 每一行选中那几个词的框并成一块（画高亮用）。</summary>
    public static List<RectD> Boxes(IReadOnlyList<(int Line, OcrWord Word)> words, int from, int to)
    {
        var (start, end) = Ordered(words, from, to);
        var boxes = new List<RectD>();
        if (start > end)
        {
            return boxes;
        }

        foreach (var group in words.Skip(start).Take(end - start + 1).GroupBy(word => word.Line))
        {
            boxes.Add(RectD.FromLtrb(group.Min(word => word.Word.Box.X), group.Min(word => word.Word.Box.Y),
                group.Max(word => word.Word.Box.Right), group.Max(word => word.Word.Box.Bottom)));
        }

        return boxes;
    }

    private static (int Start, int End) Ordered(IReadOnlyList<(int Line, OcrWord Word)> words, int from, int to)
    {
        var start = Math.Clamp(Math.Min(from, to), 0, words.Count);
        var end = Math.Clamp(Math.Max(from, to), -1, words.Count - 1);
        return (start, end);
    }
}
