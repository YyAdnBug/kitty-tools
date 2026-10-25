// 第五版第 1 批：和 mac 的同步格式对齐（PLAN-v5 §2 / §3）。
// 用仓库里的 sync-golden.json（40 个样本，由 mac 的 JSONEncoder 生成）逐个校验：
// 内容的 JSON 文本、SHA-256 前 16 字节的哈希、版本钟的写法，以及一整个同步文件的编码。
using System.Text.Json;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncGoldenTests
{
    private static JsonDocument Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "sync-golden.json");
        Assert.IsTrue(File.Exists(path), path);
        return JsonDocument.Parse(File.ReadAllText(path));
    }

    [TestMethod]
    public void CanonicalJsonAndHashMatchEverySample()
    {
        using var document = Load();
        var cases = document.RootElement.GetProperty("cases");
        var checkedCount = 0;
        foreach (var item in cases.EnumerateArray())
        {
            var kind = item.GetProperty("kind").GetString();
            if (kind == "clock")
            {
                var clock = new SyncClock();
                if (item.GetProperty("input").TryGetProperty("clock", out var counters))
                {
                    foreach (var counter in counters.EnumerateObject())
                    {
                        clock[counter.Name] = counter.Value.GetInt32();
                    }
                }

                Assert.AreEqual(item.GetProperty("text").GetString(), clock.Text(), "clock");
                continue;
            }

            if (kind == "file")
            {
                continue;
            }

            var input = item.GetProperty("input");
            // order 类别的输入是 {"ids":[…]}，内容就是这个数组本身。
            var source = kind == "order" ? input.GetProperty("ids") : input;
            var json = CanonicalJson.Write(source);
            Assert.AreEqual(item.GetProperty("json").GetString(), json, kind);
            Assert.AreEqual(item.GetProperty("hash").GetString(), CanonicalJson.Hash(json), kind);
            checkedCount++;
        }

        Assert.IsTrue(checkedCount >= 30, $"checked {checkedCount}");
    }

    [TestMethod]
    public void ClockOrderAndUnion()
    {
        var first = SyncClock.Parse("MAC-1:2,WIN-2:1");
        var second = SyncClock.Parse("MAC-1:3,WIN-2:1");
        var third = SyncClock.Parse("MAC-1:3");
        Assert.AreEqual("MAC-1:2,WIN-2:1", first.Text());
        Assert.IsTrue(first.Precedes(second));
        Assert.IsFalse(second.Precedes(first));
        Assert.IsFalse(first.Precedes(third)); // 少了 WIN-2，不算「更早」
        Assert.IsFalse(first.Precedes(first));
        Assert.AreEqual("MAC-1:3,WIN-2:1", first.Union(second).Text());

        Assert.IsTrue(SyncClock.Parse(string.Empty).IsEmpty);
        Assert.ThrowsExactly<FormatException>(() => SyncClock.Parse("bad"));
        Assert.ThrowsExactly<FormatException>(() => SyncClock.Parse("A:1,A:2"));
        Assert.ThrowsExactly<FormatException>(() => SyncClock.Parse("A:-1"));
    }

    [TestMethod]
    public void DecodesAndReencodesGoldenFile()
    {
        using var document = Load();
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (item.GetProperty("kind").GetString() != "file")
            {
                continue;
            }

            var json = item.GetProperty("json").GetString()!;
            var file = SyncFile.Decode(json, "clips");
            Assert.IsNotNull(file);
            Assert.IsFalse(file!.IsNewer);
            Assert.AreEqual(json, file.Encode(), "整份文件再编码要一样");
            Assert.AreEqual(2, file.Records.Count);
            Assert.AreEqual(1, file.Erased.Count);
        }
    }

    [TestMethod]
    public void RejectsBrokenFilesAndFlagsNewer()
    {
        var good = SyncFile.Empty("clips");
        var record = new SyncRecord
        {
            Id = "A", Clock = SyncClock.Parse("WIN:1"), Modified = 5, Value = "{}",
        };
        good.Records.Add(record);
        var encoded = good.Encode();
        Assert.IsNotNull(SyncFile.Decode(encoded, "clips"));
        Assert.IsNull(SyncFile.Decode(encoded, "words")); // kind 对不上

        Assert.IsNull(SyncFile.Decode("{}", "clips"));
        Assert.IsNull(SyncFile.Decode("""{"format":0,"kind":"clips"}""", "clips"));
        Assert.IsNull(SyncFile.Decode(
            """{"format":1,"kind":"clips","records":[{"clock":"A:1","id":"X","modified":-1,"value":"{}"}]}""",
            "clips"));
        Assert.IsNull(SyncFile.Decode(
            """{"format":1,"kind":"clips","records":[{"clock":"A:1","id":"X","modified":1,"value":"{}"},{"clock":"A:2","id":"X","modified":2,"value":"{}"}]}""",
            "clips"));

        var newer = SyncFile.Decode(
            """{"format":2,"kind":"clips","records":[{"clock":"A:1","id":"X","modified":1,"value":"{}"}],"extra":true}""",
            "clips");
        Assert.IsNotNull(newer);
        Assert.IsTrue(newer!.IsNewer);
    }

    [TestMethod]
    public void DecodeExactRejectsNonCanonicalValues()
    {
        Assert.IsTrue(CanonicalJson.IsCanonical("""{"a":1,"b":"x"}"""));
        Assert.IsTrue(CanonicalJson.IsCanonical("""["a","b"]"""));
        Assert.IsFalse(CanonicalJson.IsCanonical("""{"b":"x","a":1}"""));      // 键没排序
        Assert.IsFalse(CanonicalJson.IsCanonical("""{"a":1,"b":null}"""));     // 空值要省掉
        Assert.IsFalse(CanonicalJson.IsCanonical("""{"a":"x\/y"}"""));          // 不该转义 /
        Assert.IsFalse(CanonicalJson.IsCanonical("""{"a":"\u4f60"}"""));       // 非 ASCII 不该转义
        Assert.IsFalse(CanonicalJson.IsCanonical("not json"));
    }

    [TestMethod]
    public void MergePicksNewestAndHonoursTombstones()
    {
        SyncFile File(params SyncRecord[] records) => new() { Kind = "clips", Records = records.ToList() };

        var older = new SyncRecord { Id = "X", Clock = SyncClock.Parse("WIN:1"), Modified = 10, Value = "old" };
        var newer = new SyncRecord { Id = "X", Clock = SyncClock.Parse("MAC:2"), Modified = 20, Value = "new" };
        var merged = SyncMerge.Merge("clips", new[] { File(older), File(newer) });
        Assert.AreEqual("new", merged.Records.Single().Value);

        var erased = new SyncFile
        {
            Kind = "clips",
            Erased = new List<SyncErased>
            {
                new() { Id = "X", Clock = SyncClock.Parse("WIN:3") },
            },
        };
        Assert.AreEqual(0, SyncMerge.Merge("clips", new[] { File(older), erased }).Records.Count);

        var resurrected = new SyncRecord { Id = "X", Clock = SyncClock.Parse("WIN:4"), Modified = 30, Value = "back" };
        Assert.AreEqual("back", SyncMerge.Merge("clips", new[] { File(resurrected), erased }).Records.Single().Value);
    }
}
