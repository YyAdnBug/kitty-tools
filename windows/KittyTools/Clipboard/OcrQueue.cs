// 图片的后台识字（第三版 §5，E4）：一张一张排队，结果写进 clips.ocr_text。
// 用系统的 Windows.Media.Ocr（和截图识字同一套）；空闲回收时放掉引擎；全部识完 1.5 秒后自动释放。
// 只认图片文件；失败就记日志、不再重试同一张（避免空转）。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class OcrQueue
{
    private static readonly HashSet<long> Failed = new();
    private static OcrEngine? _engine;
    private static DispatcherQueue? _dispatcher;
    private static bool _running;
    private static bool _logged;

    public static void Start(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        IdleReclaimer.Register(Release);
        _ = Task.Run(PumpAsync);
    }

    /// <summary>新图片入库后踢一下（已经跑着就不管）。</summary>
    public static void Kick() => _ = Task.Run(PumpAsync);

    public static void Release()
    {
        _engine = null;
        Log.Info("ocr.released");
    }

    private static async Task PumpAsync()
    {
        if (_running || _dispatcher is null)
        {
            return;
        }

        _running = true;
        try
        {
            while (true)
            {
                var store = ClipboardService.Instance?.Store;
                var next = store?.PendingOcr().FirstOrDefault(entry => !Failed.Contains(entry.Id));
                if (next is null)
                {
                    break;
                }

                var text = await RecognizeAsync(next);
                if (text is null)
                {
                    Failed.Add(next.Id);
                    continue;
                }

                _dispatcher.TryEnqueue(() =>
                {
                    ClipboardService.Instance?.Store.SetOcrText(next.Id, text);
                });
                Log.Info($"ocr.done bytes={next.ImageBytes} chars={text.Length}");
                await Task.Delay(200);
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"ocr.failed {ex.GetType().Name}");
        }
        finally
        {
            _running = false;
        }
    }

    private static async Task<string?> RecognizeAsync(ClipEntry entry)
    {
        try
        {
            var path = ClipboardService.Instance?.Store.Images.PathFor(entry.Id);
            if (path is null || !File.Exists(path))
            {
                return null;
            }

            _engine ??= OcrEngine.TryCreateFromUserProfileLanguages();
            if (_engine is null)
            {
                Log.Warn("ocr.no-engine");
                return null;
            }

            if (!_logged)
            {
                _logged = true;
                Log.Info($"ocr.engine lang={_engine.RecognizerLanguage?.LanguageTag}");
            }

            var file = await StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            using var bitmap = await decoder.GetSoftwareBitmapAsync();
            var result = await _engine.RecognizeAsync(bitmap);
            var text = result.Text;
            return string.IsNullOrWhiteSpace(text) ? string.Empty : text;
        }
        catch (Exception ex)
        {
            Log.Warn($"ocr.image-failed {ex.GetType().Name}");
            return null;
        }
    }
}
