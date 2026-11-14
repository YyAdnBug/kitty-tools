// 启动器每条命令的快捷键（PLAN-v18 L3，mac 8a8c7eac bf9add16 LauncherModel.runHotKey）：设置 › 启动器 › 命令和别名 那一列录的键，
// HotKeyManager 每条命令一个固定的热键号（这次运行里不复用）。按了：系统命令不用确认的直接执行，要确认的（清空回收站、注销、重启、关机）
// 打开启动器填好它的别名、等再按一次 Enter；关键词命令打开启动器填好「别名 」接着打（ip、汇率只填别名）。
// 注册跟着启动器功能开关和这条命令的开关；「在这些应用里停用」选「全部」时连它们一起停（PLAN-v17 H3）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class LauncherCommandKeys
{
    /// <summary>「命令」表此刻的设置。</summary>
    public static LauncherCommandSettings Settings
        => LauncherCommandTable.FromStored(SettingsService.Current.LauncherCommandAliases, SettingsService.Current.LauncherCommandsOff);

    /// <summary>表里全部的行：我的脚本（PLAN-v18 L1）、关键词命令、系统命令（编号、标题、原来的关键词、图标）。</summary>
    public static IEnumerable<LauncherBuiltIn> Rows
        => ScriptRows.Concat(BundledRows).Concat(LauncherCommandTable.BuiltIns).Concat(SystemCommands.Rows());

    /// <summary>自己的脚本那几行：编号「script:路径」，原来的别名是头部写的 keyword（没写是空）。</summary>
    public static IEnumerable<LauncherBuiltIn> ScriptRows => ScriptRowsWhere(bundled: false);

    /// <summary>自带的命令那几行（PLAN-v18 D8）。</summary>
    public static IEnumerable<LauncherBuiltIn> BundledRows => ScriptRowsWhere(bundled: true);

    private static IEnumerable<LauncherBuiltIn> ScriptRowsWhere(bool bundled)
        => SettingsService.Current.LauncherScripts
            ? ScriptLibrary.Scripts.Where(script => script.IsBundled == bundled)
                .Select(script => new LauncherBuiltIn(ScriptId(script), script.Title, script.Keyword ?? string.Empty, Glyphs.Code))
            : Enumerable.Empty<LauncherBuiltIn>();

    public static string ScriptId(ScriptCommand script) => "script:" + script.Path;

    /// <summary>设了快捷键、开着的命令（编号 → 组合）：HotKeyManager 注册它们。</summary>
    public static IEnumerable<(string Id, HotKeyBinding Binding)> Bindings()
    {
        if (!Features.IsOn(Feature.Launcher) || SettingsService.Current.LauncherCommandHotKeys is not { Count: > 0 } stored)
        {
            yield break;
        }

        var settings = Settings;
        foreach (var row in Rows)
        {
            if (settings.IsOn(row.Id) && stored.TryGetValue(row.Id, out var text) &&
                HotKeyRules.TryParse(text, out var key, out var modifiers))
            {
                yield return (row.Id, new HotKeyBinding(key, modifiers));
            }
        }
    }

    public static void Run(string id)
    {
        var settings = Settings;
        if (!Features.IsOn(Feature.Launcher) || !settings.IsOn(id) || Rows.FirstOrDefault(row => row.Id == id) is not { } row)
        {
            return;
        }

        var alias = settings.Alias(id, row.Keyword);
        Log.Info($"launcher.command-hotkey {id}");
        // 脚本：不要参数、不用确认、看过全文的直接跑；别的打开启动器填好「别名 」（参数、确认、看全文在那里做）
        if (id.StartsWith("script:", StringComparison.Ordinal) && ScriptLibrary.Scripts.FirstOrDefault(script => ScriptId(script) == id) is { } script)
        {
            if (!script.TakesInput && script.Confirmation is null && !script.IsDownloaded)
            {
                ScriptHost.Run(script, Array.Empty<string>(), Windows.Win32.PInvoke.GetForegroundWindow());
                return;
            }

            Open((alias is { Length: > 0 } typed ? typed : script.Title) + " ");
            return;
        }

        if (id.StartsWith("system:", StringComparison.Ordinal) && SystemCommands.TargetOf(row.Keyword) is { } target)
        {
            if (SystemCommands.Confirmation(target) is null)
            {
                if (!SystemCommands.Execute(target, out var error))
                {
                    NoticeHost.Show($"没能{row.Title}", error, NoticeTone.Error);
                }

                return;
            }

            // 不可撤销的：打开启动器填好它，再按 Enter 才执行（同启动器里第一下只上膛）
            Open(alias ?? row.Title);
            return;
        }

        Open(alias is null ? string.Empty : id is "builtin:ip" or "builtin:currency" ? alias : alias + " ");
    }

    private static void Open(string query)
    {
        OverlayHost.SetLauncherQuery(query);
        OverlayHost.Show(OverlayKind.Launcher);
    }
}
