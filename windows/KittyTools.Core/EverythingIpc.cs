// Everything（voidtools）窗口消息协议的纯函数部分（PLAN-v25 F12、§5 第 3 批；配单测）：拼 WM_COPYDATA 的查询、解回包。
// 发消息、收回包在 App 的 Launcher/EverythingSearch.cs。不带 Everything SDK 的 DLL、不抄它的源码，只照协议本身写：
// 结构和常量照 SDK 的 everything_ipc.h（随 SDK 发布；1.5 的 SDK3 在 github.com/voidtools/everything_sdk3，MIT），
// 用第三方 MIT 实现 everything-ipc（Rust）交叉核对过。
//
// 查询（WM_COPYDATA，dwData = CopyDataQuery2W = 18）：7 个 DWORD + UTF-16 查询串 + NUL
//   reply_hwnd、reply_copydata_message（回包的 dwData 就是它）、search_flags、offset、max_results、request_flags、sort_type。
// 回包（Everything 往 reply_hwnd 发 WM_COPYDATA）：5 个 DWORD（totitems、numitems、offset、request_flags、sort_type）
//   + numitems 个 8 字节的项（flags、data_offset：从整个缓冲区开头算）；每项的数据按回包头里的 request_flags 从低位到高位依次排：
//   字符串 = DWORD 长度 + 长度个 UTF-16 + NUL；大小 = 8 字节；日期 = 8 字节 FILETIME；属性 / 次数 = 4 字节。
// 回包是别的进程发来的：每个偏移、长度都查边界，有一处不对整包丢掉（Parse 返回 null）。
using System.Buffers.Binary;
using System.Text;

namespace KittyTools.Core;

/// <summary>Everything 的一条结果：所在文件夹、名字、是不是文件夹（含盘）。</summary>
public readonly record struct EverythingHit(string Folder, string Name, bool IsFolder)
{
    public string Path => Folder.EndsWith('\\') ? Folder + Name : Folder + "\\" + Name;
}

public static class EverythingIpc
{
    /// <summary>EVERYTHING_IPC_COPYDATA_QUERY2W。</summary>
    public const uint CopyDataQuery2W = 18;

    public const uint RequestFileName = 0x1;
    public const uint RequestPath = 0x2;

    /// <summary>EVERYTHING_SORT_DATE_MODIFIED_DESCENDING。</summary>
    public const uint SortDateModifiedDescending = 14;

    /// <summary>项的 flags：EVERYTHING_IPC_FOLDER 0x1、EVERYTHING_IPC_DRIVE 0x2（照 everything_ipc.h，Windows 上核对）。</summary>
    public const uint ItemFolder = 0x1;

    public const uint ItemDrive = 0x2;

    /// <summary>一次最多要多少条（同 FileSearchSql.DefaultLimit）。</summary>
    public const uint MaxResults = FileSearchSql.DefaultLimit;

    /// <summary>回包里超过这么多项的当坏包（我们只要 MaxResults 条）。</summary>
    public const int MaxItems = 10_000;

    private const int QueryHeader = 28;
    private const int ListHeader = 20;
    private const int ItemSize = 8;

    // request_flags 每一位的数据有多长：0 = 字符串（DWORD 长度 + UTF-16 + NUL），否则是定长字节数
    private static readonly (uint Bit, int Size)[] Fields =
    {
        (0x1, 0),      // FILE_NAME
        (0x2, 0),      // PATH
        (0x4, 0),      // FULL_PATH_AND_FILE_NAME
        (0x8, 0),      // EXTENSION
        (0x10, 8),     // SIZE
        (0x20, 8),     // DATE_CREATED
        (0x40, 8),     // DATE_MODIFIED
        (0x80, 8),     // DATE_ACCESSED
        (0x100, 4),    // ATTRIBUTES
        (0x200, 0),    // FILE_LIST_FILE_NAME
        (0x400, 4),    // RUN_COUNT
        (0x800, 8),    // DATE_RUN
        (0x1000, 8),   // DATE_RECENTLY_CHANGED
        (0x2000, 0),   // HIGHLIGHTED_FILE_NAME
        (0x4000, 0),   // HIGHLIGHTED_PATH
        (0x8000, 0),   // HIGHLIGHTED_FULL_PATH_AND_FILE_NAME
    };

    /// <summary>
    /// 查询串：每个词加引号、空格连（Everything 里空格是「并且」，引号让 ! 这类当普通字）。
    /// 词先过 FileSearchFilter.Tokens（已经没有 \ / : * ? " &lt; &gt; |）。
    /// </summary>
    public static string SearchText(IReadOnlyList<string> tokens)
        => string.Join(' ', tokens.Where(token => token.Length > 0).Select(token => "\"" + token.Replace("\"", string.Empty, StringComparison.Ordinal) + "\""));

    /// <summary>WM_COPYDATA 的数据：匹配名字（不区分大小写、不匹配路径），要名字和文件夹，按修改时间从新到旧。</summary>
    public static byte[] Query(string search, uint replyHwnd, uint replyId, uint maxResults = MaxResults)
    {
        var text = Encoding.Unicode.GetBytes(search);
        var bytes = new byte[QueryHeader + text.Length + 2];
        var span = bytes.AsSpan();
        BinaryPrimitives.WriteUInt32LittleEndian(span[0..], replyHwnd);
        BinaryPrimitives.WriteUInt32LittleEndian(span[4..], replyId);
        BinaryPrimitives.WriteUInt32LittleEndian(span[8..], 0);  // search_flags：不区分大小写、不全词、不匹配路径、不用正则
        BinaryPrimitives.WriteUInt32LittleEndian(span[12..], 0); // offset
        BinaryPrimitives.WriteUInt32LittleEndian(span[16..], maxResults);
        BinaryPrimitives.WriteUInt32LittleEndian(span[20..], RequestFileName | RequestPath);
        BinaryPrimitives.WriteUInt32LittleEndian(span[24..], SortDateModifiedDescending);
        text.CopyTo(span[QueryHeader..]);
        return bytes; // 最后两个字节是 0 = NUL
    }

    /// <summary>解回包；格式不对返回 null。盘（flags 带 Drive、文件夹为空）照样返回，调用方按需丢。</summary>
    public static List<EverythingHit>? Parse(ReadOnlySpan<byte> reply)
    {
        if (reply.Length < ListHeader)
        {
            return null;
        }

        var count = BinaryPrimitives.ReadUInt32LittleEndian(reply[4..]);
        var flags = BinaryPrimitives.ReadUInt32LittleEndian(reply[12..]);
        if (count > MaxItems || ListHeader + (long)count * ItemSize > reply.Length)
        {
            return null;
        }

        // 不认识的位：不知道它占多长，后面的字段读不对
        uint known = 0;
        foreach (var (bit, _) in Fields)
        {
            known |= bit;
        }

        if ((flags & ~known) != 0 || (flags & (RequestFileName | RequestPath)) != (RequestFileName | RequestPath))
        {
            return null;
        }

        var hits = new List<EverythingHit>((int)count);
        for (var index = 0; index < count; index++)
        {
            var item = reply[(ListHeader + index * ItemSize)..];
            var itemFlags = BinaryPrimitives.ReadUInt32LittleEndian(item);
            var offset = BinaryPrimitives.ReadUInt32LittleEndian(item[4..]);
            if (offset >= reply.Length)
            {
                return null;
            }

            var position = (int)offset;
            string? name = null;
            string? folder = null;
            foreach (var (bit, size) in Fields)
            {
                if ((flags & bit) == 0)
                {
                    continue;
                }

                if (size > 0)
                {
                    if (position + size > reply.Length)
                    {
                        return null;
                    }

                    position += size;
                    continue;
                }

                if (!ReadString(reply, ref position, out var text))
                {
                    return null;
                }

                if (bit == RequestFileName)
                {
                    name = text;
                }
                else if (bit == RequestPath)
                {
                    folder = text;
                }
            }

            hits.Add(new EverythingHit(folder ?? string.Empty, name ?? string.Empty, (itemFlags & (ItemFolder | ItemDrive)) != 0));
        }

        return hits;
    }

    /// <summary>DWORD 长度（字符数，不含 NUL）+ 那么多个 UTF-16 + NUL。</summary>
    private static bool ReadString(ReadOnlySpan<byte> reply, ref int position, out string text)
    {
        text = string.Empty;
        if (position + 4 > reply.Length)
        {
            return false;
        }

        var length = BinaryPrimitives.ReadUInt32LittleEndian(reply[position..]);
        var bytes = ((long)length + 1) * 2;
        if (length > 32_767 || position + 4 + bytes > reply.Length)
        {
            return false;
        }

        text = Encoding.Unicode.GetString(reply.Slice(position + 4, (int)length * 2));
        position += 4 + (int)bytes;
        return true;
    }
}
