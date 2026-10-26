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

/// <summary>一条标注存盘的样子。Tool 是 App 里工具枚举的名字（小写）；坐标是原图里的像素。</summary>
public sealed record ShotAnnotationData(
    string Tool, RectD Rect, IReadOnlyList<PointD> Points, string Text, uint Argb, double Width);

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
                result.Add(new ShotAnnotationData(
                    toolName,
                    new RectD(rect[0].GetDouble(), rect[1].GetDouble(), rect[2].GetDouble(), rect[3].GetDouble()),
                    points,
                    text,
                    argb,
                    width));
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            result.Clear();
        }

        return result;
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
