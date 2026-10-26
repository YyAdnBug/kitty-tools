// 分段 MP4 → 普通 MP4 的无损重封装（REVIEW R23）：录制时写 FMPEG4，停止时把临时文件的两路
// 压缩样本原样搬进一个普通 MP4，不重编码。闪退 / 断电时临时文件本身是分段 MP4，也能放。
//
// 用 Media Foundation 的 SourceReader + SinkWriter：
// - 一个 SourceReader 同时读视频 / 音频，ReadSample(ANY_STREAM) 按实际交错顺序取样本；
//   之前每路各开一个 reader，带音轨的长文件会在 copy-video 卡住（R24 探针发现）。
// - 每一路用 GetNativeMediaType 取原生压缩类型，AddStream / SetInputMediaType 都传同一个类型；
// - 时间戳按每一路的第一帧归零；
// - 重封装失败就返回 false，调用方把分段文件原样改名（至少能放）。
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Media.MediaFoundation;

namespace KittyTools;

internal static unsafe class Mp4Remux
{
    private const uint AnyStream = 0xFFFFFFFE;
    private const uint EndOfStream = 0x00000002;

    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00AA00389B71");
    private static readonly Guid AudioMajor = new("73647561-0000-0010-8000-00AA00389B71");
    private static readonly Guid TranscodeContainerType = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    private static readonly Guid Mpeg4Container = new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a");
    private static readonly Guid EnableHardwareTransforms = new("a634a91c-822b-41b9-a494-4de4643612b0");

    /// <summary>带超时的重封装：坏源 / 驱动卡住时，启动和停止不跟着一起卡死。</summary>
    public static bool TryRemuxWithTimeout(string source, string destination, int seconds = 5)
    {
        try
        {
            var task = Task.Run(() => TryRemux(source, destination));
            if (!task.Wait(TimeSpan.FromSeconds(seconds)))
            {
                Log.Warn($"record.remux-timeout {seconds}s");
                return false;
            }

            return task.Result;
        }
        catch (Exception ex)
        {
            Log.Warn($"record.remux-timeout-failed {ex.GetType().Name}");
            return false;
        }
    }

    public static bool TryRemux(string source, string destination)
    {
        var started = Environment.TickCount64;
        IMFSourceReader* reader = null;
        IMFSinkWriter* writer = null;
        IMFAttributes* attributes = null;
        try
        {
            if (PInvoke.MFStartup(0x00020070, 0).Failed)
            {
                Log.Warn("record.remux-failed startup");
                return false;
            }

            if (PInvoke.MFCreateAttributes(&attributes, 1).Failed || attributes is null)
            {
                Log.Warn("record.remux-failed attributes");
                return false;
            }

            var container = Mpeg4Container;
            attributes->SetGUID(TranscodeContainerType, container);
            attributes->SetUINT32(EnableHardwareTransforms, 0);
            if (PInvoke.MFCreateSinkWriterFromURL(destination, null, attributes, &writer).Failed || writer is null)
            {
                return false;
            }

            if (PInvoke.MFCreateSourceReaderFromURL(source, null, &reader).Failed || reader is null)
            {
                Log.Warn("record.remux-failed source-reader");
                return false;
            }

            var outputs = new uint[8];
            var firsts = new long[8];
            Array.Fill(outputs, uint.MaxValue);
            Array.Fill(firsts, -1);
            var mapped = 0;
            for (uint index = 0; index < outputs.Length; index++)
            {
                IMFMediaType* native = null;
                try
                {
                    reader->GetNativeMediaType(index, 0, &native);
                    if (native is null)
                    {
                        break;
                    }

                    Guid major;
                    native->GetGUID(MajorType, out major);
                    if (major != VideoMajor && major != AudioMajor)
                    {
                        continue;
                    }

                    uint output = 0;
                    writer->AddStream(native, &output);
                    writer->SetInputMediaType(output, native, null);
                    outputs[index] = output;
                    mapped++;
                }
                catch (Exception ex) when (ex.HResult == unchecked((int)0xC00D36B3))
                {
                    // 没有这一路编号了。
                    break;
                }
                finally
                {
                    if (native is not null)
                    {
                        native->Release();
                    }
                }
            }

            if (mapped == 0)
            {
                Log.Warn("record.remux no-streams");
                return false;
            }

            writer->BeginWriting();
            var written = 0;
            while (true)
            {
                uint actual = 0;
                uint flags = 0;
                long timestamp = 0;
                IMFSample* sample = null;
                try
                {
                    reader->ReadSample(AnyStream, 0, out actual, out flags, out timestamp, &sample);
                    if ((flags & EndOfStream) != 0 || sample is null)
                    {
                        break;
                    }

                    if (actual >= outputs.Length || outputs[actual] == uint.MaxValue)
                    {
                        continue;
                    }

                    if (firsts[actual] < 0)
                    {
                        firsts[actual] = timestamp;
                    }

                    if (++written > 200_000 || timestamp - firsts[actual] > 900_000_000L)
                    {
                        Log.Warn($"record.remux cap stream={actual} written={written}");
                        break;
                    }

                    sample->SetSampleTime(timestamp - firsts[actual]);
                    writer->WriteSample(outputs[actual], sample);
                }
                finally
                {
                    if (sample is not null)
                    {
                        sample->Release();
                    }
                }
            }

            writer->Finalize();
            var ok = File.Exists(destination) && new FileInfo(destination).Length > 0;
            Log.Info($"record.remux ok={ok} ms={Environment.TickCount64 - started} samples={written}");
            return ok;
        }
        catch (Exception ex)
        {
            Log.Warn($"record.remux-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return false;
        }
        finally
        {
            if (reader is not null)
            {
                reader->Release();
            }

            if (writer is not null)
            {
                writer->Release();
            }

            if (attributes is not null)
            {
                attributes->Release();
            }

            PInvoke.MFShutdown();
        }
    }
}
