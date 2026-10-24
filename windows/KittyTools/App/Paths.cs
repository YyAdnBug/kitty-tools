// 进程级路径和名字。Debug / Release 的数据目录、互斥量、托盘 Run 值全部分开，
// 可以同时装、同时跑（热键会互相占用，后启动的那个标红）。
namespace KittyTools.Infrastructure;

internal static class Paths
{
#if DEBUG
    public const string ProductName = "Kitty Tools Dev";
    public const string DataFolderName = "KittyTools.Dev";
    public const string MutexName = @"Local\KittyTools.Dev";
    public const string InstancePipeName = "KittyTools.Dev.Instance";
    public const string RunValueName = "KittyTools.Dev";
    public const string CredentialPrefix = "KittyTools.Dev/";
#else
    public const string ProductName = "Kitty Tools";
    public const string DataFolderName = "KittyTools";
    public const string MutexName = @"Local\KittyTools";
    public const string InstancePipeName = "KittyTools.Instance";
    public const string RunValueName = "KittyTools";
    public const string CredentialPrefix = "KittyTools/";
#endif

    public static string DataDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), DataFolderName);

    public static string SettingsFile => Path.Combine(DataDirectory, "settings.json");

    public static string LogsDirectory => Path.Combine(DataDirectory, "logs");

    public static string ImagesDirectory => Path.Combine(DataDirectory, "images");

    public static string ImagesFile(long id) => Path.Combine(ImagesDirectory, $"{id}.png");

    public static string DatabaseFile => Path.Combine(DataDirectory, "kitty.sqlite3");

    public static string ExecutablePath => Environment.ProcessPath ?? string.Empty;
}
