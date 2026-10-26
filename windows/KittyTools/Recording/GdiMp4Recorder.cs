// 直接录 H.264 MP4（R14）：GDI 抓屏 → Media Foundation SinkWriter（RGB32 → H.264）。
// 声音（PLAN-v6 第 2 批）：默认输出设备回环 + 默认麦克风，两路都转成 48 kHz 双声道 float32，
// 按 QPC 时间戳混进同一个 AudioMixBuffer，再以 16 位 PCM 写进同一个 SinkWriter（AAC 160 kbps）。
// 视频和音频用同一个 QPC 起点，样本时间就是真实时间；中间没有声音的段按静音补齐。
// 失败时返回 null，由 RecordingHost 报错；设置里的「系统声音 / 麦克风」决定建不建音轨。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal sealed unsafe class GdiMp4Recorder : IVideoRecorder
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

    // 音轨的媒体类型（mfapi.h）。
    private static readonly Guid AudioMajor = new("73647561-0000-0010-8000-00AA00389B71");
    private static readonly Guid Aac = new("00001610-0000-0010-8000-00AA00389B71");
    private static readonly Guid Pcm = new("00000001-0000-0010-8000-00AA00389B71");
    private static readonly Guid AudioChannels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    private static readonly Guid AudioSamplesPerSecond = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    private static readonly Guid AudioAvgBytesPerSecond = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    private static readonly Guid AudioBlockAlignment = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    private static readonly Guid AudioBitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    private static readonly Guid AacPayloadType = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    private static readonly Guid AacProfile = new("7632f0e6-9538-4d61-acda-ea29c8c14456");

    private const int AudioBitrateBytes = 20_000; // 160 kbps
    private const long AudioFlushMargin100Ns = 1_500_000; // 提前 150 ms 交出，等两路都到齐
    private const long AacLcProfile = 0x29;

    private readonly PixelBounds _region;
    private readonly int _fps;
    private readonly string _temporary;
    private readonly string _final;
    private readonly bool _systemAudio;
    private readonly bool _microphone;
    private readonly ManualResetEventSlim _stop = new(false);
    private readonly ManualResetEventSlim _ready = new(false);
    private Thread? _thread;
    private string? _startupError;
    private string? _audioNote;
    private bool _microphoneDenied;

    private GdiMp4Recorder(
        PixelBounds region, int fps, string temporary, string final, bool systemAudio, bool microphone)
    {
        _region = region;
        _fps = fps;
        _temporary = temporary;
        _final = final;
        _systemAudio = systemAudio;
        _microphone = microphone;
    }

    /// <summary>麦克风打不开是不是因为没权限（RecordingHost 用它把开关弹回关）。</summary>
    public bool MicrophoneDenied => _microphoneDenied;

    public int Frames { get; private set; }

    public long ElapsedMs { get; private set; }

    public string TemporaryPath => _temporary;

    public string OutputPath => _final;

    /// <summary>写进 MP4 的音频帧数（探针用）。</summary>
    public long AudioFrames { get; private set; }

    public static GdiMp4Recorder? Start(
        int fps, string folder, bool systemAudio, bool microphone, out string? error, out string? note)
        => StartCore(fps, folder, null, systemAudio, microphone, out error, out note);

    public static GdiMp4Recorder? StartRegion(
        PixelBounds region, int fps, string folder, bool systemAudio, bool microphone,
        out string? error, out string? note)
        => StartCore(fps, folder, region, systemAudio, microphone, out error, out note);

    private static GdiMp4Recorder? StartCore(
        int fps, string folder, PixelBounds? region, bool systemAudio, bool microphone,
        out string? error, out string? note)
    {
        error = null;
        note = null;
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
        var recorder = new GdiMp4Recorder(
            new PixelBounds(target.Left, target.Top, target.Left + size.Width, target.Top + size.Height),
            fps, temporary, final, systemAudio, microphone);
        recorder._thread = new Thread(recorder.Run) { IsBackground = true, Name = "kitty-mp4-recorder" };
        recorder._thread.Start();
        Log.Info($"mp4.start {size.Width}x{size.Height} fps={fps} at={target.Left},{target.Top} audio={systemAudio}/{microphone}");
        if (!recorder._ready.Wait(TimeSpan.FromSeconds(10)))
        {
            error = "录制线程没有启动起来";
            recorder._stop.Set();
            recorder._thread.Join(TimeSpan.FromSeconds(3));
            recorder.Dispose();
            return null;
        }

        if (recorder._startupError is not null)
        {
            error = recorder._startupError;
            recorder._stop.Set();
            recorder._thread.Join(TimeSpan.FromSeconds(3));
            recorder._thread = null;
            recorder.Dispose();
            return null;
        }

        note = recorder._audioNote;
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
        AudioCaptureSet? audio = null;
        uint audioStream = 0;
        var hasAudio = false;
        var start100 = 0L;
        var lastVideoTime = 0L;
        var lastVideoDuration = 10_000_000L / _fps;
        delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int> write = null;
        try
        {
            if (CoInitializeEx(IntPtr.Zero, 0) >= 0)
            {
                initializedCom = true;
            }

            if (MFStartup(MfVersion, 0) < 0)
            {
                _startupError = "媒体组件没有启动起来";
                Log.Warn("mp4.mfstartup-failed");
                return;
            }

            mfStarted = true;

            if (_systemAudio || _microphone)
            {
                audio = AudioCaptureSet.Open(_systemAudio, _microphone);
                _audioNote = audio.Note;
                _microphoneDenied = audio.MicrophoneDenied;
            }

            if (MFCreateSinkWriterFromURL(_temporary, IntPtr.Zero, IntPtr.Zero, out writer) < 0)
            {
                _startupError = "没能建 MP4 写入器";
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
                _startupError = "没能建视频流";
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
                _startupError = "视频编码器不接受这个画面格式";
                Log.Warn($"mp4.inputtype 0x{hr:X8}");
                return;
            }

            if (audio is { HasSource: true })
            {
                hasAudio = AddAudioStream(writer, add, setInput, &audioStream, out var audioError);
                if (!hasAudio)
                {
                    AppendAudioNote(audioError ?? "音轨没建起来");
                    Log.Warn("mp4.audio-stream-failed");
                }
            }

            var begin = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)writer)[5];
            if (begin(writer) < 0)
            {
                _startupError = "MP4 写入器没能开始";
                Log.Warn("mp4.begin-failed");
                return;
            }

            start100 = AudioRules.Now100Ns();
            if (hasAudio)
            {
                audio?.Start(start100);
            }

            _ready.Set();

            var frameBytes = width * height * 4;
            var stride = width * 4;
            var started = Environment.TickCount64;
            var interval = 1000.0 / _fps;
            var next = 0.0;
            var frames = 0;
            var last = new byte[frameBytes];
            var hasFrame = false;
            write = (delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int>)(*(void***)writer)[6];
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

                // 先把这一轮采到的声音收进来；录屏循环 33 ms 一轮，WASAPI 缓冲 200 ms，够用。
                audio?.Poll();
                var frame100 = AudioRules.Now100Ns();

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
                    if (hasAudio && audio is not null)
                    {
                        var until = AudioRules.FramesAt(
                            AudioRules.Now100Ns() - AudioFlushMargin100Ns, start100);
                        FlushAudio(writer, write, audioStream, audio, until);
                    }

                    next = (Environment.TickCount64 - started) + interval;
                    continue;
                }

                var (rings, keycap) = RecordingEffects.Snapshot();
                if (rings.Count > 0 || keycap is not null)
                {
                    RecordingOverlay.Render(
                        last, width, height, Environment.TickCount64, rings, keycap);
                }

                // 时间戳用抓这一帧开始时的 QPC，和音频同一个时钟；编码慢不会让声音跑到画面前面。
                var sampleTime = frame100 - start100;
                if (sampleTime <= lastVideoTime)
                {
                    sampleTime = lastVideoTime + 1;
                }

                if (WriteFrame(writer, write, stream, last, width, height, stride, frameBytes,
                        sampleTime, _fps) < 0)
                {
                    break;
                }

                frames++;
                Frames = frames;
                ElapsedMs = Environment.TickCount64 - started;
                lastVideoTime = sampleTime;
                lastVideoDuration = 10_000_000L / _fps;
                next = (Environment.TickCount64 - started) + interval;

                if (hasAudio && audio is not null)
                {
                    var until = AudioRules.FramesAt(
                        AudioRules.Now100Ns() - AudioFlushMargin100Ns, start100);
                    if (FlushAudio(writer, write, audioStream, audio, until) < 0)
                    {
                        hasAudio = false;
                        AppendAudioNote("音轨写到一半失败了");
                        Log.Warn("mp4.audio-write-failed");
                    }
                }
            }

            if (hasAudio && audio is not null)
            {
                audio.Stop();
                // 把停止时还留在 WASAPI 缓冲里的最后几包收完。
                audio.Poll();
                var end = lastVideoTime + lastVideoDuration;
                FlushAudio(writer, write, audioStream, audio, end * AudioRules.SampleRate / 10_000_000);
                Log.Info(
                    $"mp4.audio loopback={audio.LoopbackPackets}@{audio.LoopbackPeak:F3} " +
                    $"mic={audio.MicrophonePackets}@{audio.MicrophonePeak:F3} " +
                    $"frames={AudioFrames} peak={audio.Bus.Peak:F3}");
            }

            if (_audioNote is not null)
            {
                Log.Info($"mp4.audio-note {_audioNote}");
            }
        }
        catch (Exception ex)
        {
            Log.Error("mp4.record-failed", ex);
            if (_startupError is null && !_ready.IsSet)
            {
                _startupError = ex.Message;
            }
        }
        finally
        {
            _ready.Set();
            try
            {
                audio?.Dispose();
            }
            catch (Exception ex)
            {
                Log.Warn($"mp4.audio-dispose {ex.GetType().Name}");
            }

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

    private static bool AddAudioStream(
        IntPtr writer,
        delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint*, int> add,
        delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, int> setInput,
        uint* audioStream, out string? error)
    {
        error = null;
        var outType = NewMediaType();
        try
        {
            SetGuid(outType, MajorType, AudioMajor);
            SetGuid(outType, Subtype, Aac);
            SetUInt32(outType, AudioChannels, AudioRules.Channels);
            SetUInt32(outType, AudioSamplesPerSecond, AudioRules.SampleRate);
            SetUInt32(outType, AudioBitsPerSample, 16);
            SetUInt32(outType, AudioBlockAlignment, AudioRules.PcmBlockAlign);
            SetUInt32(outType, AudioAvgBytesPerSecond, AudioBitrateBytes);
            SetUInt32(outType, AacPayloadType, 0);
            SetUInt32(outType, AacProfile, (uint)AacLcProfile);
            if (add(writer, outType, audioStream) < 0)
            {
                error = "MP4 写入器不接受 AAC 音轨";
                return false;
            }
        }
        finally
        {
            Release(outType);
        }

        var inType = NewMediaType();
        try
        {
            SetGuid(inType, MajorType, AudioMajor);
            SetGuid(inType, Subtype, Pcm);
            SetUInt32(inType, AudioChannels, AudioRules.Channels);
            SetUInt32(inType, AudioSamplesPerSecond, AudioRules.SampleRate);
            SetUInt32(inType, AudioBitsPerSample, 16);
            SetUInt32(inType, AudioBlockAlignment, AudioRules.PcmBlockAlign);
            SetUInt32(inType, AudioAvgBytesPerSecond, AudioRules.PcmBytesPerSecond);
            if (setInput(writer, *audioStream, inType, IntPtr.Zero) < 0)
            {
                error = "AAC 编码器不接受 48 kHz 16 位 PCM";
                return false;
            }
        }
        finally
        {
            Release(inType);
        }

        return true;
    }

    /// <summary>把缓冲里到 <paramref name="untilFrame"/> 的混音写成 10 ms 一包的 PCM；返回写的帧数，负数是失败。</summary>
    private int FlushAudio(
        IntPtr writer, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int> write, uint stream,
        AudioCaptureSet audio, long untilFrame)
    {
        var pcm = new byte[AudioRules.ChunkFrames * AudioRules.PcmBlockAlign];
        var total = 0;
        while (true)
        {
            var frames = audio.Bus.DrainPcm16(untilFrame, pcm, AudioRules.ChunkFrames);
            if (frames <= 0)
            {
                break;
            }

            var startFrame = audio.Bus.Flushed - frames;
            var sampleTime = startFrame * 10_000_000L / AudioRules.SampleRate;
            var result = WriteAudio(writer, write, stream, pcm, frames, sampleTime);
            if (result < 0)
            {
                return -1;
            }

            total += frames;
            AudioFrames += frames;
            if (frames < AudioRules.ChunkFrames)
            {
                break;
            }
        }

        return total;
    }

    private static int WriteAudio(
        IntPtr writer, delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, int> write, uint stream,
        byte[] pcm, int frames, long sampleTime)
    {
        var bytes = frames * AudioRules.PcmBlockAlign;
        if (MFCreateMemoryBuffer((uint)bytes, out var buffer) < 0)
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

            fixed (byte* source = pcm)
            {
                Buffer.MemoryCopy(source, pointer, bytes, bytes);
            }

            var unlock = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)buffer)[4];
            unlock(buffer);
            var setLength = (delegate* unmanaged[Stdcall]<IntPtr, uint, int>)(*(void***)buffer)[6];
            setLength(buffer, (uint)bytes);

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
                setDuration(sample, frames * 10_000_000L / AudioRules.SampleRate);
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

    private void AppendAudioNote(string note)
    {
        _audioNote = string.IsNullOrEmpty(_audioNote) ? note : _audioNote + "；" + note;
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
