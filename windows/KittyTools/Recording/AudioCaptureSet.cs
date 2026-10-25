// 录屏声音的两路（R14）：系统声音回环 + 麦克风，各自一个 WasaCapture，写进同一个 AudioMixBuffer。
// 一路打不开不影响另一路；两路都打不开就不给 MP4 加音轨，只用一句提示说明原因。
// 麦克风没权限时把 AccessDenied 交给 RecordingHost，由它把设置里的麦克风开关弹回关。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal sealed class AudioCaptureSet : IDisposable
{
    private readonly List<WasaCapture> _sources = new();
    private readonly List<string> _notes = new();
    private bool _started;

    private AudioCaptureSet()
    {
        Bus = new AudioMixBuffer();
    }

    public AudioMixBuffer Bus { get; }

    public bool HasSource => _sources.Count > 0;

    public bool MicrophoneDenied { get; private set; }

    public float LoopbackPeak => Peak(loopback: true);

    public float MicrophonePeak => Peak(loopback: false);

    public long LoopbackPackets => Packets(loopback: true);

    public long MicrophonePackets => Packets(loopback: false);

    public string? Note => _notes.Count == 0 ? null : string.Join("；", _notes);

    public static AudioCaptureSet Open(bool systemSound, bool microphone)
    {
        var set = new AudioCaptureSet();
        if (systemSound)
        {
            var loopback = WasaCapture.Open(loopback: true, out var error);
            if (loopback is null)
            {
                set._notes.Add("系统声音没打开（" + (error ?? "未知原因") + "）");
            }
            else
            {
                set._sources.Add(loopback);
            }
        }

        if (microphone)
        {
            var mic = WasaCapture.Open(loopback: false, out var error);
            if (mic is null)
            {
                set.MicrophoneDenied = true;
                set._notes.Add("麦克风没打开（" + (error ?? "未知原因") + "）");
            }
            else
            {
                set._sources.Add(mic);
            }
        }

        if (!set.HasSource)
        {
            set._notes.Add("这段录屏只有画面");
        }

        return set;
    }

    public void Start(long start100Ns)
    {
        var started = new List<WasaCapture>();
        foreach (var source in _sources)
        {
            try
            {
                source.Start(start100Ns);
                started.Add(source);
            }
            catch (Exception ex)
            {
                Log.Warn($"audio.start-failed loopback={source.Loopback} hr=0x{ex.HResult:X8}");
                source.Dispose();
            }
        }

        _sources.Clear();
        _sources.AddRange(started);
        _started = true;
    }

    /// <summary>取走这一轮采到的所有包；设备中途没了就把那一路关掉，另一路照录。</summary>
    public void Poll()
    {
        if (!_started)
        {
            return;
        }

        for (var index = _sources.Count - 1; index >= 0; index--)
        {
            try
            {
                _sources[index].Poll(Bus);
            }
            catch (Exception ex)
            {
                Log.Warn($"audio.poll-failed loopback={_sources[index].Loopback} hr=0x{ex.HResult:X8}");
                _notes.Add(_sources[index].Loopback ? "系统声音断了" : "麦克风断开了");
                _sources[index].Dispose();
                _sources.RemoveAt(index);
            }
        }
    }

    public void Stop()
    {
        _started = false;
        foreach (var source in _sources)
        {
            try
            {
                source.Stop();
            }
            catch
            {
                // 设备已经没了就算了。
            }
        }
    }

    public void Dispose()
    {
        Stop();
        foreach (var source in _sources)
        {
            source.Dispose();
        }

        _sources.Clear();
    }

    private float Peak(bool loopback)
    {
        var peak = 0f;
        foreach (var source in _sources)
        {
            if (source.Loopback == loopback && source.Peak > peak)
            {
                peak = source.Peak;
            }
        }

        return peak;
    }

    private long Packets(bool loopback)
    {
        long packets = 0;
        foreach (var source in _sources)
        {
            if (source.Loopback == loopback)
            {
                packets += source.Packets;
            }
        }

        return packets;
    }
}
