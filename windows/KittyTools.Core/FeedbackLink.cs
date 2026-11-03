// 关于页「反馈问题」（PLAN-v11 F10，mac X14）：打开 GitHub 上新建问题的页面，只预填版本号、架构和系统版本，
// 不带任何用户数据（剪贴板、原文、路径、日志都不带）。纯函数，配单测。
namespace KittyTools.Core;

public static class FeedbackLink
{
    public const string NewIssue = "https://github.com/YyAdnBug/kitty-tools/issues/new";

    /// <summary>新建问题的地址：标题「[Windows 0.1.1] 」，正文是版本、系统和两行要填的。</summary>
    public static string Url(string appVersion, string architecture, string osName)
    {
        var title = $"[Windows {appVersion}] ";
        var body = $"版本：Kitty Tools {appVersion}（Windows {architecture}）\n系统：{osName}\n\n遇到了什么：\n\n怎么能重现：\n";
        return $"{NewIssue}?title={Uri.EscapeDataString(title)}&body={Uri.EscapeDataString(body)}";
    }

    /// <summary>系统的名字：「Windows 11 10.0.22631」（10.0 的内部版本号 22000 起是 Windows 11）。</summary>
    public static string OsName(Version version)
        => $"Windows {(version.Major == 10 && version.Build >= 22000 ? "11" : "10")} {version.Major}.{version.Minor}.{version.Build}";
}
