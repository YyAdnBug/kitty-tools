// 状态和提醒的图标能挑任意系统表情（PLAN-v16 E1，照 mac StatusScreenTests.customEmojiSymbols）：系统表情在 JSON 里放 emoji 键、symbol 写空，
// 读回来还是它；没挑的编出来和以前逐字一样（自带三个的 golden 不动）。同步那一行照 mac SyncRecords.encoder（键排好序、不转义非 ASCII）。
using System.Text;
using System.Text.Json;
using KittyTools.Core;
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class StatusEmojiKeyTests
{
    [TestMethod]
    public void SystemEmojiAreRecognised()
    {
        foreach (var emoji in new[] { "🍵", "👩‍💻", "🇨🇳", "❤️", "1️⃣", "👍🏽" })
        {
            Assert.IsTrue(StatusEmojiCatalog.IsCustom(emoji), emoji);
            Assert.IsTrue(StatusEmojiCatalog.IsStorable(emoji), emoji);
        }

        foreach (var text in new[] { "1", "©", "a", "🍵🍵", "zzz", "eyes", "", "🍵 " })
        {
            Assert.IsFalse(StatusEmojiCatalog.IsCustom(text), text);
        }

        Assert.IsTrue(StatusEmojiCatalog.IsStorable(string.Empty) && StatusEmojiCatalog.IsStorable("zzz") && !StatusEmojiCatalog.IsStorable("eyes"));
        // 表情码段里还没收进 Unicode 表的也认；码段外没收的不认
        Assert.IsTrue(StatusEmojiCatalog.IsCustom(char.ConvertFromUtf32(0x1FAFE)));
        Assert.IsFalse(StatusEmojiCatalog.IsCustom(char.ConvertFromUtf32(0x10FFF0)));
    }

    [TestMethod]
    public void EmojiGoesInTheEmojiKey()
    {
        var tea = StatusPresets.BuiltIn()[2].Copy();
        tea.Symbol = "🍵";
        // 同步那一行：mac 的 SyncRecords.encoder 排好序的键（emoji 在 detail 和 id 之间）
        Assert.AreEqual("{\"autoEndMinutes\":0,\"emoji\":\"🍵\",\"id\":\"back\",\"power\":\"awake\",\"style\":\"sign\",\"symbol\":\"\",\"title\":\"马上回来\"}",
            StatusPresets.Canonical(tea));
        Assert.AreEqual("🍵", StatusPresetSync.Decode(StatusPresets.Canonical(tea))?.Symbol);
        // 没挑的照旧（和自带的 golden 逐字一样）
        Assert.AreEqual("{\"autoEndMinutes\":5,\"id\":\"clean\",\"power\":\"normal\",\"style\":\"blackout\",\"symbol\":\"glowing-star\",\"title\":\"清洁屏幕\"}",
            StatusPresets.Canonical(StatusPresets.BuiltIn()[0]));

        // 设置导出：symbol 写空、emoji 键；读回来还是它；收拾一遍不变
        var json = Write(tea, StatusPresets.BuiltIn()[0]);
        using var document = JsonDocument.Parse(json);
        var objects = document.RootElement.EnumerateArray().ToList();
        Assert.AreEqual(string.Empty, objects[0].GetProperty("symbol").GetString());
        Assert.AreEqual("🍵", objects[0].GetProperty("emoji").GetString());
        Assert.IsFalse(objects[1].TryGetProperty("emoji", out _));
        Assert.AreEqual("glowing-star", objects[1].GetProperty("symbol").GetString());
        var loaded = StatusPresets.ReadList(document.RootElement)!;
        Assert.AreEqual("🍵", loaded[0].Symbol);
        Assert.IsTrue(loaded[1].SameAs(StatusPresets.BuiltIn()[0]));
        Assert.AreEqual("🍵", StatusPresets.Sanitized(loaded)[0].Symbol);
        // emoji 键不是字符串：整条解不出（同 mac 解码失败）
        Assert.IsNull(StatusPresets.Read(JsonDocument.Parse("{\"id\":\"x\",\"title\":\"t\",\"symbol\":\"\",\"style\":\"sign\",\"power\":\"awake\",\"autoEndMinutes\":0,\"emoji\":1}").RootElement));
    }

    [TestMethod]
    public void MacOnlyIconsAlsoUseTheEmojiKeyAndSurvive()
    {
        // mac 后来加的 12 个、动画表情包的：这一版画不出，但收到了不置空、编回去照样在 emoji 键（不然同步回去会抹掉 mac 上挑的）
        foreach (var icon in new[] { "cook", "pack:dog" })
        {
            var preset = StatusPresets.BuiltIn()[2].Copy();
            preset.Symbol = icon;
            Assert.IsTrue(StatusPresets.Canonical(preset).Contains($"\"emoji\":\"{icon}\"", StringComparison.Ordinal), icon);
            Assert.AreEqual(icon, StatusPresets.Sanitized(new[] { preset })[0].Symbol, icon);
        }

        // 旧的系统符号名照旧换成表情、乱写的置空
        var odd = StatusPresets.BuiltIn()[2].Copy();
        odd.Symbol = "run";
        Assert.AreEqual(string.Empty, StatusPresets.Sanitized(new[] { odd })[0].Symbol);
    }

    private static string Write(params StatusPreset[] presets)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartArray();
            foreach (var preset in presets)
            {
                StatusPresets.Write(writer, preset);
            }

            writer.WriteEndArray();
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }
}
