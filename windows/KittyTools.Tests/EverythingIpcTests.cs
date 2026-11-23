// Everything 窗口消息协议的拼包和解包（PLAN-v25 F12；Core EverythingIpc）。回包是手工照协议拼的：
// 头 5 个 DWORD，接每项 8 字节（flags、data_offset），数据按 request_flags 从低位到高位，字符串 = DWORD 长度 + UTF-16 + NUL。
using System.Buffers.Binary;
using System.Text;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class EverythingIpcTests
{
    [TestMethod]
    public void SearchTextQuotesEveryToken()
    {
        Assert.AreEqual("\"季度\" \"报告!\"", EverythingIpc.SearchText(new[] { "季度", "报告!" }));
        Assert.AreEqual("\"ab\"", EverythingIpc.SearchText(new[] { "a\"b", "" }));
    }

    [TestMethod]
    public void QueryLayout()
    {
        var bytes = EverythingIpc.Query("\"jpg\"", replyHwnd: 0x00120ABC, replyId: 0x4B540001, maxResults: 500);
        var span = bytes.AsSpan();
        Assert.AreEqual(28 + 5 * 2 + 2, bytes.Length);
        Assert.AreEqual(0x00120ABCu, BinaryPrimitives.ReadUInt32LittleEndian(span[0..]));
        Assert.AreEqual(0x4B540001u, BinaryPrimitives.ReadUInt32LittleEndian(span[4..]));
        Assert.AreEqual(0u, BinaryPrimitives.ReadUInt32LittleEndian(span[8..]), "search_flags：不区分大小写、不匹配路径");
        Assert.AreEqual(0u, BinaryPrimitives.ReadUInt32LittleEndian(span[12..]));
        Assert.AreEqual(500u, BinaryPrimitives.ReadUInt32LittleEndian(span[16..]));
        Assert.AreEqual(0x3u, BinaryPrimitives.ReadUInt32LittleEndian(span[20..]), "request_flags：名字 + 文件夹");
        Assert.AreEqual(14u, BinaryPrimitives.ReadUInt32LittleEndian(span[24..]), "按修改时间从新到旧");
        Assert.AreEqual("\"jpg\"", Encoding.Unicode.GetString(span.Slice(28, 10)));
        Assert.AreEqual((byte)0, bytes[^1]);
        Assert.AreEqual((byte)0, bytes[^2]);
    }

    [TestMethod]
    public void ParsesNamesFoldersAndFolderFlag()
    {
        var reply = Reply(0x3, (0, new object[] { "季度报告.docx", @"D:\工作\2025" }), (1, new object[] { "照片", @"C:\Users\YY" }));
        var hits = EverythingIpc.Parse(reply)!;
        Assert.AreEqual(2, hits.Count);
        Assert.AreEqual(@"D:\工作\2025\季度报告.docx", hits[0].Path);
        Assert.IsFalse(hits[0].IsFolder);
        Assert.AreEqual("照片", hits[1].Name);
        Assert.AreEqual(@"C:\Users\YY", hits[1].Folder);
        Assert.IsTrue(hits[1].IsFolder);
    }

    [TestMethod]
    public void SkipsFieldsItDidNotAskFor()
    {
        // Everything 多给了大小（0x10，8 字节）和修改时间（0x40，8 字节）：照样找得到名字和文件夹
        var reply = Reply(0x3 | 0x10 | 0x40, (0, new object[] { "a.txt", @"D:\x", 1234L, 5678L }));
        var hit = EverythingIpc.Parse(reply)!.Single();
        Assert.AreEqual(@"D:\x\a.txt", hit.Path);
    }

    [TestMethod]
    public void DriveItemsHaveNoFolder()
    {
        var hit = EverythingIpc.Parse(Reply(0x3, (2, new object[] { "D:", "" })))!.Single();
        Assert.AreEqual(string.Empty, hit.Folder);
        Assert.IsTrue(hit.IsFolder);
    }

    [TestMethod]
    public void EmptyListIsFine()
    {
        Assert.AreEqual(0, EverythingIpc.Parse(Reply(0x3))!.Count);
    }

    [TestMethod]
    public void RejectsBrokenReplies()
    {
        var good = Reply(0x3, (0, new object[] { "a.txt", @"D:\x" }));
        Assert.IsNull(EverythingIpc.Parse(good.AsSpan(0, 12)), "头不全");
        Assert.IsNull(EverythingIpc.Parse(good.AsSpan(0, good.Length - 3)), "最后一个字符串被截断");

        var tooMany = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(tooMany.AsSpan(4), 1_000_000);
        Assert.IsNull(EverythingIpc.Parse(tooMany), "项数离谱");

        var pastEnd = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(pastEnd.AsSpan(20 + 4), (uint)good.Length + 10);
        Assert.IsNull(EverythingIpc.Parse(pastEnd), "data_offset 越界");

        var longString = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(longString.AsSpan(28), 0xFFFF_FFF0);
        Assert.IsNull(EverythingIpc.Parse(longString), "字符串长度越界");

        var unknownBit = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(unknownBit.AsSpan(12), 0x3 | 0x10000);
        Assert.IsNull(EverythingIpc.Parse(unknownBit), "不认识的字段：不知道多长，后面读不对");

        var noPath = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32LittleEndian(noPath.AsSpan(12), 0x1);
        Assert.IsNull(EverythingIpc.Parse(noPath), "没给文件夹");
    }

    /// <summary>照协议拼一个回包：每项 (flags, 按位从低到高的字段值)；string = 字符串，long = 8 字节。</summary>
    private static byte[] Reply(uint requestFlags, params (uint Flags, object[] Fields)[] items)
    {
        var data = new List<byte>();
        var offsets = new List<int>();
        var start = 20 + items.Length * 8;
        foreach (var (_, fields) in items)
        {
            offsets.Add(start + data.Count);
            foreach (var field in fields)
            {
                switch (field)
                {
                    case string text:
                        var length = new byte[4];
                        BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)text.Length);
                        data.AddRange(length);
                        data.AddRange(Encoding.Unicode.GetBytes(text));
                        data.AddRange(new byte[2]);
                        break;
                    case long number:
                        var bytes = new byte[8];
                        BinaryPrimitives.WriteInt64LittleEndian(bytes, number);
                        data.AddRange(bytes);
                        break;
                }
            }
        }

        var reply = new byte[start + data.Count];
        var span = reply.AsSpan();
        BinaryPrimitives.WriteUInt32LittleEndian(span[0..], (uint)items.Length); // totitems
        BinaryPrimitives.WriteUInt32LittleEndian(span[4..], (uint)items.Length); // numitems
        BinaryPrimitives.WriteUInt32LittleEndian(span[8..], 0);                  // offset
        BinaryPrimitives.WriteUInt32LittleEndian(span[12..], requestFlags);
        BinaryPrimitives.WriteUInt32LittleEndian(span[16..], 14);
        for (var index = 0; index < items.Length; index++)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(span[(20 + index * 8)..], items[index].Flags);
            BinaryPrimitives.WriteUInt32LittleEndian(span[(24 + index * 8)..], (uint)offsets[index]);
        }

        data.CopyTo(reply, start);
        return reply;
    }
}
