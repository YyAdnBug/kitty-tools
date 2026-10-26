// PLAN-v5 第 3 批的集成测试，REVIEW R26 §3 起走真的执行层（Core 的 SyncRunner + ClipSync / VocabularySync / EngineSync）：
// 一个临时同步文件夹里两台 Windows（各自一份数据：片段与收藏 + 收藏夹、生词本、网页搜索；账本和数据存在一起，能整份存成
// 备份再读回来）和一台假 Mac（照文件格式存内容本身、落什么存什么；起始的值取自 golden 样本），随机加 / 改 / 删几轮，
// 最后三边一样、再合一轮谁都不写；中途把一台的数据换成旧备份（库被退回去）→ 它认出并换编号、旧内容不翻回来；
// 在假 Mac 的子文件夹里放一个写坏的文件 → 只跳过那一版，别的照合。
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncIntegrationTests
{
    private const string GroupA = "0F8FAD5B-D9CB-469F-A165-70867728950E";
    private const string GroupB = "7C9E6679-7425-40DE-944B-E07FC1F90AE7";

    private sealed class Rng(ulong seed)
    {
        private ulong _state = seed;

        public ulong Next()
        {
            _state += 0x9E3779B97F4A7C15;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }

        public int Below(int n) => (int)(Next() % (ulong)n);

        public bool Chance(int percent) => Below(100) < percent;

        public T Pick<T>(IReadOnlyList<T> items) => items[Below(items.Count)];
    }

    private static SyncNode Windows(string name, string data)
        => new(name, data, new MemoryClipSource(), new MemoryWordSource(), new MemoryEngineSource());

    private static SyncNode Mac(string data)
        => new("MAC-TEST", data,
            new MemoryValueSource(ClipSync.Kind, ClipSync.JoinKey),
            new MemoryValueSource(VocabularySync.Kind, VocabularySync.JoinKey),
            new MemoryValueSource(EngineSync.Kind, EngineSync.JoinKey));

    private static MemoryValueSource Map(SyncNode node, string kind)
        => node.Sources.OfType<MemoryValueSource>().Single(source => source.Kind == kind);

    [TestMethod]
    public void TwoWindowsAndAFakeMacConvergeWithRollbackAndABadFile()
    {
        foreach (var seed in new ulong[] { 20261025, 20261026, 7 })
        {
            Run(seed);
        }
    }

    private static void Run(ulong seed)
    {
        using var temp = new TempFolder();
        var folder = temp.Sub("sync");
        var a = Windows("WIN-A", temp.Sub("a"));
        var b = Windows("WIN-B", temp.Sub("b"));
        var mac = Mac(temp.Sub("mac"));
        var nodes = new[] { a, b, mac };
        SeedMacFromGolden(mac);
        a.Source<MemoryClipSource>().Add("A 原来就有的");
        b.Source<MemoryWordSource>().Add("cat", "zh-Hans", "猫");

        long now = 0;
        foreach (var node in new[] { mac, a, b })
        {
            Assert.AreNotEqual("stopped", node.Round(folder, ref now).State, node.Name);
        }

        var rng = new Rng(seed);
        for (var step = 0; step < 24; step++)
        {
            foreach (var node in nodes)
            {
                if (node == mac)
                {
                    EditMac(mac, rng, step);
                }
                else
                {
                    EditWindows(node, rng, step);
                }

                // 两台 Windows 同时加了一样的正文：合到同一条（编号小的留下）。
                if (step == 5 && node != mac)
                {
                    node.Source<MemoryClipSource>().Add("两台都加的同一段");
                }

                var result = node.Round(folder, ref now);
                Assert.AreNotEqual("stopped", result.State, $"{node.Name} 第 {step} 步：{result.Message}");
            }
        }

        Settle(nodes, folder, ref now);
        AssertSame(nodes, seed);
        AssertQuiet(nodes, folder, ref now);
        Assert.AreEqual(1, a.Source<MemoryClipSource>().Rows.Count(row => row.Text == "两台都加的同一段"),
            "同一段文字只留一条");

        // 写坏假 Mac 的文件：只跳过那一版，别人照合，本机不变。
        var macFile = Path.Combine(folder, SyncDisk.KindPath(mac.Device.Id, ClipSync.Kind));
        var macGood = File.ReadAllText(macFile);
        File.WriteAllText(macFile, "{ 这不是 JSON");
        var before = Values(a, ClipSync.Kind);
        Assert.AreNotEqual("stopped", a.Round(folder, ref now).State);
        AssertSameMap(before, Values(a, ClipSync.Kind), "坏文件不该改动别的电脑");
        File.WriteAllText(macFile, macGood);

        // 时间机器：B 先有一条旧内容并同步出去，再备份 B 的数据。
        var clipsB = b.Source<MemoryClipSource>();
        var old = clipsB.Add("B 的旧内容");
        Settle(nodes, folder, ref now);
        var backup = b.Save();

        // 备份之后 B 把那条改了、又加了一条，三台合完。
        clipsB.Replace(clipsB.Rows.Single(row => row.Uid == old.Uid) with { Text = "B 的新内容" });
        clipsB.Add("备份之后才有的");
        a.Source<MemoryClipSource>().Add("备份之后才有的 A");
        Settle(nodes, folder, ref now);
        AssertSame(nodes, seed);

        // 换回旧备份（同步文件夹里本机那份的 epoch 已经比备份里的大）。
        b.Load(backup);
        Assert.IsFalse(clipsB.Rows.Any(row => row.Text == "备份之后才有的"), "备份里是旧的样子");
        var rolled = b.Round(folder, ref now);
        Assert.IsTrue(rolled.Rotated, "应该认出库被退回去了");
        Assert.AreNotEqual("WIN-B", b.Device.Id, "换一个新编号");
        Settle(nodes, folder, ref now);
        AssertSame(nodes, seed);
        Assert.IsFalse(clipsB.Rows.Any(row => row.Text == "B 的旧内容" && row.Favorite), "备份里的旧内容不该翻回来");
        Assert.IsTrue(clipsB.Rows.Any(row => row.Text == "B 的新内容"));
        Assert.IsTrue(clipsB.Rows.Any(row => row.Text == "备份之后才有的"), "备份之后的新内容应该回来");
        AssertQuiet(nodes, folder, ref now);
    }

    private static void Settle(SyncNode[] nodes, string folder, ref long now)
    {
        for (var settle = 0; settle < 4; settle++)
        {
            foreach (var node in nodes)
            {
                var result = node.Round(folder, ref now);
                Assert.AreNotEqual("stopped", result.State, $"{node.Name}：{result.Message}");
            }
        }
    }

    // ---- 起始数据和随机改动 ----

    private static void SeedMacFromGolden(SyncNode mac)
    {
        using var document = JsonDocument.Parse(
            File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "sync-golden.json")));
        var clips = Map(mac, ClipSync.Kind).Map;
        var words = Map(mac, VocabularySync.Kind).Map;
        var engines = Map(mac, EngineSync.Kind).Map;
        var groups = new List<string>();
        var engineIds = new[] { "google", "baidu", "maps" };
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (!item.TryGetProperty("json", out var jsonElement) || jsonElement.GetString() is not { } json)
            {
                continue;
            }

            switch (item.GetProperty("kind").GetString())
            {
                case "clip" when clips.Count < 8:
                    clips[MemoryClipSource.NewUid()] = json;
                    break;
                case "word" when words.Count < 6:
                    words[MemoryClipSource.NewUid()] = json;
                    break;
                case "group" when groups.Count < 2:
                    groups.Add(json);
                    break;
                case "engine" when engines.Count < engineIds.Length:
                    engines[engineIds[engines.Count]] = json;
                    break;
            }
        }

        clips[ClipSync.GroupPrefix + GroupA] = groups[0];
        clips[ClipSync.GroupPrefix + GroupB] = groups[1];
        clips[SyncEngine.OrderID] = SyncEngine.OrderValue(new[] { ClipSync.GroupPrefix + GroupA, ClipSync.GroupPrefix + GroupB });
        engines[SyncEngine.OrderID] = SyncEngine.OrderValue(new[] { "google", "bing" });
    }

    private static void EditWindows(SyncNode node, Rng rng, int step)
    {
        var clips = node.Source<MemoryClipSource>();
        var words = node.Source<MemoryWordSource>();
        var retained = clips.Rows.Where(row => row.IsRetained).ToList();
        switch (rng.Below(9))
        {
            case 0:
            case 1:
                clips.Add($"{node.Name} 新加的 {step}", snippet: rng.Chance(30));
                break;
            case 2 when retained.Count > 0:
            {
                // 备注：带空白、空串的也要原样同步。
                var row = rng.Pick(retained);
                clips.Replace(row with { Note = rng.Pick(new[] { $"备注 {step}", "  ", "", "tab\t\tend " }) });
                break;
            }

            case 3 when retained.Count > 0:
            {
                var row = rng.Pick(retained);
                clips.Replace(row with { Favorite = false, Snippet = false, Group = null });
                break;
            }

            case 4 when retained.Count > 0 && clips.Groups.Count > 0:
            {
                var row = rng.Pick(retained);
                clips.Replace(row with { Favorite = true, Group = rng.Pick(clips.Groups).Id });
                break;
            }

            case 5:
                if (clips.Groups.Count < 4)
                {
                    clips.Groups.Add(new SyncClipGroup(MemoryClipSource.NewUid(), $"{node.Name} 的收藏夹 {step}", step));
                }
                else
                {
                    var doomed = rng.Pick(clips.Groups);
                    clips.Groups.Remove(doomed);
                    clips.Rows = clips.Rows.Select(row => row.Group == doomed.Id ? row with { Group = null } : row)
                        .ToList();
                }

                break;
            case 6:
                words.Add($"{node.Name} word {step}", "zh-Hans", $"词 {step}");
                break;
            case 7 when words.Rows.Count(row => row.Favorite) > 0:
            {
                var word = rng.Pick(words.Rows.Where(row => row.Favorite).ToList());
                words.Rows = words.Rows.Select(row => row.Id == word.Id ? row with { Favorite = false } : row).ToList();
                break;
            }

            case 8:
            {
                var engines = node.Source<MemoryEngineSource>();
                if (rng.Chance(50) || engines.Engines.Count < 3)
                {
                    engines.Engines.Add(new SearchEngine
                    {
                        Id = "custom-" + node.Name + "-" + step, Name = "自建 " + step, Keyword = "k" + step,
                        UrlTemplate = "https://example.com/" + step + "?q={query}",
                    });
                }
                else
                {
                    engines.Engines.RemoveAt(rng.Below(engines.Engines.Count));
                }

                break;
            }
        }
    }

    private static void EditMac(SyncNode mac, Rng rng, int step)
    {
        var clips = Map(mac, ClipSync.Kind).Map;
        var words = Map(mac, VocabularySync.Kind).Map;
        var ids = clips.Keys.Where(id => Guid.TryParse(id, out _)).OrderBy(id => id, StringComparer.Ordinal).ToList();
        switch (rng.Below(4))
        {
            case 0:
                clips[MemoryClipSource.NewUid()] = ClipSync.Clip($"Mac 新加的 {step}", true, rng.Chance(30), null, null);
                break;
            case 1 when ids.Count > 0:
                // Mac 那边取消收藏：这条从文件里拿掉。
                clips.Remove(rng.Pick(ids));
                break;
            case 2 when ids.Count > 0:
            {
                var id = rng.Pick(ids);
                using var document = JsonDocument.Parse(clips[id]);
                var text = document.RootElement.GetProperty("text").GetString()!;
                clips[id] = ClipSync.Clip(text, true, true, $"Mac 备注 {step}", null);
                break;
            }

            case 3:
                words[MemoryClipSource.NewUid()] = VocabularySync.Word($"mac word {step}", "en", $"word {step}", "zhipu", step);
                break;
        }
    }

    // ---- 断言 ----

    private static Dictionary<string, string> Values(SyncNode node, string kind)
        => new(node.Sources.Single(source => source.Kind == kind).Values()!, StringComparer.Ordinal);

    private static void AssertSame(SyncNode[] nodes, ulong seed)
    {
        foreach (var kind in new[] { ClipSync.Kind, VocabularySync.Kind, EngineSync.Kind })
        {
            var expected = Values(nodes[0], kind);
            foreach (var node in nodes.Skip(1))
            {
                AssertSameMap(expected, Values(node, kind), $"种子 {seed}：{kind} 在 {node.Name} 和 {nodes[0].Name} 不一样");
            }
        }
    }

    /// <summary>安静下来以后再合一轮：谁都不写文件、不落改动（编 → 落 → 再编字节一样）。</summary>
    private static void AssertQuiet(SyncNode[] nodes, string folder, ref long now)
    {
        foreach (var node in nodes)
        {
            var applied = node.Sources.Sum(source => source.Applied);
            var result = node.Round(folder, ref now);
            Assert.AreEqual("idle", result.State, $"{node.Name}：{result.Message}");
            Assert.AreEqual(0, result.Written.Count, $"{node.Name} 安静下来以后还在重写 {string.Join(',', result.Written)}");
            Assert.AreEqual(applied, node.Sources.Sum(source => source.Applied), $"{node.Name} 安静下来以后还在落改动");
        }
    }

    private static void AssertSameMap(
        IReadOnlyDictionary<string, string> expected, IReadOnlyDictionary<string, string> actual, string note)
    {
        var missing = expected.Keys.Where(key => !actual.ContainsKey(key)).ToList();
        var extra = actual.Keys.Where(key => !expected.ContainsKey(key)).ToList();
        var changed = expected.Where(pair => actual.TryGetValue(pair.Key, out var value) && value != pair.Value)
            .Select(pair => pair.Key).ToList();
        Assert.IsTrue(missing.Count == 0 && extra.Count == 0 && changed.Count == 0,
            $"{note}；少 {string.Join(',', missing)}；多 {string.Join(',', extra)}；不一样 {string.Join(',', changed)}");
    }
}
