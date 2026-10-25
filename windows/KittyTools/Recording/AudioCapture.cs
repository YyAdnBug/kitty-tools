// 录音（第四版基础版）：WinRT MediaCapture 录默认麦克风，直接写 M4A（AAC）。
// 不用 WASAPI 互操作：MediaCapture 自己处理权限 / 重采样 / 编码；第一次用会触发系统的麦克风隐私授权。
// 只做麦克风，系统声音 / 混音 / 电平表 / 暂停没做（报告 §3）。
using KittyTools.Infrastructure;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace KittyTools;

internal static class AudioCapture
{
    private static MediaCapture? _capture;

    public static bool IsRecording => _capture is not null;

    /// <summary>上一次失败是不是「没有麦克风权限」（E_ACCESSDENIED）。</summary>
    public static bool LastAccessDenied { get; private set; }

    public static async Task<string?> StartAsync(string path)
    {
        try
        {
            var capture = new MediaCapture();
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                StreamingCaptureMode = StreamingCaptureMode.Audio,
                SharingMode = MediaCaptureSharingMode.SharedReadOnly,
            });
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
            var file = await folder.CreateFileAsync(
                Path.GetFileName(path), CreationCollisionOption.ReplaceExisting);
            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
            await capture.StartRecordToStorageFileAsync(profile, file);
            _capture = capture;
            Log.Info("audio.capture-start");
            return path;
        }
        catch (Exception ex)
        {
            LastAccessDenied = ex.HResult == unchecked((int)0x80070005);
            Log.Error($"audio.capture-start-failed hr=0x{ex.HResult:X8} {ex.Message}");
            _capture = null;
            return null;
        }
    }

    public static async Task<bool> StopAsync()
    {
        if (_capture is not { } capture)
        {
            return false;
        }

        _capture = null;
        try
        {
            await capture.StopRecordAsync();
            capture.Dispose();
            Log.Info("audio.capture-stop");
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.capture-stop-failed {ex.GetType().Name}");
            try
            {
                capture.Dispose();
            }
            catch
            {
                // 已经没了。
            }

            return false;
        }
    }
}
