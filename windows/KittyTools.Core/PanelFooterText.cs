// 剪贴板 / 启动器底栏的文案（PLAN-v7 §3.1 §3.2，纯函数 + 单测）：左边的状态、右边主动作的动词。
// 动词跟着 LauncherModel.Execute 的分支走：改了哪种结果 Enter 做什么，这里一起改。
namespace KittyTools.Core;

/// <summary>底栏主动作：动词 + 是否危险色（上膛的不可撤销命令）。</summary>
public readonly record struct FooterVerb(string Text, bool Danger);

public static class PanelFooterText
{
    /// <summary>按住 Shift 时剪贴板底栏左边换成这一句。</summary>
    public const string ShiftHint = "Shift+Enter 粘贴为纯文本";

    /// <summary>打开「默认粘贴为纯文本」后 Shift+Enter 是保留格式（mac 体检 A5）。</summary>
    public const string ShiftHintRich = "Shift+Enter 保留格式粘贴";

    /// <summary>剪贴板底栏左边：「N 条」，暂停记录时前面加「⏸ 已暂停记录 ·」。</summary>
    public static string ClipStatus(int count, bool paused)
        => paused ? $"⏸ 已暂停记录 · {count} 条" : $"{count} 条";

    /// <summary>多选时左边的字。</summary>
    public static string ClipSelected(int count) => $"已选 {count} 条";

    /// <summary>启动器的种类名：行尾和底栏左边是同一个字（照 mac kindTitle）。文件按扩展名（文件夹写「文件夹」）。</summary>
    public static string LauncherKindName(LauncherKind kind, string target) => kind switch
    {
        LauncherKind.App => "应用",
        LauncherKind.Setting => "设置",
        LauncherKind.Command => "系统",
        LauncherKind.Action => "命令",
        LauncherKind.Url => "网址",
        LauncherKind.Path => LauncherText.FileKindTitle(target, target.EndsWith('\\')),
        LauncherKind.Search => "搜索",
        LauncherKind.Calculation => "计算",
        LauncherKind.Clip => "剪贴板",
        LauncherKind.Translate => "翻译",
        LauncherKind.Process => "进程",
        LauncherKind.Ip => "网络",
        LauncherKind.Prompt when target.StartsWith("system-", StringComparison.Ordinal) => "系统",
        LauncherKind.Prompt when target == "translate-fy" => "翻译",
        LauncherKind.Prompt => "搜索",
        _ => string.Empty,
    };

    /// <summary>
    /// 启动器底栏「动词 ↩」（照 mac primaryAction 的名字）：应用 / 文件「打开」、命令「运行」、网址「打开网址」、计算「粘贴」…；
    /// 上膛的不可撤销命令换成「确认 + 原来的名字」（系统命令写它的标题：「确认清空回收站」）、危险色。
    /// 带对象模式（quit / kill / port…）的名字由 LauncherModel 按模式给。
    /// </summary>
    public static FooterVerb LauncherVerb(LauncherKind kind, string target, bool armed, string title = "")
    {
        var verb = kind switch
        {
            LauncherKind.Action or LauncherKind.Command => "运行",
            LauncherKind.Url => "打开网址",
            LauncherKind.Search => "搜索",
            LauncherKind.Calculation or LauncherKind.Ip => "粘贴",
            LauncherKind.Clip => target.Length == 0 ? "打开" : "搜索",
            LauncherKind.Translate => "翻译",
            LauncherKind.Prompt => "补全关键词",
            LauncherKind.Process => "结束",
            _ => "打开",
        };
        if (armed)
        {
            return new FooterVerb(kind == LauncherKind.Command && title.Length > 0 ? "确认" + title : "确认" + verb, Danger: true);
        }

        return new FooterVerb(verb, Danger: false);
    }
}
