// 截图历史的纯规则（PLAN-v8 H1–H4，照 mac ShotHistory.swift）：种类、该清掉哪些（30 天 / 2 GB，最新那条不按总量删）、
// 标注的 JSON（Windows 自己的格式：tool 名和字段名进了磁盘，以后别改）、缩略图尺寸、按天分组的标题。配单测 ShotHistoryTests。
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core;

public enum ShotKind
{
    Shot,
    Scroll,
    Video,
    Audio,
    Gif,
}

/// <summary>
/// 一条标注存盘的样子。Tool 是 AnnotationKind 的名字（小写）；坐标是原图里的像素。Argb / Width 是第一版就有的两个字段，
/// 照旧写（颜色、线宽 DIP）；Palette、Weight、Option、Number、Bend 是 PLAN-v9 第 5a 批加的，旧数据里没有（-1 / 0），
/// 读的时候按 Argb、Width 换算。
/// </summary>
public sealed record ShotAnnotationData(
    string Tool, RectD Rect, IReadOnlyList<PointD> Points, string Text, uint Argb, double Width,
    int Palette = -1, int Weight = -1, int Option = 0, int Number = 0, VectorD Bend = default);

/// <summary>算该清掉哪些时只看这三样。CreatedAt 是 Unix 毫秒。</summary>
public readonly record struct ShotStaleItem(string Id, long CreatedAt, long Bytes);

public static class ShotHistoryRules
{
    public const int DefaultDays = 30;

    public const long DefaultBytes = 2L * 1024 * 1024 * 1024;

    /// <summary>缩略图最长边（历史窗口的网格用；本来就小的不放大）。</summary>
    public const int ThumbnailSide = 480;

    public static string StorageName(ShotKind kind) => kind switch
    {
        ShotKind.Scroll => "scroll",
        ShotKind.Video => "video",
        ShotKind.Audio => "audio",
        ShotKind.Gif => "gif",
        _ => "shot",
    };

    public static ShotKind? Parse(string? name) => name switch
    {
        "shot" => ShotKind.Shot,
        "scroll" => ShotKind.Scroll,
        "video" => ShotKind.Video,
        "audio" => ShotKind.Audio,
        "gif" => ShotKind.Gif,
        _ => null,
    };

    public static string Title(ShotKind kind) => kind switch
    {
        ShotKind.Scroll => "长截图",
        ShotKind.Video => "录屏",
        ShotKind.Audio => "录音",
        ShotKind.Gif => "GIF",
        _ => "截图",
    };

    /// <summary>录制的那几种只记文件和封面，没有原图、不能标注。</summary>
    public static bool IsRecording(ShotKind kind) => kind is ShotKind.Video or ShotKind.Audio or ShotKind.Gif;

    /// <summary>
    /// 该删哪些：过期的（days > 0 时），以及从新到旧累计超过 limitBytes 之后的那些（limitBytes > 0 时）。
    /// 最新那条不按总量删——上限设得比一张图还小的话，刚截完就没了。
    /// </summary>
    public static List<string> Stale(IEnumerable<ShotStaleItem> items, long nowMs, int days, long limitBytes)
    {
        var doomed = new List<string>();
        var cutoff = days > 0 ? nowMs - days * 86_400_000L : long.MinValue;
        long total = 0;
        var index = 0;
        foreach (var item in items.OrderByDescending(item => item.CreatedAt))
        {
            if (item.CreatedAt < cutoff)
            {
                doomed.Add(item.Id);
            }
            else
            {
                total += item.Bytes;
                if (limitBytes > 0 && total > limitBytes && index > 0)
                {
                    doomed.Add(item.Id);
                }
            }

            index++;
        }

        return doomed;
    }

    /// <summary>缩略图尺寸：最长边 side，等比，至少 1；本来就小的原样。</summary>
    public static (int Width, int Height) ThumbnailSize(int width, int height, int side = ThumbnailSide)
    {
        var longest = Math.Max(width, height);
        if (longest <= side || longest <= 0)
        {
            return (Math.Max(1, width), Math.Max(1, height));
        }

        var ratio = (double)side / longest;
        return (Math.Max(1, (int)Math.Round(width * ratio)), Math.Max(1, (int)Math.Round(height * ratio)));
    }

    /// <summary>
    /// 标注 → JSON：<c>[{"tool":"rectangle","rect":[x,y,w,h],"points":[[x,y]],"text":"","color":"#AARRGGBB","width":3}]</c>。
    /// 没有标注返回 null（库里存 NULL）。
    /// </summary>
    public static string? EncodeAnnotations(IReadOnlyList<ShotAnnotationData> annotations)
    {
        if (annotations.Count == 0)
        {
            return null;
        }

        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartArray();
            foreach (var annotation in annotations)
            {
                writer.WriteStartObject();
                writer.WriteString("tool", annotation.Tool);
                writer.WriteStartArray("rect");
                writer.WriteNumberValue(annotation.Rect.X);
                writer.WriteNumberValue(annotation.Rect.Y);
                writer.WriteNumberValue(annotation.Rect.Width);
                writer.WriteNumberValue(annotation.Rect.Height);
                writer.WriteEndArray();
                writer.WriteStartArray("points");
                foreach (var point in annotation.Points)
                {
                    writer.WriteStartArray();
                    writer.WriteNumberValue(point.X);
                    writer.WriteNumberValue(point.Y);
                    writer.WriteEndArray();
                }

                writer.WriteEndArray();
                writer.WriteString("text", annotation.Text);
                writer.WriteString("color", "#" + annotation.Argb.ToString("X8", CultureInfo.InvariantCulture));
                writer.WriteNumber("width", annotation.Width);
                if (annotation.Palette >= 0)
                {
                    writer.WriteNumber("palette", annotation.Palette);
                }

                if (annotation.Weight >= 0)
                {
                    writer.WriteNumber("weight", annotation.Weight);
                }

                if (annotation.Option != 0)
                {
                    writer.WriteNumber("option", annotation.Option);
                }

                if (annotation.Number != 0)
                {
                    writer.WriteNumber("number", annotation.Number);
                }

                if (annotation.Bend != VectorD.Zero)
                {
                    writer.WriteStartArray("bend");
                    writer.WriteNumberValue(annotation.Bend.X);
                    writer.WriteNumberValue(annotation.Bend.Y);
                    writer.WriteEndArray();
                }

                writer.WriteEndObject();
            }

            writer.WriteEndArray();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>JSON → 标注；读不懂的整段返回空，单条缺字段的跳过（坏一条不连累别的）。</summary>
    public static List<ShotAnnotationData> DecodeAnnotations(string? json)
    {
        var result = new List<ShotAnnotationData>();
        if (string.IsNullOrWhiteSpace(json))
        {
            return result;
        }

        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return result;
            }

            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object ||
                    !item.TryGetProperty("tool", out var tool) || tool.GetString() is not { Length: > 0 } toolName ||
                    !item.TryGetProperty("rect", out var rect) || rect.ValueKind != JsonValueKind.Array ||
                    rect.GetArrayLength() != 4)
                {
                    continue;
                }

                var points = new List<PointD>();
                if (item.TryGetProperty("points", out var list) && list.ValueKind == JsonValueKind.Array)
                {
                    foreach (var point in list.EnumerateArray())
                    {
                        if (point.ValueKind == JsonValueKind.Array && point.GetArrayLength() == 2)
                        {
                            points.Add(new PointD(point[0].GetDouble(), point[1].GetDouble()));
                        }
                    }
                }

                var text = item.TryGetProperty("text", out var textValue) ? textValue.GetString() ?? string.Empty : string.Empty;
                var argb = 0xFFFF2D55u;
                if (item.TryGetProperty("color", out var color) && color.GetString() is { Length: 9 } hex && hex[0] == '#' &&
                    uint.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var parsed))
                {
                    argb = parsed;
                }

                var width = item.TryGetProperty("width", out var widthValue) && widthValue.TryGetDouble(out var w) ? w : 3;
                var bend = VectorD.Zero;
                if (item.TryGetProperty("bend", out var bendValue) && bendValue.ValueKind == JsonValueKind.Array &&
                    bendValue.GetArrayLength() == 2)
                {
                    bend = new VectorD(bendValue[0].GetDouble(), bendValue[1].GetDouble());
                }

                result.Add(new ShotAnnotationData(
                    toolName,
                    new RectD(rect[0].GetDouble(), rect[1].GetDouble(), rect[2].GetDouble(), rect[3].GetDouble()),
                    points,
                    text,
                    argb,
                    width,
                    Integer(item, "palette", -1),
                    Integer(item, "weight", -1),
                    Integer(item, "option", 0),
                    Integer(item, "number", 0),
                    bend));
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            result.Clear();
        }

        return result;
    }

    private static int Integer(JsonElement item, string name, int fallback)
        => item.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : fallback;

    /// <summary>
    /// 标注 → 存盘的样子（坐标挪到原图里：减掉选区左上角 dx、dy）。字段怎么放：矩形类 rect；箭头 / 直线 / 荧光笔
    /// points = [起点, 终点] + bend；画笔 points；文字 rect = 左上角 + 文字框大小；序号 rect 的 x、y = 圆心 + number。
    /// </summary>
    public static ShotAnnotationData ToData(Annotation annotation, double dx, double dy)
    {
        PointD Moved(PointD point) => new(point.X - dx, point.Y - dy);
        var rect = annotation.Rect.Offset(-dx, -dy);
        var points = (IReadOnlyList<PointD>)Array.Empty<PointD>();
        switch (annotation.Kind)
        {
            case AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter:
                points = new[] { Moved(annotation.From), Moved(annotation.To) };
                rect = default;
                break;
            case AnnotationKind.Pen:
                points = annotation.Points.Select(Moved).ToArray();
                rect = default;
                break;
            case AnnotationKind.Counter:
                var center = Moved(annotation.From);
                rect = new RectD(center.X, center.Y, 0, 0);
                break;
        }

        return new ShotAnnotationData(
            AnnotationKinds.StorageName(annotation.Kind), rect, points, annotation.Text,
            AnnotationPalette.ArgbOf(annotation.Style.Color), annotation.Style.LineWidth,
            annotation.Style.Color, annotation.Style.Weight, annotation.Style.Option, annotation.Number,
            annotation.Bend);
    }

    /// <summary>
    /// 存盘的 → 标注（坐标加回 dx、dy）；认不得的工具名、缺点的线返回 null（以后加的工具在旧版本里跳过）。
    /// 第一版的数据没有 palette / weight：颜色取最近的那个、线宽换成最近的档；箭头的点是 points 的头尾。
    /// 文字的大小（rect 的宽高）旧数据里是 0，由 App 量一遍补上。
    /// </summary>
    public static Annotation? FromData(ShotAnnotationData data, double dx, double dy)
    {
        if (AnnotationKinds.Parse(data.Tool) is not { } kind)
        {
            return null;
        }

        PointD Moved(PointD point) => new(point.X + dx, point.Y + dy);
        var style = new AnnotationStyle(
            data.Palette is >= 0 and < 8 ? data.Palette : AnnotationPalette.Nearest(data.Argb),
            data.Weight is >= 0 and <= 2 ? data.Weight : AnnotationStyle.WeightFromWidth(data.Width),
            Math.Max(0, data.Option));
        var annotation = new Annotation { Kind = kind, Style = style, Text = data.Text };
        switch (kind)
        {
            case AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Highlighter:
                if (data.Points.Count < 2)
                {
                    return null;
                }

                return annotation with
                {
                    From = Moved(data.Points[0]),
                    To = Moved(data.Points[^1]),
                    Bend = kind == AnnotationKind.Highlighter ? VectorD.Zero : data.Bend,
                };
            case AnnotationKind.Pen:
                return data.Points.Count == 0 ? null : annotation with { Points = data.Points.Select(Moved).ToArray() };
            case AnnotationKind.Counter:
                return annotation with
                {
                    From = new PointD(data.Rect.X + dx, data.Rect.Y + dy), Number = Math.Max(1, data.Number),
                };
            default:
                return annotation with { Rect = data.Rect.Offset(dx, dy) };
        }
    }

    /// <summary>历史窗口按天分组的标题：「今天」「昨天」「10 月 24 日」，不是今年的带年份。都是本地日期。</summary>
    public static string DayTitle(DateTime day, DateTime today)
    {
        var date = day.Date;
        if (date == today.Date)
        {
            return "今天";
        }

        if (date == today.Date.AddDays(-1))
        {
            return "昨天";
        }

        return date.Year == today.Year
            ? $"{date.Month} 月 {date.Day} 日"
            : $"{date.Year} 年 {date.Month} 月 {date.Day} 日";
    }
}
