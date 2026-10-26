// Kitty Tools 安装程序的入口（PLAN-setup）。同一个 exe 三种用法：
//   --pack <本体> <zip> <输出>                        打包：build-release.ps1 把 release 的 zip 接在本体后面
//   自己带载荷（KittyTools-x.y.z-windows-*-setup.exe）  安装；--quiet --dir <路径> [--no-autostart] [--no-launch] 不弹界面
//   不带载荷、文件名是 Uninstall.exe                    卸载；--quiet [--with-data] 不弹界面
// 退出码见 ExitCodes。KITTY_SETUP_TEST_KEY=<字母数字> 时注册表登记、开机启动值、快捷方式、凭据前缀、互斥量、数据目录
// 全换成测试用的名字（SetupRules.NamesFor）；名字不合规就直接退出，不退回正式名。
// 日志在 %TEMP%\KittyTools-setup.log（测试名下另一个文件），只记步骤和错误类型。
using KittyTools.Core;
using Windows.Win32;
using Windows.Win32.System.Com;

namespace KittyTools.Setup;

internal static class ExitCodes
{
    public const int Ok = 0;
    public const int Error = 1;
    public const int BadPackage = 2;
    public const int AppRunning = 3;
    public const int BadDirectory = 4;
    public const int Cancelled = 5;
}

/// <summary>给用户看的错误（文案已经写好），其他异常只进日志。</summary>
internal sealed class SetupException(string message) : Exception(message);

internal sealed class SetupArgs
{
    public bool Quiet { get; private set; }

    public string? Dir { get; private set; }

    public bool NoAutostart { get; private set; }

    public bool NoLaunch { get; private set; }

    public bool WithData { get; private set; }

    /// <summary>卸载程序从 %TEMP% 那份接着跑时：原来的安装目录。</summary>
    public string? From { get; private set; }

    /// <summary>卸载程序从 %TEMP% 那份接着跑时：等安装目录里那份（这个进程号）退出，再删安装目录。</summary>
    public int? WaitPid { get; private set; }

    public string[]? Pack { get; private set; }

    public static SetupArgs Parse(string[] args)
    {
        var result = new SetupArgs();
        for (var index = 0; index < args.Length; index++)
        {
            string? Next() => index + 1 < args.Length ? args[++index] : null;
            switch (args[index].ToLowerInvariant())
            {
                case "--quiet":
                    result.Quiet = true;
                    break;
                case "--dir":
                    result.Dir = Next();
                    break;
                case "--no-autostart":
                    result.NoAutostart = true;
                    break;
                case "--no-launch":
                    result.NoLaunch = true;
                    break;
                case "--with-data":
                    result.WithData = true;
                    break;
                case "--from":
                    result.From = Next();
                    break;
                case "--wait-pid":
                    result.WaitPid = int.TryParse(Next(), out var pid) ? pid : null;
                    break;
                case "--pack":
                    result.Pack = args[(index + 1)..];
                    index = args.Length;
                    break;
            }
        }

        return result;
    }
}

internal static class SetupLog
{
    private static readonly Lock Gate = new();
    private static string? _path;

    public static string? Path => _path;

    public static void Open(string fileName) => _path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), fileName);

    public static void Write(string line)
    {
        if (_path is null)
        {
            return;
        }

        lock (Gate)
        {
            try
            {
                File.AppendAllText(_path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.ProcessId}] {line}\n");
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // 日志写不进去不影响安装。
            }
        }
    }
}

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var options = SetupArgs.Parse(args);
        if (options.Pack is not null)
        {
            return Pack(options.Pack);
        }

        SetupNames names;
        try
        {
            names = SetupRules.NamesFor(Environment.GetEnvironmentVariable(SetupRules.TestKeyVariable));
        }
        catch (ArgumentException)
        {
            return ExitCodes.Error;
        }

        SetupLog.Open(names.LogFile);
        SetupLog.Write($"setup.start args={string.Join(' ', args)}");
        PInvoke.CoInitializeEx(null, COINIT.COINIT_APARTMENTTHREADED);
        try
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("ProcessPath 为空");
            SetupTrailer? trailer;
            using (var file = File.OpenRead(exe))
            {
                trailer = SetupPayload.ReadTrailer(file);
            }

            if (trailer is not null)
            {
                return Installer.Run(exe, trailer, options, names);
            }

            if (string.Equals(System.IO.Path.GetFileName(exe), SetupRules.UninstallerName, StringComparison.OrdinalIgnoreCase))
            {
                return Uninstaller.Run(exe, options, names);
            }

            SetupLog.Write("setup.no-payload");
            if (!options.Quiet)
            {
                SetupUi.ShowError("安装包不完整", "请重新下载 Kitty Tools 的安装包。");
            }

            return ExitCodes.BadPackage;
        }
        catch (Exception ex)
        {
            SetupLog.Write($"setup.fatal {ex}");
            if (!options.Quiet)
            {
                SetupUi.ShowError("出错了", $"没能完成。详情在日志里：{SetupLog.Path}");
            }

            return ExitCodes.Error;
        }
    }

    /// <summary>--pack &lt;本体&gt; &lt;zip&gt; &lt;输出&gt;：没有窗口也没有控制台，结果只看退出码（失败原因写进日志）。</summary>
    private static int Pack(string[] paths)
    {
        SetupLog.Open(SetupRules.NamesFor(null).LogFile);
        if (paths.Length != 3)
        {
            SetupLog.Write("pack.usage");
            return ExitCodes.Error;
        }

        try
        {
            SetupPayload.Pack(paths[0], paths[1], paths[2]);
            SetupLog.Write("pack.ok");
            return ExitCodes.Ok;
        }
        catch (Exception ex)
        {
            SetupLog.Write($"pack.failed {ex.GetType().Name} {ex.Message}");
            return ExitCodes.Error;
        }
    }
}
