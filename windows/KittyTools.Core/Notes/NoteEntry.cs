// 设置的导出 / 导入里第七类「便签」的一条（PLAN-v13 第 2 批，照 mac Storage/SettingsArchive.swift 的 NoteEntry）：
// 编号、标题、正文、颜色、建于、改于、修订号、归档、固定、顺序，自定义纸色另带可选的 tint「#RRGGBB」（color 写最接近的那种预设）。
// 时间是整数毫秒（和便签库同一个口径；文件里别的时间是只到秒的 ISO 8601）。键名同 mac 的 Codable：
// id、title、body、color、createdAt、modifiedAt、revision、archived、pinned、order、tint。
// **读是宽松的**：哪一条缺字段、类型不对（连「不是一个对象」在内）只丢那一条（Sanitized 里筛掉）；编号得是 UUID（统一成大写）、不重复；
// 正文去 NUL、不超过单条上限，顺序得是有限的数；标题超长的截到上限；颜色、时间、修订号、顺序夹进范围。条数最多 MaxNotes。
using System.Globalization;
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;

namespace KittyTools.Core.Notes;

public sealed record NoteEntry
{
    public const int MaxNotes = 5000;

    public string Id { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public string Body { get; init; } = string.Empty;

    public int Color { get; init; }

    public long CreatedAt { get; init; }

    public long ModifiedAt { get; init; }

    public int Revision { get; init; }

    public bool Archived { get; init; }

    public bool Pinned { get; init; }

    public double Order { get; init; }

    public string? Tint { get; init; }

    /// <summary>内存里的纸色：color + tint 合起来。</summary>
    public int NoteColor => Note.ColorFrom(Color, Tint is null ? null : Note.RgbFromHex(Tint));

    /// <summary>没删的便签 → 文件里的样子（「最近删除」里的给 null）。</summary>
    public static NoteEntry? From(Note note)
        => note.DeletedAt is not null
            ? null
            : new NoteEntry
            {
                Id = note.Id,
                Title = note.Title,
                Body = note.Body,
                Color = Note.StoredPreset(note.Color),
                CreatedAt = note.CreatedAt,
                ModifiedAt = note.ModifiedAt,
                Revision = note.Revision,
                Archived = note.IsArchived,
                Pinned = note.IsPinned,
                Order = note.Order,
                Tint = Note.CustomRgb(note.Color) is { } rgb ? Note.Hex(rgb) : null,
            };

    /// <summary>文件里的一条 → NoteEntry；缺字段、类型不对给 null（只丢这一条）。</summary>
    public static NoteEntry? Read(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !ReadString(element, "id", out var id) || !ReadString(element, "title", out var title) ||
            !ReadString(element, "body", out var body) ||
            !element.TryGetProperty("color", out var color) || !color.TryGetInt32(out var colorValue) ||
            !element.TryGetProperty("createdAt", out var created) || !created.TryGetInt64(out var createdValue) ||
            !element.TryGetProperty("modifiedAt", out var modified) || !modified.TryGetInt64(out var modifiedValue) ||
            !element.TryGetProperty("revision", out var revision) || !revision.TryGetInt32(out var revisionValue) ||
            !ReadBool(element, "archived", out var archived) || !ReadBool(element, "pinned", out var pinned) ||
            !element.TryGetProperty("order", out var order) || order.ValueKind != JsonValueKind.Number ||
            !order.TryGetDouble(out var orderValue))
        {
            return null;
        }

        return new NoteEntry
        {
            Id = id,
            Title = title,
            Body = body,
            Color = colorValue,
            CreatedAt = createdValue,
            ModifiedAt = modifiedValue,
            Revision = revisionValue,
            Archived = archived,
            Pinned = pinned,
            Order = orderValue,
            // 自定义纸色的色值是可选的：没有、类型不对都当没有（这一条照样要）
            Tint = element.TryGetProperty("tint", out var tint) && tint.ValueKind == JsonValueKind.String ? tint.GetString() : null,
        };
    }

    private static bool ReadString(JsonElement element, string name, out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return true;
    }

    private static bool ReadBool(JsonElement element, string name, out bool value)
    {
        value = false;
        if (!element.TryGetProperty(name, out var property) ||
            property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }

        value = property.GetBoolean();
        return true;
    }

    /// <summary>读文件时的收拾（mac SettingsArchive.sanitized 的便签那段）。</summary>
    public static List<NoteEntry> Sanitized(IEnumerable<JsonElement> raw)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<NoteEntry>();
        foreach (var element in raw.Take(MaxNotes))
        {
            if (Read(element) is not { } entry || !Guid.TryParse(entry.Id, out var guid) ||
                !double.IsFinite(entry.Order))
            {
                continue;
            }

            var body = Note.SanitizedText(entry.Body);
            var id = guid.ToString("D").ToUpperInvariant();
            if (Encoding.UTF8.GetByteCount(body) > Note.MaxBodyBytes || !ids.Add(id))
            {
                continue;
            }

            result.Add(entry with
            {
                Id = id,
                Body = body,
                Title = Note.SanitizedTitle(entry.Title),
                Color = Note.StoredPreset(entry.Color),
                Tint = entry.Tint is null ? null : Note.RgbFromHex(entry.Tint) is { } rgb ? Note.Hex(rgb) : null,
                CreatedAt = Math.Max(entry.CreatedAt, 0),
                ModifiedAt = Math.Max(entry.ModifiedAt, 0),
                Revision = Math.Clamp(entry.Revision, 0, Note.MaxRevision),
                Order = Math.Clamp(entry.Order, -1e9, 1e9),
            });
        }

        return result;
    }

    /// <summary>写进导出文件的一条（键按字母排；顺序是 Swift JSONEncoder 的 Double 写法：最短往返）。</summary>
    public string Json()
    {
        var builder = new StringBuilder(Body.Length + 256);
        builder.Append("{\"archived\":").Append(Archived ? "true" : "false");
        builder.Append(",\"body\":");
        CanonicalJson.WriteString(Body, builder);
        builder.Append(",\"color\":").Append(Color.ToString(CultureInfo.InvariantCulture));
        builder.Append(",\"createdAt\":").Append(CreatedAt.ToString(CultureInfo.InvariantCulture));
        builder.Append(",\"id\":");
        CanonicalJson.WriteString(Id, builder);
        builder.Append(",\"modifiedAt\":").Append(ModifiedAt.ToString(CultureInfo.InvariantCulture));
        builder.Append(",\"order\":").Append(Order.ToString("R", CultureInfo.InvariantCulture));
        builder.Append(",\"pinned\":").Append(Pinned ? "true" : "false");
        builder.Append(",\"revision\":").Append(Revision.ToString(CultureInfo.InvariantCulture));
        if (Tint is not null)
        {
            builder.Append(",\"tint\":");
            CanonicalJson.WriteString(Tint, builder);
        }

        builder.Append(",\"title\":");
        CanonicalJson.WriteString(Title, builder);
        return builder.Append('}').ToString();
    }

    /// <summary>导出时能不能带「便签」这一类（mac notesFit）：条数不超过上限、每条正文不超过单条上限。</summary>
    public static bool Fit(IReadOnlyCollection<NoteEntry> notes)
        => notes.Count <= MaxNotes && notes.All(note => Encoding.UTF8.GetByteCount(note.Body) <= Note.MaxBodyBytes);
}
