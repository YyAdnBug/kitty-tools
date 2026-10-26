// 分段 MP4 → 普通 MP4 的无损重封装（REVIEW R23）：录制时写 FMPEG4，停止时把临时文件的两路
// 压缩样本原样搬进一个普通 MP4，不重编码。闪退 / 断电时临时文件本身是分段 MP4，也能放。
//
// 用 Media Foundation 的 SourceReader + SinkWriter：
// - 每一路用 GetNativeMediaType 取原生压缩类型，AddStream / SetInputMediaType 都传同一个类型；
// - ReadSample 逐帧读，时间戳减去这一路第一帧的，从 0 开始；
// - 重封装失败就返回 false，调用方把分段文件原样改名（至少能放）。
using KittyTools.Infrastructure;
using Windows.Win32;
using Windows.Win32.Media.MediaFoundation;

namespace KittyTools;

internal static unsafe class Mp4Remux
{
    private static readonly Guid TranscodeContainerType = new("150ff23f-4abc-478b-ac4f-e1916fba1cca");
    private static readonly Guid Mpeg4Container = new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a");
    private static readonly Guid EnableHardwareTransforms = new("a634a91c-822b-41b9-a494-4de4643612b0");

    public static bool TryRemux(string source, string destination)
    {
        var started = Environment.TickCount64;
        IMFSourceReader* videoReader = null;
        IMFSourceReader* audioReader = null;
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

            var video = AddStream(writer, source, 0, out var videoReaderLocal, out var videoOutput);
            videoReader = videoReaderLocal;
            var audio = AddStream(writer, source, 1, out var audioReaderLocal, out var audioOutput);
            audioReader = audioReaderLocal;
            if (!video && !audio)
            {
                return false;
            }

            writer->BeginWriting();
            if (video)
            {
                Copy(videoReader, writer, videoOutput, 0);
            }

            if (audio)
            {
                Copy(audioReader, writer, audioOutput, 1);
            }
            writer->Finalize();
            var ok = File.Exists(destination) && new FileInfo(destination).Length > 0;
            Log.Info($"record.remux ok={ok} ms={Environment.TickCount64 - started}");
            return ok;
        }
        catch (Exception ex)
        {
            Log.Warn($"record.remux-failed {ex.GetType().Name} 0x{ex.HResult:X8}");
            return false;
        }
        finally
        {
            if (videoReader is not null)
            {
                videoReader->Release();
            }

            if (audioReader is not null)
            {
                audioReader->Release();
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

    private static bool AddStream(
        IMFSinkWriter* writer, string source, uint streamIndex,
        out IMFSourceReader* reader, out uint outputStream)
    {
        reader = null;
        outputStream = 0;
        IMFMediaType* type = null;
        try
        {
            IMFSourceReader* localReader = null;
            if (PInvoke.MFCreateSourceReaderFromURL(source, null, &localReader).Failed || localReader is null)
            {
                Log.Warn("record.remux-failed source-reader");
                return false;
            }

            reader = localReader;
            reader->GetNativeMediaType(streamIndex, 0, &type);
            if (type is null)
            {
                Log.Warn($"record.remux-failed media-type stream={streamIndex}");
                reader->Release();
                reader = null;
                return false;
            }
            uint localOutput = 0;
            writer->AddStream(type, &localOutput);
            outputStream = localOutput;
            writer->SetInputMediaType(outputStream, type, null);
            return true;
        }
        catch (Exception ex)
        {
            // 没有这一路（比如录屏没开声音）：不是失败，调用方按只有画面处理。
            Log.Info($"record.remux stream-missing stream={streamIndex} 0x{ex.HResult:X8}");
            if (reader is not null)
            {
                reader->Release();
                reader = null;
            }

            return false;
        }
        finally
        {
            if (type is not null)
            {
                type->Release();
            }
        }
    }

    private static void Copy(
        IMFSourceReader* reader, IMFSinkWriter* writer, uint outputStream, uint inputStream)
    {
        long first = -1;
        while (true)
        {
            uint actualStream = 0;
            MF_SOURCE_READER_FLAG flags = 0;
            long timestamp = 0;
            IMFSample* sample = null;
            try
            {
                reader->ReadSample(inputStream, 0, out actualStream, out uint rawFlags, out timestamp, &sample);
                flags = (MF_SOURCE_READER_FLAG)rawFlags;
                if (first < 0)
                {
                }

                if ((flags & MF_SOURCE_READER_FLAG.MF_SOURCE_READERF_ENDOFSTREAM) != 0)
                {
                    break;
                }

                if (sample is null)
                {
                    continue;
                }

                if (first < 0)
                {
                    first = timestamp;
                }
                sample->SetSampleTime(timestamp - first);
                writer->WriteSample(outputStream, sample);
            }
            finally
            {
                if (sample is not null)
                {
                    sample->Release();
                }
            }
        }
    }
}
