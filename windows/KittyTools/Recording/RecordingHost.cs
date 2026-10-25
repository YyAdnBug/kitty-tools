// 录屏的入口和收尾（第四版基础版）：Alt+R / 托盘切换；录制中禁掉系统闲置睡眠；停止后放到保存目录，
// 轻提示 + 在资源管理器里显示。启动时看到上次留下的临时文件就挪进保存目录（闪退恢复）。
// 范围：整屏、无声音、无选区 / 倒数 / HUD / 点按圈 / 按键提示（这些在报告里记为没做）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class RecordingHost
{
    private static IVideoRecorder? _recorder;
    private static long _startedAt;

    public static bool IsRecording => _recorder is not null;

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
    public static void StartRegion(PixelBounds region)
    {
        if (_recorder is not null)
        {
            return;
        }

        IVideoRecorder? recorder = SettingsService.Current.RecordMp4
            ? Mp4Recorder.StartRegion(region, SettingsService.Current.RecordFps, Folder, out var error)
            : AviRecorder.StartRegion(region, SettingsService.Current.RecordFps, Folder, out error);
        if (recorder is null)
        {
            NoticeHost.Show("没能开始录屏", error ?? "未知原因", NoticeTone.Error);
            return;
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
            File.Move(temporary, path, overwrite: true);
            SettingsService.Current.RecordingTempPath = null;
            SettingsService.Save();
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
