// 便签正文编辑器里跟图片有关的那一半（PLAN-v13 第 4 / 7 批，照 mac Notes/NoteTextView+Images.swift；令牌在 Core 的 NoteImages）：
// - 载入：正文里每张图先是一个占位的 U+FFFC，图片目录里读到了就换成 RichEdit 的图片对象（InsertImage，宽高按令牌里的宽度或原图大小、
//   不超过这一行的可用宽）；读不到的留着空位（同 mac 的占位框）。
// - 插图：粘贴、拖进来、菜单「插入图片…」：先存进图片目录（线程池上），再插进正文——每张图独占一行，插完光标落到图下一行的行首
//   （NoteImages.InsertionPlan）；一步撤销。
// - 第 7 批：右键选区里的图——宽度五档（小 / 中 / 大 / 铺满 / 原始大小，令牌里的宽度，一步撤销）、裁切…（一个对话框里拖出要留下的那块，
//   另存一张新图换上去，令牌的宽度按裁下来的比例换算；原图没人用 30 天后清掉）、拷贝图片（转成 PNG 写剪贴板）。
//   mac 还能拖图片右下角的把手改宽、在原地盖一层裁：RichEdit 里的图拿不到把手，Windows 用菜单和对话框（MAC-DIFF）。
using System.Runtime.InteropServices.WindowsRuntime;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
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

    // ---- 第 7 批：宽度、裁切、拷贝 ----

    /// <summary>选区里的图：第几张、在正文里的位置。</summary>
    private List<(int Index, int Position)> SelectedImages()
    {
        var selection = Selection;
        var picked = new List<(int Index, int Position)>();
        var index = _text.AsSpan(0, Math.Min(selection.Location, _text.Length)).Count(ObjectChar);
        for (var position = selection.Location; position < Math.Min(selection.End, _text.Length); position++)
        {
            if (_text[position] != ObjectChar)
            {
                continue;
            }

            if (index < _images.Count)
            {
                picked.Add((index, position));
            }

            index++;
        }

        return picked;
    }

    /// <summary>右键菜单最前面的图片那几项（选区里没有图就不加）。</summary>
    private void AddImageItems(IList<MenuFlyoutItemBase> items)
    {
        var picked = SelectedImages();
        if (picked.Count == 0 || NoteId is null)
        {
            return;
        }

        var widths = picked.Select(item => _images[item.Index].Width).Distinct().ToList();
        var current = widths.Count == 1 ? NoteImages.PresetOf(widths[0]) : null;
        var width = new MenuFlyoutSubItem { Text = "图片宽度", Icon = new FontIcon { Glyph = "\uE740" } };
        foreach (var preset in NoteImages.Presets)
        {
            var item = new ToggleMenuFlyoutItem { Text = NoteImages.Title(preset), IsChecked = current == preset };
            item.Click += (_, _) => SetImageWidth(NoteImages.WidthOf(preset), picked);
            width.Items.Add(item);
        }

        items.Add(width);
        if (picked.Count == 1)
        {
            var one = picked[0];
            Add(items, "裁切…", "\uE7A8", () => _ = CropImageAsync(one), _images[one.Index].Ext != "gif");
            Add(items, "拷贝图片", Glyphs.Copy, () => _ = CopyImageAsync(_images[one.Index]), true);
        }

        items.Add(new MenuFlyoutSeparator());
    }

    /// <summary>改几张图的宽度（令牌里的宽度；字还是那几个 U+FFFC），一步撤销。</summary>
    private void SetImageWidth(int? width, IReadOnlyList<(int Index, int Position)> picked)
    {
        if (picked.All(item => item.Index < _images.Count && _images[item.Index].Width == width))
        {
            return;
        }

        _undo.Command(Snapshot());
        foreach (var (index, position) in picked)
        {
            if (index >= _images.Count)
            {
                continue;
            }

            var image = _images[index] with { Width = width };
            _images[index] = image;
            if (Images?.CachedSize(image.Id) is { } size && _imageBytes.TryGetValue(image.Id, out var bytes))
            {
                PlaceImage(position, image, size, bytes);
            }
        }

        Publish();
    }

    /// <summary>拷贝图片：转成 PNG 写剪贴板（同截图、钉图那一路）。</summary>
    private async Task CopyImageAsync(NoteImages.Image image)
    {
        if (Images is not { } store || await NoteImageStore.PngOfAsync(store.PathFor(image)) is not { } png)
        {
            NoticeHost.Show("读不出这张图片", string.Empty, NoticeTone.Warning);
            return;
        }

        var prepared = await ClipboardWriter.PrepareImageAsync(png);
        if (!ClipboardWriter.WriteImagePng(prepared.Png, prepared.Dib))
        {
            NoticeHost.Show("没能拷贝", "剪贴板被别的程序占着", NoticeTone.Warning);
        }
    }

    /// <summary>裁切：对话框里拖出要留下的那块，另存一张新图换上去（一步撤销，撤回原图）。</summary>
    private async Task CropImageAsync((int Index, int Position) picked)
    {
        if (Images is not { } store || picked.Index >= _images.Count || _box.XamlRoot is not { } root)
        {
            return;
        }

        var image = _images[picked.Index];
        var path = store.PathFor(image);
        if (await store.SizeOfAsync(image) is not { } size || await BytesAsync(store, image) is not { } bytes)
        {
            NoticeHost.Show("读不出这张图片", string.Empty, NoticeTone.Warning);
            return;
        }

        if (await NoteImageCrop.AskAsync(root, bytes, size) is not { } rect)
        {
            return;
        }

        var result = await NoteImageStore.CropAsync(path, rect.X, rect.Y, rect.Width, rect.Height, store.Directory);
        if (result.Stored is not { } stored)
        {
            var rejection = result.Rejection ?? NoteImageRules.Rejection.Unsaved;
            NoticeHost.Show(NoteImageRules.NoticeTitle(rejection), NoteImageRules.NoticeDetail(rejection), NoticeTone.Warning);
            return;
        }

        // 等对话框的这一会儿正文可能改过：还是同一张图、还在那个位置才换
        if (picked.Index >= _images.Count || _images[picked.Index] != image || picked.Position >= _text.Length
            || _text[picked.Position] != ObjectChar)
        {
            return;
        }

        store.Remember(stored);
        var fullWidth = size.Orientation is >= 5 and <= 8 ? size.PixelHeight : size.PixelWidth;
        var replaced = stored.Image with { Width = NoteImages.CroppedWidth(image.Width, fullWidth, rect.Width) };
        _undo.Command(Snapshot());
        _images[picked.Index] = replaced;
        if (await BytesAsync(store, replaced) is { } croppedBytes && picked.Position < _text.Length && _text[picked.Position] == ObjectChar)
        {
            PlaceImage(picked.Position, replaced, stored.Size, croppedBytes);
        }

        Publish();
    }
}
