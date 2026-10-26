// 进程级路径和名字。Debug / Release 的数据目录、互斥量、托盘 Run 值全部分开，
// 可以同时装、同时跑（热键会互相占用，后启动的那个标红）。
namespace KittyTools.Infrastructure;

internal static class Paths
{
#if DEBUG
    // 调试构建可以用 KITTY_DEV_SUFFIX 另开一套数据 / 互斥量 / 托盘名，方便同时跑多个自检
    // （Release 永远用下面固定的那套，不受影响）。
    private static readonly string Suffix =
        Environment.GetEnvironmentVariable("KITTY_DEV_SUFFIX") is { Length: > 0 } value ? "." + value : string.Empty;

    public static string ProductName => "Kitty Tools Dev" + Suffix;

    public static string DataFolderName => "KittyTools.Dev" + Suffix;

    public static string MutexName => @"Local\KittyTools.Dev" + Suffix;

    public static string InstancePipeName => "KittyTools.Dev.Instance" + Suffix;

    public static string RunValueName => "KittyTools.Dev" + Suffix;

    public static string CredentialPrefix => "KittyTools.Dev/" + Suffix;
#else
    // 自检（内存探针、冷启动这类要在 Release AOT 下量的）用的独立一套：KITTY_PROBE_PROFILE=<字母数字> 时数据目录、
    // 互斥量、托盘名、凭据前缀都换成「.Probe.<名字>」，不碰真实数据，也不和正在用的那个抢单实例（REVIEW R27）。
    // 正常运行不设这个变量，永远是下面固定的那套。
    private static readonly string Suffix =
        Environment.GetEnvironmentVariable("KITTY_PROBE_PROFILE") is { Length: > 0 and <= 32 } value &&
        value.All(char.IsAsciiLetterOrDigit)
            ? ".Probe." + value
            : string.Empty;

    public static string ProductName => "Kitty Tools" + Suffix;

    public static string DataFolderName => "KittyTools" + Suffix;

    public static string MutexName => @"Local\KittyTools" + Suffix;

    public static string InstancePipeName => "KittyTools.Instance" + Suffix;

    public static string RunValueName => "KittyTools" + Suffix;

    public static string CredentialPrefix => "KittyTools/" + Suffix;
#endif

    /// <summary>自检那一套（Debug 版、或 Release 的探针档）：才认 --clipboard-paused 这类自检开关。</summary>
#if DEBUG
    public static bool IsTestProfile => true;
#else
    public static bool IsTestProfile => Suffix.Length > 0;
#endif

    public static string DataDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), DataFolderName);

    public static string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    public static string LogsDirectory => Path.Combine(DataDirectory, "logs");

    public static string ImagesDirectory => Path.Combine(DataDirectory, "images");

    public static string ImagesFile(long id) => Path.Combine(ImagesDirectory, $"{id}.png");

    public static string DatabaseFile => Path.Combine(DataDirectory, "kitty.sqlite3");

    /// <summary>自动更新的下载目录（第二版 §5）。</summary>
    public static string UpdatesDirectory => Path.Combine(DataDirectory, "updates");

    public static string ExecutablePath => Environment.ProcessPath ?? string.Empty;
}
