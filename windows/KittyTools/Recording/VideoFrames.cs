// 自检用的逐帧解码（REVIEW R24、PLAN-v11 C2 的短视频）：Media Foundation 的 SourceReader 按顺序解出 MP4 的每一帧，
// 交出这一帧自己的时间戳和 BGRA 像素。和 MediaComposition.GetThumbnailAsync 按时间取帧不同，这里不会取到「附近的另一帧」，
// 音画同步要拿每帧真实的时间戳去找闪白。只给探针用，不进录制的路径。
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Media.MediaFoundation;

namespace KittyTools;

internal static unsafe class VideoFrames
{
    private const uint FirstVideoStream = 0xFFFFFFFC;
    private const uint AllStreams = 0xFFFFFFFE;
    private const uint EndOfStream = 0x00000002;

    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00AA00389B71");
    private static readonly Guid Rgb32 = new("00000016-0000-0010-8000-00AA00389B71");
    private static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    private static readonly Guid EnableVideoProcessing = new("fb394f3d-ccf1-42ee-bbb3-f9b845d5681d");

    /// <summary>一帧：时间戳（秒，文件里写的那个）、BGRA 像素（自上而下，每行 Width * 4 字节；回调返回后就失效）。</summary>
    public delegate void FrameHandler(double seconds, ReadOnlySpan<byte> bgra, int width, int height);

    /// <summary>按顺序解出每一帧交给 <paramref name="onFrame"/>，返回帧数；失败返回 -1。</summary>
    public static int Read(string path, FrameHandler onFrame)
    {
        IMFAttributes* attributes = null;
        IMFSourceReader* reader = null;
        IMFMediaType* wanted = null;
        IMFMediaType* current = null;
        var frames = 0;
        try
        {
            PInvoke.MFStartup(0x00020070, 0).ThrowOnFailure();
            PInvoke.MFCreateAttributes(&attributes, 1).ThrowOnFailure();
            attributes->SetUINT32(EnableVideoProcessing, 1);
            PInvoke.MFCreateSourceReaderFromURL(path, attributes, &reader).ThrowOnFailure();
            reader->SetStreamSelection(AllStreams, false);
            reader->SetStreamSelection(FirstVideoStream, true);

            PInvoke.MFCreateMediaType(&wanted).ThrowOnFailure();
            wanted->SetGUID(MajorType, VideoMajor);
            wanted->SetGUID(Subtype, Rgb32);
            reader->SetCurrentMediaType(FirstVideoStream, null, wanted);
            reader->GetCurrentMediaType(FirstVideoStream, &current);
            current->GetUINT64(FrameSize, out var packed);
            var width = (int)(packed >> 32);
            var height = (int)(packed & 0xFFFFFFFF);
            var stride = width * 4;
            try
            {
                current->GetUINT32(DefaultStride, out var value);
                stride = (int)value;
            }
            catch (Exception)
            {
                // 没写默认步长：RGB32 按自上而下、每行 width * 4。
            }

            var row = width * 4;
            var buffer = new byte[row * height];
            while (true)
            {
                IMFSample* sample = null;
                IMFMediaBuffer* media = null;
                try
                {
                    reader->ReadSample(FirstVideoStream, 0, out _, out var flags, out var timestamp, &sample);
                    if ((flags & EndOfStream) != 0)
                    {
                        break;
                    }

                    if (sample is null)
                    {
                        continue;
                    }

                    sample->ConvertToContiguousBuffer(&media);
                    byte* data;
                    uint length;
                    media->Lock(&data, null, &length);
                    try
                    {
                        // 解码器常把每行补齐到 16 / 64 像素、又不写默认步长：缓冲区比 width * 4 * height 大时按「长度 / 行数」算。
                        // 步长是负的：最后一行在最前面（自下而上），翻回自上而下。
                        var absStride = Math.Abs(stride);
                        if (absStride == row && length > (uint)(row * height) && length % (uint)height == 0)
                        {
                            absStride = (int)(length / (uint)height);
                        }

                        for (var y = 0; y < height; y++)
                        {
                            var sourceRow = stride >= 0 ? y : height - 1 - y;
                            if ((long)(sourceRow + 1) * absStride > length)
                            {
                                break;
                            }

                            new ReadOnlySpan<byte>(data + (long)sourceRow * absStride, row)
                                .CopyTo(buffer.AsSpan(y * row, row));
                        }
                    }
                    finally
                    {
                        media->Unlock();
                    }

                    onFrame(timestamp / 10_000_000.0, buffer, width, height);
                    frames++;
                }
                finally
                {
                    if (media is not null)
                    {
                        media->Release();
                    }

                    if (sample is not null)
                    {
                        sample->Release();
                    }
                }
            }

            return frames;
        }
        catch (Exception ex)
        {
            KittyTools.Infrastructure.Log.Warn($"video-frames.failed {ex.GetType().Name} 0x{ex.HResult:X8} frames={frames}");
            return -1;
        }
        finally
        {
            if (current is not null)
            {
                current->Release();
            }

            if (wanted is not null)
            {
                wanted->Release();
            }

            if (reader is not null)
            {
                reader->Release();
            }

            if (attributes is not null)
            {
                attributes->Release();
            }

            PInvoke.MFShutdown();
        }
    }
}
