// 快速记一条（PLAN-v13 第 5 批，全局键默认 Alt+N；照 mac Notes/NoteCapture.swift 的规则部分）：
// - 草稿：点面板外面、再按快捷键、Ctrl+W 收起时留着（连同标题、选的目的地），下次呼出还在；Esc 一起清空并收起；保存后一起清空。
//   **重启也不丢**：停手约 1 秒、面板收起、退出前存进数据目录里的 notes-draft.json（不在任何备份、导出、同步的范围里），清空时删掉。
//   Esc 清掉的草稿不是空的：提示「已清空草稿」+「恢复」。
// - 标题：记成新便签时顶上那一行是标题框，填了就是新便签的标题；只填了标题、正文空着也算有内容。记到已有的某条时没有这个框。
// - 记到哪：默认新便签；也可以接在最近改过的 8 条没归档的便签之一后面（Ctrl+1 新便签，Ctrl+2–Ctrl+9 那 8 条）。
// - 保存（正文里 Enter，Shift+Enter 换行）：去掉首尾空白，空的不存；新便签 = 新建一条；已有的 = 接在它正文后面（原来末尾没换行就先换一行）。
//   存完会超过 Note.MaxBodyBytes 时不存，底栏就地说。
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;

namespace KittyTools.Core.Notes;

public static class NoteCaptureRules
{
    public const int DestinationLimit = 8;

    public const int DraftDelayMs = 1000;

    public const string DraftName = "notes-draft.json";

    public sealed record Draft(string Title = "", string Body = "", string? Destination = null)
    {
        public bool IsEmpty => NoteText.TrimSpacesAndNewlines(Title).Length == 0 && NoteText.TrimSpacesAndNewlines(Body).Length == 0;

        public string Json()
        {
            var builder = new StringBuilder("{\"body\":");
            CanonicalJson.WriteString(Body, builder);
            if (Destination is not null)
            {
                builder.Append(",\"destination\":");
                CanonicalJson.WriteString(Destination, builder);
            }

            builder.Append(",\"title\":");
            CanonicalJson.WriteString(Title, builder);
            return builder.Append('}').ToString();
        }

        /// <summary>读回来；写坏的、空的给 null。</summary>
        public static Draft? Read(string? text)
        {
            if (string.IsNullOrEmpty(text))
            {
                return null;
            }

            try
            {
                using var document = JsonDocument.Parse(text);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object)
                {
                    return null;
                }

                string Field(string name)
                    => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                        ? value.GetString() ?? string.Empty
                        : string.Empty;

                var destination = Field("destination");
                var draft = new Draft(Field("title"), Field("body"), destination.Length == 0 ? null : destination);
                return draft.IsEmpty ? null : draft;
            }
            catch (JsonException)
            {
                return null;
            }
        }
    }

    /// <summary>可以记到的已有便签：没归档没删的里最近改过的 8 条。</summary>
    public static List<Note> Destinations(IEnumerable<Note> active)
        => active.OrderByDescending(note => note.ModifiedAt).ThenByDescending(note => note.Id, StringComparer.Ordinal)
            .Take(DestinationLimit).ToList();

    /// <summary>接在已有正文后面：原来有内容、末尾没换行就先换一行。</summary>
    public static string Appending(string text, string? old)
        => string.IsNullOrEmpty(old) ? text : old + (old.EndsWith('\n') ? string.Empty : "\n") + text;

    /// <summary>Esc 清掉的草稿放回来：标题空着才用草稿的，正文接在现在打的前面，目的地没选才用草稿的。</summary>
    public static Draft Restored(Draft current, Draft cleared)
        => new(
            NoteText.TrimSpacesAndNewlines(current.Title).Length == 0 ? cleared.Title : current.Title,
            current.Body.Length == 0 ? cleared.Body : Appending(current.Body, cleared.Body),
            current.Destination ?? cleared.Destination);

    public enum Outcome
    {
        Empty,
        TooLong,
        Saved,
    }

    /// <summary>存之前查一遍：空的不存、超上限的不存（给底栏的一句话）。body = 存完之后那条便签的正文。</summary>
    public static (Outcome Outcome, string Body, string? Notice) Check(string draft, string title, Note? target)
    {
        var text = NoteText.TrimSpacesAndNewlines(draft);
        var ownTitle = target is null ? NoteText.TrimSpacesAndNewlines(title) : string.Empty;
        if (text.Length == 0 && ownTitle.Length == 0)
        {
            return (Outcome.Empty, string.Empty, null);
        }

        var body = Appending(text, target?.Body);
        if (Encoding.UTF8.GetByteCount(body) > Note.MaxBodyBytes)
        {
            return (Outcome.TooLong, body,
                target is null ? "太长了，一条便签最多 1 MB" : "接上这段就超过一条便签 1 MB 的上限了，换一条记");
        }

        return (Outcome.Saved, body, null);
    }
}
