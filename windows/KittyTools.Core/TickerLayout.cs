// 一行每秒在变的读数怎么切、怎么滚（REVIEW R107，照 mac Shell/Ticker.swift；App 的 Ui/TickerText.cs 用）：整行交给排版排一次，
// 各字的左边在哪（edges，末尾多一个行尾）由排版给；画的时候按字切开，每块是整行里这个字占的那一段，两头按像素取整（块和块正好接上），
// 最后一块往右多 1 DIP（有的字形会探出一点）。每秒只换变了的那几位数字：位置都没动、变的都是数字换数字、给了方向才滚，否则整行重排。
// 夹在两个数字中间的冒号抬高一点，落在数字的竖直中间（「14:02」；mac 的系统字体排整行时自己换成抬高的冒号，Segoe UI 没有这个替换）。
namespace KittyTools.Core;

public static class TickerLayout
{
    /// <summary>滑多远：行高的这么多倍（mac travel）。</summary>
    public const double Travel = 0.6;

    /// <summary>
    /// 冒号抬多高：字号的这么多倍。Segoe UI 的冒号两点落在基线到 x 高之间（中线约 0.25 em），数字到大写高（中线约 0.35 em），
    /// 差 0.1 em（mac 实测抬高的冒号比普通的高 1.4 pt / 13–14 pt，也是约 0.1 em）。
    /// </summary>
    public const double ColonLiftEm = 0.1;

    /// <summary>
    /// 各字切在哪（物理像素，[Left, Right)）：edges 是各字左边（DIP，末尾多一个行尾，个数 = 字数 + 1）。两头按像素四舍五入，
    /// 最后一块往右多 1 DIP 的像素。edges 个数不对是空的。
    /// </summary>
    public static IReadOnlyList<(int Left, int Right)> Slices(IReadOnlyList<double> edges, double scale)
    {
        if (edges.Count < 2 || scale <= 0)
        {
            return Array.Empty<(int, int)>();
        }

        var slices = new List<(int, int)>(edges.Count - 1);
        for (var index = 0; index < edges.Count - 1; index++)
        {
            var left = (int)Math.Round(edges[index] * scale);
            var right = (int)Math.Round(edges[index + 1] * scale) + (index == edges.Count - 2 ? (int)Math.Ceiling(scale) : 0);
            slices.Add((left, Math.Max(left, right)));
        }

        return slices;
    }

    /// <summary>
    /// 这一次能不能滚：给了方向、字数一样、各字的位置都没动（差不到 0.01 DIP）、变了的都是数字换数字——能滚给出变了的下标（可能是空的：
    /// 什么都没变），不能滚（整行重排）是 null。
    /// </summary>
    public static IReadOnlyList<int>? Rolling(
        IReadOnlyList<string> previous, IReadOnlyList<double> previousEdges,
        IReadOnlyList<string> next, IReadOnlyList<double> nextEdges, int direction)
    {
        if (direction == 0 || previous.Count != next.Count || previousEdges.Count != nextEdges.Count ||
            previousEdges.Where((edge, index) => Math.Abs(edge - nextEdges[index]) > 0.01).Any())
        {
            return null;
        }

        var changed = Enumerable.Range(0, next.Count).Where(index => previous[index] != next[index]).ToList();
        return changed.All(index => IsDigit(previous[index]) && IsDigit(next[index])) ? changed : null;
    }

    /// <summary>第 index 个字是不是夹在两个数字中间的冒号（要抬高）。</summary>
    public static bool LiftsColon(IReadOnlyList<string> characters, int index)
        => index > 0 && index < characters.Count - 1 && characters[index] == ":" &&
           IsDigit(characters[index - 1]) && IsDigit(characters[index + 1]);

    /// <summary>冒号抬多高（DIP，按像素取整：落在半像素上会糊）。</summary>
    public static double ColonLift(double fontSize, double scale)
        => scale <= 0 ? 0 : Math.Round(fontSize * ColonLiftEm * scale) / scale;

    public static bool IsDigit(string element) => element.Length == 1 && char.IsAsciiDigit(element[0]);
}
