// 截图历史（PLAN-v8 第 1 批，照 mac 的 ShotHistory.swift）：截图、长截图、钉过的、录屏 / 录音 / GIF 都进这一个历史
// （识字、翻译不产出图，不进）。每条存原图 + 标注（JSON）+ 一张小缩略图：<数据目录>\shots\<id>.png、<id>-t.png，
// 记录在主库的 shots 表。录制的只记文件路径和一张封面（有的话），不复制文件。
// 和 mac 不一样（替用户定的）：画了标注的那几条另存一张成品 <id>-c.png——Windows 的标注渲染要冻结帧（马赛克取像素），
// 离开遮罩之后合成不了；没画标注的成品就是原图，不多存。
// 默认留 30 天、总共 2 GB，超了先删最旧的（ShotHistoryRules.Stale）；天数和占用在 设置 › 截图 里改（PLAN-v9 S8）。
// 「保留截图历史」关掉或截图功能关掉时不记、已记的留着。
// 图不进每日备份、历史不进同步。写图在线程池，库只在 UI 线程上碰（和别的几个 store 共用主库连接）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal sealed class ShotItem
{
    public string Id { get; init; } = string.Empty;

    public ShotKind Kind { get; init; }

    /// <summary>Unix 毫秒。</summary>
    public long CreatedAt { get; init; }

    /// <summary>原图的像素尺寸（录制的是封面的；没有封面是 0）。</summary>
    public int PixelWidth { get; init; }

    public int PixelHeight { get; init; }

    /// <summary>截的那块屏的缩放（1.5 = 150%）。</summary>
    public double Scale { get; init; } = 1;

    /// <summary>截的时候前台是哪个程序（拿不到就是 null）。</summary>
    public string? Source { get; init; }

    /// <summary>存过盘的话存到哪了（文件可能被挪走、删掉，那一条照样能看）。</summary>
    public string? SavedPath { get; set; }

    /// <summary>录制的那个文件。</summary>
    public string? FilePath { get; init; }

    /// <summary>当初画的标注（坐标是原图里的像素），第 3 批的标注遮罩接着改。</summary>
    public List<ShotAnnotationData> Annotations { get; set; } = new();

    /// <summary>钉过的时间（Unix 毫秒）。</summary>
    public long? PinnedAt { get; set; }

    /// <summary>当初在屏幕上框的那一块（物理像素，全局坐标），钉回原位用；录制的没有。</summary>
    public PixelBounds? Frame { get; init; }

    /// <summary>原图 + 缩略图占多少字节（算总量上限用）。</summary>
    public long Bytes { get; init; }
}

/// <summary>标注和存盘的样子互转（规则在 Core 的 ShotHistoryRules.ToData / FromData，配单测）。</summary>
internal static class ShotAnnotations
{
    public static ShotAnnotationData ToData(Annotation annotation, double dx, double dy)
        => ShotHistoryRules.ToData(annotation, dx, dy);

    /// <summary>
    /// 存盘的 → 标注；认不得的工具名返回 null。文字的框按这块屏的缩放重新量（旧数据没存大小，5d 之前存的是 Segoe UI 16 量的）。
    /// </summary>
    public static Annotation? FromData(ShotAnnotationData data, double dx, double dy, double scale)
        => ShotHistoryRules.FromData(data, dx, dy) is { } annotation
            ? annotation.Kind == AnnotationKind.Text ? AnnotationRenderer.Measured(annotation, scale) : annotation
            : null;
}

internal sealed class ShotHistory
{
    private const string Columns =
        "id, kind, created_at, pixel_width, pixel_height, scale_percent, source_name, saved_path, file_path, " +
        "annotations, pinned_at, bytes, frame";

    private readonly Database _database;
    private readonly DispatcherQueue _queue;
    private readonly List<ShotItem> _items = new();

    private ShotHistory(Database database, DispatcherQueue queue)
    {
        _database = database;
        _queue = queue;
        Directory.CreateDirectory(Folder);
        Reload();
        Prune();
    }

    public static ShotHistory? Instance { get; private set; }

    public static string Folder => Path.Combine(Paths.DataDirectory, "shots");

    /// <summary>记不记：截图功能开着、「保留截图历史」开着。</summary>
    public static bool IsOn => SettingsService.Current.ShotHistory && Features.IsOn(Feature.Screenshot);

    /// <summary>新的在前。</summary>
    public IReadOnlyList<ShotItem> Items => _items;

    /// <summary>加了、删了、改了（历史窗口据此刷新）。在 UI 线程上触发。</summary>
    public event Action? Changed;

    /// <summary>某一条的缩略图重做好了（改了标注之后）：历史窗口清掉它的缓存。</summary>
    public event Action<string>? ThumbnailChanged;

    public static void Start(Database database, DispatcherQueue queue)
    {
        try
        {
            Instance = new ShotHistory(database, queue);
        }
        catch (Exception ex)
        {
            Log.Error("shots.start-failed", ex);
        }
    }

    public static string ImagePath(string id) => Path.Combine(Folder, id + ".png");

    public static string ThumbnailPath(string id) => Path.Combine(Folder, id + "-t.png");

    /// <summary>画了标注的那几条的成品图（原图 + 标注）。</summary>
    public static string ComposedPath(string id) => Path.Combine(Folder, id + "-c.png");

    /// <summary>
    /// 截图 / 长截图：<paramref name="originalPng"/> 是没画标注的那张，<paramref name="composedPng"/> 是画了标注的成品
    /// （缩略图画成品，历史里一眼看到的就是最后那张；没有标注时传 null）。返回这一条的编号，没记返回 null。
    /// </summary>
    public static async Task<string?> RecordAsync(
        byte[] originalPng,
        int width,
        int height,
        double scale,
        ShotKind kind,
        IReadOnlyList<ShotAnnotationData>? annotations = null,
        byte[]? composedPng = null,
        string? savedPath = null,
        bool pinned = false,
        PixelBounds? frame = null,
        string? source = null)
    {
        if (Instance is not { } history || !IsOn)
        {
            return null;
        }

        var id = NewId();
        var bytes = await Task.Run(() => WriteFilesAsync(id, originalPng, composedPng ?? originalPng, composedPng));
        if (bytes is null)
        {
            return null;
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        history.OnUi(() => history.Add(new ShotItem
        {
            Id = id,
            Kind = kind,
            CreatedAt = now,
            PixelWidth = width,
            PixelHeight = height,
            Scale = scale,
            // 来源程序：开遮罩之前记下的前台程序（PLAN-v9 S13，ScreenshotSession.ForegroundAppName）；拿不到是 null，历史窗口就不显示。
            Source = source,
            SavedPath = savedPath,
            Annotations = annotations?.ToList() ?? new List<ShotAnnotationData>(),
            PinnedAt = pinned ? now : null,
            Frame = frame,
            Bytes = bytes.Value,
        }));
        return id;
    }

    /// <summary>
    /// 录屏 / 录音 / GIF：文件归保存的文件夹管，这里只记路径和一张封面。没给封面时录屏取 0.5 s 那一帧、GIF 取第一帧，
    /// 录音没有封面（历史窗口画波形图标）。哪个线程调都行。
    /// </summary>
    public static async Task RecordFileAsync(string file, ShotKind kind, byte[]? posterPng = null)
    {
        if (Instance is not { } history || !IsOn)
        {
            return;
        }

        try
        {
            posterPng ??= kind switch
            {
                ShotKind.Video => await VideoPosterAsync(file),
                ShotKind.Gif => await File.ReadAllBytesAsync(file),
                _ => null,
            };
        }
        catch (Exception ex)
        {
            Log.Warn($"shots.poster-failed {ex.GetType().Name}");
            posterPng = null;
        }

        var id = NewId();
        long bytes = 0;
        var width = 0;
        var height = 0;
        if (posterPng is not null && await ImageCodec.ReadPngAsync(posterPng) is { } poster)
        {
            width = poster.Width;
            height = poster.Height;
            bytes = await Task.Run(() => WriteFilesAsync(id, null, posterPng, null)) ?? 0;
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        history.OnUi(() => history.Add(new ShotItem
        {
            Id = id,
            Kind = kind,
            CreatedAt = now,
            PixelWidth = width,
            PixelHeight = height,
            SavedPath = file,
            FilePath = file,
            Bytes = bytes,
        }));
    }

    /// <summary>录屏的封面：0.5 s（不到 1 s 的取中间）那一帧，长边缩到缩略图那么大。</summary>
    internal static async Task<byte[]?> VideoPosterAsync(string path)
    {
        var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
        var clip = await Windows.Media.Editing.MediaClip.CreateFromFileAsync(file);
        var composition = new Windows.Media.Editing.MediaComposition();
        composition.Clips.Add(clip);
        var properties = clip.GetVideoEncodingProperties();
        var (width, height) = ShotHistoryRules.ThumbnailSize((int)properties.Width, (int)properties.Height);
        var at = TimeSpan.FromSeconds(Math.Min(0.5, clip.OriginalDuration.TotalSeconds / 2));
        using var image = await composition.GetThumbnailAsync(
            at, width, height, Windows.Media.Editing.VideoFramePrecision.NearestFrame);
        var bytes = new byte[image.Size];
        using (var reader = new Windows.Storage.Streams.DataReader(image.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)image.Size);
            reader.ReadBytes(bytes);
        }

        return bytes;
    }

    /// <summary>存过盘了：那一条跟着记上存到哪（UI 线程）。</summary>
    public void MarkSaved(string id, string path)
    {
        if (Find(id) is not { } item)
        {
            return;
        }

        item.SavedPath = path;
        Execute("UPDATE shots SET saved_path = $p WHERE id = $id;", path, id);
        Changed?.Invoke();
    }

    /// <summary>又钉了一次（UI 线程）。</summary>
    public void MarkPinned(string id)
    {
        if (Find(id) is not { } item)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        item.PinnedAt = now;
        using var statement = _database.Connection.Prepare("UPDATE shots SET pinned_at = $at WHERE id = $id;");
        statement.BindInt64(1, now);
        statement.BindText(2, id);
        statement.Step();
        Changed?.Invoke();
    }

    /// <summary>改完标注回写同一条（原图不动），缩略图按新的成品重做（第 3 批的标注遮罩用）。</summary>
    public void UpdateAnnotations(string id, IReadOnlyList<ShotAnnotationData> annotations, byte[] composedPng)
    {
        if (Find(id) is not { } item)
        {
            return;
        }

        item.Annotations = annotations.ToList();
        Execute(
            "UPDATE shots SET annotations = $a WHERE id = $id;",
            ShotHistoryRules.EncodeAnnotations(annotations),
            id);
        Changed?.Invoke();
        _ = Task.Run(async () =>
        {
            if (annotations.Count > 0)
            {
                await File.WriteAllBytesAsync(ComposedPath(id), composedPng);
            }
            else
            {
                TryDelete(ComposedPath(id));
            }

            if (await ImageCodec.ScaledPngAsync(composedPng, ShotHistoryRules.ThumbnailSide) is { } small)
            {
                await File.WriteAllBytesAsync(ThumbnailPath(id), small);
                OnUi(() => ThumbnailChanged?.Invoke(id));
            }
        });
    }

    public ShotItem? Find(string id) => _items.FirstOrDefault(item => item.Id == id);

    /// <summary>原图（截图 / 长截图才有）；文件没了返回 null。</summary>
    public static byte[]? ReadImage(string id) => ReadFile(ImagePath(id));

    /// <summary>拷贝 / 存储 / 钉图用的成品：画了标注的是「编号-c.png」，没画的就是原图。</summary>
    public static byte[]? ReadOutput(string id) => ReadFile(ComposedPath(id)) ?? ReadFile(ImagePath(id));

    private static byte[]? ReadFile(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>这一条存过 / 录下来的那个文件还在不在。</summary>
    public static bool FileExists(ShotItem item)
        => (item.FilePath ?? item.SavedPath) is { Length: > 0 } path && File.Exists(path);

    /// <summary>删掉几条：记录和图都删，录制的文件不动（它归保存的文件夹管）。</summary>
    public void Remove(IReadOnlyCollection<string> ids)
    {
        if (ids.Count == 0)
        {
            return;
        }

        var doomed = new HashSet<string>(ids);
        _items.RemoveAll(item => doomed.Contains(item.Id));
        foreach (var id in doomed)
        {
            Execute("DELETE FROM shots WHERE id = $id;", id);
            TryDelete(ImagePath(id));
            TryDelete(ThumbnailPath(id));
            TryDelete(ComposedPath(id));
        }

        Log.Info($"shots.removed count={doomed.Count}");
        Changed?.Invoke();
    }

    /// <summary>过期的、超总量的清掉（启动时、每记一条之后）。</summary>
    public void Prune()
    {
        var stale = ShotHistoryRules.Stale(
            _items.Select(item => new ShotStaleItem(item.Id, item.CreatedAt, item.Bytes)),
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            Math.Max(0, SettingsService.Current.ShotHistoryDays),
            Math.Max(0, SettingsService.Current.ShotHistoryMegabytes) * 1_048_576L);
        if (stale.Count > 0)
        {
            Remove(stale);
        }
    }

    private void Add(ShotItem item)
    {
        _items.Insert(0, item);
        using (var statement = _database.Connection.Prepare(
            $"INSERT INTO shots({Columns}) VALUES($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);"))
        {
            statement.BindText(1, item.Id);
            statement.BindText(2, ShotHistoryRules.StorageName(item.Kind));
            statement.BindInt64(3, item.CreatedAt);
            statement.BindInt64(4, item.PixelWidth);
            statement.BindInt64(5, item.PixelHeight);
            statement.BindInt64(6, (long)Math.Round(item.Scale * 100));
            statement.BindText(7, item.Source);
            statement.BindText(8, item.SavedPath);
            statement.BindText(9, item.FilePath);
            statement.BindText(10, ShotHistoryRules.EncodeAnnotations(item.Annotations));
            if (item.PinnedAt is { } pinned)
            {
                statement.BindInt64(11, pinned);
            }
            else
            {
                statement.BindNull(11);
            }

            statement.BindInt64(12, item.Bytes);
            statement.BindText(13, item.Frame is { } frame
                ? $"{frame.Left},{frame.Top},{frame.Right},{frame.Bottom}"
                : null);
            statement.Step();
        }

        Log.Info($"shots.recorded kind={ShotHistoryRules.StorageName(item.Kind)} bytes={item.Bytes}");
        Prune();
        Changed?.Invoke();
    }

    private void Reload()
    {
        _items.Clear();
        using var statement = _database.Connection.Prepare(
            $"SELECT {Columns} FROM shots ORDER BY created_at DESC;");
        while (statement.Step())
        {
            if (ShotHistoryRules.Parse(statement.GetText(1)) is not { } kind || statement.GetText(0) is not { } id)
            {
                continue;
            }

            _items.Add(new ShotItem
            {
                Id = id,
                Kind = kind,
                CreatedAt = statement.GetInt64(2),
                PixelWidth = statement.GetInt32(3),
                PixelHeight = statement.GetInt32(4),
                Scale = Math.Max(1, statement.GetInt64(5)) / 100.0,
                Source = statement.GetText(6),
                SavedPath = statement.GetText(7),
                FilePath = statement.GetText(8),
                Annotations = ShotHistoryRules.DecodeAnnotations(statement.GetText(9)),
                PinnedAt = statement.IsNull(10) ? null : statement.GetInt64(10),
                Bytes = statement.GetInt64(11),
                Frame = ParseFrame(statement.GetText(12)),
            });
        }
    }

    private static PixelBounds? ParseFrame(string? text)
    {
        var parts = text?.Split(',');
        return parts is { Length: 4 } &&
               int.TryParse(parts[0], out var left) && int.TryParse(parts[1], out var top) &&
               int.TryParse(parts[2], out var right) && int.TryParse(parts[3], out var bottom)
            ? new PixelBounds(left, top, right, bottom)
            : null;
    }

    /// <summary>原图（可以没有）、成品（画了标注才有）和缩略图写盘，返回一共多少字节；写不成返回 null。在线程池上跑。</summary>
    private static async Task<long?> WriteFilesAsync(
        string id, byte[]? originalPng, byte[] thumbnailSource, byte[]? composedPng)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            long bytes = 0;
            if (originalPng is not null)
            {
                await File.WriteAllBytesAsync(ImagePath(id), originalPng);
                bytes += originalPng.Length;
            }

            if (composedPng is not null)
            {
                await File.WriteAllBytesAsync(ComposedPath(id), composedPng);
                bytes += composedPng.Length;
            }

            if (await ImageCodec.ScaledPngAsync(thumbnailSource, ShotHistoryRules.ThumbnailSide) is { } small)
            {
                await File.WriteAllBytesAsync(ThumbnailPath(id), small);
                bytes += small.Length;
            }

            return bytes;
        }
        catch (Exception ex)
        {
            Log.Warn($"shots.write-failed {ex.GetType().Name}");
            TryDelete(ImagePath(id));
            TryDelete(ThumbnailPath(id));
            TryDelete(ComposedPath(id));
            return null;
        }
    }

    private void Execute(string sql, string? first, string second)
    {
        using var statement = _database.Connection.Prepare(sql);
        statement.BindText(1, first);
        statement.BindText(2, second);
        statement.Step();
    }

    private void Execute(string sql, string only)
    {
        using var statement = _database.Connection.Prepare(sql);
        statement.BindText(1, only);
        statement.Step();
    }

    private void OnUi(Action action)
    {
        if (_queue.HasThreadAccess)
        {
            action();
        }
        else
        {
            _queue.TryEnqueue(() => action());
        }
    }

    private static string NewId() => Guid.NewGuid().ToString("D").ToUpperInvariant();

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // 删不掉留着，下次清理再试。
        }
    }
}
