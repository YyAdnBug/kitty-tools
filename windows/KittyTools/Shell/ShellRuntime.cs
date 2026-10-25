// 壳的运行时：隐藏窗口、托盘、热键、浮层、轻提示、设置窗和单实例转发。
// 第 1 批只把壳做齐；各模块的入口先给轻提示，面板内容是占位。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Win32;

namespace KittyTools;

internal sealed class ShellRuntime
{
    private Window? _keeper;
    private SettingsWindow? _settingsWindow;
    private string _hotKeySignature = string.Empty;
    private bool? _autoCheck;

    public static ShellRuntime? Instance { get; private set; }

    public HotKeyManager HotKeys { get; } = new();

    public ClipboardService? Clipboard { get; private set; }

    public static ShellRuntime Start()
    {
        var runtime = new ShellRuntime();
        Instance = runtime;
        runtime.Initialize();
        return runtime;
    }

    private void Initialize()
    {
        // WinUI 3 在最后一个 XAML 窗口关闭时会结束进程；常驻托盘要留一个永不关闭的
        // 隐藏窗口。它不激活、不进任务栏和 Alt+Tab，只负责把 XAML 生命周期撑住。
        _keeper = new Window { Title = Paths.ProductName };
        _keeper.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(-32000, -32000, 1, 1));
        _keeper.AppWindow.IsShownInSwitchers = false;

        if (!HiddenWindow.Create())
        {
            Application.Current.Exit();
            return;
        }

        try
        {
            // 打不开时先问用户：用备份 / 重新开始 / 退出（第三版 §2.1）。
            var database = Recovery.OpenWithRecovery();
            if (database is null)
            {
                Application.Current.Exit();
                return;
            }

            Clipboard = ClipboardService.Start(database, new ImageStore(Paths.ImagesDirectory));
            Clipboard.Suspended = !Features.IsOn(Feature.Clipboard);
            // 翻译历史和生词本用同一个库（第三版 §3.1）。
            TranslationHistory.Start(database);
            LauncherFavorites.Start(database);
            // 同步（第五版）：本机编号、账本和执行层。
            var syncDevice = SyncDevice.Start(database);
            var syncLedger = SyncLedger.Start(database);
            var syncer = Syncer.Start(syncDevice, syncLedger);
            if (syncer.Enabled)
            {
                syncer.StartTimer(DispatcherQueue.GetForCurrentThread()!);
                _ = syncer.RoundAsync();
            }
            // 图片的后台识字排队（第三版 §5）。
            OcrQueue.Start(DispatcherQueue.GetForCurrentThread()!);
        }
        catch (Exception ex)
        {
            Log.Error("clipboard.start-failed", ex);
            NoticeHost.Show("剪贴板历史用不了", "数据库打不开，其它功能不受影响", NoticeTone.Error);
        }

        // 每日备份：启动时、锁屏 / 解锁、睡眠唤醒各看一眼今天备过没有（不另加定时器）。
        ScheduleBackup();

        TranslateServiceStore.Start(SettingsService.Current);
        TranslateHost.Initialize();
        if (Clipboard is not null)
        {
            LauncherUsageStore.Start(Clipboard.Database);
        }

        AppCatalog.Start();
        LauncherModel.Start();

        HiddenWindow.Message += OnHiddenMessage;
        Tray.Add();
        HotKeys.Pressed += OnHotKey;
        RegisterHotKeys();
        SettingsService.Changed += OnSettingsChanged;
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        UpdateService.Initialize(dispatcher!);
        _autoCheck = SettingsService.Current.AutoCheckUpdates;
        UpdateService.Configure(SettingsService.Current.AutoCheckUpdates);
        SingleInstance.StartServer(() =>
            dispatcher?.TryEnqueue(() => ShowSettings(welcome: false)));

        Log.Info("shell.ready");
        Theme.VerifyThemeResources();

        // 上次录到一半的文件（第四版闪退恢复）。
        RecordingHost.RecoverOnStartup();

        // REVIEW R11：截图卡片拖出去的临时 PNG 启动时清空（用时生成，不在每次拖出后删）。
        try
        {
            var temp = Path.Combine(Path.GetTempPath(), "kitty-shots");
            if (Directory.Exists(temp))
            {
                foreach (var file in Directory.EnumerateFiles(temp, "*.png"))
                {
                    File.Delete(file);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"screenshot.temp-cleanup-failed {ex.GetType().Name}");
        }

        // 启动 3 秒后预建浮层 / 翻译浮窗：第一次按热键不用再建 XAML 树（第二版 §4.2）。
        DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
        {
            await Task.Delay(3000);
            if (Features.IsOn(Feature.Clipboard) || Features.IsOn(Feature.Launcher))
            {
                OverlayHost.Prewarm();
            }

            if (Features.IsOn(Feature.Translate))
            {
                TranslateHost.Prewarm();
            }
        });

        if (MemoryProbe.Requested)
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(MemoryProbe.Run);
        }
#if DEBUG
        if (Environment.GetCommandLineArgs().Contains("--tray-menu", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(Tray.ShowMenu);
        }

        // 调试用：看轻提示胶囊的样子（截图 / 手测用，不影响正常启动）。
        if (Environment.GetCommandLineArgs().Contains("--notice", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(
                () => NoticeHost.Show("已复制到剪贴板", "3 条记录已合并", NoticeTone.Normal));
        }

        if (Environment.GetCommandLineArgs().Contains("--notice-error", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(
                () => NoticeHost.Show("更新失败", "旧版本还能正常用，详情看日志", NoticeTone.Error));
        }

        // 调试用：跳过热键直接打开剪贴板面板（热键被别的实例占着时也能看界面）。
        if (Environment.GetCommandLineArgs().Contains("--clipboard-panel", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(OpenClipboard);
        }

        // 调试用：直接走「截取上次区域」（先手动把 ScreenshotLast* 写进设置）。
        if (Environment.GetCommandLineArgs().Contains("--screenshot-last", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(ScreenshotSession.StartLast);
        }

        // 调试 / 自检：把已有的录屏转成 GIF（第四版第 3 批）。
        var gifArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--gif=", StringComparison.OrdinalIgnoreCase));
        if (gifArg is not null)
        {
            var path = gifArg["--gif=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => _ = GifService.ConvertAsync(path));
        }

        // 调试 / 自检：压缩一个已有的录屏（第四版第 3 批）。
        var compressArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--compress=", StringComparison.OrdinalIgnoreCase));
        if (compressArg is not null)
        {
            var path = compressArg["--compress=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => _ = CompressionService.CompressAsync(path));
        }

        // 调试 / 自检：录 4 秒整屏，报告写进给定目录（第四版第 1 批的验收用）。
        var probeArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--record-probe=", StringComparison.OrdinalIgnoreCase));
        if (probeArg is not null)
        {
            var folder = probeArg["--record-probe=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => _ = RecordingProbe.RunAsync(folder));
        }

#if DEBUG
        // 调试用：直接开录屏的选区遮罩（截图 / 手测 Alt+R 的界面）。
        if (Environment.GetCommandLineArgs().Contains("--record-select", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(
                () => ScreenshotSession.Start(ScreenshotMode.Record));
        }

        // 调试：读一个音频 / 视频文件的时长（MediaPlayer），验证录音 / 压缩产物能解码。
        var checkArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--media-check=", StringComparison.OrdinalIgnoreCase));
        if (checkArg is not null)
        {
            var path = checkArg["--media-check=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
            {
                try
                {
                    using var player = new Windows.Media.Playback.MediaPlayer
                    {
                        Source = Windows.Media.Core.MediaSource.CreateFromUri(new Uri(path)),
                    };
                    await Task.Delay(1500);
                    Log.Info($"media.check {Path.GetFileName(path)} duration={player.NaturalDuration.TotalSeconds:F2}s");
                }
                catch (Exception ex)
                {
                    Log.Warn($"media.check-failed {ex.GetType().Name}");
                }
            });
        }

        // 调试：浏览器历史 / Firefox 书签（R20）。
        if (Environment.GetCommandLineArgs().Contains("--history", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() =>
            {
                HistoryIndex.Load();
                BookmarkIndex.Load();
                Log.Info($"history.debug hits={HistoryIndex.Search("github").Count}");
            });
        }

        // 调试 / 自检：文件搜索（R17）的耗时和结果数。
        var fileSearchArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--file-search=", StringComparison.OrdinalIgnoreCase));
        if (fileSearchArg is not null)
        {
            var word = fileSearchArg["--file-search=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
            {
                var watch = System.Diagnostics.Stopwatch.StartNew();
                var hits = await FileSearch.SearchAsync(word, CancellationToken.None);
                Log.Info($"files.search-debug hits={hits.Count} ms={watch.ElapsedMilliseconds}");
            });
        }

        // 调试：打印端口表的前几行（R18）。
        if (Environment.GetCommandLineArgs().Contains("--ports", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() =>
            {
                var rows = PortTable.Read();
                Log.Info($"ports.count={rows.Count} first={string.Join(';', rows.Take(5).Select(row => $"{row.Protocol} {row.Local}:{row.Port} pid={row.Pid}"))}");
            });
        }

        // 调试用：自动录 N 秒麦克风（MediaCapture 的 M4A），手测托盘 / 文件。
        var audioUiArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--audio-rec-ui=", StringComparison.OrdinalIgnoreCase));
        if (audioUiArg is not null && int.TryParse(audioUiArg["--audio-rec-ui=".Length..], out var audioSeconds))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
            {
                AudioHost.Start();
                await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(audioSeconds, 1, 60)));
                AudioHost.Stop();
            });
        }

        // 调试用：自动录 N 秒（手测托盘 / 轻提示 / 保存目录，不用真的按热键）。
        var recordUiArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--record-ui=", StringComparison.OrdinalIgnoreCase));
        if (recordUiArg is not null && int.TryParse(recordUiArg["--record-ui=".Length..], out var seconds))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
            {
                RecordingHost.StartRegion(new PixelBounds(0, 0, 1280, 720));
                await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(seconds, 1, 60)));
                RecordingHost.Stop();
            });
        }

        // 调试用：直接录一块固定区域 N 秒（不经过遮罩 / 倒数），验区域裁剪和文件头。
        var regionArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--record-region=", StringComparison.OrdinalIgnoreCase));
        if (regionArg is not null && int.TryParse(regionArg["--record-region=".Length..], out var regionSeconds))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(async () =>
            {
                RecordingHost.StartRegion(new PixelBounds(100, 100, 900, 700));
                await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(regionSeconds, 1, 60)));
                RecordingHost.Stop();
            });
        }

        // 调试用：塞一条示例片段（截图 / 手测片段、备注和收藏夹）。
        if (Environment.GetCommandLineArgs().Contains("--seed-snippet", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() =>
            {
                ClipboardService.Instance?.Store.AddSnippet(
                    "Hello {cursor}world — {date} {time}", "示例片段（自动填日期）");
            });
        }
#endif

        // 调试用：打开面板时带一个搜索词。
        var queryArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--clipboard-query=", StringComparison.OrdinalIgnoreCase));
        if (queryArg is not null)
        {
            var query = queryArg["--clipboard-query=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => OverlayHost.SetClipboardQuery(query));
        }

        // 调试用：直接打开设置里的某一页，比如 --settings=clipboard。
        var settingsArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--settings=", StringComparison.OrdinalIgnoreCase));
        if (settingsArg is not null)
        {
            var page = settingsArg["--settings=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ShowSettings(welcome: false, page));
        }

        // 调试用：直接打开翻译浮窗，带文字时自动翻。
        if (Environment.GetCommandLineArgs().Contains("--translate", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowInput());
        }

        var translateArg = Environment.GetCommandLineArgs()
            .FirstOrDefault(arg => arg.StartsWith("--translate-text=", StringComparison.OrdinalIgnoreCase));
        if (translateArg is not null)
        {
            var text = translateArg["--translate-text=".Length..];
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowText(text));
        }

        if (Environment.GetCommandLineArgs().Contains("--selection", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => TranslateHost.ShowSelection());
        }

        if (Environment.GetCommandLineArgs().Contains("--ocr", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Ocr));
        }

        if (Environment.GetCommandLineArgs().Contains("--screenshot-translate", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Translate));
        }

        if (Environment.GetCommandLineArgs().Contains("--update-check", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => _ = UpdateService.CheckAsync(userInitiated: true));
        }
        if (Environment.GetCommandLineArgs().Contains("--screenshot", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() => ScreenshotSession.Start(ScreenshotMode.Capture));
        }

        if (Environment.GetCommandLineArgs().Contains("--launcher", StringComparer.OrdinalIgnoreCase))
        {
            var launcherQuery = Environment.GetCommandLineArgs()
                .FirstOrDefault(arg => arg.StartsWith("--launcher-query=", StringComparison.OrdinalIgnoreCase));
            var launcherMode = Environment.GetCommandLineArgs()
                .FirstOrDefault(arg => arg.StartsWith("--launcher-mode=", StringComparison.OrdinalIgnoreCase));
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(() =>
            {
                OverlayHost.Show(OverlayKind.Launcher);
                if (launcherQuery is not null)
                {
                    var value = launcherQuery["--launcher-query=".Length..];
                    if (launcherMode is not null)
                    {
                        value = launcherMode["--launcher-mode=".Length..] + " " + value;
                    }

                    OverlayHost.SetLauncherQuery(value);
                }
            });
        }

        if (Environment.GetCommandLineArgs().Contains("--dump-icon", StringComparer.OrdinalIgnoreCase))
        {
            _ = Task.Run(async () =>
            {
                await Task.Delay(6000);
                var app = AppCatalog.Instance?.Apps.FirstOrDefault(
                              item => item.Title.Contains("Chrome", StringComparison.OrdinalIgnoreCase))
                          ?? AppCatalog.Instance?.Apps.FirstOrDefault(item => item.IconData is { Length: > 0 });
                if (app?.IconData is { } bytes)
                {
                    var path = Path.Combine(Paths.DataDirectory, "icon-dump.png");
                    await File.WriteAllBytesAsync(path, bytes);
                    Log.Info($"launcher.icon-dump {path} {bytes.Length}");
                }
            });
        }

        if (Environment.GetCommandLineArgs().Contains("--cred-smoke", StringComparer.OrdinalIgnoreCase))
        {
            var written = Credentials.Set("smoke-test", "credential-value");
            var read = Credentials.Get("smoke-test") == "credential-value";
            var deleted = Credentials.Delete("smoke-test");
            Log.Info($"cred.smoke write={written} read={read} delete={deleted}");
        }
#endif
        // 自动更新换上新版本后带 --updated 启动：清理 *.old 并提示一次（第二版 §5）。
        if (Environment.GetCommandLineArgs().Contains("--updated", StringComparer.OrdinalIgnoreCase))
        {
            DispatcherQueue.GetForCurrentThread()?.TryEnqueue(AutoUpdater.HandleUpdatedLaunch);
        }

        if (SettingsService.IsNew)
        {
            ShowSettings(welcome: true);
        }
    }

    public void ShowSettings(bool welcome, string page = "general")
    {
        OverlayHost.Hide(restoreForeground: false);
        if (_settingsWindow is null || _settingsWindow.IsClosed)
        {
            _settingsWindow = new SettingsWindow();
        }

        _settingsWindow.ShowPage(welcome, page);
    }

    /// <summary>关掉设置窗（内存探针、自动更新重启前用）。</summary>
    public void CloseSettings()
    {
        try
        {
            _settingsWindow?.Close();
        }
        catch
        {
            // 已经关掉的跳过。
        }

        _settingsWindow = null;
    }

    public void ToggleCopyTranslate()
    {
        SettingsService.Current.CopyTranslate = !SettingsService.Current.CopyTranslate;
        SettingsService.Save();
        NoticeHost.Show("复制即译", SettingsService.Current.CopyTranslate ? "已打开" : "已关闭", NoticeTone.Normal);
    }

    public void TogglePauseClipboard()
    {
        if (Clipboard is null || !Features.IsOn(Feature.Clipboard))
        {
            return;
        }

        Clipboard.Paused = !Clipboard.Paused;
        NoticeHost.Show("剪贴板记录", Clipboard.Paused ? "已暂停" : "已恢复", NoticeTone.Normal);
    }

    public void OpenClipboard()
    {
        if (!Features.IsOn(Feature.Clipboard))
        {
            NoticeHost.Show("剪贴板已关闭", "到 设置 › 通用 › 功能 里打开", NoticeTone.Warning);
            return;
        }

        OverlayHost.Show(OverlayKind.Clipboard);
    }

    /// <summary>功能开关改了：停 / 起后台工作、收起被关掉的那块浮层（第三版 §2.3）。</summary>
    private void ApplyFeatures()
    {
        if (Clipboard is { } clipboard)
        {
            clipboard.Suspended = !Features.IsOn(Feature.Clipboard);
        }

        Log.Info(
            "features " + string.Join(
                ' ',
                Enum.GetValues<Feature>().Select(feature => $"{Features.Key(feature)}={Features.IsOn(feature)}")));

        if (!Features.IsOn(Feature.Clipboard))
        {
            OverlayHost.HideKind(OverlayKind.Clipboard);
        }

        if (!Features.IsOn(Feature.Launcher))
        {
            OverlayHost.HideKind(OverlayKind.Launcher);
        }

        if (!Features.IsOn(Feature.Translate))
        {
            TranslateHost.Hide(restoreForeground: false);
        }
    }

    /// <summary>后台跑一次每日备份（今天备过就直接返回）。</summary>
    private static void ScheduleBackup()
    {
        var directory = Paths.DataDirectory;
        _ = Task.Run(() =>
        {
            try
            {
                Backup.Run(directory, DateTime.Now);
                // 设置与数据的每日自动备份（第三版 §2.2），和数据库备份同一个 backups 文件夹。
                ArchiveService.BackupDaily();
            }
            catch (Exception ex)
            {
                Log.Warn($"backup.task-failed {ex.GetType().Name}");
            }
        });
    }

    public void ShowNotice(string title, string detail, NoticeTone tone = NoticeTone.Normal)
        => NoticeHost.Show(title, detail, tone);

    public void Exit()
    {
        Log.Info("app.exit");
        Clipboard?.CommitDeletion();
        HotKeys.UnregisterAll();
        Tray.Remove();
        Application.Current.Exit();
    }

    private void OnHiddenMessage(uint msg, Windows.Win32.Foundation.WPARAM wParam, Windows.Win32.Foundation.LPARAM lParam)
    {
        const uint WmWtsSessionChange = 0x02B1;
        const uint WmPowerBroadcast = 0x0218;
        if (msg == PInvoke.WM_HOTKEY)
        {
            // 录屏倒数期间 Esc 取消（第四版）。
            if (RecordingCountdown.Active && (int)wParam.Value == RecordingCountdown.EscapeId)
            {
                RecordingCountdown.Cancel();
                return;
            }

            // 长截图期间 Enter / Esc 是临时注册的（第三版 §7）。
            if (ScrollingCapture.Active && (int)wParam.Value is ScrollingCapture.EnterId or ScrollingCapture.EscapeId)
            {
                if ((int)wParam.Value == ScrollingCapture.EnterId)
                {
                    ScrollingCapture.Complete();
                }
                else
                {
                    ScrollingCapture.Cancel();
                }

                return;
            }

            HotKeys.OnHotKey((int)wParam.Value);
        }
        else if (msg == PInvoke.WM_CLIPBOARDUPDATE)
        {
            Clipboard?.OnClipboardUpdate();
        }
        else if (msg == Tray.CallbackMessage)
        {
            Tray.OnCallback(msg, wParam, lParam);
        }
        else if (msg == WmWtsSessionChange)
        {
            // 7 = 锁屏：录屏 / 录音停掉并保存；8 = 解锁时看一眼今天的备份。
            if (wParam.Value == 7)
            {
                StopRecordingForSession();
                ScheduleBackup();
            }
            else if (wParam.Value == 8)
            {
                ScheduleBackup();
            }
        }
        else if (msg == WmPowerBroadcast && wParam.Value is 7 or 0x12)
        {
            // 7 = 从睡眠唤醒（PBT_APMRESUMESUSPEND）、0x12 = 自动唤醒。
            ScheduleBackup();
            _ = Syncer.Instance?.RoundAsync();
        }
        else if (msg == WmPowerBroadcast && wParam.Value == 4)
        {
            // PBT_APMSUSPEND：睡之前把录屏 / 录音收尾。
            StopRecordingForSession();
        }
    }

    /// <summary>锁屏 / 睡眠：录屏和录音都停止并保存（第四版）。</summary>
    private static void StopRecordingForSession()
    {
        if (RecordingHost.IsRecording)
        {
            Log.Info("record.session-stop");
            RecordingHost.Stop();
        }

        if (AudioHost.IsRecording)
        {
            Log.Info("audio.session-stop");
            AudioHost.Stop();
        }
    }

    private void OnHotKey(string action)
    {
        // 功能关掉了就什么都不做（热键本来也没注册，保险）。
        if (!Features.IsOn(Features.ForHotKey(action)))
        {
            return;
        }

        switch (action)
        {
            case HotKeyActions.Clipboard:
                OverlayHost.Toggle(OverlayKind.Clipboard);
                break;
            case HotKeyActions.Launcher:
                OverlayHost.Toggle(OverlayKind.Launcher);
                break;
            case HotKeyActions.SelectionTranslate:
                TranslateHost.ShowSelection();
                break;
            case HotKeyActions.InputTranslate:
                TranslateHost.ToggleInput();
                break;
            case HotKeyActions.ScreenshotTranslate:
                ScreenshotSession.Start(ScreenshotMode.Translate);
                break;
            case HotKeyActions.Screenshot:
                ScreenshotSession.Start(ScreenshotMode.Capture);
                break;
            case HotKeyActions.ScreenshotLast:
                ScreenshotSession.StartLast();
                break;
            case HotKeyActions.Record:
                RecordingHost.Toggle();
                break;
            case HotKeyActions.Ocr:
                ScreenshotSession.Start(ScreenshotMode.Ocr);
                break;
        }
    }

    private void OnSettingsChanged()
    {
        // 只在热键真的变了时才重注册：每次保存都清空重注册的话，别的设置一改热键也会短暂失效
        // （第二版 §2 第 1 条）。
        var signature = HotKeySignature(SettingsService.Current);
        if (signature != _hotKeySignature)
        {
            RegisterHotKeys();
        }

        if (_autoCheck != SettingsService.Current.AutoCheckUpdates)
        {
            _autoCheck = SettingsService.Current.AutoCheckUpdates;
            UpdateService.Configure(SettingsService.Current.AutoCheckUpdates);
        }

        Theme.ApplyAccent();
        TranslateHost.ApplyCopyTranslate();
        ApplyFeatures();
        _settingsWindow?.RefreshTheme();
    }

    /// <summary>重注册全部热键，并记下这次用的绑定组合（用来判断下次保存要不要重注册）。</summary>
    private void RegisterHotKeys()
    {
        HotKeys.RegisterAll(SettingsService.Current);
        _hotKeySignature = HotKeySignature(SettingsService.Current);
    }

    private static string HotKeySignature(Settings settings)
        => string.Join(
            '|',
            Enum.GetValues<Feature>().Select(feature => $"{feature}:{Features.IsOn(feature)}")
                .Concat(settings.HotKeys
                    .OrderBy(hotkey => hotkey.Action, StringComparer.Ordinal)
                    .Select(hotkey => $"{hotkey.Action}:{hotkey.Modifiers}:{hotkey.VirtualKey}")));
}
