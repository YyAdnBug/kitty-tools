// 录音的入口（PLAN-v6 第 3 批）：托盘 / 快捷键开始或停止，和录屏同一个文件夹、同一套 WASAPI 采集。
// 只建一路 AAC 音轨写 .m4a；支持系统声音 / 麦克风、暂停 / 继续、电平（RMS dBFS）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AudioHost
{
    private static AudioRecorder? _recorder;
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

    public static string Elapsed
    {
        get
        {
            if (_recorder is null)
            {
                return RecorderRules.Duration(0);
            }

            var elapsed = Environment.TickCount64 - _startedAt - _pausedTotal;
            if (IsPaused)
            {
                elapsed -= Environment.TickCount64 - _pausedAt;
            }

            return RecorderRules.Duration(Math.Max(0, elapsed));
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
            IsArmed = false;
            AudioHud.Hide();
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
        var recorder = AudioRecorder.Start(
            RecordingHost.Folder, settings.RecordSystemSound, settings.RecordMicrophone,
            out var error, out var note);
        if (recorder is null)
        {
            IsArmed = false;
            AudioHud.Hide();
            NoticeHost.Show("没能开始录音", error ?? "未知原因", NoticeTone.Error);
            if (settings.RecordMicrophone)
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "ms-settings:privacy-microphone",
                        UseShellExecute = true,
                    });
                }
                catch
                {
                    // 打不开设置就算了。
                }
            }

            return;
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
        AudioHud.Show(note);
        NoticeHost.Show(
            "正在录音",
            string.IsNullOrEmpty(note) ? "托盘「停止录音」结束" : note,
            string.IsNullOrEmpty(note) ? NoticeTone.Normal : NoticeTone.Warning);
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

    public static void Stop()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
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
        NoticeHost.Show("录音已保存", Path.GetFileName(path), NoticeTone.Normal);
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "/select,\"" + path + "\"",
                UseShellExecute = true,
            });
        }
        catch
        {
            // 打不开资源管理器就算了。
        }
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
            NoticeHost.Show("上次的录音已保存", Path.GetFileName(final), NoticeTone.Normal);
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.recover-failed {ex.GetType().Name}");
        }
    }
}
