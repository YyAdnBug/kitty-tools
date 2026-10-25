// PLAN-v5 第 3 批的集成测试（R13 验收）：一个临时同步文件夹里两台 Windows（各自一个数据目录：本机数据 + 账本 + epoch）
// 和一台按 §2 格式写文件的假 Mac（值取自 golden 样本），随机加 / 改 / 删几轮，最后三份一样；
// 中途把一台的数据目录换成旧备份（库被退回去）→ 它认出并换编号、旧内容不翻回来；
// 在假 Mac 的子文件夹里放一个写坏的文件 → 只跳过那一版，别的照合。
using System.Text;
using System.Text.Json;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncIntegrationTests
{
    private const string Kind = "clips";
    private const string Library = "5B2E1F7A-6C3D-4E8F-9A01-2B3C4D5E6F70";

    /// <summary>一台电脑：数据目录（本机数据 + 账本 + epoch）+ 同步文件夹里的子目录。</summary>
    private sealed class Node
    {
        public Node(string root, string id, bool joining)
        {
            Root = root;
            Id = id;
            Ledger = joining ? null : new SyncLedgerData();
        }

        public string Root { get; }

        public string Id { get; set; }

        public Dictionary<string, string> Local { get; } = new(StringComparer.Ordinal);

        public SyncLedgerData? Ledger { get; set; }

        public int Epoch { get; set; }

        public bool Rotated { get; set; }

        public string Folder => Path.Combine(Root, "sync");

        public string DeviceFolder => Path.Combine(Folder, "devices", Id);

        public string DataFolder => Path.Combine(Root, "data", Id);
    }

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
    }

    [TestMethod]
    public void TwoWindowsAndAFakeMacConvergeWithRollbackAndABadFile()
    {
        var root = Path.Combine(Path.GetTempPath(), "kitty-sync-it-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var a = new Node(root, "WIN-A", joining: false);
            var b = new Node(root, "WIN-B", joining: false);
            var mac = new Node(root, "MAC-TEST", joining: true);
            var nodes = new[] { a, b, mac };
            Directory.CreateDirectory(Path.Combine(a.Folder, "devices"));
            File.WriteAllText(
                Path.Combine(a.Folder, SyncFolderRules.MarkerFile), SyncFolderRules.Marker(Library));

            // 假 Mac 的值用 golden 样本里的写法（键排序、不写 null），写出去之前先确认是规范写法。
            var golden = GoldenClipValue();
            Assert.IsTrue(CanonicalJson.IsCanonical(golden));
            mac.Local["mac-1"] = golden;
            WriteData(mac);

            long now = 0;
            now = Round(a, now);
            now = Round(b, now);
            now = Round(mac, now);
            foreach (var node in nodes)
            {
                var path = Path.Combine(node.DeviceFolder, Kind + ".json");
                Assert.IsTrue(File.Exists(path), node.Id + " 没写文件");
                Assert.IsNotNull(ReadFile(path), node.Id + " 的文件读不回来");
            }

            // 随机加 / 改 / 删：两台 Windows 各自动，Mac 也动。
            var rng = new Rng(20261025);
            for (var step = 0; step < 24; step++)
            {
                foreach (var node in nodes)
                {
                    if (rng.Chance(45) && node.Local.Count > 0)
                    {
                        var key = node.Local.Keys.OrderBy(item => item, StringComparer.Ordinal)
                            .ElementAt(rng.Below(node.Local.Count));
                        if (rng.Chance(35))
                        {
                            node.Local.Remove(key);
                        }
                        else
                        {
                            node.Local[key] = ClipJson($"{node.Id} 改的 {step}");
                        }
                    }
                    else if (rng.Chance(55))
                    {
                        node.Local[$"{node.Id}-{step}"] = ClipJson($"{node.Id} 新加的 {step}");
                    }

                    WriteData(node);
                    now = Round(node, now);
                }
            }

            // 安静下来：都读最新的，各合两轮。
            for (var settle = 0; settle < 2; settle++)
            {
                foreach (var node in nodes)
                {
                    now = Round(node, now);
                }
            }

            AssertSame(a, b, mac);

            // 写坏假 Mac 的文件：只跳过那一版，别人照合，本机不变。
            var macFile = Path.Combine(mac.DeviceFolder, Kind + ".json");
            var macGood = File.ReadAllText(macFile);
            File.WriteAllText(macFile, "{ 这不是 JSON");
            var before = new Dictionary<string, string>(a.Local, StringComparer.Ordinal);
            now = Round(a, now);
            AssertSameLocal(before, a.Local, "坏文件不该改动别的电脑");
            File.WriteAllText(macFile, macGood);
            now = Round(a, now);
            now = Round(mac, now);

            // 时间机器：先把 B 的一条旧内容放到同步文件夹里，再备份 B 的数据目录。
            b.Local["WIN-B-old"] = ClipJson("B 的旧内容");
            WriteData(b);
            now = Round(b, now);
            now = Round(a, now);
            var backup = Path.Combine(root, "data", "WIN-B-backup");
            CopyDirectory(b.DataFolder, backup);
            var backupEpoch = b.Epoch;

            // 备份之后 B 把那条改了、A 也加了一条，三台合完。
            b.Local["WIN-B-old"] = ClipJson("B 的新内容");
            b.Local["WIN-B-after"] = ClipJson("备份之后才有的");
            WriteData(b);
            now = Round(b, now);
            a.Local["WIN-A-after"] = ClipJson("备份之后才有的 A");
            now = Round(a, now);
            now = Round(b, now);
            now = Round(mac, now);
            AssertSameLocal(a.Local, b.Local, "备份之前三台应该已经一样");

            // 换回旧备份；同步文件夹里本机那一份的 epoch 已经比备份里的新（从备份恢复过）。
            CopyDirectory(backup, b.DataFolder);
            ReadData(b);
            Assert.IsFalse(b.Local.ContainsKey("WIN-B-after"), "备份恢复之后本机是旧的样子");
            var folderDevice = Path.Combine(a.Folder, "devices", b.Id, SyncFolderRules.DeviceFile);
            File.WriteAllText(folderDevice, SyncFolderRules.DeviceJson(backupEpoch + 3, "WIN-B"));

            // 下一轮认出被退回去了：换编号，旧内容（备份里那些）不翻回来。
            now = Round(b, now);
            Assert.IsTrue(b.Rotated, "应该认出库被退回去了");
            Assert.AreNotEqual("WIN-B", b.Id, "换一个新编号");
            for (var settle = 0; settle < 3; settle++)
            {
                foreach (var node in nodes)
                {
                    now = Round(node, now);
                }
            }

            AssertSame(a, b, mac);
            Assert.IsFalse(
                b.Local.Values.Contains(ClipJson("B 的旧内容")), "备份里的旧内容不该被救回来");
            Assert.IsTrue(b.Local.ContainsKey("WIN-B-after"), "备份之后的新内容应该回来");
        }
        finally
        {
            if (Environment.GetEnvironmentVariable("KITTY_IT_KEEP") != "1")
            {
                try
                {
                    Directory.Delete(root, recursive: true);
                }
                catch
                {
                    // 临时目录留给系统清理。
                }
            }
        }
    }

    private static string ClipJson(string text)
        => $"{{\"favorite\":true,\"snippet\":false,\"text\":{Quote(text)}}}";

    private static string Quote(string value)
    {
        var builder = new StringBuilder();
        CanonicalJson.WriteString(value, builder);
        return builder.ToString();
    }

    /// <summary>跑一轮：读自己那份和别的电脑的、合、落地、写自己的文件和 device.json（epoch +1）。</summary>
    private static long Round(Node node, long now)
    {
        now += 1000;
        Directory.CreateDirectory(Path.Combine(node.Folder, "devices"));
        if (!File.Exists(Path.Combine(node.Folder, SyncFolderRules.MarkerFile)))
        {
            File.WriteAllText(
                Path.Combine(node.Folder, SyncFolderRules.MarkerFile), SyncFolderRules.Marker(Library));
        }

        // 文件夹里本机那一份的 epoch 比本机记的大：库被退回去了，换一个新编号（同 Syncer）。
        var devicePath = Path.Combine(node.DeviceFolder, SyncFolderRules.DeviceFile);
        var folderEpoch = File.Exists(devicePath) &&
                          SyncFolderRules.ParseDevice(File.ReadAllText(devicePath)) is { } parsed
            ? parsed.Epoch
            : 0;
        if (node.Epoch > 0 && folderEpoch > node.Epoch)
        {
            node.Id = NewDeviceId();
            node.Epoch = 0;
            node.Rotated = true;
            devicePath = Path.Combine(node.DeviceFolder, SyncFolderRules.DeviceFile);
        }

        var own = ReadFile(Path.Combine(node.DeviceFolder, Kind + ".json"));
        var others = new List<SyncFileData>();
        foreach (var directory in Directory.EnumerateDirectories(Path.Combine(node.Folder, "devices")))
        {
            var id = Path.GetFileName(directory);
            if (id == node.Id || !SyncFolderRules.IsDeviceName(id))
            {
                continue;
            }

            if (ReadFile(Path.Combine(directory, Kind + ".json")) is { } file)
            {
                others.Add(file);
            }
        }

        var outcome = SyncEngine.Round(
            node.Local, new Dictionary<string, long>(), node.Ledger, own, others, node.Id, now,
            JoinMode.Union, value => value);
        foreach (var (id, value) in outcome.Changes)
        {
            if (value is null)
            {
                node.Local.Remove(id);
            }
            else
            {
                node.Local[id] = value;
            }
        }

        node.Ledger = outcome.Ledger;
        WriteData(node);
        Directory.CreateDirectory(node.DeviceFolder);
        File.WriteAllText(
            Path.Combine(node.DeviceFolder, Kind + ".json"), ToFile(Kind, outcome.Own).Encode());
        File.WriteAllText(devicePath, SyncFolderRules.DeviceJson(node.Epoch + 1, node.Id));
        node.Epoch++;
        return now;
    }

    private static string NewDeviceId() => "W" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();

    private static void AssertSame(Node first, Node second, Node third)
    {
        AssertSameLocal(first.Local, second.Local, "两台 Windows 应该一样");
        AssertSameLocal(first.Local, third.Local, "假 Mac 和 Windows 应该一样");
        // 文件里也是同一组编号和同样的内容。
        var records = new[] { first, second, third }
            .Select(node => Records(File.ReadAllText(Path.Combine(node.DeviceFolder, Kind + ".json"))))
            .ToList();
        Assert.AreEqual(records[0], records[1]);
        Assert.AreEqual(records[0], records[2]);
    }

    private static void AssertSameLocal(
        IReadOnlyDictionary<string, string> expected, IReadOnlyDictionary<string, string> actual, string note)
    {
        var missing = expected.Keys.Where(key => !actual.ContainsKey(key)).ToList();
        var extra = actual.Keys.Where(key => !expected.ContainsKey(key)).ToList();
        var changed = expected.Where(pair =>
            actual.TryGetValue(pair.Key, out var value) && value != pair.Value).Select(pair => pair.Key).ToList();
        Assert.AreEqual(expected.Count, actual.Count,
            $"{note}；少 {string.Join(',', missing)}；多 {string.Join(',', extra)}；不一样 {string.Join(',', changed)}");
        foreach (var (id, value) in expected)
        {
            Assert.IsTrue(actual.TryGetValue(id, out var other) && other == value, note + "：" + id);
        }
    }

    private static string Records(string json)
    {
        using var document = JsonDocument.Parse(json);
        return string.Join('|', document.RootElement.GetProperty("records").EnumerateArray()
            .Select(item => item.GetProperty("id").GetString() + ":" + item.GetProperty("value").GetString())
            .OrderBy(item => item, StringComparer.Ordinal));
    }

    private static string GoldenClipValue()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "sync-golden.json");
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        foreach (var item in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            if (item.GetProperty("kind").GetString() == "clip")
            {
                return item.GetProperty("json").GetString() ?? string.Empty;
            }
        }

        throw new InvalidOperationException("golden 里没有 clip 样本");
    }

    // ---- 数据目录（本机数据 + 账本 + epoch）的落盘 / 读回 ----

    private static void WriteData(Node node)
    {
        Directory.CreateDirectory(node.DataFolder);
        var builder = new StringBuilder("{");
        var first = true;
        foreach (var (id, value) in node.Local.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(':');
            CanonicalJson.WriteString(value, builder);
        }

        builder.Append('}');
        File.WriteAllText(Path.Combine(node.DataFolder, "local.json"), builder.ToString());
        File.WriteAllText(Path.Combine(node.DataFolder, "ledger.json"), LedgerText(node.Ledger));
        File.WriteAllText(Path.Combine(node.DataFolder, "epoch.txt"), node.Epoch.ToString());
    }

    private static void ReadData(Node node)
    {
        node.Local.Clear();
        using (var local = JsonDocument.Parse(File.ReadAllText(Path.Combine(node.DataFolder, "local.json"))))
        {
            foreach (var property in local.RootElement.EnumerateObject())
            {
                node.Local[property.Name] = property.Value.GetString() ?? string.Empty;
            }
        }

        node.Ledger = ParseLedger(File.ReadAllText(Path.Combine(node.DataFolder, "ledger.json")));
        node.Epoch = int.Parse(File.ReadAllText(Path.Combine(node.DataFolder, "epoch.txt")));
    }

    private static string LedgerText(SyncLedgerData? ledger)
    {
        if (ledger is null)
        {
            return "null";
        }

        var builder = new StringBuilder("{\"entries\":{");
        var first = true;
        foreach (var (id, entry) in ledger.Entries.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(":{\"clock\":");
            CanonicalJson.WriteString(entry.Clock.Text(), builder);
            builder.Append(",\"hash\":");
            CanonicalJson.WriteString(entry.Hash, builder);
            builder.Append(",\"modified\":").Append(entry.Modified).Append('}');
        }

        builder.Append("},\"erased\":{");
        first = true;
        foreach (var (id, clock) in ledger.Erased.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!first)
            {
                builder.Append(',');
            }

            first = false;
            CanonicalJson.WriteString(id, builder);
            builder.Append(':');
            CanonicalJson.WriteString(clock.Text(), builder);
        }

        builder.Append("}}");
        return builder.ToString();
    }

    private static SyncLedgerData? ParseLedger(string text)
    {
        if (text == "null")
        {
            return null;
        }

        using var document = JsonDocument.Parse(text);
        var ledger = new SyncLedgerData();
        foreach (var property in document.RootElement.GetProperty("entries").EnumerateObject())
        {
            ledger.Entries[property.Name] = new SyncEntry(
                SyncClock.Parse(property.Value.GetProperty("clock").GetString()),
                property.Value.GetProperty("hash").GetString() ?? string.Empty,
                property.Value.GetProperty("modified").GetInt64());
        }

        foreach (var property in document.RootElement.GetProperty("erased").EnumerateObject())
        {
            ledger.Erased[property.Name] = SyncClock.Parse(property.Value.GetString());
        }

        return ledger;
    }

    private static SyncFileData? ReadFile(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var file = SyncFile.Decode(File.ReadAllText(path), Kind);
        if (file is null || file.IsNewer)
        {
            // 读不出来（写坏了、别的类别）：只扔这一版，这一类照合。
            return null;
        }

        var data = new SyncFileData();
        foreach (var record in file.Records)
        {
            data.Records[record.Id] = new SyncValue
            {
                Value = record.Value,
                Clock = record.Clock,
                Modified = record.Modified,
            };
        }

        foreach (var erased in file.Erased)
        {
            data.Erased[erased.Id] = erased.Clock;
        }

        return data;
    }

    private static SyncFile ToFile(string kind, SyncFileData data)
    {
        var file = new SyncFile { Kind = kind };
        foreach (var (id, value) in data.Records)
        {
            file.Records.Add(new SyncRecord
            {
                Id = id,
                Clock = value.Clock,
                Modified = value.Modified,
                Value = value.Value,
            });
        }

        foreach (var (id, clock) in data.Erased)
        {
            file.Erased.Add(new SyncErased { Id = id, Clock = clock });
        }

        return file;
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), overwrite: true);
        }
    }
}
