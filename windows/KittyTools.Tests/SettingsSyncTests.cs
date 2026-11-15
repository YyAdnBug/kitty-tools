// PLAN-v21 第 1 批：设置同步的对照表、值的写法、透传 / 改的时刻 / 存过的键。
// mac 那边的写法照 SyncRecords.encoder（CanonicalJson）；mac 的 NoteSyncerTests 里出现过的几行（"16"、"5000000"、
// {"keyCode":0,"modifiers":2048}、"pref:新版本才有的设置"）原样拿来当输入。MacKeys 是 mac origin/macos 58f15ee3 的
// Prefs.defaults（加上 SettingsArchive.kinds 另加的源 / 目标语言）里的全部键名——对照表里的 mac 键必须都在里面。
using KittyTools.Core.Sync;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class SettingsSyncTests
{
    private static readonly HashSet<string> MacKeys = new(StringComparer.Ordinal)
    {
        "appearance", "accent", "statusItemVisible", "dockIconOnTahoe", "statusItemStyle", "clipboardHideOnUnfocus",
        "launcherBrowserBookmarks", "launcherBrowserHistory", "launcherFallbackAlways", "launcherShowsFrequent",
        "launcherRomanInput", "launcherScripts", "launcherCommandAliases", "launcherAppAliases", "launcherCommandsOff",
        "launcherCommandHotKeys", "hotKeyBlockedApps", "launchpadColumns", "launchpadRows", "launchpadLayout",
        "launchpadPinchGesture", "launchpadPinchSense", "launchpadCorner", "dockPreviewDelay", "dockPreviewCmdTab",
        "finderOpenWithApps", "panelSqueezeEntrance", "floatingPinned", "updateAutoCheck", "clipboardHistoryRetentionDays",
        "clipboardImageCacheMaxMb", "clipboardExcludedBundleIDs", "clipboardBlockSensitive", "clipboardPastePlainByDefault",
        "clipboardImageOcr", "clipboardClearOnExit", "clipboardClearOnLock", "clipboardShowPreview", "clipboardLinkPreview",
        "clipboardPasteOnClick", "clipboardPanelPosition", "launcherPanelPosition", "translateNativeLang",
        "translateForeignLang", "translateDeleteNewline", "autoCopy", "translateCopyRecognized", "translateScreenshotOverlay",
        "translateHistoryEnabled", "translateHistoryLimit", "translatePanelPosition", "translateClipboardMonitor",
        "translateSystemDictionary", "translateWordMode", "translateWordRecording", "translateWordAccent",
        "translateFontScale", "translateCollapsedServices", "ocrJoinLines", "screenshotShutterSound", "screenshotPlacement",
        "screenshotToolbarAlign", "screenshotCopyAs", "scrollCaptureSpeed", "screenshotKeepsColors", "screenshotFindsElements",
        "shotHistory", "shotHistoryDays", "shotHistoryMegabytes", "screenRecordFrameRate", "screenRecordCountdown",
        "screenRecordShowsCursor", "screenRecordSharpness", "screenRecordCodec", "screenRecordKeysShortcutsOnly",
        "screenRecordSystemAudio", "screenRecordMicrophone", "screenRecordShowsClicks", "screenRecordShowsKeys",
        "audioRecordSource", "audioRecordStartsImmediately", "statusScreenExitHint", "statusScreenHotKeyEntersFirst",
        "statusScreenAnimations", "remindersSnoozeMinutes", "emojiPackDownloads", "notesFontSize", "notesMarkdown",
        "notesLineSpacing", "notesDeckEnabled", "notesDeckEdge", "notesDeckDisplay", "notesDeckStyle", "notesDeckSize",
        "notesDeckSense", "notesDeckAlwaysFanned", "notesDeckHidesPill", "notesDeckPreview", "notesDeckOpensOnHover",
        "notesDeckOverFullScreen", "notesDeckNoteSize", "finderMenuGrouped", "finderCompressSkip",
        "translateSourceLang", "translateTargetLang",
        "feature.clipboard", "feature.launcher", "feature.translate", "feature.screenshot", "feature.record",
        "feature.notes", "feature.reminders", "feature.statusScreen", "feature.launchpad", "feature.dockPreview",
        "feature.finderMenu", "feature.island",
    };

    /// <summary>mac SettingsSync.localKeys（留在本机）：对照表里不该有。</summary>
    private static readonly string[] MacLocalKeys =
    {
        "launchpadColumns", "launchpadRows", "launchpadPinchGesture", "launchpadPinchSense", "launchpadCorner",
        "feature.launchpad", "screenRecordMicrophone", "audioRecordSource", "screenRecordShowsKeys", "feature.dockPreview",
        "feature.finderMenu", "notesDeckDisplay", "statusItemVisible", "clipboardHideOnUnfocus", "floatingPinned",
        "statusScreenPresets", "reminders",
    };

    [TestMethod]
    public void MapCoversRealMacKeysOnly()
    {
        var ids = SettingsSyncMap.Shared.Select(key => key.Id).ToList();
        Assert.AreEqual(81, ids.Count, "PLAN-v21 §1 A、B 组（含 7 个功能开关）");
        Assert.AreEqual(15, SettingsSyncMap.WindowsOnly.Count, "C 组（快捷键另算）");
        CollectionAssert.AllItemsAreUnique(ids);
        CollectionAssert.AllItemsAreUnique(SettingsSyncMap.Shared.Select(key => key.Field).ToList());
        foreach (var key in SettingsSyncMap.Shared)
        {
            Assert.IsTrue(key.Shared);
            StringAssert.StartsWith(key.Id, SettingsSyncMap.PrefPrefix);
            Assert.IsTrue(MacKeys.Contains(key.Id[SettingsSyncMap.PrefPrefix.Length..]), $"{key.Id} 不是 mac 的偏好键");
        }

        foreach (var local in MacLocalKeys)
        {
            Assert.IsNull(SettingsSyncMap.FindShared(SettingsSyncMap.PrefPrefix + local), $"{local} mac 留在本机");
        }

        // Windows 独有的那几项和 mac 的键不撞名（windows-settings 里两种编号放在一起）
        foreach (var key in SettingsSyncMap.WindowsOnly)
        {
            Assert.IsFalse(key.Shared);
            Assert.IsNull(SettingsSyncMap.FindShared(key.Id), key.Id);
            Assert.IsFalse(MacKeys.Contains(key.Id[SettingsSyncMap.PrefPrefix.Length..]), key.Id);
        }
    }

    [TestMethod]
    public void ValuesWriteLikeTheMacEncoder()
    {
        Assert.AreEqual("true", SettingValue.Of(true).Encode());
        Assert.AreEqual("16", SettingValue.Of(16L).Encode());
        Assert.AreEqual("1", SettingValue.Of(1.0)!.Encode(), "整数值的小数写成整数（mac JSONEncoder）");
        Assert.AreEqual("1.25", SettingValue.Of(1.25)!.Encode());
        Assert.AreEqual("\"top\"", SettingValue.Of("top").Encode());
        // 非 ASCII、斜杠原样；引号、反斜杠、换行短写法，别的控制字符 \u00xx
        Assert.AreEqual("\"中文/a\\\"b\\\\c\\nd\\u001f\"", SettingValue.Of("中文/a\"b\\c\nd\u001f").Encode());
        Assert.AreEqual("[\"a\",\"b\"]", SettingValue.Of(new[] { "a", "b" }).Encode());
        Assert.AreEqual("{\"a\":\"2\",\"b\":\"1\"}",
            SettingValue.Of(new Dictionary<string, string> { ["b"] = "1", ["a"] = "2" }).Encode(), "键排好序");
        Assert.IsNull(SettingValue.Of(double.NaN));

        foreach (var text in new[] { "true", "false", "16", "1.25", "\"top\"", "[\"a\",\"b\"]", "[]", "{\"a\":\"2\"}", "\"\"" })
        {
            Assert.AreEqual(text, SettingValue.Decode(text)?.Encode(), text);
        }

        // 编回去不一字不差的当解不开（mac decodeExact）
        foreach (var text in new[] { " true", "1.0", "16 ", "{\"b\":\"1\",\"a\":\"2\"}", "[1]", "{\"a\":1}", "null", "\"\\/\"", "{\"bool\":{\"_0\":true}}", "" })
        {
            Assert.IsNull(SettingValue.Decode(text), text);
        }
    }

    [TestMethod]
    public void KeysConvertBothWays()
    {
        var accent = SettingsSyncMap.FindShared("pref:accent")!;
        Assert.AreEqual("\"pink\"", accent.Outgoing(SettingValue.Of("brand")), "Windows 旧的默认值 brand 就是品牌粉");
        Assert.AreEqual("\"graphite\"", accent.Outgoing(SettingValue.Of("graphite")));
        Assert.AreEqual(SettingValue.Of("system"), accent.Incoming("\"system\""));
        Assert.IsNull(accent.Incoming("\"rainbow\""));

        var placement = SettingsSyncMap.FindShared("pref:screenshotPlacement")!;
        Assert.AreEqual("\"corner\"", placement.Outgoing(SettingValue.Of("card")));
        Assert.AreEqual(SettingValue.Of("card"), placement.Incoming("\"corner\""));
        Assert.AreEqual(SettingValue.Of("none"), placement.Incoming("\"none\""));
        Assert.IsNull(placement.Incoming("\"clothesline\""), "晾衣绳 Windows 没有：落不下");

        var collapsed = SettingsSyncMap.FindShared("pref:translateCollapsedServices")!;
        Assert.AreEqual("\"zhipu\\nopenai\"", collapsed.Outgoing(SettingValue.Of(new[] { "zhipu", "openai" })), "mac 是换行隔开的一段");
        Assert.AreEqual(SettingValue.Of(new[] { "zhipu", "openai" }), collapsed.Incoming("\"zhipu\\nopenai\""));
        Assert.AreEqual(SettingValue.Of(Array.Empty<string>()), collapsed.Incoming("\"\""));

        var scale = SettingsSyncMap.FindShared("pref:translateFontScale")!;
        Assert.AreEqual(SettingValue.Of(1.0), scale.Incoming("1"), "mac 把 1.0 写成 1");
        Assert.AreEqual("1.25", scale.Outgoing(SettingValue.Of(1.25)!));
        Assert.IsNull(scale.Incoming("9"));

        var native = SettingsSyncMap.FindShared("pref:translateNativeLang")!;
        Assert.AreEqual(SettingValue.Of("zh-Hans"), native.Incoming("\"zh-Hans\""));
        Assert.IsNull(native.Incoming("\"klingon\""));

        var size = SettingsSyncMap.FindShared("pref:notesFontSize")!;
        Assert.AreEqual(SettingValue.Of(16L), size.Incoming("16"));
        Assert.IsNull(size.Incoming("5000000"), "超出 mac 收设置的范围（mac 的单测里就是这一行）");
        Assert.IsNull(size.Incoming("true"), "类型不对");
        Assert.IsNull(size.Outgoing(SettingValue.Of(5_000_000L)), "对面落不下的不发");
        Assert.IsNull(size.Outgoing(SettingValue.Of(true)), "Windows 这边的类型不对也不发");

        var theme = SettingsSyncMap.FindShared("pref:appearance")!;
        Assert.AreEqual("Theme", theme.Field);
        Assert.IsNull(theme.Incoming("\"sepia\""));
        Assert.AreEqual("Accent", accent.Field);
        Assert.AreEqual("feature.recording", SettingsSyncMap.FindShared("pref:feature.record")!.Field, "Windows 的录制叫 recording");
        Assert.IsNull(SettingsSyncMap.FindShared("pref:feature.screenshot"), "截图在 Windows 上没有开关：透传");
        Assert.IsNull(SettingsSyncMap.FindShared("pref:feature.keepAwake"), "mac 0.9.0 拿掉了保持唤醒：Windows 独有");
        Assert.IsNotNull(SettingsSyncMap.FindWindows("pref:feature.keepAwake"));

        var hotKey = SettingsSyncMap.HotKey("clipboard");
        Assert.AreEqual("hotkey:clipboard", hotKey.Id);
        Assert.AreEqual("\"Alt+C\"", hotKey.Outgoing(SettingValue.Of("Alt+C")));
        Assert.AreEqual(SettingValue.Of(string.Empty), hotKey.Incoming("\"\""), "清除了的也是一条");
        Assert.IsNull(hotKey.Incoming("{\"keyCode\":0,\"modifiers\":2048}"), "mac 的写法：这边落不下");
    }

    [TestMethod]
    public void OnlyStoredKeysAreSent()
    {
        var size = SettingsSyncMap.FindShared("pref:notesFontSize")!;
        var theme = SettingsSyncMap.FindShared("pref:appearance")!;
        var source = SettingsSyncMap.FindShared("pref:translateSourceLang")!;
        var stored = new HashSet<string>(StringComparer.Ordinal);
        var readings = new[]
        {
            new SettingReading(size, SettingValue.Of(15L), SettingValue.Of(15L)),
            new SettingReading(theme, SettingValue.Of("dark"), SettingValue.Of("system")),
            new SettingReading(source, null, null),
        };
        var own = SettingsSync.Own(readings, stored);
        CollectionAssert.AreEquivalent(new[] { "pref:appearance" }, own.Keys.ToList(), "和默认一样、从没改过的不发");
        Assert.AreEqual("\"dark\"", own["pref:appearance"]);
        CollectionAssert.AreEquivalent(new[] { "Theme" }, stored.ToList());

        // 改回默认值还是存过（mac 也是）：照发
        readings[1] = readings[1] with { Value = SettingValue.Of("system") };
        own = SettingsSync.Own(readings, stored);
        Assert.AreEqual("\"system\"", own["pref:appearance"]);
    }

    [TestMethod]
    public void ChangesWinPassthroughAndKeepTimes()
    {
        var known = new Dictionary<string, string> { ["pref:notesFontSize"] = "15" };
        var own = new Dictionary<string, string> { ["pref:notesFontSize"] = "15", ["pref:appearance"] = "\"dark\"" };
        var passthrough = new Dictionary<string, string> { ["pref:notesFontSize"] = "5000000", ["pref:新版本才有的设置"] = "true" };
        var times = new Dictionary<string, long> { ["pref:gone"] = 1 };

        // 交出去的：透传着的那几项是透传的那份（mac：交本机的旧值就把新版本写的翻回去）
        var values = SettingsSync.Values(own, passthrough);
        Assert.AreEqual("5000000", values["pref:notesFontSize"]);
        Assert.AreEqual("true", values["pref:新版本才有的设置"]);

        Assert.IsTrue(SettingsSync.Record(known, own, passthrough, times, now: 100));
        Assert.AreEqual(100, times["pref:appearance"]);
        Assert.IsFalse(times.ContainsKey("pref:notesFontSize"), "没变的不记");
        Assert.IsFalse(times.ContainsKey("pref:gone"), "本机和透传里都没有了的不再记");
        Assert.AreEqual("5000000", passthrough["pref:notesFontSize"], "本机没改它：透传留着");

        // 本机自己又改了它：换成本机的，透传的扔掉
        var changed = new Dictionary<string, string>(own) { ["pref:notesFontSize"] = "16" };
        Assert.IsTrue(SettingsSync.Record(own, changed, passthrough, times, now: 200));
        Assert.IsFalse(passthrough.ContainsKey("pref:notesFontSize"));
        Assert.AreEqual("16", SettingsSync.Values(changed, passthrough)["pref:notesFontSize"]);
        Assert.AreEqual(200, times["pref:notesFontSize"]);
        Assert.IsFalse(SettingsSync.Record(changed, changed, passthrough, times, now: 300));

        SettingsSync.Landed(new Dictionary<string, string?> { ["pref:notesFontSize"] = "17" }, times);
        Assert.IsFalse(times.ContainsKey("pref:notesFontSize"), "同步落下去的那几项清掉它们的时刻");
    }

    [TestMethod]
    public void PlanLandsWhatItKnowsAndPassesTheRest()
    {
        var changes = new Dictionary<string, string?>
        {
            ["pref:notesFontSize"] = "17",
            ["pref:appearance"] = null,
            ["pref:新版本才有的设置"] = "true",
            ["hotkey:noteAll"] = "{\"keyCode\":0,\"modifiers\":2048}",
            ["pref:screenshotPlacement"] = "\"clothesline\"",
            ["pref:launchpadColumns"] = "9",
            ["pref:老的"] = null,
        };
        var passthrough = new Dictionary<string, string> { ["pref:老的"] = "1" };
        var plan = SettingsSync.Plan(changes, SettingsSyncMap.FindShared, passthrough, windowsKind: false, sharedFrozen: false);
        Assert.AreEqual(2, plan.Writes.Count);
        Assert.AreEqual(SettingValue.Of(17L), plan.Writes.Single(write => write.Key.Field == "NotesFontSize").Value);
        Assert.IsNull(plan.Writes.Single(write => write.Key.Field == "Theme").Value, "对面改回默认 = 本机也回到默认");
        CollectionAssert.AreEquivalent(
            new[] { "pref:新版本才有的设置", "hotkey:noteAll", "pref:screenshotPlacement", "pref:launchpadColumns" },
            plan.Passthrough.Keys.ToList(), "不认识的、mac 独有的、落不下的原样存着；删了的跟着删");
        Assert.AreEqual("{\"keyCode\":0,\"modifiers\":2048}", plan.Passthrough["hotkey:noteAll"]);

        // App 再核一遍不收的（不能当全局热键用的组合）：进透传
        var hotKey = SettingsSyncMap.HotKey("clipboard");
        plan = SettingsSync.Plan(new Dictionary<string, string?> { [hotKey.Id] = "\"A\"" },
            id => id == hotKey.Id ? hotKey : null, new Dictionary<string, string>(), windowsKind: true, sharedFrozen: false,
            accept: (_, value) => value.Text.Contains('+'));
        Assert.AreEqual(0, plan.Writes.Count);
        Assert.AreEqual("\"A\"", plan.Passthrough[hotKey.Id]);
    }

    [TestMethod]
    public void WindowsKindFreezesSharedKeysOnceAMacIsThere()
    {
        SettingKey? Find(string id) => SettingsSyncMap.FindShared(id) ?? SettingsSyncMap.FindWindows(id);
        var changes = new Dictionary<string, string?>
        {
            ["pref:notesFontSize"] = "17",
            ["pref:appearance"] = null,
            ["pref:LauncherRecentPrograms"] = "false",
            ["pref:ClipboardExcludedApps"] = null,
        };

        // 还没有 Mac：共有的值照落，共有的删除不落（这一类里只会是「改走 settings」那一刻留下的墓碑）
        var plan = SettingsSync.Plan(changes, Find, new Dictionary<string, string>(), windowsKind: true, sharedFrozen: false);
        CollectionAssert.AreEquivalent(new[] { "NotesFontSize", "LauncherRecentPrograms", "ClipboardExcludedApps" },
            plan.Writes.Select(write => write.Key.Field).ToList());
        Assert.IsNull(plan.Writes.Single(write => write.Key.Field == "ClipboardExcludedApps").Value, "Windows 独有的删除照落");

        // 有了 Mac：共有的只认 settings 一类，这里一项都不落、也不透传
        plan = SettingsSync.Plan(changes, Find, new Dictionary<string, string>(), windowsKind: true, sharedFrozen: true);
        CollectionAssert.AreEquivalent(new[] { "LauncherRecentPrograms", "ClipboardExcludedApps" },
            plan.Writes.Select(write => write.Key.Field).ToList());
        Assert.AreEqual(0, plan.Passthrough.Count);
    }

    [TestMethod]
    public void ClashNamesTheFirstPair()
    {
        Assert.AreEqual(("clipboard", "launcher"), SettingsSync.Clash(new Dictionary<string, string>
        {
            ["clipboard"] = "Alt+C",
            ["home"] = string.Empty,
            ["launcher"] = "alt+c",
        }.OrderBy(pair => pair.Key)));
        Assert.IsNull(SettingsSync.Clash(new Dictionary<string, string> { ["a"] = "", ["b"] = "" }));
    }
}
