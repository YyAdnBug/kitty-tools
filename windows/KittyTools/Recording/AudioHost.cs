// 录音的入口（第四版基础版）：托盘开始 / 停止，存到录屏同一个文件夹，文件名「录音 日期.m4a」。
// 只录麦克风；没有录音控制条 / 电平表 / 暂停按钮，暂停只在调试时用（报告 §3）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AudioHost
{
    private static bool _recording;
    private static long _startedAt;
    private static string? _path;

    public static bool IsRecording => _recording;

    public static string? LastPath => _path;

    public static event Action? Changed;

    public static string Elapsed => RecorderRules.Duration(
        _recording ? Environment.TickCount64 - _startedAt : 0);

    public static async void Start()
    {
        if (_recording)
        {
            return;
        }

        Directory.CreateDirectory(RecordingHost.Folder);
        var path = Path.Combine(RecordingHost.Folder, RecorderRules.FileName(DateTime.Now, audio: true));
        var started = await AudioCapture.StartAsync(path);
        if (started is null)
        {
            NoticeHost.Show(
                "没能开始录音",
                "没有麦克风权限，或者没有可用的麦克风。可以在 设置 › 隐私 › 麦克风 里允许桌面应用。",
                NoticeTone.Error);
            return;
        }

        _recording = true;
        _startedAt = Environment.TickCount64;
        _path = path;
        Log.Info("audio.begin");
        NoticeHost.Show("正在录音", "托盘「停止录音」结束", NoticeTone.Normal);
        Changed?.Invoke();
    }

    public static async void Stop()
    {
        if (!_recording)
        {
            return;
        }

        _recording = false;
        var stopped = await AudioCapture.StopAsync();
        _path = await LatestAsync(_path);
        Changed?.Invoke();
        if (!stopped || _path is null || !File.Exists(_path))
        {
            NoticeHost.Show("录音失败", "没有写出文件", NoticeTone.Error);
            return;
        }

        Log.Info($"audio.saved {Path.GetFileName(_path)} size={new FileInfo(_path).Length}");
        NoticeHost.Show("录音已保存", Path.GetFileName(_path), NoticeTone.Normal);
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "/select,\"" + _path + "\"",
                UseShellExecute = true,
            });
        }
        catch
        {
            // 打不开资源管理器就算了。
        }
    }

    /// <summary>MediaCapture 偶尔会加后缀；取目录里最新的那一个。</summary>
    private static Task<string?> LatestAsync(string? path)
    {
        if (path is null)
        {
            return Task.FromResult<string?>(null);
        }

        try
        {
            if (File.Exists(path))
            {
                return Task.FromResult<string?>(path);
            }

            var folder = Path.GetDirectoryName(path)!;
            var name = Path.GetFileNameWithoutExtension(path);
            var latest = Directory.EnumerateFiles(folder, name + "*.m4a")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            return Task.FromResult(latest);
        }
        catch
        {
            return Task.FromResult<string?>(path);
        }
    }
}
