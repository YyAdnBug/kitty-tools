// 第 1 批的壳：单实例、设置、托盘、热键、浮层和轻提示。各模块后续接上。
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;

namespace KittyTools;

public partial class App : Application
{
    private ShellRuntime? _runtime;

    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Record("appdomain", e.ExceptionObject as Exception);
        UnhandledException += (_, e) => CrashLog.Record("xaml", e.Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => CrashLog.Record("task", e.Exception);
        try
        {
            InitializeComponent();
        }
        catch (Exception ex)
        {
            CrashLog.Record("initialize", ex);
            throw;
        }
    }

    private static void LogCrash(string stage, Exception? ex) => CrashLog.Record(stage, ex);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Log.Initialize();
            SettingsService.Load();
            CrashLog.CheckOnStartup();
            Theme.ApplyAccent();
            Theme.WatchSystemAccent();
            XamlProbe.Run();
            _runtime = ShellRuntime.Start();
            if (Environment.GetCommandLineArgs().Contains("--crash-test", StringComparer.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("--crash-test");
            }
        }
        catch (Exception ex)
        {
            LogCrash("launched", ex);
            throw;
        }
    }
}
