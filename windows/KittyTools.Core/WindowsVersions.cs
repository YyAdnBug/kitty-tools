// 支持哪些 Windows、哪些效果要看系统版本（PLAN-v27 §2，W1–W3：Windows 10 2004 起「尽力支持」；纯函数，配单测）。
// 版本号是 Environment.OSVersion（.NET 5 起给的是真版本，不受清单影响）：Major 10，Build 是内部版本号。
namespace KittyTools.Core;

public static class WindowsVersions
{
    /// <summary>最低支持：Windows 10 2004（19041）——自家浮窗不进截图（WDA_EXCLUDEFROMCAPTURE）、截图不录鼠标都从它起；2004 到 22H2 是同一套系统。</summary>
    public const int MinimumBuild = 19041;

    /// <summary>Windows 11 从 22000 起（DWM 圆角、云母、Segoe Fluent Icons）。</summary>
    public const int Windows11Build = 22000;

    /// <summary>截图 / 录屏能关掉系统画的黄框（GraphicsCaptureSession.IsBorderRequired）：20348 起，Win10 上没有。</summary>
    public const int CaptureBorderToggleBuild = 20348;

    /// <summary>太老的系统启动时说的话（安装包里 Inno 用它自己的那句）。</summary>
    public const string TooOldMessage = "Kitty Tools 需要 Windows 10 2004 或更新的系统（推荐 Windows 11）。\n\n在 设置 › Windows 更新 里更新系统后再打开。";

    public static bool IsSupported(Version version) => version.Major > 10 || (version.Major == 10 && version.Build >= MinimumBuild);

    public static bool IsWindows11(Version version) => version.Major > 10 || (version.Major == 10 && version.Build >= Windows11Build);

    /// <summary>
    /// Win11 才自带的字体（Segoe UI Variable 各款、Cascadia Mono）在 Win10 上换成 Win10 自带的（PLAN-v27 W3）。
    /// XAML 的 FontFamily 能写「A, B」自己退；Win2D（DirectWrite）和便签的 RichEdit 只认一个名字、找不到就随便换，这几处用它。
    /// </summary>
    public static string FontFor(Version version, string windows11Face)
        => IsWindows11(version) ? windows11Face
            : windows11Face.StartsWith("Cascadia", StringComparison.OrdinalIgnoreCase) ? "Consolas" : "Segoe UI";

    /// <summary>同上，按这台电脑的系统。</summary>
    public static string FontFor(string windows11Face) => FontFor(Environment.OSVersion.Version, windows11Face);

    /// <summary>录屏、抓窗口时屏幕 / 窗口外面会有一圈系统画的黄框（录出来的视频和图里没有）。</summary>
    public static bool ShowsCaptureBorder(Version version) => version.Major == 10 && version.Build < CaptureBorderToggleBuild;
}
