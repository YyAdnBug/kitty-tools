// GPU 录屏（PLAN-v6 第 1 批）：Windows.Graphics.Capture 抓屏 → D3D11 纹理 → Media Foundation SinkWriter
// （DXGI 设备管理器 + 硬件 H.264 编码，分段 MP4）。选区用 CopySubresourceRegion 裁，纹理池复用，不每帧新建。
// 时间戳用 Direct3D11CaptureFrame.SystemRelativeTime（QPC）；超过 1 秒没新帧就补上一帧，帧率是上限。
// 失败返回 null，由 RecordingHost 退 GDI 那条路（GdiMp4Recorder）。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Direct3D;
using Windows.Win32.Graphics.Direct3D11;
using Windows.Win32.Graphics.Dxgi;
using Windows.Win32.Graphics.Dxgi.Common;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.Media.MediaFoundation;
using Windows.Win32.System.Com;
using Windows.Win32.System.WinRT;

namespace KittyTools;

internal sealed unsafe class WgcRecorder : IVideoRecorder
{
    private const uint MfVersion = 0x00020070;
    private const int RingSize = 2;

    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00AA00389B71");
    private static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");
    private static readonly Guid Argb32 = new("00000015-0000-0010-8000-00AA00389B71");
    private static readonly Guid AvgBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid Mpeg2Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    private static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
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
    private const uint AacLcProfile = 0x29;
    private static readonly Guid SinkWriterD3DManager = new("ec822da2-e1e9-4b29-a0d8-563c719f5269");
    private static readonly Guid EnableHardwareTransforms = new("a634a91c-822b-41b9-a494-4de4643612b0");
    private static readonly Guid TranscodeContainerType = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    private static readonly Guid Mpeg4Container = new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a");
    // REVIEW R23：录制写分段 MP4（moov 及时写盘，闪退也能放），停止时再无损重封装成普通 MP4。
    private static readonly Guid Fmp4Container = new("9ba876f1-419f-4b77-a1e0-35959d9d4004");

    private readonly PixelBounds _region;
    private readonly IntPtr _window;
    private readonly int _fps;
    private readonly bool _systemAudio;
    private readonly bool _microphone;
    private readonly string _temporary;
    private readonly string _final;
    private readonly ManualResetEventSlim _stop = new(false);
    private readonly AutoResetEvent _frameReady = new(false);
    private readonly object _gate = new();
    private PendingFrame? _latest;
    private readonly List<IntPtr> _free = new();
    private readonly Dictionary<IntPtr, IntPtr> _renderTargets = new();
    private readonly ManualResetEventSlim _ready = new(false);
    private Thread? _thread;
    private D3DContext? _context;
    private WgcEffects? _effects;
    private WgcScaler? _scaler;
    private bool _effectsTried;
    private int _originX;
    private int _originY;
    private string? _startupError;
    private string? _note;
    private int _outputWidth;
    private int _outputHeight;
    private int _cropLeft;
    private int _cropTop;
    private int _sourceWidth;
    private int _sourceHeight;
    private TimeSpan _startCpu;
    private long _startWall;
    private long _startWorkingSet;
    private int _nextStatMs = 10_000;
    private int _arrivedFrames;
    private int _acceptedFrames;
    private long _writeTicks;
    private long _copyTicks;
    private long _qiTicks;
    private AudioCaptureSet? _audio;
    private uint _audioStream;
    private bool _hasAudio;
    private long _audioFrames;
    private bool _microphoneDenied;
    private long _start100;
    private volatile bool _closed;

    private WgcRecorder(
        PixelBounds region, IntPtr window, int fps, bool systemAudio, bool microphone,
        string temporary, string final)
    {
        _region = region;
        _window = window;
        _fps = Math.Clamp(fps, RecorderRules.MinFps, RecorderRules.MaxFps);
        _systemAudio = systemAudio;
        _microphone = microphone;
        _temporary = temporary;
        _final = final;
    }

    public int Frames { get; private set; }

    public long ElapsedMs { get; private set; }

    public string TemporaryPath => _temporary;

    public string OutputPath => _final;

    public string? Error => _startupError;

    public string? Note => _note;

    public string? LiveNote => _audio?.Note ?? _note;

    public bool MicrophoneDenied => _microphoneDenied;

    private sealed class PendingFrame
    {
        public ID3D11Texture2D* Source;
        public Direct3D11CaptureFrame? Frame;
        public long Time;
        public int Width;
        public int Height;
    }

    public static WgcRecorder? Start(
        int fps, string folder, bool systemAudio, bool microphone, out string? error, out string? note)
        => StartCore(fps, folder, null, IntPtr.Zero, systemAudio, microphone, out error, out note);

    public static WgcRecorder? StartRegion(
        PixelBounds region, int fps, string folder, bool systemAudio, bool microphone,
        out string? error, out string? note)
        => StartCore(fps, folder, region, IntPtr.Zero, systemAudio, microphone, out error, out note);

    /// <summary>录一个窗口本身：窗口挪动、被挡住都照录。</summary>
    public static WgcRecorder? StartWindow(
        IntPtr hwnd, int fps, string folder, bool systemAudio, bool microphone,
        out string? error, out string? note)
        => StartCore(fps, folder, null, hwnd, systemAudio, microphone, out error, out note);

    private static WgcRecorder? StartCore(
        int fps, string folder, PixelBounds? region, IntPtr window,
        bool systemAudio, bool microphone, out string? error, out string? note)
    {
        error = null;
        note = null;
        if (window == IntPtr.Zero && region is null)
        {
            error = "没有选择录制范围";
            return null;
        }

        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }

        var name = Path.ChangeExtension(RecorderRules.FileName(DateTime.Now), ".mp4");
        var final = UniquePath(Path.Combine(folder, name));
        var temporary = Path.Combine(folder, "." + Guid.NewGuid().ToString("N") + ".tmp.mp4");
        var recorder = new WgcRecorder(region ?? default, window, fps, systemAudio, microphone, temporary, final);
        recorder._thread = new Thread(recorder.Run) { IsBackground = true, Name = "kitty-wgc-recorder" };
        recorder._thread.Start();
        if (!recorder._ready.Wait(TimeSpan.FromSeconds(12)))
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

        note = recorder._note;
        return recorder;
    }

    public string? Stop()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(20));
        _thread = null;
        return _final;
    }

    public void Dispose()
    {
        _closed = true;
        _stop.Dispose();
        _frameReady.Dispose();
        _ready.Dispose();
    }

    private void Run()
    {
        D3DContext? context = null;
        GraphicsCaptureItem? item = null;
        Direct3D11CaptureFramePool? pool = null;
        GraphicsCaptureSession? session = null;
        IntPtr writer = IntPtr.Zero;
        IMFDXGIDeviceManager* manager = null;
        IMFAttributes* attributes = null;
        var initializedCom = false;
        var mfStarted = false;
        try
        {
            var com = PInvoke.CoInitializeEx(COINIT.COINIT_MULTITHREADED);
            initializedCom = !com.Failed;
            if (PInvoke.MFStartup(MfVersion, 0).Failed)
            {
                _startupError = "媒体组件没有启动起来";
                return;
            }

            mfStarted = true;
            context = D3DContext.Create(out var d3dError);
            _context = context;
            if (context is null)
            {
                _startupError = "没建起 D3D 设备（" + d3dError + "）";
                return;
            }

            item = _window != IntPtr.Zero
                ? WgcInterop.ForWindow(_window)
                : WgcInterop.ForMonitor(MonitorHandle());
            if (item is null)
            {
                _startupError = "抓不到这块屏幕";
                return;
            }

            _sourceWidth = item.Size.Width;
            _sourceHeight = item.Size.Height;
            if (_sourceWidth < 2 || _sourceHeight < 2)
            {
                _startupError = "录制范围太小";
                return;
            }

            if (_window != IntPtr.Zero)
            {
                var size = RecordingPipeline.EvenSize(_sourceWidth, _sourceHeight);
                _outputWidth = size.Width;
                _outputHeight = size.Height;
                RECT windowRect;
                if (PInvoke.GetWindowRect(new HWND(_window), &windowRect))
                {
                    _originX = windowRect.left;
                    _originY = windowRect.top;
                }
            }
            else
            {
                var info = MonitorInfo();
                var crop = RecordingPipeline.Crop(
                    _region.Left, _region.Top, _region.Right, _region.Bottom,
                    info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom);
                if (crop is null)
                {
                    _startupError = "选区不在屏幕里";
                    return;
                }

                _cropLeft = crop.Value.Left;
                _cropTop = crop.Value.Top;
                _originX = info.rcMonitor.left + _cropLeft;
                _originY = info.rcMonitor.top + _cropTop;
                var size = RecordingPipeline.EvenSize(
                    crop.Value.Right - crop.Value.Left, crop.Value.Bottom - crop.Value.Top);
                _outputWidth = size.Width;
                _outputHeight = size.Height;
            }

            // 纹理池：每帧先拷到一张自己的纹理上，编码线程慢慢写，不占着 WGC 的帧。
            for (var index = 0; index < RingSize; index++)
            {
                var texture = context.CreateTexture(_outputWidth, _outputHeight, renderTarget: true);
                if (texture is null)
                {
                    _startupError = "建不出录制纹理";
                    return;
                }

                _free.Add((IntPtr)texture);
            }

            var first = (ID3D11Texture2D*)_free[0];
            D3D11_TEXTURE2D_DESC ringDesc;
            first->GetDesc(&ringDesc);
            Log.Info($"wgc.texture {ringDesc.Width}x{ringDesc.Height} fmt={ringDesc.Format} bind={ringDesc.BindFlags} usage={ringDesc.Usage}");

            if (_systemAudio || _microphone)
            {
                _audio = AudioCaptureSet.Open(_systemAudio, _microphone);
                _note = _audio.Note;
                _microphoneDenied = _audio.MicrophoneDenied;
            }

            if (!CreateSinkWriter(context, &writer, &manager, &attributes, out var writerError))
            {
                _startupError = writerError ?? "没建起 MP4 写入器";
                return;
            }

            if (_audio is { HasSource: true })
            {
                uint audioStream;
                _hasAudio = AddAudioStream(writer, &audioStream, out var audioError);
                _audioStream = audioStream;
                if (!_hasAudio)
                {
                    AppendNote(audioError ?? "音轨没建起来");
                    Log.Warn("wgc.audio-stream-failed");
                }
            }

            ((IMFSinkWriter*)writer)->BeginWriting();

            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                context.WinRt, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized,
                4, item.Size);
            pool.FrameArrived += OnFrameArrived;
            session = pool.CreateCaptureSession(item);
            try
            {
                session.IsCursorCaptureEnabled = true;
            }
            catch
            {
                // 老系统没有这个属性。
            }

            try
            {
                session.IsBorderRequired = false;
            }
            catch
            {
                // 同上。
            }


            _start100 = AudioRules.Now100Ns();
            session.StartCapture();
            if (_hasAudio)
            {
                _audio?.Start(_start100);
            }

            _ready.Set();
            var process = Process.GetCurrentProcess();
            _startCpu = process.TotalProcessorTime;
            _startWall = Stopwatch.GetTimestamp();
            _startWorkingSet = process.WorkingSet64;

            var interval = 10_000_000L / _fps;
            var nextWrite = 0L;
            ID3D11Texture2D* lastTexture = null;
            while (!_stop.IsSet)
            {
                var now = AudioRules.Now100Ns() - _start100;
                _audio?.Poll();
                PendingFrame? latest = null;
                lock (_gate)
                {
                    if (_latest is not null && now >= nextWrite)
                    {
                        latest = _latest;
                        _latest = null;
                    }
                }

                if (latest is not null)
                {
                    var ring = CopyPending(latest);
                    ReleasePending(latest);
                    if (ring is not null)
                    {
                        if (lastTexture is not null)
                        {
                            ReturnTexture(lastTexture);
                            lastTexture = null;
                        }

                        var time = Math.Max(0, nextWrite);
                        var writeStart = Stopwatch.GetTimestamp();
                        ApplyEffects(ring);
                        var written = WriteFrame(writer, ring, time, interval);
                        _writeTicks += Stopwatch.GetTimestamp() - writeStart;
                        if (!written)
                        {
                            ReturnTexture(ring);
                            break;
                        }

                        lastTexture = ring;
                        nextWrite = time + interval;
                        Frames++;
                        ElapsedMs = Math.Max(ElapsedMs, time / 10_000);
                    }
                }
                else if (lastTexture is not null && now >= nextWrite)
                {
                    // 屏幕没变 / 新帧还没到：按 30 fps 的节拍补上一帧，时长才准。
                    var time = nextWrite;
                    if (!WriteFrame(writer, lastTexture, time, interval))
                    {
                        _note = "编码器停止接收画面";
                        break;
                    }

                    nextWrite = time + interval;
                    Frames++;
                    ElapsedMs = Math.Max(ElapsedMs, time / 10_000);
                }
                else
                {
                    _frameReady.WaitOne(5);
                }

                // 编码偶尔慢一拍：落后超过 5 帧就别追赶了，从现在接着写。
                if (nextWrite < now - interval * 5)
                {
                    nextWrite = now;
                }

                if (_hasAudio && _audio is not null)
                {
                    FlushAudio(writer, _audioStream, AudioRules.FramesAt(now - AudioFlushMargin100Ns, 0));
                }

                var elapsed = Math.Max(0, now / 10_000);
                if (elapsed >= _nextStatMs)
                {
                    _nextStatMs = (int)(elapsed / 10_000 + 1) * 10_000;
                    Log.Info($"wgc.mem t={elapsed / 1000}s ws={process.WorkingSet64 / (1024 * 1024)}MB frames={Frames} arrived={_arrivedFrames} accepted={_acceptedFrames}");
                }
            }

            if (lastTexture is not null)
            {
                ReturnTexture(lastTexture);
                lastTexture = null;
            }

            if (_hasAudio && _audio is not null)
            {
                _audio.Stop();
                _audio.Poll();
                FlushAudio(writer, _audioStream, nextWrite * AudioRules.SampleRate / 10_000_000);
            }

            if (_note is not null)
            {
                Log.Info($"wgc.audio-note {_note}");
            }
        }
        catch (Exception ex)
        {
            Log.Error("wgc.record-failed", ex);
            if (_startupError is null && !_ready.IsSet)
            {
                _startupError = ex.Message;
            }
        }
        finally
        {
            _closed = true;
            _ready.Set();
            try
            {
                session?.Dispose();
            }
            catch
            {
                // 会话已经没了。
            }

            try
            {
                pool?.Dispose();
            }
            catch
            {
                // 同上。
            }

            item = null;
            foreach (var texture in _free)
            {
                ((ID3D11Texture2D*)texture)->Release();
            }

            _free.Clear();
            foreach (var view in _renderTargets.Values)
            {
                ((ID3D11RenderTargetView*)view)->Release();
            }

            _renderTargets.Clear();
            lock (_gate)
            {
                if (_latest is not null)
                {
                    ReleasePending(_latest);
                    _latest = null;
                }
            }

            if (writer != IntPtr.Zero)
            {
                try
                {
                    ((IMFSinkWriter*)writer)->Finalize();
                }
                catch (Exception ex)
                {
                    Log.Warn($"wgc.finalize-failed 0x{ex.HResult:X8}");
                }

                ((IMFSinkWriter*)writer)->Release();
            }

            if (attributes is not null)
            {
                attributes->Release();
            }

            if (manager is not null)
            {
                manager->Release();
            }

            _context = null;
            try
            {
                _scaler?.Dispose();
                _scaler = null;
                _effects?.Dispose();
            }
            catch
            {
                // 画布已经没了。
            }

            _effects = null;
            context?.Dispose();
            if (mfStarted)
            {
                PInvoke.MFShutdown();
            }

            if (initializedCom)
            {
                PInvoke.CoUninitialize();
            }

            try
            {
                if (File.Exists(_temporary))
                {
                    // 先写 .remux 临时名；超时 / 失败时不会在 _final 留一个 80 字节壳。
                    var staging = _final + ".remux.mp4";
                    if (Mp4Remux.TryRemuxWithTimeout(_temporary, staging))
                    {
                        File.Move(staging, _final, overwrite: true);
                        File.Delete(_temporary);
                    }
                    else
                    {
                        try
                        {
                            if (File.Exists(staging))
                            {
                                File.Delete(staging);
                            }
                        }
                        catch
                        {
                            // 卡住的线程还占着就先留着。
                        }

                        // 重封装失败：分段 MP4 原样改名，至少能放（R23 的退路）。
                        File.Move(_temporary, _final, overwrite: true);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"wgc.move-failed {ex.GetType().Name}");
            }

            Log.Info($"wgc.done frames={Frames} ms={ElapsedMs} size={(File.Exists(_final) ? new FileInfo(_final).Length : 0)}");
            if (_audio is not null)
            {
                Log.Info(
                    $"wgc.audio frames={_audioFrames} loop={_audio.LoopbackPackets}@{_audio.LoopbackPeak:F3} " +
                    $"mic={_audio.MicrophonePackets}@{_audio.MicrophonePeak:F3} note={_audio.Note}");
            }
            if (_startWall != 0)
            {
                var process = Process.GetCurrentProcess();
                var wall = (Stopwatch.GetTimestamp() - _startWall) / (double)Stopwatch.Frequency;
                var cpu = (process.TotalProcessorTime - _startCpu).TotalSeconds;
                var cpuPercent = wall <= 0 ? 0 : cpu / wall * 100;
                var memory = (process.WorkingSet64 - _startWorkingSet) / (1024 * 1024);
                Log.Info($"wgc.stats cpu={cpuPercent:F1}%single memDelta={memory}MB ws={process.WorkingSet64 / (1024 * 1024)}MB wall={wall:F1}s arrived={_arrivedFrames} accepted={_acceptedFrames} writeMs={_writeTicks * 1000.0 / Stopwatch.Frequency:F0} copyMs={_copyTicks * 1000.0 / Stopwatch.Frequency:F0} qiMs={_qiTicks * 1000.0 / Stopwatch.Frequency:F0}");
            }
        }
    }

    private IntPtr MonitorHandle()
    {
        var monitor = PInvoke.MonitorFromPoint(
            new System.Drawing.Point(_region.Left, _region.Top), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        return (IntPtr)monitor.Value;
    }

    private MONITORINFO MonitorInfo()
    {
        var monitor = PInvoke.MonitorFromPoint(
            new System.Drawing.Point(_region.Left, _region.Top), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        PInvoke.GetMonitorInfo(monitor, &info);
        return info;
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        if (_closed)
        {
            return;
        }

        Direct3D11CaptureFrame? frame = null;
        ID3D11Texture2D* texture = null;
        try
        {
            frame = sender.TryGetNextFrame();
            if (frame is null)
            {
                return;
            }

            System.Threading.Interlocked.Increment(ref _arrivedFrames);
            var content = frame.ContentSize;

            if (content.Width != _sourceWidth || content.Height != _sourceHeight)
            {
                if (_window == IntPtr.Zero)
                {
                    _note = "屏幕尺寸变了，录制已停止";
                    _stop.Set();
                    return;
                }

                // R29：录单个窗口时拖边不停止；输出尺寸不变，后面按新内容居中裁 / 补黑边。
                _sourceWidth = content.Width;
                _sourceHeight = content.Height;
                _cropLeft = 0;
                _cropTop = 0;
                _note = "窗口尺寸变了";
            }

            var time = frame.SystemRelativeTime.Ticks;
            // frame.Surface 每取一次就是一个新的 WinRT 包装，拿着这张纹理（连带整个 D3D 设备）：不 Dispose 的话要等 GC
            // 终结才放，录屏时几乎不 GC，停止后设备就销毁不掉（REVIEW R27：每录一次留下一个设备）。
            using var surface = frame.Surface;
            lock (_gate)
            {
                if (_closed)
                {
                    // 正在收尾（finally 已经放过 _latest 了）：迟到的这一帧自己放掉，不再存进去。
                    return;
                }

                var qiStart = Stopwatch.GetTimestamp();
                texture = WgcInterop.TextureOf(surface);
                _qiTicks += Stopwatch.GetTimestamp() - qiStart;
                if (_latest is not null)
                {
                    ReleasePending(_latest);
                }

                _latest = new PendingFrame
                {
                    Source = texture,
                    Frame = frame,
                    Time = time,
                    Width = content.Width,
                    Height = content.Height,
                };
                _acceptedFrames++;
            }

            // 纹理和帧的所有权交给编码线程；这里不再动它们。
            texture = null;
            frame = null;
            _frameReady.Set();
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.frame-failed 0x{ex.HResult:X8}");
        }
        finally
        {
            if (texture is not null)
            {
                texture->Release();
            }

            frame?.Dispose();
        }
    }

    /// <summary>把一帧从 WGC 的纹理拷进纹理池里的一张；没有空闲纹理就丢这一帧。</summary>
    private ID3D11Texture2D* CopyPending(PendingFrame pending)
    {
        ID3D11Texture2D* target;
        lock (_gate)
        {
            if (_free.Count == 0)
            {
                return null;
            }

            target = (ID3D11Texture2D*)_free[^1];
            _free.RemoveAt(_free.Count - 1);
        }

        int sourceLeft;
        int sourceTop;
        int destinationLeft;
        int destinationTop;
        int copyWidth;
        int copyHeight;
        if (_window == IntPtr.Zero)
        {
            // 选区：从屏幕帧里裁固定的 cropLeft / cropTop，不做居中。
            sourceLeft = _cropLeft;
            sourceTop = _cropTop;
            copyWidth = Math.Min(_outputWidth, pending.Width - sourceLeft);
            copyHeight = Math.Min(_outputHeight, pending.Height - sourceTop);
            destinationLeft = 0;
            destinationTop = 0;
        }
        else
        {
            // 窗口：窗口尺寸变了就按新内容居中裁 / 补黑边，输出尺寸不变（R29）。
            copyWidth = Math.Min(_outputWidth, pending.Width);
            copyHeight = Math.Min(_outputHeight, pending.Height);
            sourceLeft = Math.Max(0, (pending.Width - copyWidth) / 2);
            sourceTop = Math.Max(0, (pending.Height - copyHeight) / 2);
            destinationLeft = Math.Max(0, (_outputWidth - copyWidth) / 2);
            destinationTop = Math.Max(0, (_outputHeight - copyHeight) / 2);
        }

        if (copyWidth < 2 || copyHeight < 2)
        {
            ReturnTexture(target);
            _stop.Set();
            _note = "裁不出选区";
            return null;
        }

        // R29：窗口尺寸变了就等比缩放 + 居中补黑；缩放器起不来再退回居中裁。
        if (_window != IntPtr.Zero &&
            (pending.Width != _outputWidth || pending.Height != _outputHeight))
        {
            _scaler ??= WgcScaler.TryCreate(_context!);
            var scaleStart = Stopwatch.GetTimestamp();
            if (_scaler?.Draw(
                    pending.Source, pending.Width, pending.Height,
                    target, _outputWidth, _outputHeight) == true)
            {
                _copyTicks += Stopwatch.GetTimestamp() - scaleStart;
                return target;
            }
        }
        var box = new D3D11_BOX
        {
            left = (uint)sourceLeft,
            top = (uint)sourceTop,
            front = 0,
            right = (uint)(sourceLeft + copyWidth),
            bottom = (uint)(sourceTop + copyHeight),
            back = 1,
        };
        var copyStart = Stopwatch.GetTimestamp();
        if (_window != IntPtr.Zero || copyWidth < _outputWidth || copyHeight < _outputHeight)
        {
            ClearTarget(target);
        }
        _context!.Context->CopySubresourceRegion(
            (ID3D11Resource*)target, 0, (uint)destinationLeft, (uint)destinationTop, 0,
            (ID3D11Resource*)pending.Source, 0, box);
        _copyTicks += Stopwatch.GetTimestamp() - copyStart;
        return target;
    }

    /// <summary>窗口变小 / 变大时四周补黑；目标纹理是 render target。</summary>
    private void ClearTarget(ID3D11Texture2D* target)
    {
        var key = (IntPtr)target;
        if (!_renderTargets.TryGetValue(key, out var viewValue))
        {
            ID3D11RenderTargetView* created = null;
            _context!.Device->CreateRenderTargetView((ID3D11Resource*)target, null, &created);
            viewValue = (IntPtr)created;
            if (created is not null)
            {
                _renderTargets[key] = viewValue;
            }
        }

        var view = (ID3D11RenderTargetView*)viewValue;
        if (view is not null)
        {
            var black = stackalloc float[4];
            _context!.Context->ClearRenderTargetView(view, black);
        }
    }

    private static void ReleasePending(PendingFrame pending)
    {
        if (pending.Source is not null)
        {
            pending.Source->Release();
            pending.Source = null;
        }

        pending.Frame?.Dispose();
        pending.Frame = null;
    }

    private void ApplyEffects(ID3D11Texture2D* texture)
    {
        var (rings, keycap) = RecordingEffects.Snapshot();
        if (rings.Count == 0 && keycap is null)
        {
            return;
        }

        if (_effects is null && !_effectsTried)
        {
            _effectsTried = true;
            _effects = _context is null ? null : WgcEffects.TryCreate(_context);
        }

        _effects?.Draw(
            texture, _outputWidth, _outputHeight, _originX, _originY, rings, keycap,
            Environment.TickCount64);
    }

    private bool AddAudioStream(IntPtr writer, uint* audioStream, out string? error)
    {
        error = null;
        IMFMediaType* outType = null;
        try
        {
            PInvoke.MFCreateMediaType(&outType).ThrowOnFailure();
            outType->SetGUID(MajorType, AudioMajor);
            outType->SetGUID(Subtype, Aac);
            outType->SetUINT32(AudioChannels, AudioRules.Channels);
            outType->SetUINT32(AudioSamplesPerSecond, AudioRules.SampleRate);
            outType->SetUINT32(AudioBitsPerSample, 16);
            outType->SetUINT32(AudioBlockAlignment, AudioRules.PcmBlockAlign);
            outType->SetUINT32(AudioAvgBytesPerSecond, AudioBitrateBytes);
            outType->SetUINT32(AacPayloadType, 0);
            outType->SetUINT32(AacProfile, AacLcProfile);
            ((IMFSinkWriter*)writer)->AddStream(outType, audioStream);
        }
        catch (Exception ex)
        {
            error = $"MP4 写入器不接受 AAC 音轨（0x{ex.HResult:X8}）";
            return false;
        }
        finally
        {
            if (outType is not null)
            {
                outType->Release();
            }
        }

        IMFMediaType* inType = null;
        try
        {
            PInvoke.MFCreateMediaType(&inType).ThrowOnFailure();
            inType->SetGUID(MajorType, AudioMajor);
            inType->SetGUID(Subtype, Pcm);
            inType->SetUINT32(AudioChannels, AudioRules.Channels);
            inType->SetUINT32(AudioSamplesPerSecond, AudioRules.SampleRate);
            inType->SetUINT32(AudioBitsPerSample, 16);
            inType->SetUINT32(AudioBlockAlignment, AudioRules.PcmBlockAlign);
            inType->SetUINT32(AudioAvgBytesPerSecond, AudioRules.PcmBytesPerSecond);
            ((IMFSinkWriter*)writer)->SetInputMediaType(*audioStream, inType, null);
            return true;
        }
        catch (Exception ex)
        {
            error = $"AAC 编码器不接受 48 kHz 16 位 PCM（0x{ex.HResult:X8}）";
            return false;
        }
        finally
        {
            if (inType is not null)
            {
                inType->Release();
            }
        }
    }

    /// <summary>把缓冲里到 <paramref name="untilFrame"/> 的混音写成 10 ms 一包的 PCM。</summary>
    private void FlushAudio(IntPtr writer, uint stream, long untilFrame)
    {
        if (_audio is null)
        {
            return;
        }

        var pcm = new byte[AudioRules.ChunkFrames * AudioRules.PcmBlockAlign];
        while (true)
        {
            var frames = _audio.Bus.DrainPcm16(untilFrame, pcm, AudioRules.ChunkFrames);
            if (frames <= 0)
            {
                break;
            }

            var startFrame = _audio.Bus.Flushed - frames;
            var sampleTime = startFrame * 10_000_000L / AudioRules.SampleRate;
            if (!WriteAudio(writer, stream, pcm, frames, sampleTime))
            {
                AppendNote("音轨写到一半失败了");
                Log.Warn("wgc.audio-write-failed");
                _hasAudio = false;
                return;
            }

            _audioFrames += frames;
            if (frames < AudioRules.ChunkFrames)
            {
                break;
            }
        }
    }

    private static bool WriteAudio(
        IntPtr writer, uint stream, byte[] pcm, int frames, long sampleTime)
    {
        IMFMediaBuffer* buffer = null;
        IMFSample* sample = null;
        try
        {
            var bytes = (uint)(frames * AudioRules.PcmBlockAlign);
            if (PInvoke.MFCreateMemoryBuffer(bytes, &buffer).Failed)
            {
                return false;
            }

            byte* pointer;
            uint max;
            uint current;
            buffer->Lock(&pointer, &max, &current);
            fixed (byte* source = pcm)
            {
                Buffer.MemoryCopy(source, pointer, bytes, bytes);
            }

            buffer->Unlock();
            buffer->SetCurrentLength(bytes);
            if (PInvoke.MFCreateSample(&sample).Failed)
            {
                return false;
            }

            sample->AddBuffer(buffer);
            sample->SetSampleTime(sampleTime);
            sample->SetSampleDuration(frames * 10_000_000L / AudioRules.SampleRate);
            ((IMFSinkWriter*)writer)->WriteSample(stream, sample);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.audio-sample 0x{ex.HResult:X8}");
            return false;
        }
        finally
        {
            if (sample is not null)
            {
                sample->Release();
            }

            if (buffer is not null)
            {
                buffer->Release();
            }
        }
    }

    private void AppendNote(string note)
    {
        _note = string.IsNullOrEmpty(_note) ? note : _note + "；" + note;
    }

    private void ReturnTexture(ID3D11Texture2D* texture)
    {
        lock (_gate)
        {
            _free.Add((IntPtr)texture);
        }
    }

    private bool WriteFrame(IntPtr writer, ID3D11Texture2D* texture, long time, long duration)
    {
        IMFMediaBuffer* buffer = null;
        IMFSample* sample = null;
        try
        {
            var iid = typeof(ID3D11Texture2D).GUID;
            var hr = PInvoke.MFCreateDXGISurfaceBuffer(iid, (IUnknown*)texture, 0, false, &buffer);
            if (hr.Failed)
            {
                Log.Warn($"wgc.surfacebuffer 0x{hr.Value:X8}");
                return false;
            }

            // DXGI surface buffer 的 current length 是 0；SinkWriter 要它等于整帧大小，否则 WriteSample 报 E_INVALIDARG。
            buffer->GetMaxLength(out var maxLength);
            buffer->SetCurrentLength(maxLength);

            hr = PInvoke.MFCreateSample(&sample);
            if (hr.Failed)
            {
                Log.Warn($"wgc.sample 0x{hr.Value:X8}");
                return false;
            }

            sample->AddBuffer(buffer);
            sample->SetSampleTime(time);
            sample->SetSampleDuration(duration);
            try
            {
                ((IMFSinkWriter*)writer)->WriteSample(0, sample);
            }
            catch (Exception ex)
            {
                Log.Warn($"wgc.write-sample 0x{ex.HResult:X8} time={time}");
                return false;
            }

            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"wgc.write-failed 0x{ex.HResult:X8}");
            return false;
        }
        finally
        {
            if (sample is not null)
            {
                sample->Release();
            }

            if (buffer is not null)
            {
                buffer->Release();
            }
        }
    }

    private bool CreateSinkWriter(
        D3DContext context, IntPtr* writer, IMFDXGIDeviceManager** manager, IMFAttributes** attributes,
        out string? error)
    {
        error = null;
        var hr = PInvoke.MFCreateDXGIDeviceManager(out var token, manager);
        if (hr.Failed)
        {
            error = "没能建 DXGI 设备管理器";
            return false;
        }

        try
        {
            var dxgiIid = typeof(IDXGIDevice).GUID;
            IDXGIDevice* dxgi = null;
            context.Device->QueryInterface(&dxgiIid, (void**)&dxgi);
            try
            {
                (*manager)->ResetDevice((IUnknown*)dxgi, token);
            }
            finally
            {
                dxgi->Release();
            }
        }
        catch (Exception ex)
        {
            error = $"设备管理器不接受 D3D 设备（0x{ex.HResult:X8}）";
            return false;
        }

        hr = PInvoke.MFCreateAttributes(attributes, 3);
        if (hr.Failed)
        {
            error = "没能建写入器属性";
            return false;
        }

        var managerKey = SinkWriterD3DManager;
        (*attributes)->SetUnknown(&managerKey, (IUnknown*)*manager);
        (*attributes)->SetUINT32(EnableHardwareTransforms, 1);
        (*attributes)->SetGUID(TranscodeContainerType, Fmp4Container);

        // 先试硬件编码；不行再去掉硬件标志（软件编码也能用 GPU 抓屏），还不行就退 GDI。
        hr = PInvoke.MFCreateSinkWriterFromURL(_temporary, null, *attributes, (IMFSinkWriter**)writer);
        if (hr.Failed)
        {
            Log.Warn($"wgc.sinkwriter-hw 0x{hr.Value:X8}");
            (*attributes)->SetUINT32(EnableHardwareTransforms, 0);
            hr = PInvoke.MFCreateSinkWriterFromURL(_temporary, null, *attributes, (IMFSinkWriter**)writer);
            if (hr.Failed)
            {
                error = $"没能建 MP4 写入器（0x{hr.Value:X8}）";
                return false;
            }
        }

        try
        {
            var media = CreateVideoType();
            try
            {
                uint stream;
                ((IMFSinkWriter*)*writer)->AddStream(media, &stream);
                var input = CreateInputType();
                try
                {
                    ((IMFSinkWriter*)*writer)->SetInputMediaType(stream, input, null);
                }
                finally
                {
                    input->Release();
                }
            }
            finally
            {
                media->Release();
            }

            return true;
        }
        catch (Exception ex)
        {
            error = $"编码器不接受 H.264 / 这个尺寸（0x{ex.HResult:X8}）";
            Log.Warn($"wgc.streams-failed 0x{ex.HResult:X8}");
            return false;
        }
    }

    private IMFMediaType* CreateVideoType()
    {
        IMFMediaType* type = null;
        PInvoke.MFCreateMediaType(&type).ThrowOnFailure();
        type->SetGUID(MajorType, VideoMajor);
        type->SetGUID(Subtype, H264);
        type->SetUINT32(AvgBitrate, RecordingPipeline.BitrateFor(_outputWidth, _outputHeight, _fps));
        type->SetUINT64(FrameSize, ((ulong)(uint)_outputWidth << 32) | (uint)_outputHeight);
        type->SetUINT64(FrameRate, ((ulong)(uint)_fps << 32) | 1);
        type->SetUINT32(InterlaceMode, 2);
        type->SetUINT32(Mpeg2Profile, 77); // Main
        return type;
    }

    private IMFMediaType* CreateInputType()
    {
        IMFMediaType* type = null;
        PInvoke.MFCreateMediaType(&type).ThrowOnFailure();
        type->SetGUID(MajorType, VideoMajor);
        type->SetGUID(Subtype, Argb32);
        type->SetUINT64(FrameSize, ((ulong)(uint)_outputWidth << 32) | (uint)_outputHeight);
        type->SetUINT64(FrameRate, ((ulong)(uint)_fps << 32) | 1);
        type->SetUINT32(InterlaceMode, 2);
        type->SetUINT32(DefaultStride, (uint)(_outputWidth * 4));
        return type;
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
}
