// 录屏的入口和收尾：Alt+R / 托盘切换；录制中禁掉系统闲置睡眠；录的窗口关了、磁盘不够了按停止收尾（R8）；停止后放到保存目录，
// 轻提示 + 在资源管理器里显示。启动时看到上次留下的临时文件就挪进保存目录（闪退恢复）。
// PLAN-v6 第 1 批起默认走 WGC + 硬件 H.264；有系统声音 / 麦克风时仍走 GDI 那条（第 2 批再并到 GPU 管线）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static class RecordingHost
{
    private static IVideoRecorder? _recorder;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _diskTimer;
    private static long _startedAt;
    private static bool _microphoneSettingsPending;

    public static bool IsRecording => _recorder is not null;

    /// <summary>录屏暂停着（PLAN-v26 V1）。</summary>
    public static bool IsPaused => _recorder?.Paused == true;

    private static long _pausedAt;
    private static long _pausedTotal;

    /// <summary>这段录屏藏起的桌面图标（PLAN-v11 F6），停下时显示回来。</summary>
    private static IDisposable? _desktopIcons;

    public static string? LiveNote => _recorder?.LiveNote;

    /// <summary>这一段录不录系统声音（开录时的设置；录制条上的图标，PLAN-v9 R7）。</summary>
    public static bool WithSystemAudio { get; private set; }

    /// <summary>这一段录不录麦克风（开录时的设置，权限被拒就是 false）。</summary>
    public static bool WithMicrophone { get; private set; }

    public static string? LastPath { get; private set; }

    public static event Action? Changed;

    public static string Folder
    {
        get
        {
            var configured = SettingsService.Current.RecordDirectory;
            if (!string.IsNullOrWhiteSpace(configured))
            {
                return configured;
            }

            var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
            return Path.Combine(
                string.IsNullOrEmpty(videos) ? Paths.DataDirectory : videos, "Screen Recordings");
        }
    }

    public static string Elapsed => RecorderRules.Duration(ElapsedMs);

    /// <summary>已录的毫秒数，不算暂停的时间（同 AudioHost）。</summary>
    public static long ElapsedMs
    {
        get
        {
            if (!IsRecording)
            {
                return 0;
            }

            var elapsed = Environment.TickCount64 - _startedAt - _pausedTotal;
            if (IsPaused)
            {
                elapsed -= Environment.TickCount64 - _pausedAt;
            }

            return Math.Max(0, elapsed);
        }
    }

    /// <summary>
    /// 暂停 / 继续录屏（PLAN-v26 V1，同 mac 0.10.3）：暂停时不录画面和声音、不占麦克风、放开「别睡眠」；计时不算暂停的时间。
    /// </summary>
    public static void TogglePause()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        if (recorder.Paused)
        {
            recorder.Paused = false;
            _pausedTotal += Environment.TickCount64 - _pausedAt;
            SetThreadExecutionState(EsContinuous | EsSystemRequired | EsDisplayRequired);
            Log.Info("record.resumed");
        }
        else
        {
            _pausedAt = Environment.TickCount64;
            recorder.Paused = true;
            SetThreadExecutionState(EsContinuous);
            Log.Info("record.paused");
        }

        RecordingHud.RefreshPause();
        Changed?.Invoke();
    }

    /// <summary>
    /// 全局动作「暂停 / 继续录制」（recordPause，PLAN-v26 V2）：在录屏就暂停 / 继续录屏，在录音就暂停 / 继续录音（待录时不算在录）；
    /// 都没在录时提示一句。
    /// </summary>
    public static void TogglePauseAny()
    {
        if (IsRecording)
        {
            TogglePause();
        }
        else if (AudioHost.IsRecording && !AudioHost.IsArmed)
        {
            if (AudioHost.IsPaused)
            {
                AudioHost.Resume();
            }
            else
            {
                AudioHost.Pause();
            }

            AudioHud.RefreshPause();
        }
        else
        {
            NoticeHost.Show("没有在录制", "录屏或录音时按它暂停、再按继续", NoticeTone.Normal);
        }
    }

    public static void Toggle()
    {
        if (IsRecording)
        {
            Stop();
            return;
        }

        // 没在录：先开截图遮罩选区域（和截图同一套），Enter 后倒数 3 秒开始。
        ScreenshotSession.Start(ScreenshotMode.Record);
    }

    /// <summary>选区确认、倒数结束后真正开始录。</summary>
    public static void StartRegion(PixelBounds region) => Start(region, IntPtr.Zero);

    /// <summary>录一个窗口本身（选区遮罩里单击窗口取整窗时走这条）。</summary>
    public static void StartWindow(IntPtr hwnd)
    {
        if (_recorder is not null || hwnd == IntPtr.Zero)
        {
            return;
        }

        if (!PInvoke.GetWindowRect(new HWND(hwnd), out var rect))
        {
            RecordingFrame.Hide();
            NoticeHost.Show("没能开始录屏", "拿不到这个窗口的位置", NoticeTone.Error);
            return;
        }

        Start(new PixelBounds(rect.left, rect.top, rect.right, rect.bottom), hwnd);
    }

    private static void Start(PixelBounds region, IntPtr window)
    {
        if (_recorder is not null)
        {
            return;
        }

        // 提醒的长提示音别录进去（PLAN-v16 E2）
        ReminderSound.Stop();
        var settings = SettingsService.Current;
        // 录一块区域时整段藏起桌面图标（PLAN-v11 F6）；录一扇窗口时画面里本来就没有桌面。
        var icons = window == IntPtr.Zero ? DesktopIcons.HideIfEnabled() : null;
        IVideoRecorder? recorder;
        string? error;
        string? note;
        recorder = window != IntPtr.Zero
            ? WgcRecorder.StartWindow(
                window, settings.RecordFps, Folder,
                settings.RecordSystemSound, settings.RecordMicrophone, out error, out note)
            : WgcRecorder.StartRegion(
                region, settings.RecordFps, Folder,
                settings.RecordSystemSound, settings.RecordMicrophone, out error, out note);
        if (recorder is null)
        {
            Log.Warn($"record.wgc-fallback {error}");
            recorder = GdiMp4Recorder.StartRegion(
                region, settings.RecordFps, Folder,
                settings.RecordSystemSound, settings.RecordMicrophone, out error, out note);
        }

        if (recorder is null)
        {
            icons?.Dispose();
            RecordingFrame.Hide();
            RecordingHud.Hide();
            NoticeHost.Show("没能开始录屏", error ?? "未知原因", NoticeTone.Error);
            return;
        }

        _desktopIcons = icons;

        var microphoneDenied = recorder is WgcRecorder { MicrophoneDenied: true } ||
                               recorder is GdiMp4Recorder { MicrophoneDenied: true };
        WithSystemAudio = settings.RecordSystemSound;
        WithMicrophone = settings.RecordMicrophone && !microphoneDenied;

        if (note is not null)
        {
            NoticeHost.Show("这段录屏没有完整声音", note, NoticeTone.Warning);
        }

        if (recorder is WgcRecorder { MicrophoneDenied: true } ||
            recorder is GdiMp4Recorder { MicrophoneDenied: true })
        {
            settings.RecordMicrophone = false;
            SettingsService.Save();
            _microphoneSettingsPending = true;
        }

        _recorder = recorder;
        _startedAt = Environment.TickCount64;
        _pausedTotal = 0;
        SettingsService.Current.RecordingTempPath = recorder.TemporaryPath;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous | EsSystemRequired | EsDisplayRequired);
        RecordingFrame.Show(region, window);
        RecordingHud.Show(region);
        if (SettingsService.Current.RecordClicks || SettingsService.Current.RecordKeys)
        {
            InputHooks.ShortcutsOnly = SettingsService.Current.RecordKeysShortcutsOnly;
            InputHooks.Start(
                region,
                (x, y, down, right) =>
                {
                    if (SettingsService.Current.RecordClicks)
                    {
                        RecordingEffects.Click(x, y, down, right);
                    }
                },
                text =>
                {
                    if (SettingsService.Current.RecordKeys)
                    {
                        RecordingEffects.Key(text);
                    }
                });
        }

        WatchForInterruptions(recorder);
        Log.Info("record.begin");
        NoticeHost.Show("正在录屏", "Alt+R 或托盘「停止录屏」结束", NoticeTone.Normal);
        Changed?.Invoke();
    }

    public static void Stop() => StopCore(null);

    /// <summary>中途出事（R8）：和点停止走同一条收尾、保存已录的部分，原因写进「录屏已保存」的提示（同 mac 的结果岛）。</summary>
    public static void StopFor(string reason)
    {
        Log.Info($"record.interrupted {reason}");
        StopCore(reason);
    }

    /// <summary>
    /// R8（照 mac ScreenRecorder）：录的窗口关了 / 录的屏断开了（WGC 的 GraphicsCaptureItem.Closed），
    /// 保存目录所在的盘剩不到 1 GB（每 10 s 看一次）——都按停止收尾。锁屏、睡眠在 ShellRuntime。
    /// </summary>
    private static void WatchForInterruptions(IVideoRecorder recorder)
    {
        var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        if (recorder is WgcRecorder wgc && queue is not null)
        {
            wgc.SourceClosed += () => queue.TryEnqueue(() =>
            {
                if (ReferenceEquals(_recorder, wgc))
                {
                    StopFor(wgc.RecordsWindow ? "录的窗口关了" : "录的屏幕断开了");
                }
            });
        }

        if (queue is null)
        {
            return;
        }

        _diskTimer = queue.CreateTimer();
        _diskTimer.Interval = TimeSpan.FromSeconds(10);
        _diskTimer.IsRepeating = true;
        _diskTimer.Tick += (_, _) =>
        {
            if (ReferenceEquals(_recorder, recorder) && !HasRoomFor(recorder.TemporaryPath))
            {
                StopFor("磁盘剩余不到 1 GB");
            }
        };
        _diskTimer.Start();
    }

    internal static bool HasRoomFor(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            return string.IsNullOrEmpty(root) || RecorderRules.HasRoom(new DriveInfo(root).AvailableFreeSpace);
        }
        catch (Exception ex)
        {
            // 读不到剩余空间（网络盘之类）就不拦。
            Log.Warn($"record.disk-check {ex.GetType().Name}");
            return true;
        }
    }

    private static void StopWatching()
    {
        _diskTimer?.Stop();
        _diskTimer = null;
    }

    private static void StopCore(string? reason)
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
        StopWatching();
        RecordingHud.Hide();
        RecordingFrame.Hide();
        InputHooks.Stop();
        RecordingEffects.Clear();
        var path = recorder.Stop();
        recorder.Dispose();
        _desktopIcons?.Dispose();
        _desktopIcons = null;
        SettingsService.Current.RecordingTempPath = null;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous);
        IdleReclaimer.Schedule();
        LastPath = path;
        Changed?.Invoke();
        if (path is null)
        {
            NoticeHost.Show("录屏失败", "没有写出文件", NoticeTone.Error);
            return;
        }

        Log.Info($"record.saved {Path.GetFileName(path)}");
        _ = ShotHistory.RecordFileAsync(path, Core.ShotKind.Video);
        ScreenshotCard.ShowFile(path, Core.ShotKind.Video);
        // 不再自己弹资源管理器（mac 也不弹，PLAN-v8 H14）：提示上给「在资源管理器中显示」「打开」。
        NoticeHost.Show("录屏已保存",
            reason is null ? Path.GetFileName(path) : $"{reason}，已录的部分存在 {Path.GetFileName(path)}",
            reason is null ? NoticeTone.Normal : NoticeTone.Warning,
            NoticeActions.Reveal(path), NoticeActions.Open(path));
        OpenMicrophoneSettingsIfPending();
    }

    /// <summary>放弃这段录屏：停止、删掉文件。</summary>
    public static void Abandon()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
        StopWatching();
        RecordingHud.Hide();
        RecordingFrame.Hide();
        InputHooks.Stop();
        RecordingEffects.Clear();
        var path = recorder.Stop();
        recorder.Dispose();
        _desktopIcons?.Dispose();
        _desktopIcons = null;
        SettingsService.Current.RecordingTempPath = null;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous);
        IdleReclaimer.Schedule();
        Changed?.Invoke();
        if (path is not null)
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception ex)
            {
                Log.Warn($"record.abandon-delete {ex.GetType().Name}");
            }
        }

        Log.Info("record.abandoned");
        NoticeHost.Show("已放弃这段录屏", string.Empty, NoticeTone.Normal);
        OpenMicrophoneSettingsIfPending();
    }

    /// <summary>麦克风权限被拒绝时，录完再打开系统设置，免得起录那一刻挡住画面 / 被录进去。</summary>
    private static void OpenMicrophoneSettingsIfPending()
    {
        if (!_microphoneSettingsPending)
        {
            return;
        }

        _microphoneSettingsPending = false;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "ms-settings:privacy-microphone",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Log.Warn($"record.mic-settings {ex.GetType().Name}");
        }
    }

    /// <summary>上次录到一半的文件（闪退恢复）。重封装在线程池上做（REVIEW R51：以前在启动路径的 UI 线程上同步等），做完回 UI 线程提示。</summary>
    public static async Task RecoverOnStartupAsync()
    {
        var temporary = SettingsService.Current.RecordingTempPath;
        if (string.IsNullOrEmpty(temporary) || !File.Exists(temporary))
        {
            return;
        }

        try
        {
            var folder = Folder;
            var path = Path.Combine(folder, RecorderRules.FileName(DateTime.Now));
            await Task.Run(() =>
            {
                Directory.CreateDirectory(folder);
                if (Mp4Remux.TryRemuxWithTimeout(temporary, path))
                {
                    File.Delete(temporary);
                }
                else
                {
                    // 分段 MP4 原样挪过去，至少能放（R23 的退路）。
                    File.Move(temporary, path, overwrite: true);
                }
            });

            // 恢复的这一会儿又开了一段新的录屏：它的临时文件别清掉。
            if (SettingsService.Current.RecordingTempPath == temporary)
            {
                SettingsService.Current.RecordingTempPath = null;
                SettingsService.Save();
            }

            Log.Info($"record.recovered size={(File.Exists(path) ? new FileInfo(path).Length : 0)}");
            NoticeHost.Show("上次的录屏已保存", Path.GetFileName(path), NoticeTone.Normal, NoticeActions.Reveal(path));
        }
        catch (Exception ex)
        {
            Log.Warn($"record.recover-failed {ex.GetType().Name}");
        }
    }

    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsDisplayRequired = 0x00000002;

    [DllImport("kernel32.dll", EntryPoint = "SetThreadExecutionState")]
    private static extern uint SetThreadExecutionStateNative(uint flags);

    private static uint SetThreadExecutionState(uint flags)
        => SetThreadExecutionStateNative(flags);
}
