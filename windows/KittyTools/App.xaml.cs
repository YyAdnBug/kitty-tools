// 第 1 批的壳：单实例、设置、托盘、热键、浮层和轻提示。各模块后续接上。
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;

namespace KittyTools;

public partial class App : Application
{
    private ShellRuntime? _runtime;

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
            System.IO.File.AppendAllText(
                System.IO.Path.Combine(System.IO.Path.GetTempPath(), "kitty-crash.txt"),
                $"{DateTime.Now:O} {stage}: {ex}\n\n");
        }
        catch
        {
            // 崩溃日志写不出来就算了。
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Log.Initialize();
            SettingsService.Load();
            Theme.ApplyAccent();
            _runtime = ShellRuntime.Start();
        }
        catch (Exception ex)
        {
            LogCrash("launched", ex);
            throw;
        }
    }
}
