// 便签图片目录的纯规则（PLAN-v13 第 2 批，照 mac Notes/NoteImageStore.swift 的纯函数部分；读写文件、转码在 App 的 NoteImageStore）：
// - 文件名 `<大写 UUID>.<小写扩展名>`（Identifier：别的名字一律不当图片读，账文件 .orphans.json 也不是）；
// - 上限：原始输入 160 MB、存下去的那份 20 MB、像素 4000 万；
// - **没人引用的图片满 30 天才删**（OrphanPlan）：从**第一次发现**没人引用算起，不是文件时间（很早插入的图今天刚被删掉也要再留 30 天，
//   撤销、从 7 天内的备份恢复才找得回来）；账记在目录里的 .orphans.json（编号 → 第一次发现的时刻，整数毫秒）。
//   mac 记在 .orphans.plist：两边不互读这本账（它只在本机、跟着本机的备份走）。
// - 显示尺寸（PointSize）：像素按 DPI 换成 DIP（96 DPI = 1:1；带 EXIF 方向 5–8 的宽高互换）。mac 按 72 DPI 算点，两边的系统缩放口径不同，
//   ponytail：同一张 144 DPI 的图 mac 显示成像素的一半、这里 2/3；令牌里记了宽度的两边一样大。
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace KittyTools.Core.Notes;

public static class NoteImageRules
{
    public const int MaxPixels = 40_000_000;

    public const int MaxFileBytes = 20 * 1024 * 1024;

    public const int MaxInputBytes = 160 * 1024 * 1024;

    public const int OrphanDays = 30;

    public const string LedgerName = ".orphans.json";

    private const long Day = 86_400_000;

    /// <summary>文件名 → 编号；不是 `&lt;UUID&gt;.&lt;小写字母数字 1–10 位&gt;` 给 null。</summary>
    public static Guid? Identifier(string name)
    {
        var parts = name.Split('.');
        if (parts.Length != 2 || parts[0].Length != 36 || !Guid.TryParseExact(parts[0], "D", out var id))
        {
            return null;
        }

        var ext = parts[1];
        return ext.Length is >= 1 and <= NoteImages.MaxExtension &&
               ext.All(ch => char.IsAsciiDigit(ch) || ch is >= 'a' and <= 'z')
            ? id
            : null;
    }

    /// <summary>文件自己的扩展名像不像样：小写字母数字 1–10 位（大写的先转小写）。</summary>
    public static string? CleanExtension(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }

        var ext = raw.TrimStart('.').ToLowerInvariant();
        return ext.Length is >= 1 and <= NoteImages.MaxExtension && ext.All(ch => char.IsAsciiDigit(ch) || ch is >= 'a' and <= 'z')
            ? ext
            : null;
    }

    public readonly record struct OrphanPlan(IReadOnlyList<Guid> Remove, IReadOnlyDictionary<Guid, long> Ledger);

    /// <summary>清理的规则：还被引用 → 从账上去掉；没被引用、账上没有 → 记上「现在」；没被引用、账上记的早于 30 天之前 → 删；
    /// 文件已经不在的条目去掉。</summary>
    public static OrphanPlan Plan(
        IEnumerable<Guid> files, IReadOnlySet<Guid> referenced, IReadOnlyDictionary<Guid, long> ledger, long now,
        long keepMs = OrphanDays * Day)
    {
        var remove = new List<Guid>();
        var next = new Dictionary<Guid, long>();
        foreach (var id in files.Distinct().OrderBy(id => NoteImages.IdText(id), StringComparer.Ordinal))
        {
            if (referenced.Contains(id))
            {
                continue;
            }

            if (!ledger.TryGetValue(id, out var since))
            {
                next[id] = now;
                continue;
            }

            if (now - since >= keepMs)
            {
                remove.Add(id);
            }
            else
            {
                next[id] = since;
            }
        }

        return new OrphanPlan(remove, next);
    }

    /// <summary>账文件的内容 → 账；读不出来（坏了）当空账——不删任何东西。</summary>
    public static Dictionary<Guid, long> ReadLedger(string? text)
    {
        var found = new Dictionary<Guid, long>();
        if (string.IsNullOrEmpty(text))
        {
            return found;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return found;
            }

            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (Guid.TryParse(property.Name, out var id) && property.Value.TryGetInt64(out var since))
                {
                    found[id] = since;
                }
            }
        }
        catch (JsonException)
        {
            return new Dictionary<Guid, long>();
        }

        return found;
    }

    public static string WriteLedger(IReadOnlyDictionary<Guid, long> ledger)
    {
        var builder = new StringBuilder("{");
        var first = true;
        foreach (var (id, since) in ledger.OrderBy(pair => NoteImages.IdText(pair.Key), StringComparer.Ordinal))
        {
            builder.Append(first ? string.Empty : ",").Append('"').Append(NoteImages.IdText(id)).Append("\":")
                .Append(since.ToString(CultureInfo.InvariantCulture));
            first = false;
        }

        return builder.Append('}').ToString();
    }

    /// <summary>一张图的尺寸（文件头里读出来的）：像素、DPI、EXIF 方向、显示用的 DIP 大小（转正之后）。</summary>
    public readonly record struct ImageSize(int PixelWidth, int PixelHeight, double Dpi, int Orientation, double Width, double Height);

    public static ImageSize Size(int pixelWidth, int pixelHeight, double dpi, int orientation)
    {
        // 不在 24–2400 里的按 96 算（同 mac F22：JFIF 密度单位是 0 的 JPEG 会报出 1 之类的值，图被放大几十倍）
        var resolution = double.IsFinite(dpi) && dpi is >= 24 and <= 2400 ? dpi : 96;
        var rotated = orientation is >= 5 and <= 8;
        var (width, height) = rotated ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight);
        var scale = 96 / resolution;
        return new ImageSize(pixelWidth, pixelHeight, resolution, orientation,
            Math.Round(width * scale, MidpointRounding.AwayFromZero), Math.Round(height * scale, MidpointRounding.AwayFromZero));
    }

    public enum Rejection
    {
        TooLarge,
        TooManyPixels,
        Unreadable,
        Unsaved,
    }

    public static string NoticeTitle(Rejection rejection) => rejection switch
    {
        Rejection.TooLarge or Rejection.TooManyPixels => "图片太大了",
        Rejection.Unreadable => "读不出这张图片",
        _ => "裁好的图存不下",
    };

    public static string NoticeDetail(Rejection rejection) => rejection switch
    {
        Rejection.TooLarge => "单张最多 20 MB",
        Rejection.TooManyPixels => "像素太多",
        Rejection.Unreadable => "换个文件试试",
        _ => "看看磁盘还有没有地方",
    };
}
