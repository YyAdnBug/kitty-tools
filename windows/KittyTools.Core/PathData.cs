// 功能图标（FeatureIcons，"F1 M…"）的路径数据解析（2026-10-30，0.1.1）：XamlReader.Load 在 Native AOT 里
// 拿回来的对象转不成 Path（Release 一打开设置窗就 InvalidCastException），所以自己解析，KindTile 再拼成 PathGeometry。
// 生成脚本（icons/build-icons.swift）只出 M L C Q Z 五种命令、全是绝对坐标；别的命令（相对坐标、H V S T A）直接报错，
// 改生成脚本时这里跟着加。连写的坐标照 SVG 的规矩续上一条命令（M 之后续成 L）。
namespace KittyTools.Core;

public enum PathCommand
{
    Line,
    Quadratic,
    Cubic,
}

/// <summary>一段：直线只用 (X1, Y1)；二次曲线是控制点 1 + 终点 2；三次曲线是控制点 1、2 + 终点 3。</summary>
public readonly record struct PathSegmentData(
    PathCommand Command, double X1, double Y1, double X2 = 0, double Y2 = 0, double X3 = 0, double Y3 = 0);

/// <summary>一个子路径：起点、各段、有没有 Z。</summary>
public sealed record PathFigureData(double StartX, double StartY, IReadOnlyList<PathSegmentData> Segments, bool Closed);

/// <summary>整条路径：F1 是非零填充、F0 / 不写是奇偶。</summary>
public sealed record PathDataResult(bool NonZero, IReadOnlyList<PathFigureData> Figures);

public static class PathData
{
    public static PathDataResult Parse(string data)
    {
        var index = 0;
        var nonZero = false;
        SkipSeparators(data, ref index);
        if (index + 1 < data.Length && data[index] == 'F')
        {
            nonZero = data[index + 1] switch
            {
                '1' => true,
                '0' => false,
                _ => throw new FormatException($"路径数据的填充规则不认识：{data[index + 1]}"),
            };
            index += 2;
        }

        var figures = new List<PathFigureData>();
        List<PathSegmentData>? segments = null;
        double startX = 0, startY = 0;
        var command = '\0';

        void Finish(bool closed)
        {
            if (segments is not null)
            {
                figures.Add(new PathFigureData(startX, startY, segments, closed));
                segments = null;
            }
        }

        while (true)
        {
            SkipSeparators(data, ref index);
            if (index >= data.Length)
            {
                break;
            }

            var next = data[index];
            if (char.IsLetter(next))
            {
                command = next;
                index++;
            }
            else if (command is '\0' or 'Z')
            {
                throw new FormatException($"路径数据第 {index} 个字符前少了命令");
            }

            switch (command)
            {
                case 'M':
                    Finish(closed: false);
                    startX = Number(data, ref index);
                    startY = Number(data, ref index);
                    segments = new List<PathSegmentData>();
                    // 起点后面连写的坐标是直线。
                    command = 'L';
                    break;
                case 'L':
                    Current().Add(new PathSegmentData(PathCommand.Line, Number(data, ref index), Number(data, ref index)));
                    break;
                case 'Q':
                    Current().Add(new PathSegmentData(
                        PathCommand.Quadratic, Number(data, ref index), Number(data, ref index),
                        Number(data, ref index), Number(data, ref index)));
                    break;
                case 'C':
                    Current().Add(new PathSegmentData(
                        PathCommand.Cubic, Number(data, ref index), Number(data, ref index),
                        Number(data, ref index), Number(data, ref index),
                        Number(data, ref index), Number(data, ref index)));
                    break;
                case 'Z':
                    // Z 之后不是 M 的话，下一个子路径从这一个的起点接着画（SVG 的规矩）：起点不动。
                    Finish(closed: true);
                    break;
                default:
                    throw new FormatException($"路径数据里有不支持的命令：{command}");
            }
        }

        Finish(closed: false);
        return new PathDataResult(nonZero, figures);

        List<PathSegmentData> Current() => segments ??= new List<PathSegmentData>();
    }

    private static void SkipSeparators(string data, ref int index)
    {
        while (index < data.Length && (char.IsWhiteSpace(data[index]) || data[index] == ','))
        {
            index++;
        }
    }

    private static double Number(string data, ref int index)
    {
        SkipSeparators(data, ref index);
        var start = index;
        if (index < data.Length && data[index] is '-' or '+')
        {
            index++;
        }

        var dot = false;
        var exponent = false;
        while (index < data.Length)
        {
            var c = data[index];
            if (char.IsAsciiDigit(c))
            {
                index++;
            }
            else if (c == '.' && !dot && !exponent)
            {
                dot = true;
                index++;
            }
            else if (c is 'e' or 'E' && !exponent && index > start)
            {
                exponent = true;
                index++;
                if (index < data.Length && data[index] is '-' or '+')
                {
                    index++;
                }
            }
            else
            {
                break;
            }
        }

        if (!double.TryParse(
                data.AsSpan(start, index - start), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var value))
        {
            throw new FormatException($"路径数据第 {start} 个字符处不是数字");
        }

        return value;
    }
}
