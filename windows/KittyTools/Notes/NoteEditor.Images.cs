// 便签正文编辑器里跟图片有关的那一半（PLAN-v13 第 4 / 7 批，照 mac Notes/NoteTextView+Images.swift；令牌在 Core 的 NoteImages）：
// - 载入：正文里每张图先是一个占位的 U+FFFC，图片目录里读到了就换成 RichEdit 的图片对象（InsertImage，宽高按令牌里的宽度或原图大小、
//   不超过这一行的可用宽）；读不到的留着空位（同 mac 的占位框）。
// - 插图：粘贴、拖进来、菜单「插入图片…」：先存进图片目录（线程池上），再插进正文——每张图独占一行，插完光标落到图下一行的行首
//   （NoteImages.InsertionPlan）；一步撤销。
// - 宽度五档（小 / 中 / 大 / 铺满 / 原始大小）、裁切、拷贝图片：第 7 批。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Text;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal sealed partial class NoteEditor
{
    /// <summary>这一行能放多宽的图（正文框的宽减去内边距）。</summary>
    private double AvailableWidth => Math.Max((_box.ActualWidth > 0 ? _box.ActualWidth : 360) - _box.Padding.Left - _box.Padding.Right - 8, 40);

    /// <summary>一张图在正文里画多大：记了宽度按它（「铺满」= 这一行的可用宽），没记按原图大小；都不超过可用宽、按比例算高。</summary>
    private (int Width, int Height) DisplaySize(NoteImages.Image image, NoteImageRules.ImageSize size)
    {
        var available = AvailableWidth;
        var width = image.Width is { } wanted ? Math.Min(wanted, available) : Math.Min(size.Width, available);
        if (image.Width == NoteImages.MaxWidth)
        {
            width = available;
        }

        var height = size.Width > 0 ? width * size.Height / size.Width : width;
        return ((int)Math.Max(Math.Round(width), 1), (int)Math.Max(Math.Round(height), 1));
    }

    private partial async Task LoadImagesAsync()
    {
        if (Images is not { } store || _images.Count == 0)
        {
            return;
        }

        var noteId = NoteId;
        var wanted = _images.ToList();
        for (var index = 0; index < wanted.Count; index++)
        {
            var image = wanted[index];
            var bytes = await BytesAsync(store, image);
            var size = await store.SizeOfAsync(image);
            if (bytes is null || size is not { } known || NoteId != noteId)
            {
                continue;
            }

            // 等的这一会儿正文可能改过：按「第几张图」重新找它现在的位置，还是同一张才换
            var position = ObjectPosition(index);
            if (position < 0 || index >= _images.Count || _images[index] != image)
            {
                continue;
            }

            PlaceImage(position, image, known, bytes);
        }
    }

    /// <summary>第 index 个 U+FFFC 在哪（没有给 -1）。</summary>
    private int ObjectPosition(int index)
    {
        var seen = 0;
        for (var position = 0; position < _text.Length; position++)
        {
            if (_text[position] != ObjectChar)
            {
                continue;
            }

            if (seen == index)
            {
                return position;
            }

            seen++;
        }

        return -1;
    }

    private async Task<byte[]?> BytesAsync(NoteImageStore store, NoteImages.Image image)
    {
        if (_imageBytes.TryGetValue(image.Id, out var cached))
        {
            return cached;
        }

        try
        {
            var path = store.PathFor(image);
            if (!File.Exists(path))
            {
                return null;
            }

            var bytes = await File.ReadAllBytesAsync(path);
            _imageBytes[image.Id] = bytes;
            return bytes;
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.image-read-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>把 position 那个 U+FFFC（占位的字或旧的图）换成这张图（不算改字：字还是那一个 U+FFFC）。</summary>
    private void PlaceImage(int position, NoteImages.Image image, NoteImageRules.ImageSize size, byte[] bytes)
    {
        var (width, height) = DisplaySize(image, size);
        var stream = new MemoryStream(bytes, writable: false).AsRandomAccessStream();
        _applying = true;
        try
        {
            var selection = Selection;
            _box.Document.GetRange(position, position + 1).InsertImage(
                width, height, (int)(height * 0.8), VerticalCharacterAlignment.Baseline, "图片", stream);
            SetSelection(selection);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.image-place-failed {ex.GetType().Name}");
        }
        finally
        {
            _applying = false;
        }
    }

    private partial async Task<bool> PasteImagesAsync(DataPackageView content)
    {
        if (Images is not { } store)
        {
            return false;
        }

        var results = new List<NoteImageStore.StoreResult>();
        if (content.Contains(StandardDataFormats.StorageItems))
        {
            foreach (var item in await content.GetStorageItemsAsync())
            {
                if (item is StorageFile file && IsImageFile(file.Path))
                {
                    results.Add(await NoteImageStore.StoreFileAsync(file.Path, store.Directory));
                }
            }
        }
        else if (content.Contains(StandardDataFormats.Bitmap))
        {
            var reference = await content.GetBitmapAsync();
            using var stream = await reference.OpenReadAsync();
            var bytes = new byte[stream.Size];
            await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
            results.Add(await NoteImageStore.StoreBytesAsync(bytes, store.Directory));
        }

        if (results.Count == 0)
        {
            return false;
        }

        if (results.FirstOrDefault(result => result.Rejection is not null) is { Rejection: { } rejection })
        {
            NoticeHost.Show(NoteImageRules.NoticeTitle(rejection), NoteImageRules.NoticeDetail(rejection), NoticeTone.Warning);
        }

        var stored = results.Select(result => result.Stored).OfType<NoteImageStore.Stored>().ToList();
        if (stored.Count > 0)
        {
            InsertImages(stored);
        }

        return true;
    }

    private static bool IsImageFile(string path)
        => Path.GetExtension(path).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".gif" or ".heic" or ".heif" or ".bmp"
            or ".tif" or ".tiff" or ".webp";

    /// <summary>在选区那儿插几张已经存好的图（每张独占一行）：一步撤销。</summary>
    public void InsertImages(IReadOnlyList<NoteImageStore.Stored> stored)
    {
        if (stored.Count == 0)
        {
            return;
        }

        var selection = Selection;
        var plan = NoteImages.InsertionPlan(_text, selection, stored.Count);
        _undo.Command(Snapshot());
        foreach (var item in stored)
        {
            Images?.Remember(item);
        }

        // 先放字：[换行] FFFC (\r FFFC)… \r，再一张张换成图。图片表自己跟上（不经 OnTextChanging：那里把新冒出来的 U+FFFC 当成别处来的）
        var text = (plan.Lead ? "\n" : string.Empty) + string.Join("\n", stored.Select(_ => ObjectChar)) + (plan.Trail ? "\n" : string.Empty);
        var at = _text.AsSpan(0, selection.Location).Count(ObjectChar);
        var gone = _text.AsSpan(selection.Location, selection.Length).Count(ObjectChar);
        var old = _text;
        _applying = true;
        try
        {
            _box.Document.GetRange(selection.Location, selection.End).SetText(TextSetOptions.None, text.Replace('\n', '\r'));
            _text = ReadText();
        }
        finally
        {
            _applying = false;
        }

        _images.RemoveRange(Math.Min(at, _images.Count), Math.Min(gone, Math.Max(_images.Count - at, 0)));
        _images.InsertRange(Math.Min(at, _images.Count), stored.Select(item => item.Image));
        ShiftRoles(selection.Location, selection.End, _text.Length - old.Length);
        _pending.Record(new NoteRange(selection.Location, text.Length), _text.Length - old.Length);
        SetSelection(new NoteRange(selection.Location + plan.Caret, 0));
        Settle();
        var first = selection.Location + (plan.Lead ? 1 : 0);
        for (var index = 0; index < stored.Count; index++)
        {
            _ = PlaceStoredAsync(first + index * 2, stored[index]);
        }
    }

    private async Task PlaceStoredAsync(int position, NoteImageStore.Stored stored)
    {
        if (Images is not { } store || await BytesAsync(store, stored.Image) is not { } bytes)
        {
            return;
        }

        if (position < _text.Length && _text[position] == ObjectChar)
        {
            PlaceImage(position, stored.Image, stored.Size, bytes);
        }
    }

    /// <summary>同步拿下来的图到了：引用它们的占位换成图。</summary>
    public void ImagesArrived(IReadOnlySet<Guid> ids)
    {
        if (_images.Any(image => ids.Contains(image.Id)))
        {
            _ = LoadImagesAsync();
        }
    }
}
