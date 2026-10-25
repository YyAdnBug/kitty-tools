// PLAN-v5 第 3 批的集成测试（缩小版）：临时文件夹里两台 Windows + 一台假 Mac，写文件 / 读文件 / 合，
// 几轮后三份一样；值都用 golden 里的写法（键排序、不写 null）。
using System.Text.Json;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SyncIntegrationTests
{
    private sealed class Device
    {
        public string Id = string.Empty;

        public Dictionary<string, string> Local = new(StringComparer.Ordinal);

        public SyncLedgerData? Ledger = new();

        public SyncFileData Own = new();
    }

    [TestMethod]
    public void TwoWindowsAndAFakeMacConvergeOnDisk()
    {
        var root = Path.Combine(Path.GetTempPath(), "kitty-sync-it-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var devices = new List<Device>
            {
                new() { Id = "WIN-A" },
                new() { Id = "WIN-B" },
                new() { Id = "MAC-TEST" },
            };
            devices[0].Local["c1"] = """{"favorite":true,"snippet":false,"text":"Windows A"}""";
            devices[1].Local["c2"] = """{"favorite":false,"snippet":true,"text":"Windows B"}""";
            devices[2].Local["c3"] = """{"favorite":true,"snippet":false,"text":"Mac"}""";

            for (var round = 1; round <= 8; round++)
            {
                foreach (var device in devices)
                {
                    var others = new List<SyncFileData>();
                    foreach (var other in devices.Where(item => item.Id != device.Id))
                    {
                        var path = Path.Combine(root, other.Id + ".json");
                        if (File.Exists(path))
                        {
                            var decoded = SyncFile.Decode(File.ReadAllText(path), "clips");
                            Assert.IsNotNull(decoded);
                            var data = new SyncFileData();
                            foreach (var record in decoded.Records)
                            {
                                data.Records[record.Id] = new SyncValue
                                {
                                    Value = record.Value,
                                    Clock = record.Clock,
                                    Modified = record.Modified,
                                };
                            }

                            foreach (var erased in decoded.Erased)
                            {
                                data.Erased[erased.Id] = erased.Clock;
                            }

                            others.Add(data);
                        }
                    }

                    var outcome = SyncEngine.Round(
                        device.Local, new Dictionary<string, long>(), device.Ledger, device.Own,
                        others, device.Id, round * 1000, JoinMode.Union, value => value);
                    foreach (var (id, value) in outcome.Changes)
                    {
                        if (value is null)
                        {
                            device.Local.Remove(id);
                        }
                        else
                        {
                            device.Local[id] = value;
                        }
                    }

                    device.Ledger = outcome.Ledger;
                    device.Own = outcome.Own;
                    var file = new SyncFile { Kind = "clips" };
                    foreach (var (id, value) in outcome.Own.Records)
                    {
                        file.Records.Add(new SyncRecord
                        {
                            Id = id,
                            Clock = value.Clock,
                            Modified = value.Modified,
                            Value = value.Value,
                        });
                    }

                    foreach (var (id, clock) in outcome.Own.Erased)
                    {
                        file.Erased.Add(new SyncErased { Id = id, Clock = clock });
                    }

                    File.WriteAllText(Path.Combine(root, device.Id + ".json"), file.Encode());
                }
            }

            Assert.AreEqual(3, devices[0].Local.Count);
            foreach (var device in devices.Skip(1))
            {
                CollectionAssert.AreEquivalent(devices[0].Local, device.Local);
            }

            // 文件里是同一组编号、同样的字节（按编号排）。
            var first = File.ReadAllText(Path.Combine(root, "WIN-A.json"));
            var second = File.ReadAllText(Path.Combine(root, "WIN-B.json"));
            Assert.AreEqual(Records(first), Records(second));
        }
        finally
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

    private static string Records(string json)
    {
        using var document = JsonDocument.Parse(json);
        var records = document.RootElement.GetProperty("records").EnumerateArray()
            .Select(item => item.GetProperty("id").GetString() + ":" + item.GetProperty("value").GetString())
            .OrderBy(item => item, StringComparer.Ordinal);
        return string.Join('|', records);
    }
}
