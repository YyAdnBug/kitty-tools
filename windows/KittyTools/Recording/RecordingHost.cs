// 录屏的入口和收尾：Alt+R / 托盘切换；录制中禁掉系统闲置睡眠；停止后放到保存目录，
// 轻提示 + 在资源管理器里显示。启动时看到上次留下的临时文件就挪进保存目录（闪退恢复）。
// PLAN-v6 第 1 批起默认走 WGC + 硬件 H.264；有系统声音 / 麦克风时仍走 GDI 那条（第 2 批再并到 GPU 管线）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static unsafe class RecordingHost
{
    private static IVideoRecorder? _recorder;
    private static long _startedAt;
    private static bool _microphoneSettingsPending;

    public static bool IsRecording => _recorder is not null;

    public static string? LiveNote => _recorder?.LiveNote;

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

    public static string Elapsed => RecorderRules.Duration(
        IsRecording ? Environment.TickCount64 - _startedAt : 0);

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

        RECT rect;
        if (!PInvoke.GetWindowRect(new HWND(hwnd), &rect))
        {
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

        var settings = SettingsService.Current;
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
            NoticeHost.Show("没能开始录屏", error ?? "未知原因", NoticeTone.Error);
            return;
        }

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
        SettingsService.Current.RecordingTempPath = recorder.TemporaryPath;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous | EsSystemRequired | EsDisplayRequired);
        RecordingHud.Show(region);
        if (SettingsService.Current.RecordClicks || SettingsService.Current.RecordKeys)
        {
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

        Log.Info("record.begin");
        NoticeHost.Show("正在录屏", "Alt+R 或托盘「停止录屏」结束", NoticeTone.Normal);
        Changed?.Invoke();
    }

    public static void Stop()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
        RecordingHud.Hide();
        InputHooks.Stop();
        RecordingEffects.Clear();
        var path = recorder.Stop();
        recorder.Dispose();
        SettingsService.Current.RecordingTempPath = null;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous);
        LastPath = path;
        Changed?.Invoke();
        if (path is null)
        {
            NoticeHost.Show("录屏失败", "没有写出文件", NoticeTone.Error);
            return;
        }

        Log.Info($"record.saved {Path.GetFileName(path)}");
        NoticeHost.Show("录屏已保存", Path.GetFileName(path), NoticeTone.Normal);
        OpenMicrophoneSettingsIfPending();
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

    /// <summary>放弃这段录屏：停止、删掉文件。</summary>
    public static void Abandon()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }

        _recorder = null;
        RecordingHud.Hide();
        InputHooks.Stop();
        RecordingEffects.Clear();
        var path = recorder.Stop();
        recorder.Dispose();
        SettingsService.Current.RecordingTempPath = null;
        SettingsService.Save();
        SetThreadExecutionState(EsContinuous);
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

    /// <summary>上次录到一半（闪退 / 断电）：把临时文件挪进保存目录并提示。</summary>
    public static void RecoverOnStartup()
    {
        var temporary = SettingsService.Current.RecordingTempPath;
        if (string.IsNullOrEmpty(temporary) || !File.Exists(temporary))
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(Folder);
            var path = Path.Combine(Folder, RecorderRules.FileName(DateTime.Now));
            if (Mp4Remux.TryRemux(temporary, path))
            {
                File.Delete(temporary);
            }
            else
            {
                // 分段 MP4 原样挪过去，至少能放（R23 的退路）。
                File.Move(temporary, path, overwrite: true);
            }
            SettingsService.Current.RecordingTempPath = null;
            SettingsService.Save();
            Log.Info($"record.recovered size={(File.Exists(path) ? new FileInfo(path).Length : 0)}");
            NoticeHost.Show("上次的录屏已保存", Path.GetFileName(path), NoticeTone.Normal);
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
