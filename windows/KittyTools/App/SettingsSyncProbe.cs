// 设置同步的实机自检（PLAN-v21 第 2 批，只在测试档）：`--sync-settings-probe=<目录>`，同步文件夹用 KITTY_SYNC_SETTINGS_FOLDER
// 给的临时文件夹（不碰真的同步文件夹）。KITTY_SYNC_SETTINGS_ROLE 定这一份做什么：
// - a：开同步（文件夹、设置与快捷键都勾上），改主题、快捷键、关一个功能、改一项 Windows 独有的，合两轮；查只有 Windows 时没写 settings.json；
// - b：开同步合两轮，查 a 的那几项都跟过来了；
// - mac：在文件夹里照 mac 的规矩写一台假 Mac 的 settings.json（Core 的 SyncRunner + 一个照 mac 合的内存仓库，不起同步），
//   有一项 Mac 独有的、一个 mac 写法的快捷键、主题是浅色；
// - a2：再合两轮，查跟着 Mac 换了主题、Mac 独有的那两项透传进了自己那份 settings.json、Windows 的快捷键没变。
// 每份把结果写进 <目录>\report-<角色>.md（每轮多久、各项的值、对照表有没有没接上读写的），跑完就退。
using System.Diagnostics;
using System.Text;
using KittyTools.Core;
using KittyTools.Core.Sync;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class SettingsSyncProbe
{
    public const string ArgumentPrefix = "--sync-settings-probe";

    private const string MacHotKey = "{\"keyCode\":0,\"modifiers\":2048}";

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path) ? Path.Combine(Path.GetTempPath(), "kitty-sync-settings-probe") : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var role = Environment.GetEnvironmentVariable("KITTY_SYNC_SETTINGS_ROLE") ?? "a";
        var folder = Environment.GetEnvironmentVariable("KITTY_SYNC_SETTINGS_FOLDER");
        var report = new StringBuilder($"# 设置同步自检：{role}（{Paths.DataDirectory}）\n\n");
        var failures = 0;
        void Check(bool ok, string text)
        {
            failures += ok ? 0 : 1;
            report.Append(ok ? "- ok " : "- **不对** ").Append(text).Append('\n');
        }

        try
        {
            await Task.Delay(2500);
            Check(!SettingsSyncFields.Missing.Any(), "对照表每一项都接上了读写" + string.Join("、", SettingsSyncFields.Missing));
            if (string.IsNullOrEmpty(folder) || !Path.IsPathRooted(folder))
            {
                Check(false, "KITTY_SYNC_SETTINGS_FOLDER 没给（要一个临时文件夹的绝对路径）");
                return;
            }

            Directory.CreateDirectory(folder);
            if (role == "mac")
            {
                await WriteFakeMacAsync(folder, report);
                return;
            }

            if (Syncer.Instance is not { } syncer)
            {
                Check(false, "没有 Syncer");
                return;
            }

            var settings = SettingsService.Current;
            settings.SyncFolder = folder;
            settings.SyncEnabled = true;
            settings.SyncSettings = true;
            SettingsService.Save();
            var theme = SettingsSyncMap.FindShared("pref:appearance")!;
            var record = SettingsSyncMap.FindShared("pref:feature.record")!;
            var recent = SettingsSyncMap.FindWindows("pref:LauncherRecentPrograms")!;
            var launcher = SettingsSyncMap.HotKey(HotKeyActions.Launcher);
            if (role == "a")
            {
                settings.Theme = "dark";
                SettingsDefaults.SetBinding(settings, HotKeyActions.Launcher, new HotKeyBinding(0x20, HotKeyModifiers.Control | HotKeyModifiers.Alt));
                settings.Features ??= new Dictionary<string, bool>();
                settings.Features["recording"] = false;
                settings.LauncherRecentPrograms = false;
                SettingsService.Save();
                await Task.Delay(300);
            }

            for (var round = 1; round <= 2; round++)
            {
                var watch = Stopwatch.StartNew();
                await syncer.RoundAsync();
                report.Append($"- 第 {round} 轮 {watch.ElapsedMilliseconds} ms，状态 {syncer.Status.State} {syncer.Status.Message}\n");
                await Task.Delay(500);
            }

            var me = SyncDevice.Instance?.Id ?? string.Empty;
            var ownSettings = Path.Combine(folder, SyncDisk.KindPath(me, SettingsSync.Kind));
            var ownWindows = Path.Combine(folder, SyncDisk.KindPath(me, SettingsSync.WindowsKind));
            string Value(SettingKey key) => SettingsSyncFields.Read(SettingsService.Current, key)?.Encode() ?? "（没有）";
            report.Append($"- 主题 {Value(theme)}，录制功能 {Value(record)}，最近用过的程序 {Value(recent)}，启动器的键 {Value(launcher)}\n");
            report.Append($"- 存过的键 {SettingsService.Current.SyncStoredKeys?.Count ?? 0} 项；透传 {SettingsService.Current.SyncPassthrough?.Count ?? 0} 项\n");
            switch (role)
            {
                case "a":
                    Check(!File.Exists(ownSettings), "只有 Windows：没写 settings.json");
                    Check(File.Exists(ownWindows) && File.ReadAllText(ownWindows).Contains("hotkey:launcher"), "windows-settings.json 里有启动器的键");
                    break;
                case "b":
                    Check(Value(theme) == "\"dark\"", "主题跟着 a");
                    Check(Value(record) == "false", "录制功能跟着 a 关了");
                    Check(Value(recent) == "false", "Windows 独有的跟着 a");
                    Check(Value(launcher) == "\"Ctrl+Alt+Space\"", "快捷键跟着 a");
                    Check(!File.Exists(ownSettings), "还没有 Mac：没写 settings.json");
                    break;
                case "a2":
                    Check(Value(theme) == "\"light\"", "第一次和 Mac 合：主题跟着 Mac");
                    Check(Value(launcher) == "\"Ctrl+Alt+Space\"", "Windows 的快捷键不跟 Mac 走");
                    var text = File.Exists(ownSettings) ? File.ReadAllText(ownSettings) : string.Empty;
                    Check(text.Contains("pref:islandHaptics") && text.Contains("hotkey:noteAll"), "Mac 独有的那两项透传进了自己那份 settings.json");
                    Check(!text.Contains("LauncherRecentPrograms") && !text.Contains("hotkey:launcher"), "Windows 独有的不进 settings.json");
                    break;
            }
        }
        catch (Exception ex)
        {
            Check(false, $"出错 {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            report.Append(failures == 0 ? "\n全部通过。\n" : $"\n{failures} 项不对。\n");
            await File.WriteAllTextAsync(Path.Combine(directory, $"report-{role}.md"), report.ToString());
            Log.Info($"settings-sync-probe done role={role} failures={failures}");
            Environment.Exit(failures == 0 ? 0 : 1);
        }
    }

    /// <summary>照 mac 的规矩写一台假 Mac：一项一条、第一次合跟着已有的（这里它是第一台）。</summary>
    private static async Task WriteFakeMacAsync(string folder, StringBuilder report)
    {
        var mac = new FakeMac();
        mac.Map["pref:appearance"] = "\"light\"";
        mac.Map["pref:islandHaptics"] = "false";
        mac.Map["hotkey:noteAll"] = MacHotKey;
        var result = await new SyncRunner(new FakeDevice(), new ISyncSource[] { mac }, "Probe Mac")
            .RunAsync(folder, new Dictionary<string, int>(), DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        report.Append($"- 假 Mac 合了一轮：{result.State}；它的设置 {mac.Map.Count} 项（{string.Join("、", mac.Map.Keys.Order(StringComparer.Ordinal))}）\n");
    }

    private sealed class FakeDevice : ISyncDevice
    {
        public string Id { get; private set; } = "00000000-0000-4000-8000-00000000AC01";

        public string? Library { get; private set; }

        public int Epoch { get; private set; }

        public string? NotesSwitchFrom => null;

        public void SetLibrary(string library) => Library = library;

        public void Rotate() => Id = Guid.NewGuid().ToString("D").ToUpperInvariant();

        public void SetEpoch(int epoch) => Epoch = epoch;

        public void SetNotesSwitchFrom(string? oldId)
        {
        }
    }

    private sealed class FakeMac : ISyncSource
    {
        public Dictionary<string, string> Map { get; } = new(StringComparer.Ordinal);

        public string Kind => SettingsSync.Kind;

        public JoinMode Join => JoinMode.Adopt;

        public string? JoinKey(string value) => null;

        public IReadOnlyDictionary<string, string>? Values() => new Dictionary<string, string>(Map, StringComparer.Ordinal);

        public SyncLedgerData? Ledger(string library) => null;

        public string? Apply(IReadOnlyDictionary<string, string?> changes, SyncLedgerData ledger, string library)
        {
            foreach (var (id, value) in changes)
            {
                if (value is null)
                {
                    Map.Remove(id);
                }
                else
                {
                    Map[id] = value;
                }
            }

            return null;
        }
    }
}
