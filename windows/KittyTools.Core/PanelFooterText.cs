// 剪贴板 / 启动器底栏的文案（PLAN-v7 §3.1 §3.2，纯函数 + 单测）：左边的状态、右边主动作的动词。
// 动词跟着 LauncherModel.Execute 的分支走：改了哪种结果 Enter 做什么，这里一起改。
namespace KittyTools.Core;

/// <summary>底栏主动作：动词 + 是否危险色（上膛的不可撤销命令）。</summary>
public readonly record struct FooterVerb(string Text, bool Danger);

public static class PanelFooterText
{
    /// <summary>按住 Shift 时剪贴板底栏左边换成这一句。</summary>
    public const string ShiftHint = "Shift+Enter 粘贴为纯文本";

    /// <summary>剪贴板底栏左边：「N 条」，暂停记录时前面加「⏸ 已暂停记录 ·」。</summary>
    public static string ClipStatus(int count, bool paused)
        => paused ? $"⏸ 已暂停记录 · {count} 条" : $"{count} 条";

    /// <summary>多选时左边的字。</summary>
    public static string ClipSelected(int count) => $"已选 {count} 条";

    /// <summary>启动器的种类名：行尾和底栏左边是同一个字。</summary>
    public static string LauncherKindName(LauncherKind kind, string target) => kind switch
    {
        LauncherKind.App => "应用",
        LauncherKind.Setting => "设置",
        LauncherKind.Command => "系统",
        LauncherKind.Action when target.StartsWith("kill:", StringComparison.Ordinal) => "进程",
        LauncherKind.Action when target.StartsWith("port:", StringComparison.Ordinal) => "端口",
        LauncherKind.Action => "动作",
        LauncherKind.Url => "网址",
        LauncherKind.Path => "路径",
        LauncherKind.Search => "搜索",
        LauncherKind.Calculation => "计算",
        _ => string.Empty,
    };

    /// <summary>启动器底栏「动词 ↩」：上膛的危险命令一律「确认…」+ 危险色（mac 的两档用法）。</summary>
    public static FooterVerb LauncherVerb(LauncherKind kind, string target, bool armed)
    {
        if (armed)
        {
            return new FooterVerb("确认…", Danger: true);
        }

        return new FooterVerb(kind switch
        {
            LauncherKind.Command => "运行",
            LauncherKind.Action when target.StartsWith("cb:", StringComparison.Ordinal) => "搜索",
            LauncherKind.Action when target.StartsWith("fy:", StringComparison.Ordinal) => "翻译",
            LauncherKind.Action when target.StartsWith("kill:", StringComparison.Ordinal) => "结束",
            LauncherKind.Action when target.StartsWith("port:", StringComparison.Ordinal) => "复制地址",
            LauncherKind.Action => "运行",
            LauncherKind.Search => "搜索",
            LauncherKind.Calculation => "粘贴",
            _ => "打开",
        }, Danger: false);
    }
}
