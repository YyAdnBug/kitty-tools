// 进程入口。第 0 批是验证样机：没有主窗口，启动后只建隐藏窗口、托盘图标和热键，
// 由 Probe 运行时按命令行参数 / 命名管道驱动各项实测。第 1 批会把它换成正式的单实例入口。
using Microsoft.UI.Xaml;

namespace KittyTools;

public partial class App : Application
{
    private ProbeRuntime? _runtime;

    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash("appdomain", e.ExceptionObject as Exception);
        UnhandledException += (_, e) => LogCrash("xaml", e.Exception);
        try
        {
            InitializeComponent();
        }
        catch (Exception ex)
        {
            LogCrash("initialize", ex);
            throw;
        }
    }

    private static void LogCrash(string stage, Exception? ex)
    {
        try
        {
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-crash.txt");
            File.AppendAllText(path, $"{DateTime.Now:O} {stage}: {ex}\n\n");
        }
        catch
        {
            // 崩溃日志写不出来就算了，别再抛一次。
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _runtime = ProbeRuntime.Start();
    }
}
