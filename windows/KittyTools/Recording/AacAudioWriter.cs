// 录音直接写 AAC（REVIEW R28）：WASAPI 采到的 PCM 交给 Media Foundation SinkWriter，边录边编码，
// 不再先写 1 小时 690 MB 的临时 WAV。容器先写分段 MP4，停止时用 Mp4Remux 无损重封装成 .m4a
// （同一套思路，闪退时临时文件本身也能放）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Media.MediaFoundation;

namespace KittyTools;

internal sealed unsafe class AacAudioWriter : IDisposable
{
    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
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
    private static readonly Guid EnableHardwareTransforms = new("a634a91c-822b-41b9-a494-4de4643612b0");
    private static readonly Guid TranscodeContainerType = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    private static readonly Guid Fmp4Container = new("9ba876f1-419f-4b77-a1e0-35959d9d4004");
    private const uint AacLcProfile = 0x29;
    private const int AacBitrateBytes = 20_000;

    private readonly string _temporary;
    private IMFSinkWriter* _writer;
    private uint _stream;
    private long _frames;
    private bool _started;
    private bool _finished;

    private AacAudioWriter(string temporary)
    {
        _temporary = temporary;
    }

    public static AacAudioWriter? TryCreate(string temporary, out string? error)
    {
        error = null;
        var writer = new AacAudioWriter(temporary);
        try
        {
            if (PInvoke.MFStartup(0x00020070, 0).Failed)
            {
                error = "Media Foundation 启动失败";
                return null;
            }

            IMFAttributes* attributes = null;
            try
            {
                if (PInvoke.MFCreateAttributes(&attributes, 2).Failed || attributes is null)
                {
                    error = "创建编码器属性失败";
                    return null;
                }

                attributes->SetGUID(TranscodeContainerType, Fmp4Container);
                attributes->SetUINT32(EnableHardwareTransforms, 0);
                IMFSinkWriter* raw = null;
                if (PInvoke.MFCreateSinkWriterFromURL(temporary, null, attributes, &raw).Failed ||
                    raw is null)
                {
                    error = "创建 AAC 编码器失败";
                    return null;
                }

                writer._writer = raw;
                writer.Configure();
                writer._started = true;
                return writer;
            }
            finally
            {
                if (attributes is not null)
                {
                    attributes->Release();
                }
            }
        }
        catch (Exception ex)
        {
            error = ex.Message;
            Log.Warn($"audio.aac-create 0x{ex.HResult:X8}");
            writer.Dispose();
            return null;
        }
    }

    private void Configure()
    {
        IMFMediaType* outType = null;
        IMFMediaType* inType = null;
        try
        {
            PInvoke.MFCreateMediaType(&outType).ThrowOnFailure();
            outType->SetGUID(MajorType, AudioMajor);
            outType->SetGUID(Subtype, Aac);
            outType->SetUINT32(AudioChannels, AudioRules.Channels);
            outType->SetUINT32(AudioSamplesPerSecond, AudioRules.SampleRate);
            outType->SetUINT32(AudioBitsPerSample, 16);
            outType->SetUINT32(AudioBlockAlignment, AudioRules.PcmBlockAlign);
            outType->SetUINT32(AudioAvgBytesPerSecond, AacBitrateBytes);
            outType->SetUINT32(AacPayloadType, 0);
            outType->SetUINT32(AacProfile, AacLcProfile);
            uint stream = 0;
            _writer->AddStream(outType, &stream);
            _stream = stream;

            PInvoke.MFCreateMediaType(&inType).ThrowOnFailure();
            inType->SetGUID(MajorType, AudioMajor);
            inType->SetGUID(Subtype, Pcm);
            inType->SetUINT32(AudioChannels, AudioRules.Channels);
            inType->SetUINT32(AudioSamplesPerSecond, AudioRules.SampleRate);
            inType->SetUINT32(AudioBitsPerSample, 16);
            inType->SetUINT32(AudioBlockAlignment, AudioRules.PcmBlockAlign);
            inType->SetUINT32(AudioAvgBytesPerSecond, AudioRules.PcmBytesPerSecond);
            _writer->SetInputMediaType(_stream, inType, null);
            _writer->BeginWriting();
        }
        finally
        {
            if (outType is not null)
            {
                outType->Release();
            }

            if (inType is not null)
            {
                inType->Release();
            }
        }
    }

    /// <summary>写一块 PCM16；时间戳从 0 开始，暂停时直接不写，时间轴自然接上。</summary>
    public bool Write(byte[] pcm, int frames)
    {
        if (!_started || _writer is null || frames <= 0)
        {
            return false;
        }

        IMFSample* sample = null;
        IMFMediaBuffer* buffer = null;
        try
        {
            var bytes = (uint)(frames * AudioRules.PcmBlockAlign);
            if (PInvoke.MFCreateMemoryBuffer(bytes, &buffer).Failed || buffer is null)
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
            if (PInvoke.MFCreateSample(&sample).Failed || sample is null)
            {
                return false;
            }

            sample->AddBuffer(buffer);
            sample->SetSampleTime(_frames * 10_000_000L / AudioRules.SampleRate);
            sample->SetSampleDuration(frames * 10_000_000L / AudioRules.SampleRate);
            _writer->WriteSample(_stream, sample);
            _frames += frames;
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.aac-write 0x{ex.HResult:X8}");
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

    /// <summary>收尾：Finalize 分段 MP4，再无损重封装成 .m4a。</summary>
    public bool Complete(string final)
    {
        if (_finished)
        {
            return File.Exists(final);
        }

        _finished = true;
        try
        {
            if (_writer is not null)
            {
                _writer->Finalize();
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"audio.aac-finalize 0x{ex.HResult:X8}");
        }

        Release();
        if (!File.Exists(_temporary))
        {
            return false;
        }

        if (Mp4Remux.TryRemux(_temporary, final))
        {
            File.Delete(_temporary);
            return true;
        }

        // 重封装失败：分段 MP4 原样改名，媒体播放器也能放。
        File.Move(_temporary, final, overwrite: true);
        return true;
    }

    private void Release()
    {
        if (_writer is not null)
        {
            _writer->Release();
            _writer = null;
        }

        PInvoke.MFShutdown();
    }

    public void Dispose()
    {
        if (_writer is not null)
        {
            try
            {
                _writer->Finalize();
            }
            catch
            {
                // 失败也继续放。
            }

            Release();
        }
    }
}
