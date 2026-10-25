// 直接录 H.264 MP4（R14）：GDI 抓屏 → Media Foundation SinkWriter（RGB32 → H.264，硬件编码）。
// 和 AviRecorder 同一套接口；系统声音仍未接入（只有画面）。
// 失败时返回 null，由 RecordingHost 报错；`Settings.RecordMp4=false` 可退回 MJPEG AVI。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal sealed unsafe class Mp4Recorder : IVideoRecorder
{
    private const uint MfVersion = 0x00020070;
    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00AA00389B71");
    private static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");
    private static readonly Guid Rgb32 = new("00000016-0000-0010-8000-00AA00389B71");
    private static readonly Guid AvgBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");

    private readonly PixelBounds _region;
    private readonly int _fps;
    private readonly string _temporary;
    private readonly string _final;
    private readonly ManualResetEventSlim _stop = new(false);
    private Thread? _thread;

    private Mp4Recorder(PixelBounds region, int fps, string temporary, string final)
    {
        _region = region;
        _fps = fps;
        _temporary = temporary;
        _final = final;
    }

    public int Frames { get; private set; }

    public long ElapsedMs { get; private set; }

    public string TemporaryPath => _temporary;

    public string OutputPath => _final;

    public static Mp4Recorder? Start(int fps, string folder, out string? error)
        => StartCore(fps, folder, null, out error);

    public static Mp4Recorder? StartRegion(PixelBounds region, int fps, string folder, out string? error)
        => StartCore(fps, folder, region, out error);

    private static Mp4Recorder? StartCore(
        int fps, string folder, PixelBounds? region, out string? error)
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
            DriveInfo drive = new(Path.GetPathRoot(folder) ?? "C:\\");
            var bytesPerSecond = (long)size.Width * size.Height * 4 * fps;
            if (drive.AvailableFreeSpace < bytesPerSecond * 10)
            {
                error = "磁盘剩余空间不够";
                return null;
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }

        var name = Path.ChangeExtension(RecorderRules.FileName(DateTime.Now), ".mp4");
        var final = UniquePath(Path.Combine(folder, name));
        var temporary = Path.Combine(folder, "." + Guid.NewGuid().ToString("N") + ".tmp.mp4");
        var recorder = new Mp4Recorder(
            new PixelBounds(target.Left, target.Top, target.Left + size.Width, target.Top + size.Height),
            fps, temporary, final);
        recorder._thread = new Thread(recorder.Run) { IsBackground = true, Name = "kitty-mp4-recorder" };
        recorder._thread.Start();
        Log.Info($"mp4.start {size.Width}x{size.Height} fps={fps} at={target.Left},{target.Top}");
        return recorder;
    }

    public string? Stop()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(20));
        _thread = null;
        return _final;
    }

    public void Dispose() => _stop.Dispose();

    private void Run()
    {
        IntPtr writer = IntPtr.Zero;
        var initializedCom = false;
        var mfStarted = false;
        var width = _region.Width;
        var height = _region.Height;
        try
        {
            if (CoInitializeEx(IntPtr.Zero, 0) >= 0)
            {
                initializedCom = true;
            }

            if (MFStartup(MfVersion, 0) < 0)
            {
                Log.Warn("mp4.mfstartup-failed");
                return;
            }

            mfStarted = true;
            if (MFCreateSinkWriterFromURL(_temporary, IntPtr.Zero, IntPtr.Zero, out writer) < 0)
            {
                Log.Warn("mp4.sinkwriter-failed");
                return;
            }

            uint stream;
            var outType = NewMediaType();
            SetGuid(outType, MajorType, VideoMajor);
            SetGuid(outType, Subtype, H264);
            SetUInt32(outType, AvgBitrate, BitrateFor(width, height, _fps));
            SetUInt64(outType, FrameSize, ((ulong)(uint)width << 32) | (uint)height);
            SetUInt64(outType, FrameRate, ((ulong)_fps << 32) | 1);
            SetUInt32(outType, InterlaceMode, 2);
            var add = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint*, int>)(*(void***)writer)[3];
            var hr = add(writer, outType, &stream);
            Release(outType);
            if (hr < 0)
            {
                Log.Warn($"mp4.addstream 0x{hr:X8}");
                return;
            }

            var inType = NewMediaType();
            SetGuid(inType, MajorType, VideoMajor);
            SetGuid(inType, Subtype, Rgb32);
            SetUInt64(inType, FrameSize, ((ulong)(uint)width << 32) | (uint)height);
            SetUInt64(inType, FrameRate, ((ulong)_fps << 32) | 1);
            SetUInt32(inType, InterlaceMode, 2);
            SetUInt32(inType, DefaultStride, (uint)(-width * 4));
            var setInput = (delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, int>)(*(void***)writer)[4];
            hr = setInput(writer, stream, inType, IntPtr.Zero);
            Release(inType);
            if (hr < 0)
            {
                Log.Warn($"mp4.inputtype 0x{hr:X8}");
                return;
            }

            var begin = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)writer)[5];
            if (begin(writer) < 0)
            {
                Log.Warn("mp4.begin-failed");
                return;
            }

            var frameBytes = width * height * 4;
            var stride = width * 4;
            var started = Environment.TickCount64;
            var interval = 1000.0 / _fps;
            var next = 0.0;
            var frames = 0;
            var last = new byte[frameBytes];
            var hasFrame = false;
            var write = (delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int>)(*(void***)writer)[6];
            while (!_stop.IsSet)
            {
                var elapsed = Environment.TickCount64 - started;
                var wait = (int)(next - elapsed);
                if (wait > 0)
                {
                    if (_stop.Wait(wait))
                    {
                        break;
                    }

                    continue;
                }

                try
                {
                    var screens = ScreenCapture.CaptureAll();
                    var screen = screens.FirstOrDefault(item =>
                        item.Bounds.Contains(_region.Left, _region.Top) &&
                        _region.Right <= item.Bounds.Right && _region.Bottom <= item.Bounds.Bottom);
                    if (screen is not null)
                    {
                        var local = new PixelBounds(
                            _region.Left - screen.Bounds.Left, _region.Top - screen.Bounds.Top,
                            _region.Right - screen.Bounds.Left, _region.Bottom - screen.Bounds.Top);
                        last = screen.Crop(local);
                        hasFrame = true;
                    }
                }
                catch
                {
                    // 抓失败就重复上一帧。
                }

                if (!hasFrame)
                {
                    next += interval;
                    continue;
                }

                var (rings, keycap) = RecordingEffects.Snapshot();
                if (rings.Count > 0 || keycap is not null)
                {
                    RecordingOverlay.Render(
                        last, width, height, Environment.TickCount64, rings, keycap);
                }

                var sampleTime = frames * 10_000_000L / _fps;
                if (WriteFrame(writer, write, stream, last, width, height, stride, frameBytes,
                        sampleTime, _fps) < 0)
                {
                    break;
                }

                frames++;
                Frames = frames;
                ElapsedMs = Environment.TickCount64 - started;
                next += interval;
            }
        }
        catch (Exception ex)
        {
            Log.Error("mp4.record-failed", ex);
        }
        finally
        {
            if (writer != IntPtr.Zero)
            {
                var finalize = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)writer)[11];
                var hr = finalize(writer);
                Release(writer);
                Log.Info($"mp4.finalize hr=0x{hr:X8}");
            }

            if (mfStarted)
            {
                MFShutdown();
            }

            if (initializedCom)
            {
                CoUninitialize();
            }

            try
            {
                if (File.Exists(_temporary))
                {
                    File.Move(_temporary, _final, overwrite: true);
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"mp4.move-failed {ex.GetType().Name}");
            }

            Log.Info($"mp4.done frames={Frames} ms={ElapsedMs} size={(File.Exists(_final) ? new FileInfo(_final).Length : 0)}");
        }
    }

    private static int WriteFrame(
        IntPtr writer, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int> write, uint stream,
        byte[] bgra, int width, int height, int stride, int frameBytes, long sampleTime, int fps)
    {
        if (MFCreateMemoryBuffer((uint)frameBytes, out var buffer) < 0)
        {
            return -1;
        }

        try
        {
            var lockBuffer = (delegate* unmanaged[Stdcall]<IntPtr, byte**, uint*, uint*, int>)(*(void***)buffer)[3];
            byte* pointer;
            uint max;
            uint current;
            if (lockBuffer(buffer, &pointer, &max, &current) < 0)
            {
                return -1;
            }

            fixed (byte* source = bgra)
            {
                for (var row = 0; row < height; row++)
                {
                    Buffer.MemoryCopy(
                        source + (long)(height - 1 - row) * stride,
                        pointer + (long)row * stride,
                        stride, stride);
                }
            }

            var unlock = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)buffer)[4];
            unlock(buffer);
            var setLength = (delegate* unmanaged[Stdcall]<IntPtr, uint, int>)(*(void***)buffer)[6];
            setLength(buffer, (uint)frameBytes);

            if (MFCreateSample(out var sample) < 0)
            {
                return -1;
            }

            try
            {
                var addBuffer = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)(*(void***)sample)[42];
                addBuffer(sample, buffer);
                var setTime = (delegate* unmanaged[Stdcall]<IntPtr, long, int>)(*(void***)sample)[36];
                setTime(sample, sampleTime);
                var setDuration = (delegate* unmanaged[Stdcall]<IntPtr, long, int>)(*(void***)sample)[38];
                setDuration(sample, 10_000_000L / fps);
                return write(writer, stream, sample);
            }
            finally
            {
                Release(sample);
            }
        }
        finally
        {
            Release(buffer);
        }
    }

    private static uint BitrateFor(int width, int height, int fps)
    {
        var pixels = (double)width * height;
        var bitrate = pixels * fps * 0.12;
        return (uint)Math.Clamp(bitrate, 2_000_000, 24_000_000);
    }

    private static IntPtr NewMediaType()
    {
        MFCreateMediaType(out var type);
        return type;
    }

    private static void SetGuid(IntPtr type, Guid key, Guid value)
    {
        var set = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, Guid*, int>)(*(void***)type)[24];
        set(type, &key, &value);
    }

    private static void SetUInt32(IntPtr type, Guid key, uint value)
    {
        var set = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, uint, int>)(*(void***)type)[21];
        set(type, &key, value);
    }

    private static void SetUInt64(IntPtr type, Guid key, ulong value)
    {
        var set = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, ulong, int>)(*(void***)type)[22];
        set(type, &key, value);
    }

    private static void Release(IntPtr pointer)
    {
        var release = (delegate* unmanaged[Stdcall]<IntPtr, uint>)(*(void***)pointer)[2];
        release(pointer);
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path))
        {
            return path;
        }

        var directory = Path.GetDirectoryName(path)!;
        var name = Path.GetFileNameWithoutExtension(path);
        for (var index = 2; index < 1000; index++)
        {
            var candidate = Path.Combine(directory, $"{name} ({index}).mp4");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }

        return path;
    }

    [DllImport("mfplat.dll")]
    private static extern int MFStartup(uint version, uint flags);

    [DllImport("mfplat.dll")]
    private static extern int MFShutdown();

    [DllImport("mfplat.dll")]
    private static extern int MFCreateMediaType(out IntPtr type);

    [DllImport("mfplat.dll")]
    private static extern int MFCreateMemoryBuffer(uint maxLength, out IntPtr buffer);

    [DllImport("mfplat.dll")]
    private static extern int MFCreateSample(out IntPtr sample);

    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)]
    private static extern int MFCreateSinkWriterFromURL(
        string url, IntPtr byteStream, IntPtr attributes, out IntPtr writer);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint flags);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();
}
