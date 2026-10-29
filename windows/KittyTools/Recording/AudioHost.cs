// 录音的入口（PLAN-v6 第 3 批）：托盘 / 快捷键开始或停止，和录屏同一个文件夹、同一套 WASAPI 采集。
// 只建一路 AAC 音轨写 .m4a；支持系统声音 / 麦克风、暂停 / 继续、电平（RMS dBFS）、放弃（R9）。
// 保存目录的盘剩不到 1 GB 时按停止收尾（同录屏 R8，mac AudioRecorder）；锁屏时只录麦克风的照录（R11，在 ShellRuntime）。
// 录哪一路看 设置 › 录制「来源」（PLAN-v9 V5：麦克风（默认）/ 系统声音 / 两者，和录屏的两个开关分开）；
// 麦克风用不了（隐私设置里关着、没插麦克风）时退回系统声音，来源改成「系统声音」，提示带「打开设置」（同 mac）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AudioHost
{
    private static AudioRecorder? _recorder;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _diskTimer;
    private static long _startedAt;
    private static long _pausedAt;
    private static long _pausedTotal;

    public static bool IsRecording => _recorder is not null;

    /// <summary>“待录”：控制条出来了，但还没开始采（R28 的「按快捷键后立即开始录音」关掉时）。</summary>
    public static bool IsArmed { get; private set; }

    public static bool IsPaused => _recorder?.IsPaused == true;

    public static float Level => _recorder?.Level ?? -90;

    /// <summary>录音中的实时状态：麦克风 / 系统声音断了（R28）。</summary>
    public static string? StatusNote => _recorder?.LiveNote;

    public static string? LastPath { get; private set; }

    public static event Action? Changed;

    /// <summary>录这一路有没有麦克风（「没听到声音」只在有麦克风时提示，同 mac）。</summary>
    public static bool RecordsMicrophone => _recorder?.RecordsMicrophone == true;

    /// <summary>录这一路有没有系统声音（只录麦克风时锁屏照录，R11）。</summary>
    public static bool RecordsSystemAudio => _recorder?.RecordsSystemAudio == true;

    public static string Elapsed => RecorderRules.Duration(ElapsedMs);

    /// <summary>已录的毫秒数，不算暂停的时间。</summary>
    public static long ElapsedMs
    {
        get
        {
            if (_recorder is null)
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

    public static void Toggle()
    {
        if (IsRecording)
        {
            Stop();
            return;
        }

        if (IsArmed)
        {
            // 待录时再按一次（快捷键、托盘、启动器）= 开始录（同 mac「点 ● 或再按一次才开始」）；不录就点控制条上的 ✕ 关闭。
            BeginFromHud();
            return;
        }

        if (SettingsService.Current.RecordInstantStart)
        {
            Start();
        }
        else
        {
            IsArmed = true;
            AudioHud.ShowPending();
        }
    }

    /// <summary>控制条上的 ●：从待录开始真正采。</summary>
    public static void BeginFromHud()
    {
        IsArmed = false;
        AudioHud.MarkStarted();
        Start();
    }

    public static void Start()
    {
        if (_recorder is not null)
        {
            return;
        }

        var settings = SettingsService.Current;
        var (systemAudio, microphone) = RecorderRules.AudioSource(settings.AudioSource);
        var recorder = AudioRecorder.Start(RecordingHost.Folder, systemAudio, microphone, out var error, out var note);
        // 只选了麦克风、麦克风开不了：退回系统声音再试一次（选了「两者」时系统声音那一路照录，下面一样改来源）。
        var fellBack = false;
        if (recorder is null && microphone && !systemAudio)
        {
            Log.Info("audio.microphone-unavailable fallback=system");
            recorder = AudioRecorder.Start(RecordingHost.Folder, systemAudio: true, microphone: false, out error, out note);
            fellBack = recorder is not null;
        }

        if (recorder is null)
        {
            IsArmed = false;
            AudioHud.Hide();
            NoticeHost.Show("没能开始录音", error ?? "未知原因", NoticeTone.Error,
                NoticeActions.SystemSettings("ms-settings:privacy-microphone"));
            Changed?.Invoke();
            return;
        }

        if (fellBack || (microphone && recorder.MicrophoneDenied))
        {
            settings.AudioSource = "system";
            SettingsService.Save();
            note = "麦克风用不了，改成录系统声音（设置 › 隐私和安全性 › 麦克风）";
        }

        _recorder = recorder;
        SettingsService.Current.AudioTempPath = recorder.TemporaryPath;
        SettingsService.Save();
        IsArmed = false;
        AudioHud.MarkStarted();
        _startedAt = Environment.TickCount64;
        _pausedAt = 0;
        _pausedTotal = 0;
        Log.Info("audio.begin");
        WatchDisk(recorder);
        AudioHud.Show(note);
        if (string.IsNullOrEmpty(note))
        {
            NoticeHost.Show("正在录音", "托盘「停止录音」结束", NoticeTone.Normal);
        }
        else
        {
            NoticeHost.Show("正在录音", note, NoticeTone.Warning, NoticeActions.SystemSettings("ms-settings:privacy-microphone"));
        }

        Changed?.Invoke();
    }

    public static void Pause()
    {
        if (_recorder is null || _recorder.IsPaused)
        {
            return;
        }

        _recorder.Pause();
        _pausedAt = Environment.TickCount64;
        Changed?.Invoke();
        Log.Info("audio.paused");
    }

    public static void Resume()
    {
        if (_recorder is null || !_recorder.IsPaused)
        {
            return;
        }

        _recorder.Resume();
        _pausedTotal += Environment.TickCount64 - _pausedAt;
        _pausedAt = 0;
        Changed?.Invoke();
        Log.Info("audio.resumed");
    }

    public static void Stop() => StopCore(null);

    /// <summary>每 10 s 看一次保存目录的盘，剩不到 1 GB 就停下保存（同录屏 R8、mac AudioRecorder）。</summary>
    private static void WatchDisk(AudioRecorder recorder)
    {
        if (Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread() is not { } queue)
        {
            return;
        }

        _diskTimer = queue.CreateTimer();
        _diskTimer.Interval = TimeSpan.FromSeconds(10);
        _diskTimer.IsRepeating = true;
        _diskTimer.Tick += (_, _) =>
        {
            if (ReferenceEquals(_recorder, recorder) && !RecordingHost.HasRoomFor(recorder.TemporaryPath))
            {
                Log.Info("audio.interrupted disk");
                StopCore("磁盘剩余不到 1 GB");
            }
        };
        _diskTimer.Start();
    }

    /// <summary>放弃这段录音（控制条上的 ✕ 点两下，R9）：停止、删掉文件。</summary>
    public static void Abandon()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
        _diskTimer?.Stop();
        _diskTimer = null;
        IsArmed = false;
        AudioHud.Hide();
        var path = recorder.Stop();
        recorder.Dispose();
        IdleReclaimer.Schedule();
        SettingsService.Current.AudioTempPath = null;
        SettingsService.Save();
        Changed?.Invoke();
        foreach (var file in new[] { path, recorder.TemporaryPath })
        {
            try
            {
                if (file is not null && File.Exists(file))
                {
                    File.Delete(file);
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"audio.abandon-delete {ex.GetType().Name}");
            }
        }

        Log.Info("audio.abandoned");
        NoticeHost.Show("已放弃这段录音", string.Empty, NoticeTone.Normal);
    }

    private static void StopCore(string? reason)
    {
        if (_recorder is not { } recorder)
        {
            // 待录时控制条上的「停止」= 关掉控制条（以前点了没反应，只能再按一次托盘 / 快捷键）。
            if (IsArmed)
            {
                IsArmed = false;
                AudioHud.Hide();
                Changed?.Invoke();
            }

            return;
        }

        _recorder = null;
        _diskTimer?.Stop();
        _diskTimer = null;
        IsArmed = false;
        AudioHud.Hide();
        var path = recorder.Stop();
        recorder.Dispose();
        IdleReclaimer.Schedule();
        SettingsService.Current.AudioTempPath = null;
        SettingsService.Save();
        LastPath = path;
        Changed?.Invoke();
        if (path is null || !File.Exists(path))
        {
            NoticeHost.Show("录音失败", "没有写出文件", NoticeTone.Error);
            return;
        }

        Log.Info($"audio.saved {Path.GetFileName(path)} size={new FileInfo(path).Length}");
        _ = ShotHistory.RecordFileAsync(path, Core.ShotKind.Audio);
        ScreenshotCard.ShowFile(path, Core.ShotKind.Audio);
        // 不再自己弹资源管理器（PLAN-v8 H14）：提示上给「在资源管理器中显示」「打开」。
        NoticeHost.Show("录音已保存",
            reason is null ? Path.GetFileName(path) : $"{reason}，已录的部分存在 {Path.GetFileName(path)}",
            reason is null ? NoticeTone.Normal : NoticeTone.Warning,
            NoticeActions.Reveal(path), NoticeActions.Open(path));
    }

    /// <summary>上次录音闪退：把临时分段 MP4 重封装成 .m4a 并提示（R28，照 R23）。</summary>
    public static void RecoverOnStartup()
    {
        var temporary = SettingsService.Current.AudioTempPath;
        if (string.IsNullOrEmpty(temporary) || !File.Exists(temporary))
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(RecordingHost.Folder);
            var final = Path.Combine(RecordingHost.Folder, RecorderRules.FileName(DateTime.Now, audio: true));
            if (!Mp4Remux.TryRemuxWithTimeout(temporary, final))
            {
                File.Move(temporary, final, overwrite: true);
            }
            else
            {
                File.Delete(temporary);
            }

            SettingsService.Current.AudioTempPath = null;
            SettingsService.Save();
            Log.Info($"audio.recovered size={(File.Exists(final) ? new FileInfo(final).Length : 0)}");
            NoticeHost.Show("上次的录音已保存", Path.GetFileName(final), NoticeTone.Normal, NoticeActions.Reveal(final));
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.recover-failed {ex.GetType().Name}");
        }
    }
}
