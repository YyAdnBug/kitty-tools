// 录屏声音的采集（R14）：WASAPI 共享模式。
// - 系统声音：默认输出设备 + AUDCLNT_STREAMFLAGS_LOOPBACK 回环；
// - 麦克风：默认输入设备；
// 两路都要求音频引擎转成 48 kHz / 双声道 / float32（AUTOCONVERTPCM + SRC_DEFAULT_QUALITY），
// 这样混音时不用自己重采样。用轮询（每轮录屏循环里 GetNextPacketSize），不用事件模式：
// 回环在没有声音播放时不来事件。CsWin32 在 allowMarshaling=false 下生成的是函数指针结构体，AOT 能用。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Media.Audio;
using Windows.Win32.System.Com;

namespace KittyTools;

internal sealed unsafe class WasaCapture : IDisposable
{
    private const uint StreamFlagsLoopback = 0x00020000;
    private const uint StreamFlagsAutoConvert = 0x80000000;
    private const uint StreamFlagsSrcDefaultQuality = 0x08000000;
    private const uint BufferFlagsSilent = 0x00000002;
    private const int BufferDuration100Ns = 2_000_000; // 200 ms，录屏循环 33 ms 一轮，够用
    private static readonly Guid FloatSubFormat = new("00000003-0000-0010-8000-00AA00389B71");

    private IMMDeviceEnumerator* _enumerator;
    private IMMDevice* _device;
    private IAudioClient* _client;
    private IAudioCaptureClient* _capture;
    private long _start100;
    private long _fallbackFrame;
    private bool _warnedNoQpc;
    private ushort _formatTag;
    private ushort _channels;
    private uint _rate;
    private ushort _bits;
    private ushort _blockAlign;
    private AudioConverter? _converter;

    private WasaCapture(bool loopback)
    {
        Loopback = loopback;
    }

    public bool Loopback { get; }

    public bool AccessDenied { get; private set; }

    /// <summary>采到的非静音包数和峰值（探针用；0 表示这一路一直没声音）。</summary>
    public long Packets { get; private set; }

    public float Peak { get; private set; }

    public static WasaCapture? Open(bool loopback, out string? error)
    {
        var capture = new WasaCapture(loopback);
        var stage = "enumerator";
        WAVEFORMATEX* mix = null;
        try
        {
            IMMDeviceEnumerator* enumerator = null;
            MMDeviceEnumerator.CreateInstance<IMMDeviceEnumerator>(out enumerator).ThrowOnFailure();
            capture._enumerator = enumerator;

            stage = "endpoint";
            IMMDevice* device = null;
            enumerator->GetDefaultAudioEndpoint(
                loopback ? EDataFlow.eRender : EDataFlow.eCapture, ERole.eConsole, &device);
            capture._device = device;

            stage = "activate";
            IAudioClient* client = null;
            var clientIid = typeof(IAudioClient).GUID;
            device->Activate(&clientIid, CLSCTX.CLSCTX_ALL, null, (void**)&client);
            capture._client = client;

            stage = "mixformat";
            client->GetMixFormat(&mix);
            Log.Info(
                $"audio.mix-format {(loopback ? "loopback" : "mic")} tag=0x{mix->wFormatTag:X4} " +
                $"ch={mix->nChannels} rate={mix->nSamplesPerSec} bits={mix->wBitsPerSample} cb={mix->cbSize}");

            stage = "initialize";
            var flags = loopback ? StreamFlagsLoopback : 0u;
            client->Initialize(
                AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED, flags,
                BufferDuration100Ns, 0, mix, null);

            capture._formatTag = mix->wFormatTag;
            capture._channels = mix->nChannels;
            capture._rate = mix->nSamplesPerSec;
            capture._bits = mix->wBitsPerSample;
            capture._blockAlign = mix->nBlockAlign;

            var isFloat = mix->wFormatTag == 3; // WAVE_FORMAT_IEEE_FLOAT
            if (mix->wFormatTag == 0xFFFE && mix->cbSize >= 22)
            {
                var extended = (WAVEFORMATEXTENSIBLE*)mix;
                isFloat = extended->SubFormat == FloatSubFormat;
            }

            if (!isFloat && capture._bits is not (16 or 24 or 32))
            {
                throw new NotSupportedException($"不支持的采样位数 {capture._bits}");
            }

            capture._converter = new AudioConverter(
                (int)capture._rate, capture._channels, isFloat, capture._bits);
            Log.Info(
                $"audio.converter {(loopback ? "loopback" : "mic")} rate={capture._rate} " +
                $"ch={capture._channels} float={isFloat} bits={capture._bits}");

            PInvoke.CoTaskMemFree(mix);
            mix = null;

            stage = "service";
            IAudioCaptureClient* captureClient = null;
            var captureIid = typeof(IAudioCaptureClient).GUID;
            client->GetService(&captureIid, (void**)&captureClient);
            capture._capture = captureClient;

            error = null;
            Log.Info(loopback ? "audio.loopback-open" : "audio.mic-open");
            return capture;
        }
        catch (Exception ex)
        {
            if (mix is not null)
            {
                PInvoke.CoTaskMemFree(mix);
                mix = null;
            }

            capture.AccessDenied = ex.HResult == unchecked((int)0x80070005);
            error = capture.AccessDenied
                ? "没有权限"
                : $"0x{ex.HResult:X8}";
            Log.Warn($"audio.{(loopback ? "loopback" : "mic")}-open-failed stage={stage} hr=0x{ex.HResult:X8}");
            capture.Dispose();
            return null;
        }
    }

    public void Start(long start100Ns)
    {
        _start100 = start100Ns;
        _client->Start();
    }

    /// <summary>把已经采到的包全部写进混音缓冲；设备中途没了会抛异常，由 AudioCaptureSet 关掉这一路。</summary>
    public void Poll(AudioMixBuffer buffer)
    {
        uint next;
        _capture->GetNextPacketSize(&next);
        while (next > 0)
        {
            byte* data = null;
            uint frames = 0;
            uint flags = 0;
            ulong devicePosition = 0;
            ulong qpc = 0;
            _capture->GetBuffer(&data, &frames, &flags, &devicePosition, &qpc);
            try
            {
                if (frames > 0)
                {
                    long frame;
                    if (qpc != 0)
                    {
                        frame = AudioRules.FramesAt((long)qpc, _start100);
                    }
                    else
                    {
                        if (!_warnedNoQpc)
                        {
                            _warnedNoQpc = true;
                            Log.Warn("audio.no-qpc");
                        }

                        frame = _fallbackFrame;
                    }

                    _fallbackFrame += frames;

                    if ((flags & BufferFlagsSilent) == 0 && data is not null && _converter is not null)
                    {
                        var bytes = (int)frames * _blockAlign;
                        var source = new ReadOnlySpan<byte>(data, bytes);
                        var samples = _converter.Convert(source, (int)frames);
                        if (!samples.IsEmpty)
                        {
                            if (frame < buffer.Flushed)
                            {
                                Log.Warn(
                                    $"audio.late-prefix frame={frame} flushed={buffer.Flushed} " +
                                    $"frames={samples.Length / 2}");
                            }

                            Packets++;
                            var peak = PeakOf(samples);
                            if (peak > Peak)
                            {
                                Peak = peak;
                            }

                            if (!buffer.Add(frame, samples))
                            {
                                Log.Warn("audio.mix-late");
                            }
                        }
                    }
                }
            }
            finally
            {
                _capture->ReleaseBuffer(frames);
            }

            _capture->GetNextPacketSize(&next);
        }
    }

    private static float PeakOf(ReadOnlySpan<float> samples)
    {
        var peak = 0f;
        foreach (var sample in samples)
        {
            if (float.IsFinite(sample) && Math.Abs(sample) > peak)
            {
                peak = Math.Abs(sample);
            }
        }

        return peak;
    }

    public void Stop()
    {
        if (_client is not null)
        {
            _client->Stop();
        }
    }

    public void Dispose()
    {
        if (_capture is not null)
        {
            _capture->Release();
            _capture = null;
        }

        if (_client is not null)
        {
            _client->Release();
            _client = null;
        }

        if (_device is not null)
        {
            _device->Release();
            _device = null;
        }

        if (_enumerator is not null)
        {
            _enumerator->Release();
            _enumerator = null;
        }
    }
}
