// PLAN-v12 第 3 批：状态屏的纯逻辑（照 mac StatusScreenTests.swift 的口径）：状态列表的收拾和合并、和 mac 一样的 JSON、
// 退出判断（按住 Esc / 按住提示 2 秒，别的触碰取消）、退出密码（按扫描码认数字、错满 5 次收起）、小字、结束的一句话、眼睛探头。
using System.Text;
using System.Text.Json;
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class StatusScreenTests
{
    private static StatusInput Down(int key, bool repeat = false, bool modifiers = false, int scan = 0)
        => new(StatusInputKind.KeyDown, key, scan, false, repeat, modifiers);

    private static StatusInput Up(int key) => new(StatusInputKind.KeyUp, key);

    [TestMethod]
    public void Sanitized_CleansTitlesDropsBadOnesAndCaps()
    {
        var presets = new List<StatusPreset?>
        {
            new() { Id = "a", Title = "  多行\n标题  ", Detail = "  ", Symbol = "hand.raised.fill", Style = "sign", Power = "awake", AutoEndMinutes = 7 },
            new() { Id = "b", Title = "   ", Style = "sign", Power = "awake" },
            new() { Id = "a", Title = "重复的 id", Style = "sign", Power = "awake" },
            new() { Id = "c", Title = "不认识的样式", Style = "blur", Power = "awake" },
            new() { Id = "d", Title = new string('长', 40), Detail = new string('说', 70), Symbol = "rocket", Style = "dim", Power = "displayOn" },
            null,
        };
        var result = StatusPresets.Sanitized(presets);
        Assert.AreEqual(2, result.Count);
        Assert.AreEqual("多行 标题", result[0].Title);
        Assert.IsNull(result[0].Detail);
        Assert.AreEqual("raised-hand", result[0].Symbol, "旧的系统符号名换成对应的表情");
        Assert.AreEqual(0, result[0].AutoEndMinutes, "不是可选值的当「不结束」");
        Assert.AreEqual(StatusPresets.MaxTitle, StatusPresets.Length(result[1].Title));
        Assert.AreEqual(StatusPresets.MaxDetail, StatusPresets.Length(result[1].Detail!));
        Assert.AreEqual("  多行\n标题  ", presets[0]!.Title, "不改传进来的");

        // 字形簇算一个字：emoji 不被从中间截开。
        var emoji = StatusPresets.Sanitized(new[] { new StatusPreset { Id = "e", Title = string.Concat(Enumerable.Repeat("👋🏽", 31)), Style = "sign", Power = "awake" } });
        Assert.AreEqual(30, StatusPresets.Length(emoji[0].Title));

        var many = Enumerable.Range(0, 30).Select(i => new StatusPreset { Id = $"id{i}", Title = $"t{i}" });
        Assert.AreEqual(StatusPresets.MaxCount, StatusPresets.Sanitized(many).Count);
    }

    [TestMethod]
    public void Load_FallsBackToBuiltIn()
    {
        CollectionAssert.AreEqual(new[] { "clean", "busy", "back" }, StatusPresets.Load(null).Select(p => p.Id).ToList());
        CollectionAssert.AreEqual(new[] { "clean", "busy", "back" }, StatusPresets.Load(new List<StatusPreset>()).Select(p => p.Id).ToList());
        var builtIn = StatusPresets.BuiltIn();
        Assert.AreEqual("blackout", builtIn[0].Style);
        Assert.AreEqual(5, builtIn[0].AutoEndMinutes);
        Assert.AreEqual("displayOn", builtIn[1].Power);
        Assert.AreEqual("电脑正在跑任务，别动键盘和鼠标", builtIn[1].Detail);
    }

    [TestMethod]
    public void ListOperations()
    {
        var list = StatusPresets.Load(null);
        Assert.AreEqual(4, StatusPresets.Adding(StatusPresets.New("x"), list).Count);
        CollectionAssert.AreEqual(new[] { "busy", "clean", "back" }, StatusPresets.Moving("clean", 1, list).Select(p => p.Id).ToList());
        CollectionAssert.AreEqual(new[] { "clean", "busy", "back" }, StatusPresets.Moving("clean", -1, list).Select(p => p.Id).ToList());
        var one = StatusPresets.Removing("busy", StatusPresets.Removing("clean", list));
        Assert.AreEqual(1, one.Count);
        Assert.AreEqual(1, StatusPresets.Removing("back", one).Count, "至少留一个");
        CollectionAssert.AreEqual(new[] { "back", "clean", "busy" }, StatusPresets.RestoringBuiltIns(one).Select(p => p.Id).ToList());
        Assert.IsTrue(StatusPresets.IsPristine(list[0]));
        var renamed = list[0].Copy();
        renamed.Title = "   ";
        Assert.AreEqual("清洁屏幕", StatusPresets.Updating(list, renamed)[0].Title, "标题删光了留着原来的");
        renamed.Title = "擦一下";
        Assert.IsFalse(StatusPresets.IsPristine(StatusPresets.Updating(list, renamed)[0]));
        Assert.AreEqual("还没填标题", StatusPresets.Problem(new StatusPreset { Title = " " }));
        Assert.IsNull(StatusPresets.Problem(list[1]));
    }

    [TestMethod]
    public void SummaryAndAutoEnd()
    {
        var list = StatusPresets.BuiltIn();
        Assert.AreEqual("熄屏 · 5 分钟后结束", StatusPresets.Summary(list[0]));
        Assert.AreEqual("透出 · 屏幕常亮", StatusPresets.Summary(list[1]));
        Assert.AreEqual("告示 · 不睡眠", StatusPresets.Summary(list[2]));
        Assert.AreEqual("不结束", StatusPresets.AutoEndTitle(0));
        Assert.AreEqual("1 小时", StatusPresets.AutoEndTitle(60));
        Assert.AreEqual("15 分钟", StatusPresets.AutoEndTitle(15));
    }

    [TestMethod]
    public void Merged_UpdatesByIdKeepsLocalOnes()
    {
        var local = StatusPresets.Load(null);
        local.Add(new StatusPreset { Id = "mine", Title = "我的", Style = "sign", Power = "awake" });
        var incoming = new List<StatusPreset>
        {
            new() { Id = "back", Title = "外出", Style = "sign", Power = "awake" },
            new() { Id = "new", Title = "新来的", Style = "dim", Power = "normal" },
        };
        var merged = StatusPresets.Merged(incoming, local);
        CollectionAssert.AreEqual(new[] { "back", "new", "clean", "busy", "mine" }, merged.Select(p => p.Id).ToList());
        Assert.AreEqual("外出", merged[0].Title);
    }

    [TestMethod]
    public void Json_SameShapeAsMac()
    {
        // mac 的 Codable：没有说明时不写 detail；键名 camelCase。
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartArray();
            foreach (var preset in StatusPresets.BuiltIn())
            {
                StatusPresets.Write(writer, preset);
            }

            writer.WriteEndArray();
        }

        var text = Encoding.UTF8.GetString(stream.ToArray());
        StringAssert.StartsWith(text, "[{\"id\":\"clean\",\"title\":\"清洁屏幕\",\"symbol\":\"glowing-star\",\"style\":\"blackout\",\"power\":\"normal\",\"autoEndMinutes\":5}");
        using var document = JsonDocument.Parse(text);
        var read = StatusPresets.ReadList(document.RootElement)!;
        Assert.AreEqual(3, read.Count);
        Assert.IsTrue(read.Zip(StatusPresets.BuiltIn()).All(pair => pair.First.SameAs(pair.Second)));

        // mac 写出来的一条（detail 是 null、键顺序不同）也认；缺键、样式不认识的整组不要。
        using var mac = JsonDocument.Parse(
            "[{\"autoEndMinutes\":0,\"detail\":null,\"id\":\"A1\",\"power\":\"awake\",\"style\":\"dim\",\"symbol\":\"\",\"title\":\"开会\"}]");
        Assert.AreEqual("开会", StatusPresets.ReadList(mac.RootElement)![0].Title);
        using var missing = JsonDocument.Parse("[{\"id\":\"A1\",\"title\":\"t\",\"symbol\":\"\",\"style\":\"dim\",\"power\":\"awake\"}]");
        Assert.IsNull(StatusPresets.ReadList(missing.RootElement));
        using var unknown = JsonDocument.Parse("[{\"id\":\"A1\",\"title\":\"t\",\"symbol\":\"\",\"style\":\"blur\",\"power\":\"awake\",\"autoEndMinutes\":0}]");
        Assert.IsNull(StatusPresets.ReadList(unknown.RootElement));
    }

    [TestMethod]
    public void ExitHold_EscHeldTwoSecondsCompletes()
    {
        var hold = new ExitHold();
        Assert.IsFalse(hold.Handle(Down(ExitHold.Escape), 0), "开始按住的那一下不算触碰");
        Assert.AreEqual(HoldSource.Key, hold.Holding!.Value.Source);
        Assert.IsFalse(hold.Handle(Down(ExitHold.Escape, repeat: true), 500), "连发不算、不重来");
        Assert.IsFalse(hold.IsComplete(1999));
        Assert.IsTrue(hold.IsComplete(2000));
        Assert.AreEqual(500, hold.Remaining(1500));
        Assert.IsTrue(hold.IsAnythingDown(2000));
        hold.Handle(Up(ExitHold.Escape), 2100);
        Assert.IsNull(hold.Holding);
        Assert.IsFalse(hold.IsAnythingDown(2100));
    }

    [TestMethod]
    public void ExitHold_OtherTouchesCancel()
    {
        var hold = new ExitHold();
        hold.Handle(Down(ExitHold.Escape), 0);
        Assert.IsTrue(hold.Handle(Down(0x41), 300), "别的键算一次触碰");
        Assert.IsNull(hold.Holding, "并且取消按住");

        // 按着别的键时按 Esc 不开始；带修饰键的 Esc 不开始。
        var other = new ExitHold();
        other.Handle(Down(0x41), 0);
        Assert.IsTrue(other.Handle(Down(ExitHold.Escape), 10));
        Assert.IsNull(other.Holding);
        var modified = new ExitHold();
        Assert.IsTrue(modified.Handle(Down(ExitHold.Escape, modifiers: true), 0));
        Assert.IsNull(modified.Holding);

        // 「按着」的键 5 秒没动静就不算了（松开那一下没收到）。
        var stale = new ExitHold();
        stale.Handle(Down(0x41), 0);
        Assert.IsFalse(stale.Handle(Down(ExitHold.Escape), 5001));
        Assert.IsNotNull(stale.Holding);

        // 鼠标键、别的鼠标键都取消；滚动不取消，每秒最多算一次触碰。
        var mouse = new ExitHold();
        mouse.Handle(Down(ExitHold.Escape), 0);
        Assert.IsTrue(mouse.Handle(new StatusInput(StatusInputKind.Scroll), 100));
        Assert.IsNotNull(mouse.Holding);
        Assert.IsFalse(mouse.Handle(new StatusInput(StatusInputKind.Scroll), 600));
        Assert.IsTrue(mouse.Handle(new StatusInput(StatusInputKind.Touch), 700));
        Assert.IsNull(mouse.Holding);
    }

    [TestMethod]
    public void ExitHold_MouseOnHint()
    {
        var hint = new List<PixelRect> { new(800, 900, 160, 50) };
        var hold = new ExitHold();
        Assert.IsTrue(hold.Handle(new StatusInput(StatusInputKind.LeftDown, X: 10, Y: 10), 0, hint), "点在别处是触碰");
        hold.Handle(new StatusInput(StatusInputKind.LeftUp), 50);
        Assert.IsFalse(hold.Handle(new StatusInput(StatusInputKind.LeftDown, X: 850, Y: 920), 100, hint));
        Assert.AreEqual(HoldSource.Mouse, hold.Holding!.Value.Source);
        Assert.IsTrue(hold.IsComplete(2100));
        hold.Handle(new StatusInput(StatusInputKind.LeftUp), 2200);
        Assert.IsNull(hold.Holding);
    }

    [TestMethod]
    public void Passcode_ParseProblemAndDigits()
    {
        Assert.IsNull(Passcode.Parse("123"));
        Assert.IsNull(Passcode.Parse("123456789"));
        Assert.IsNull(Passcode.Parse("12a4"));
        Assert.IsNull(Passcode.Parse("１２３４"), "全角数字不算");
        Assert.AreEqual(4, Passcode.Parse("0000")!.Length);
        Assert.AreEqual("密码是 4–8 位数字", Passcode.Problem("12", "12"));
        Assert.AreEqual("再输一次，两次要一样", Passcode.Problem("1234", "1235"));
        Assert.IsNull(Passcode.Problem("1234", "1234"));
        Assert.AreEqual(1, Passcode.Digit(0x02, false));
        Assert.AreEqual(0, Passcode.Digit(0x0B, false));
        Assert.AreEqual(7, Passcode.Digit(0x47, false), "小键盘 7");
        Assert.IsNull(Passcode.Digit(0x47, true), "带扩展标志的是 Home，不是 7");
        Assert.IsNull(Passcode.Digit(0x10, false));
    }

    [TestMethod]
    public void Passcode_Typing()
    {
        var passcode = Passcode.Parse("2580")!;
        StatusInput Digit(int scan) => Down(0x30 + scan, scan: scan);
        var now = 0L;
        Assert.AreEqual(PasscodeOutcome.Edited, passcode.Handle(Digit(0x03), now += 100));
        Assert.AreEqual(PasscodeOutcome.Ignored, passcode.Handle(Digit(0x03), now + 10), "50 ms 内同一个键是同一下");
        Assert.AreEqual(PasscodeOutcome.Edited, passcode.Handle(Down(0x08), now += 100), "Backspace 删一位");
        Assert.AreEqual(0, passcode.Typed);
        Assert.AreEqual(PasscodeOutcome.Ignored, passcode.Handle(Down(0x08), now += 100), "没得删");
        foreach (var scan in new[] { 0x03, 0x06, 0x09 })
        {
            Assert.AreEqual(PasscodeOutcome.Edited, passcode.Handle(Digit(scan), now += 100));
        }

        Assert.AreEqual(PasscodeOutcome.Matched, passcode.Handle(Digit(0x0B), now += 100));

        var wrong = Passcode.Parse("1111")!;
        for (var attempt = 1; attempt <= 5; attempt++)
        {
            for (var i = 0; i < 3; i++)
            {
                wrong.Handle(new StatusInput(StatusInputKind.KeyDown, 0x60 + i, 0x4F + i), now += 100);
            }

            var outcome = wrong.Handle(new StatusInput(StatusInputKind.KeyDown, 0x63, 0x51), now += 100);
            Assert.AreEqual(attempt == 5 ? PasscodeOutcome.GaveUp : PasscodeOutcome.Wrong, outcome);
            Assert.IsTrue(wrong.Missed);
        }

        Assert.AreEqual(5, wrong.Misses);
        Assert.AreEqual(PasscodeOutcome.Cancelled, wrong.Handle(Down(ExitHold.Escape), now += 100));
        Assert.AreEqual(PasscodeOutcome.Ignored, wrong.Handle(Down(ExitHold.Escape, modifiers: true), now += 100));
        Assert.AreEqual(PasscodeOutcome.Ignored, wrong.Handle(new StatusInput(StatusInputKind.LeftDown), now += 100));
    }

    [TestMethod]
    public void Wording()
    {
        Assert.AreEqual("5 秒", StatusScreenRules.Clock(5));
        Assert.AreEqual("3 分 05 秒", StatusScreenRules.Clock(185));
        Assert.AreEqual("1 小时 23 分 05 秒", StatusScreenRules.Clock(4985));
        Assert.AreEqual("14:02 开始 · 已 3 分 05 秒", StatusScreenRules.Footer("14:02", 185));
        Assert.AreEqual("14:02 开始 · 还剩 4 分 32 秒", StatusScreenRules.Footer("14:02", 28, 5));
        Assert.AreEqual("还剩 0 秒", StatusScreenRules.Footer("x", 9999, 5)[^6..]);
        Assert.AreEqual("持续不到 1 分钟", StatusScreenRules.Summary(StatusExitReason.Held, 30, 0, 0));
        Assert.AreEqual("持续 1 小时 23 分 · 挡下 12 次触碰", StatusScreenRules.Summary(StatusExitReason.Unlocked, 4985, 12, 0));
        Assert.AreEqual("到 5 分钟自动结束", StatusScreenRules.Summary(StatusExitReason.AutoEnd, 300, 0, 5));
        Assert.AreEqual("按住 Esc 两秒，再输入密码退出", StatusScreenRules.ExitWording(true));
    }

    [TestMethod]
    public void Layout()
    {
        Assert.AreEqual(44, StatusScreenRules.TitleSize(400));
        Assert.AreEqual(96, StatusScreenRules.TitleSize(2000));
        Assert.AreEqual(67.5, StatusScreenRules.TitleSize(900), 1e-9);
        Assert.AreEqual((0.0, 0.0), StatusScreenRules.Drift(0));
        for (var minute = 0; minute < 200; minute++)
        {
            var (x, y) = StatusScreenRules.Drift(minute);
            Assert.IsTrue(Math.Abs(x) <= 12 && Math.Abs(y) <= 8);
        }

        // 150% 的 1920 × 1080 屏（物理像素 2880 × 1620）：148 × 40 DIP 的提示离底 56 DIP。
        var hint = StatusScreenRules.HintRect(new PixelRect(0, 0, 2880, 1620), 1.5);
        Assert.AreEqual(new PixelRect(1329, 1476, 222, 60), hint);
        Assert.AreEqual(new PixelRect(1317, 1464, 246, 84), StatusScreenRules.HintHitRect(new PixelRect(0, 0, 2880, 1620), 1.5));

        // 眼睛：两成在屏幕外。
        Assert.AreEqual((0.0, 1000 - 100 + 20.0), StatusScreenRules.EyesOrigin(1600, 1000, 100, new Peek(PeekEdge.Bottom, 0)));
        Assert.AreEqual((1600 - 100 + 20.0, 900.0), StatusScreenRules.EyesOrigin(1600, 1000, 100, new Peek(PeekEdge.Right, 1)));
        Assert.AreEqual((-20.0, 450.0), StatusScreenRules.EyesOrigin(1600, 1000, 100, new Peek(PeekEdge.Left, 0.5)));
    }

    [TestMethod]
    public void RandomPeek_NeverSameEdgeTwiceAndClearsTheHint()
    {
        var random = new Random(7);
        PeekEdge? last = null;
        for (var i = 0; i < 2000; i++)
        {
            var peek = StatusScreenRules.RandomPeek(last, clearOfHint: true, random);
            Assert.AreNotEqual(last, peek.Edge);
            Assert.IsTrue(peek.Along is >= 0 and <= 1);
            if (peek.Edge == PeekEdge.Bottom)
            {
                Assert.IsFalse(peek.Along > StatusScreenRules.PeekMiddleLow && peek.Along < StatusScreenRules.PeekMiddleHigh, "底边正中留给退出提示");
            }

            last = peek.Edge;
        }
    }

    [TestMethod]
    public void WhatAnimatesAndLoads()
    {
        var list = StatusPresets.BuiltIn();
        Assert.IsTrue(StatusScreenRules.Animates(true, false));
        Assert.IsFalse(StatusScreenRules.Animates(true, true));
        Assert.IsFalse(StatusScreenRules.Peeks("blackout", true));
        Assert.IsFalse(StatusScreenRules.Peeks("dim", true), "Windows 的透出不冒眼睛");
        Assert.IsTrue(StatusScreenRules.Peeks("sign", true));
        Assert.AreEqual(0, StatusScreenRules.EmojiToLoad(list[0], true).Count, "熄屏什么都不显示");
        CollectionAssert.AreEqual(new[] { "raised-hand" }, StatusScreenRules.EmojiToLoad(list[1], true).ToList());
        CollectionAssert.AreEqual(new[] { "alarm-clock", "eyes" }, StatusScreenRules.EmojiToLoad(list[2], true).ToList());
        Assert.AreEqual(0, StatusScreenRules.EmojiToLoad(list[2], false).Count);
        Assert.AreEqual(2, StatusScreenRules.DefaultIndex(list, "back"));
        Assert.AreEqual(0, StatusScreenRules.DefaultIndex(list, "gone"));
        Assert.AreEqual(0, StatusScreenRules.NextIndex(2, 3));
        Assert.AreEqual(16, StatusEmojiCatalog.Choices.Length);
        Assert.IsTrue(StatusEmojiCatalog.NeedsPlate("busts", dark: true));
        Assert.IsFalse(StatusEmojiCatalog.NeedsPlate("busts", dark: false));
    }
}
