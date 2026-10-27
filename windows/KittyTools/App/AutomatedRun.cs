// 自己会跑完就退的自检（冒烟、截图、各种探针）：这种进程不往系统托盘登记图标。
// Windows 按 exe 的完整路径记「其他系统托盘图标」（HKCU\Control Panel\NotifyIconSettings），
// 探针 exe 拷到临时目录跑一次就多一条，Windows 不会自己删，设置 › 个性化 › 任务栏里会排出十几个 KittyTools
// （2026-10-27 用户报）。手动用的调试开关（--notice、--launcher…）和 KITTY_PROBE_PROFILE 本身照常有托盘
// （HANDTEST 300 要看探针档的托盘提示）。哪些算自检见 Core 的 AutomatedRunRules。
using KittyTools.Core;

namespace KittyTools;

internal static class AutomatedRun
{
    /// <summary>这个进程是不是自动跑的自检（命令行开关或探针环境变量）。</summary>
    public static bool IsActive { get; } = AutomatedRunRules.IsAutomated(
        Environment.GetCommandLineArgs(),
        Environment.GetEnvironmentVariable);
}
