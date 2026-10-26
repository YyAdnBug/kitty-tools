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
        UnhandledException += (_, e) =>
        {
#if DEBUG
            // 原生层抛上来的只有「未指定的错误」，e.Message 里常有真正的原因（找不到的资源键之类）。
            Log.Warn("xaml.unhandled " + e.Message);
#endif
            CrashLog.Record("xaml", e.Exception);
        };
#if DEBUG
        DebugSettings.XamlResourceReferenceFailed += (_, e) => Log.Warn("xaml.resource-failed " + e.Message);
#endif
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
            var commandLine = Environment.GetCommandLineArgs();
            if (HeightAnimationProbe.IsRequested(commandLine))
            {
                // R12 的高度动画逐帧自检：只开自己的无边框窗口，跑完写报告就退。
                var directory = HeightAnimationProbe.DirectoryFrom(commandLine);
                if (directory is not null)
                {
                    _ = HeightAnimationProbe.RunAsync(directory);
                    return;
                }
            }

            _runtime = ShellRuntime.Start();
            if (UiSnapshotProbe.IsRequested(commandLine))
            {
                // PLAN-v7 §2.4：离屏出图，跑完就退；不影响正常启动。
                var directory = UiSnapshotProbe.DirectoryFrom(commandLine);
                if (directory is not null)
                {
                    _ = UiSnapshotProbe.RunAsync(directory);
                    return;
                }
            }
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
