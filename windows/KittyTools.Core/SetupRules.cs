// 安装程序（Inno Setup 7，PLAN-setup-inno）和 App 对得上的那几个名字和小规矩（纯函数 + 单测）：
// 「设置 › 应用」里的登记键、开机启动值、快捷方式、凭据前缀、互斥量、管道、数据目录、卸载清理的日志，
// 正式版一套、自检（KITTY_PROBE_PROFILE / ISCC /DTestKey）一套；installer/KittyTools.iss 里的 #define 要和这里一一对应。
// 路径一律按 Windows 的写法处理（反斜杠、不分大小写），不依赖运行平台的 Path，所以在 Mac 上也能单测。
namespace KittyTools.Core;

public sealed record SetupNames(
    string UninstallKey,
    string RunValue,
    string ShortcutFile,
    string CredentialPrefix,
    string MutexName,
    string PipeName,
    string DataFolder,
    string LogFile,
    string? ProbeProfile);

public static class SetupRules
{
    /// <summary>Inno 的 AppId（PLAN-setup-inno I2）：「设置 › 应用」里的登记、更新时找原来装在哪都靠它，永远不改。</summary>
    public const string AppId = "{FF0E2BF7-9B90-4EB0-9C08-818112ACEC15}";

    /// <summary>Inno 的卸载程序，和 KittyTools.exe 在同一个文件夹。</summary>
    public const string UninstallerName = "unins000.exe";

    public const string UninstallRoot = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";

    /// <summary>测试名：1–32 个 ASCII 字母或数字（和 App 的 KITTY_PROBE_PROFILE 同一个规矩）。</summary>
    public static bool IsValidTestKey(string key) => key.Length is >= 1 and <= 32 && key.All(char.IsAsciiLetterOrDigit);

    /// <summary>testKey 为 null 或空是正式版的名字；不合规的测试名直接抛，免得退回正式名去碰用户真实的注册表。</summary>
    public static SetupNames NamesFor(string? testKey)
    {
        if (string.IsNullOrEmpty(testKey))
        {
            return new SetupNames(
                AppId + "_is1", "KittyTools", "Kitty Tools.lnk", "KittyTools/", @"Local\KittyTools",
                "KittyTools.Instance", "KittyTools", "KittyTools-uninstall.log", null);
        }

        if (!IsValidTestKey(testKey))
        {
            throw new ArgumentException("测试名只能是 1–32 个字母或数字", nameof(testKey));
        }

        var suffix = ".Probe." + testKey;
        return new SetupNames(
            "KittyTools.Test." + testKey + "_is1",
            "KittyTools" + suffix,
            $"Kitty Tools.Test.{testKey}.lnk",
            "KittyTools/" + suffix,
            @"Local\KittyTools" + suffix,
            "KittyTools.Instance" + suffix,
            "KittyTools" + suffix,
            $"KittyTools{suffix}-uninstall.log",
            testKey);
    }

    /// <summary>反斜杠、去掉末尾的分隔符（根目录 C:\ 保留）。不解析 . 和 ..：调用方先 GetFullPath。</summary>
    public static string Normalize(string path)
    {
        var text = path.Trim().Replace('/', '\\');
        while (text.Length > 3 && text.EndsWith('\\'))
        {
            text = text[..^1];
        }

        return text.Length == 2 && text[1] == ':' ? text + "\\" : text;
    }

    /// <summary>同一个文件夹（不分大小写，末尾有没有 \ 都算；Inno 写的 InstallLocation 末尾带 \）。</summary>
    public static bool SamePath(string a, string b) => string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>文件夹里所有文件的大小，单位 KB（向上取整）；读不到的文件跳过。</summary>
    public static long DirectorySizeKb(string dir)
    {
        long bytes = 0;
        try
        {
            foreach (var file in new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories))
            {
                bytes += file.Length;
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        return (bytes + 1023) / 1024;
    }
}
