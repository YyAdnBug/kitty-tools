// 便签的图片目录（PLAN-v13 第 2 批，照 mac Notes/NoteImageStore.swift；规则在 Core 的 NoteImageRules）：
// 数据目录下的 notes-images\（和 notes.sqlite3 放一起，**不和剪贴板共用**），文件名 `<编号>.<扩展名>`，编号是大写 UUID。
// - 存：PNG / JPEG / HEIC / GIF 原样（文件进来的连扩展名也照文件自己的）；别的格式（BMP、TIFF、WebP…）一律转 PNG。
//   原始输入按 160 MB 的保险上限，存下去的那份按 20 MB 卡；转码、写盘都在线程池上做（不卡 UI 线程）。先写文件、调用方再改正文——
//   崩在中间留下的文件就是孤儿，30 天后清掉。
// - 宽高只读文件头（WIC 的 BitmapDecoder，不解像素），按编号缓存在内存里。
// - **不在启动时删孤儿**（和备份恢复冲突）：没被任何便签引用（归档的、「最近删除」里的都算引用）满 30 天才删（Purge）。
// ponytail: 清点是「列一遍目录 + 每个文件名解一个 UUID」，几千张以内很快（UI 线程上做）；几万张再挪线程池。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal sealed class NoteImageStore(string directory)
{
    private readonly Dictionary<Guid, NoteImageRules.ImageSize> _sizes = new();

    public string Directory { get; } = directory;

    public sealed record Stored(NoteImages.Image Image, NoteImageRules.ImageSize Size);

    /// <summary>存 / 裁的结果：Stored 和 Rejection 有且只有一个。</summary>
    public sealed record StoreResult(Stored? Stored, NoteImageRules.Rejection? Rejection);

    private static StoreResult Fail(NoteImageRules.Rejection rejection) => new(null, rejection);

    public string PathFor(Guid id, string ext) => Path.Combine(Directory, $"{NoteImages.IdText(id)}.{ext}");

    public string PathFor(NoteImages.Image image) => PathFor(image.Id, image.Ext);

    /// <summary>缓存里的尺寸（没读过给 null；要读用 SizeOfAsync）。</summary>
    public NoteImageRules.ImageSize? CachedSize(Guid id) => _sizes.TryGetValue(id, out var size) ? size : null;

    public async Task<NoteImageRules.ImageSize?> SizeOfAsync(NoteImages.Image image)
    {
        if (_sizes.TryGetValue(image.Id, out var found))
        {
            return found;
        }

        var size = await ReadSizeAsync(PathFor(image));
        if (size is { } value)
        {
            _sizes[image.Id] = value;
        }

        return size;
    }

    public void Remember(Stored stored) => _sizes[stored.Image.Id] = stored.Size;

    /// <summary>目录里认得出的图片文件（编号 → 文件名）。</summary>
    public Dictionary<Guid, string> Files()
    {
        var found = new Dictionary<Guid, string>();
        try
        {
            if (!System.IO.Directory.Exists(Directory))
            {
                return found;
            }

            foreach (var path in System.IO.Directory.EnumerateFiles(Directory))
            {
                var name = Path.GetFileName(path);
                if (NoteImageRules.Identifier(name) is { } id)
                {
                    found[id] = name;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.images-list-failed {ex.GetType().Name}");
        }

        return found;
    }

    // ---- 存（线程池上）----

    public static Task<StoreResult> StoreFileAsync(string path, string directory)
        => Task.Run<StoreResult>(async () =>
        {
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists)
                {
                    return Fail(NoteImageRules.Rejection.Unreadable);
                }

                if (info.Length > NoteImageRules.MaxInputBytes)
                {
                    return Fail(NoteImageRules.Rejection.TooLarge);
                }

                var bytes = await File.ReadAllBytesAsync(path);
                return await WriteAsync(bytes, NoteImageRules.CleanExtension(Path.GetExtension(path)), directory);
            }
            catch
            {
                return Fail(NoteImageRules.Rejection.Unreadable);
            }
        });

    public static Task<StoreResult> StoreBytesAsync(byte[] bytes, string directory)
        => Task.Run(() => WriteAsync(bytes, null, directory));

    private static async Task<StoreResult> WriteAsync(byte[] bytes, string? preferred, string directory)
    {
        if (bytes.Length > NoteImageRules.MaxInputBytes)
        {
            return Fail(NoteImageRules.Rejection.TooLarge);
        }

        BitmapDecoder decoder;
        using var stream = new InMemoryRandomAccessStream();
        try
        {
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            decoder = await BitmapDecoder.CreateAsync(stream);
        }
        catch
        {
            return Fail(NoteImageRules.Rejection.Unreadable);
        }

        if ((long)decoder.PixelWidth * decoder.PixelHeight > NoteImageRules.MaxPixels)
        {
            return Fail(NoteImageRules.Rejection.TooManyPixels);
        }

        var kept = KeptExtension(decoder.DecoderInformation.CodecId);
        string ext;
        byte[] output;
        if (kept is not null)
        {
            ext = preferred is not null && ExtensionMatches(preferred, kept) ? preferred : kept;
            output = bytes;
        }
        else
        {
            try
            {
                output = await EncodePngAsync(decoder);
            }
            catch
            {
                return Fail(NoteImageRules.Rejection.Unreadable);
            }

            ext = "png";
        }

        if (output.Length > NoteImageRules.MaxFileBytes)
        {
            return Fail(NoteImageRules.Rejection.TooLarge);
        }

        var id = Guid.NewGuid();
        var target = Path.Combine(directory, $"{NoteImages.IdText(id)}.{ext}");
        try
        {
            System.IO.Directory.CreateDirectory(directory);
            var temporary = target + ".tmp";
            await File.WriteAllBytesAsync(temporary, output);
            File.Move(temporary, target, overwrite: true);
        }
        catch
        {
            return Fail(NoteImageRules.Rejection.Unsaved);
        }

        var size = await SizeOfAsync(decoder);
        return new StoreResult(new Stored(new NoteImages.Image(id, ext, null), size), null);
    }

    /// <summary>原样留下的四种格式（mac keptTypes）；别的转 PNG。</summary>
    private static string? KeptExtension(Guid codec)
    {
        if (codec == BitmapDecoder.PngDecoderId)
        {
            return "png";
        }

        if (codec == BitmapDecoder.JpegDecoderId)
        {
            return "jpg";
        }

        if (codec == BitmapDecoder.GifDecoderId)
        {
            return "gif";
        }

        return codec == BitmapDecoder.HeifDecoderId ? "heic" : null;
    }

    private static bool ExtensionMatches(string preferred, string kept) => kept switch
    {
        "jpg" => preferred is "jpg" or "jpeg",
        "heic" => preferred is "heic" or "heif",
        _ => preferred == kept,
    };

    private static async Task<byte[]> EncodePngAsync(BitmapDecoder decoder)
    {
        using var pixels = await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            new BitmapTransform(), ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetSoftwareBitmap(pixels);
        await encoder.FlushAsync();
        var bytes = new byte[output.Size];
        output.Seek(0);
        await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }

    /// <summary>一张图转成 PNG 字节（「拷贝图片」写剪贴板用；转正、转到 sRGB）。读不出给 null。</summary>
    public static Task<byte[]?> PngOfAsync(string path)
        => Task.Run<byte[]?>(async () =>
        {
            try
            {
                var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
                using var source = await file.OpenReadAsync();
                return await EncodePngAsync(await BitmapDecoder.CreateAsync(source));
            }
            catch
            {
                return null;
            }
        });

    // ---- 裁切（另存一张新图，同 mac：令牌写法不改，撤销回原图，原图没人用 30 天才删）----

    /// <summary>按原图（转正之后）的像素裁 rect，照原格式存一张新图（JPEG 照 JPEG，别的一律 PNG）。</summary>
    public static Task<StoreResult> CropAsync(
        string path, int x, int y, int width, int height, string directory)
        => Task.Run<StoreResult>(async () =>
        {
            try
            {
                var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
                using var source = await file.OpenReadAsync();
                var decoder = await BitmapDecoder.CreateAsync(source);
                var size = await SizeOfAsync(decoder);
                var transform = new BitmapTransform
                {
                    Bounds = new BitmapBounds
                    {
                        X = (uint)Math.Max(x, 0),
                        Y = (uint)Math.Max(y, 0),
                        Width = (uint)Math.Max(Math.Min(width, (int)decoder.OrientedPixelWidth - x), 1),
                        Height = (uint)Math.Max(Math.Min(height, (int)decoder.OrientedPixelHeight - y), 1),
                    },
                };
                using var pixels = await decoder.GetSoftwareBitmapAsync(
                    BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
                    ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
                var jpeg = decoder.DecoderInformation.CodecId == BitmapDecoder.JpegDecoderId;
                using var output = new InMemoryRandomAccessStream();
                var encoder = await BitmapEncoder.CreateAsync(jpeg ? BitmapEncoder.JpegEncoderId : BitmapEncoder.PngEncoderId, output);
                encoder.SetSoftwareBitmap(pixels);
                await encoder.FlushAsync();
                if (output.Size > NoteImageRules.MaxFileBytes)
                {
                    return Fail(NoteImageRules.Rejection.TooLarge);
                }

                var bytes = new byte[output.Size];
                output.Seek(0);
                await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
                var ext = jpeg ? "jpg" : "png";
                var id = Guid.NewGuid();
                var target = Path.Combine(directory, $"{NoteImages.IdText(id)}.{ext}");
                System.IO.Directory.CreateDirectory(directory);
                await File.WriteAllBytesAsync(target + ".tmp", bytes);
                File.Move(target + ".tmp", target, overwrite: true);
                var cropped = NoteImageRules.Size(
                    (int)pixels.PixelWidth, (int)pixels.PixelHeight, size.Dpi, orientation: 1);
                return new StoreResult(new Stored(new NoteImages.Image(id, ext, null), cropped), null);
            }
            catch
            {
                return Fail(NoteImageRules.Rejection.Unsaved);
            }
        });

    // ---- 读宽高 ----

    public static async Task<NoteImageRules.ImageSize?> ReadSizeAsync(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenReadAsync();
            var decoder = await BitmapDecoder.CreateAsync(stream);
            return await SizeOfAsync(decoder);
        }
        catch
        {
            return null;
        }
    }

    private static async Task<NoteImageRules.ImageSize> SizeOfAsync(BitmapDecoder decoder)
    {
        var orientation = 1;
        try
        {
            var properties = await decoder.BitmapProperties.GetPropertiesAsync(new[] { "System.Photo.Orientation" });
            if (properties.TryGetValue("System.Photo.Orientation", out var value) && value.Value is ushort raw)
            {
                orientation = raw;
            }
        }
        catch
        {
            // 没有方向（PNG、GIF）：照 1 算。
        }

        return NoteImageRules.Size((int)decoder.PixelWidth, (int)decoder.PixelHeight, decoder.DpiX, orientation);
    }

    // ---- 清理（30 天）----

    /// <summary>现在清一遍：referenced = 便签仓库里所有便签（含归档、最近删除）正文里的编号。返回删了几个文件。</summary>
    public int Purge(IReadOnlySet<Guid> referenced, long now)
    {
        var files = Files();
        var ledgerPath = Path.Combine(Directory, NoteImageRules.LedgerName);
        string? text = null;
        try
        {
            text = File.Exists(ledgerPath) ? File.ReadAllText(ledgerPath) : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.orphans-unreadable {ex.GetType().Name}");
        }

        var plan = NoteImageRules.Plan(files.Keys, referenced, NoteImageRules.ReadLedger(text), now);
        foreach (var id in plan.Remove)
        {
            try
            {
                File.Delete(Path.Combine(Directory, files[id]));
            }
            catch
            {
                // 列表和删之间被别的东西删了也不算错。
            }

            _sizes.Remove(id);
        }

        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            File.WriteAllText(ledgerPath + ".tmp", NoteImageRules.WriteLedger(plan.Ledger));
            File.Move(ledgerPath + ".tmp", ledgerPath, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.orphans-write-failed {ex.GetType().Name}");
        }

        if (plan.Remove.Count > 0)
        {
            Log.Info($"notes.images-purged count={plan.Remove.Count}");
        }

        return plan.Remove.Count;
    }
}
