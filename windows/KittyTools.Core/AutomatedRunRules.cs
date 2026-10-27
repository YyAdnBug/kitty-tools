// 哪些进程算「自己会跑完就退的自检」（纯函数 + 单测）：这种进程不往系统托盘登记图标，
// 原因见 KittyTools/App/AutomatedRun.cs。新加会自己退出的自检开关时加进下面的表。
namespace KittyTools.Core;

public static class AutomatedRunRules
{
    private static readonly string[] Switches =
    {
        "--smoke",
        "--cred-smoke",
        "--ui-snapshots",
        "--clip-scroll-test",
        "--a11y-audit",
        "--wgc-probe",
        "--update-e2e",
        "--notice-anim-test",
        "--height-anim-test",
    };

    private static readonly string[] Variables =
    {
        "KITTY_MEMORY_PROBE",
        "KITTY_RECORD_PROBE_SECONDS",
    };

    /// <summary>命令行里有自检开关（含 --xxx=目录 的写法），或设了探针环境变量。</summary>
    public static bool IsAutomated(IEnumerable<string> args, Func<string, string?> variable)
        => args.Any(arg => Switches.Any(flag =>
               arg.Equals(flag, StringComparison.OrdinalIgnoreCase) ||
               arg.StartsWith(flag + "=", StringComparison.OrdinalIgnoreCase))) ||
           Variables.Any(name => !string.IsNullOrEmpty(variable(name)));
}
