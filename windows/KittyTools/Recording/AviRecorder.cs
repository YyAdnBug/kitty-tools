// 录屏（第四版）：GDI 抓屏（整屏，鼠标所在那块）→ WIC 编 JPEG → 自己写的 MJPEG AVI。
// 固定帧率；编码来不及时写重复帧，保证时长和真实时间一致。没有音轨（WASAPI 没做，见报告）。
// 输出 .avi 而不是 PLAN 的 .mp4：不用 Media Foundation，Windows 自带的播放器能放 MJPEG AVI；
// MF SinkWriter 的尝试卡在 WriteSample，已撤回（见报告）。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal interface IVideoRecorder : IDisposable
{
    int Frames { get; }

    long ElapsedMs { get; }

    string TemporaryPath { get; }

    string OutputPath { get; }

    string? Stop();
}

internal sealed class AviRecorder : IVideoRecorder
{
    private readonly PixelBounds _region;
    private readonly int _fps;
    private readonly string _temporary;
    private readonly string _final;
    private readonly ManualResetEventSlim _stop = new(false);
    private Thread? _thread;
    private byte[]? _lastJpeg;
    private bool _effectsInjected;
    private int _effectsLogged;

    private AviRecorder(PixelBounds region, int fps, string temporary, string final)
    {
        _region = region;
        _fps = Math.Clamp(fps, RecorderRules.MinFps, RecorderRules.MaxFps);
        _temporary = temporary;
        _final = final;
    }

    public int Frames { get; private set; }

    public long ElapsedMs { get; private set; }

    public string? Error { get; private set; }

    public string TemporaryPath => _temporary;

    public string OutputPath => _final;

    public bool IsRecording => _thread is { IsAlive: true };

    public static AviRecorder? Start(int fps, string folder, out string? error)
        => StartCore(fps, folder, null, out error);

    /// <summary>录一块区域（物理像素，全局坐标）；Alt+R 选区走这条。</summary>
    public static AviRecorder? StartRegion(PixelBounds region, int fps, string folder, out string? error)
        => StartCore(fps, folder, region, out error);

    private static AviRecorder? StartCore(int fps, string folder, PixelBounds? region, out string? error)
    {
        error = null;
        List<FrozenScreen> screens;
        try
        {
            screens = ScreenCapture.CaptureAll();
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }

        if (screens.Count == 0)
        {
            error = "抓不到屏幕内容";
            return null;
        }

        PInvoke.GetCursorPos(out var cursor);
        var screen = screens.FirstOrDefault(item => item.Bounds.Contains(cursor.X, cursor.Y)) ?? screens[0];
        var target = region ?? screen.Bounds;
        var size = RecorderRules.Even(target.Width, target.Height);
        try
        {
            Directory.CreateDirectory(folder);
            if (!RecorderRules.HasRoom(new DriveInfo(Path.GetPathRoot(folder) ?? "C:\\").AvailableFreeSpace))
            {
                error = "磁盘剩余空间不到 1 GB";
                return null;
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }

        var final = UniquePath(Path.Combine(folder, RecorderRules.FileName(DateTime.Now)));
        var temporary = RecorderRules.TemporaryPath(folder);
        var recorder = new AviRecorder(
            new PixelBounds(target.Left, target.Top, target.Left + size.Width, target.Top + size.Height),
            fps, temporary, final);
        recorder._thread = new Thread(recorder.Run) { IsBackground = true, Name = "kitty-recorder" };
        recorder._thread.Start();
        Log.Info($"record.start {size.Width}x{size.Height} fps={fps} at={target.Left},{target.Top}");
        return recorder;
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path))
        {
            return path;
        }

        var directory = Path.GetDirectoryName(path)!;
        return Path.Combine(directory,
            Path.GetFileNameWithoutExtension(path) + " (" + Guid.NewGuid().ToString("N") + ").avi");
    }

    private void Run()
    {
        var com = CoInitializeEx(IntPtr.Zero, 0);
        AviWriter? writer = null;
        try
        {
            var width = _region.Width & ~1;
            var height = _region.Height & ~1;
            writer = new AviWriter(_temporary, width, height, _fps);
            var clock = Stopwatch.StartNew();
            var frameDuration = 1000.0 / _fps;
            var written = 0;
            while (!_stop.IsSet)
            {
                var elapsed = clock.Elapsed.TotalMilliseconds;
                var target = (int)(elapsed / frameDuration);
                if (target <= written)
                {
                    _stop.Wait(5);
                    continue;
                }

                if (CaptureJpeg(width, height) is { } jpeg)
                {
                    _lastJpeg = jpeg;
                }

                if (_lastJpeg is null)
                {
                    _stop.Wait(10);
                    continue;
                }

                // 落后太多就补重复帧（最多补 5 帧），时间轴按固定帧率走。
                var count = Math.Min(target - written, 5);
                for (var index = 0; index < count; index++)
                {
                    writer.AddFrame(_lastJpeg);
                }

                written += count;
                Frames = written;
                ElapsedMs = (long)elapsed;
                // ponytail: R14（AVI 换成 H.264 MP4 之前）先卡在 1 GB：AVI 1.0 过 1 GB 很多播放器打不开。
                if (new FileInfo(_temporary).Length > 1L * 1024 * 1024 * 1024)
                {
                    Log.Warn("record.size-cap");
                    _stop.Set();
                    break;
                }
                if (!_effectsInjected && written >= 10 &&
                    Environment.GetEnvironmentVariable("KITTY_RECORD_EFFECTS") == "1")
                {
                    _effectsInjected = true;
                    RecordingEffects.InjectDemo(width, height);
                    Log.Info("record.effects-demo");
                }
            }

            writer.Finish();
            File.Move(_temporary, _final, overwrite: true);
            Log.Info($"record.done frames={Frames} ms={ElapsedMs} size={new FileInfo(_final).Length}");
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            Log.Error($"record.failed hr=0x{ex.HResult:X8} {ex.Message}");
            try
            {
                writer?.Finish();
            }
            catch
            {
                // 留半截文件。
            }

            if (File.Exists(_temporary))
            {
                try
                {
                    File.Move(_temporary, _final, overwrite: true);
                }
                catch
                {
                    // 下次再找回。
                }
            }
        }
        finally
        {
            if (com >= 0)
            {
                CoUninitialize();
            }

            _stop.Set();
        }
    }

    private byte[]? CaptureJpeg(int width, int height)
    {
        try
        {
            var screens = ScreenCapture.CaptureAll();
            var screen = screens.FirstOrDefault(item =>
                item.Bounds.Contains(_region.Left, _region.Top) &&
                _region.Right <= item.Bounds.Right && _region.Bottom <= item.Bounds.Bottom);
            if (screen is null)
            {
                return null;
            }

            var local = new PixelBounds(
                _region.Left - screen.Bounds.Left, _region.Top - screen.Bounds.Top,
                _region.Right - screen.Bounds.Left, _region.Bottom - screen.Bounds.Top);
            var bgra = screen.Crop(local);
            var (rings, keycap) = RecordingEffects.Snapshot();
            if ((rings.Count > 0 || keycap is not null) && _effectsLogged < 3)
            {
                _effectsLogged++;
                Log.Info($"record.effects rings={rings.Count} key={keycap?.Text}");
            }

            if (rings.Count > 0 || keycap is not null)
            {
                RecordingOverlay.Render(bgra, width, height, Environment.TickCount64, rings, keycap);
            }

            return JpegEncoder.EncodeAsync(bgra, width, height, 0.7f).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            Log.Warn($"record.capture-failed {ex.GetType().Name}");
            return null;
        }
    }

    public string? Stop()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(15));
        return File.Exists(_final) ? _final : null;
    }

    public void Dispose()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(5));
        _stop.Dispose();
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint concurrencyModel);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();
}
