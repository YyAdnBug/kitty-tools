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
        // 自检档里 KITTY_APP_THEME=dark / light 把 App 的主题定死，当作系统是深色 / 浅色（不用去改系统设置）：
        // WinUI 自己的主题画刷按它解，外观设置和系统不一致时的颜色问题要靠它看（HANDTEST 805–807）。
        if (Paths.IsTestProfile && Environment.GetEnvironmentVariable("KITTY_APP_THEME") is { } appTheme)
        {
            if (appTheme == "dark")
            {
                RequestedTheme = ApplicationTheme.Dark;
            }
            else if (appTheme == "light")
            {
                RequestedTheme = ApplicationTheme.Light;
            }
        }

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

            if (NoticeAnimationProbe.IsRequested(commandLine))
            {
                // PLAN-v7 第 3 批：轻提示长出 / 换内容 / 抖 / 缩回的逐帧自检，只抓自己的提示窗口，跑完就退。
                var directory = NoticeAnimationProbe.DirectoryFrom(commandLine);
                if (directory is not null)
                {
                    _ = NoticeAnimationProbe.RunAsync(directory);
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
            if (NotesUiProbe.IsRequested(commandLine) && NotesUiProbe.DirectoryFrom(commandLine) is { } notesProbe)
            {
                // PLAN-v13 第 5–7 批：便签各扇窗的截图自检（只在测试档），跑完就退。
                _ = NotesUiProbe.RunAsync(notesProbe);
                return;
            }

            if (NoteEditorProbe.IsRequested(commandLine) && NoteEditorProbe.DirectoryFrom(commandLine) is { } noteProbe)
            {
                // PLAN-v13 第 4 批：便签正文编辑器那 7 条 RichEdit 行为的自检（只在测试档），跑完就退。
                _ = NoteEditorProbe.RunAsync(noteProbe);
                return;
            }

            if (CopyFileProbe.IsRequested(commandLine) && CopyFileProbe.DirectoryFrom(commandLine) is { } copyProbe)
            {
                // PLAN-v15：截图拷贝为文件的自检（只在测试档），跑完就退。
                _ = CopyFileProbe.RunAsync(copyProbe);
                return;
            }

            if (PanelResizeProbe.IsRequested(commandLine) && PanelResizeProbe.DirectoryFrom(commandLine) is { } resizeProbe)
            {
                // PLAN-v16 第 1 批：拖边改大小的自检（只在测试档），跑完就退。
                _ = PanelResizeProbe.RunAsync(resizeProbe);
                return;
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
