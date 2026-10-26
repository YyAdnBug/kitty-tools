// 录音（PLAN-v6 第 3 批）：和录屏同一套 WASAPI 采集 / 混音，先写临时 WAV（自己写 RIFF 头），
// 停止后用 MediaTranscoder 转成 AAC 的 .m4a。支持系统声音 / 麦克风 / 两者、暂停 / 继续、电平（RMS dBFS）。
// 采集在专用线程上轮询；暂停期间不写样本，时间轴自然扣掉暂停时长。
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Win32;

namespace KittyTools;

internal sealed class AudioRecorder : IDisposable
{
    private readonly string _temporary;
    private readonly string _final;
    private readonly bool _systemAudio;
    private readonly bool _microphone;
    private readonly ManualResetEventSlim _stop = new(false);
    private readonly ManualResetEventSlim _ready = new(false);
    private Thread? _thread;
    private AudioCaptureSet? _audio;
    private string? _startupError;
    private string? _note;
    private bool _microphoneDenied;
    private long _start100;
    private long _paused100;
    private long _pauseStarted;
    private volatile bool _paused;
    private long _writtenFrames;

    private AudioRecorder(string temporary, string final, bool systemAudio, bool microphone)
    {
        _temporary = temporary;
        _final = final;
        _systemAudio = systemAudio;
        _microphone = microphone;
    }

    public long ElapsedMs { get; private set; }

    public float Level { get; private set; }

    public bool IsPaused => _paused;

    public string? Note => _note;

    /// <summary>录音中实时备注：麦克风 / 系统声音断了会在这里出现（R28）。</summary>
    public string? LiveNote => _audio?.Note;

    public bool MicrophoneDenied => _microphoneDenied;

    public string? OutputPath => File.Exists(_final) ? _final : null;

    public static AudioRecorder? Start(
        string folder, bool systemAudio, bool microphone, out string? error, out string? note)
    {
        error = null;
        note = null;
        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return null;
        }

        var final = Path.Combine(folder, RecorderRules.FileName(DateTime.Now, audio: true));
        var temporary = Path.Combine(folder, "." + Guid.NewGuid().ToString("N") + ".tmp.wav");
        var recorder = new AudioRecorder(temporary, final, systemAudio, microphone);
        recorder._thread = new Thread(recorder.Run) { IsBackground = true, Name = "kitty-audio-recorder" };
        recorder._thread.Start();
        if (!recorder._ready.Wait(TimeSpan.FromSeconds(8)) || recorder._startupError is not null)
        {
            error = recorder._startupError ?? "录音线程没有启动起来";
            recorder._stop.Set();
            recorder._thread.Join(TimeSpan.FromSeconds(2));
            recorder.Dispose();
            return null;
        }

        note = recorder._note;
        return recorder;
    }

    public string? Stop()
    {
        _stop.Set();
        _thread?.Join(TimeSpan.FromSeconds(15));
        _thread = null;
        return File.Exists(_final) ? _final : null;
    }

    public void Pause()
    {
        if (_paused)
        {
            return;
        }

        _pauseStarted = AudioRules.Now100Ns();
        _paused = true;
    }

    public void Resume()
    {
        if (!_paused)
        {
            return;
        }

        _paused100 += AudioRules.Now100Ns() - _pauseStarted;
        _paused = false;
    }

    public void Dispose()
    {
        _stop.Dispose();
        _ready.Dispose();
    }

    private void Run()
    {
        FileStream? stream = null;
        try
        {
            _audio = AudioCaptureSet.Open(_systemAudio, _microphone);
            _note = _audio.Note;
            _microphoneDenied = _audio.MicrophoneDenied;
            if (!_audio.HasSource)
            {
                _startupError = _note ?? "没有可用的声音来源";
                return;
            }

            stream = new FileStream(_temporary, FileMode.Create, FileAccess.Write, FileShare.Read);
            stream.Write(new byte[44]);
            _start100 = AudioRules.Now100Ns();
            _audio.Start(_start100);
            _ready.Set();

            var pcm = new byte[AudioRules.ChunkFrames * AudioRules.PcmBlockAlign];
            while (!_stop.IsSet)
            {
                var now = AudioRules.Now100Ns() - _start100 - _paused100;
                _audio.Poll();
                if (!_paused)
                {
                    var until = AudioRules.FramesAt(now - 1_500_000, 0);
                    while (true)
                    {
                        var frames = _audio.Bus.DrainPcm16(until, pcm, AudioRules.ChunkFrames);
                        if (frames <= 0)
                        {
                            break;
                        }

                        stream.Write(pcm, 0, frames * AudioRules.PcmBlockAlign);
                        _writtenFrames += frames;
                        Level = Rms(pcm, frames);
                        if (frames < AudioRules.ChunkFrames)
                        {
                            break;
                        }
                    }
                }

                ElapsedMs = Math.Max(0, now / 10_000);
                _stop.Wait(10);
            }

            _audio.Stop();
            _audio.Poll();
            var end = AudioRules.FramesAt(
                AudioRules.Now100Ns() - _start100 - _paused100, 0);
            while (true)
            {
                var frames = _audio.Bus.DrainPcm16(end, pcm, AudioRules.ChunkFrames);
                if (frames <= 0)
                {
                    break;
                }

                stream.Write(pcm, 0, frames * AudioRules.PcmBlockAlign);
                _writtenFrames += frames;
                if (frames < AudioRules.ChunkFrames)
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error("audio.record-failed", ex);
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
                if (stream is not null)
                {
                    WriteHeader(stream, _writtenFrames * AudioRules.PcmBlockAlign);
                    stream.Dispose();
                    stream = null;
                    if (TranscodeToM4a(_temporary, _final))
                    {
                        File.Delete(_temporary);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"audio.finish {ex.GetType().Name}");
            }

            _audio?.Dispose();
            _audio = null;
            Log.Info($"audio.done ms={ElapsedMs} size={(File.Exists(_final) ? new FileInfo(_final).Length : 0)}");
        }
    }

    private static void WriteHeader(FileStream stream, long dataBytes)
    {
        stream.Seek(0, SeekOrigin.Begin);
        using var writer = new BinaryWriter(stream, System.Text.Encoding.ASCII, leaveOpen: true);
        writer.Write("RIFF"u8.ToArray());
        writer.Write((uint)(36 + dataBytes));
        writer.Write("WAVEfmt "u8.ToArray());
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)AudioRules.Channels);
        writer.Write(AudioRules.SampleRate);
        writer.Write(AudioRules.PcmBytesPerSecond);
        writer.Write((short)AudioRules.PcmBlockAlign);
        writer.Write((short)16);
        writer.Write("data"u8.ToArray());
        writer.Write((uint)dataBytes);
        writer.Flush();
    }

    private static float Rms(byte[] pcm, int frames)
    {
        double sum = 0;
        for (var index = 0; index < frames * AudioRules.PcmBlockAlign; index += 2)
        {
            var value = (short)(pcm[index] | (pcm[index + 1] << 8)) / 32768.0;
            sum += value * value;
        }

        var rms = Math.Sqrt(sum / Math.Max(1, frames * 2));
        return rms <= 0.0001 ? -90 : (float)(20 * Math.Log10(rms));
    }

    private static bool TranscodeToM4a(string wav, string final)
    {
        try
        {
            var source = StorageFile.GetFileFromPathAsync(wav).AsTask().GetAwaiter().GetResult();
            var folder = StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(final)!)
                .AsTask().GetAwaiter().GetResult();
            var target = folder.CreateFileAsync(
                Path.GetFileName(final), CreationCollisionOption.ReplaceExisting)
                .AsTask().GetAwaiter().GetResult();
            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
            var transcoder = new MediaTranscoder();
            var prepared = transcoder.PrepareFileTranscodeAsync(source, target, profile)
                .AsTask().GetAwaiter().GetResult();
            if (!prepared.CanTranscode)
            {
                return false;
            }

            prepared.TranscodeAsync().AsTask().GetAwaiter().GetResult();
            return File.Exists(final);
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.m4a-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return false;
        }
    }
}
