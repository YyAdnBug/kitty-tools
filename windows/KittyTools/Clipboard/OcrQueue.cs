// 图片的后台识字（第三版 §5，E4）：一张一张排队，结果写进 clips.ocr_text。
// 用系统的 Windows.Media.Ocr（和截图识字同一套）；空闲回收时放掉引擎；全部识完 1.5 秒后自动释放。
// 只认图片文件；某一张失败就落成空串（= 识过、没字），下次启动也不再重试（REVIEW R46）。
// 剪贴板列表只许 UI 线程碰：排队取下一张、写结果都回 UI 线程，后台线程只解码和识字。
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class OcrQueue
{
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
                if (await NextAsync() is not { } next)
                {
                    break;
                }

                _engine ??= OcrEngine.TryCreateFromUserProfileLanguages();
                if (_engine is null)
                {
                    // 没装识字组件：这一轮停下，不把图记成「识过」，装上以后下次 Kick 照样能识。
                    Log.Warn("ocr.no-engine");
                    break;
                }

                // 失败（文件没了、解不开、识字抛错）也落成空串，免得每次启动都整张再解一遍、再失败一遍。
                var text = await RecognizeAsync(next.Path) ?? string.Empty;
                _dispatcher.TryEnqueue(() => ClipboardService.Instance?.Store.SetOcrText(next.Id, text));
                Log.Info($"ocr.done bytes={next.Bytes} chars={text.Length}");
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

    /// <summary>待识的下一张：回 UI 线程去取；没有了（或者派不回去）返回 null。</summary>
    private static Task<(long Id, int Bytes, string Path)?> NextAsync()
    {
        var done = new TaskCompletionSource<(long Id, int Bytes, string Path)?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = _dispatcher!.TryEnqueue(() =>
        {
            try
            {
                var store = ClipboardService.Instance?.Store;
                var next = store?.PendingOcr(limit: 1).FirstOrDefault();
                done.TrySetResult(next is null || store is null
                    ? null
                    : (next.Id, next.ImageBytes, store.Images.PathFor(next.Id)));
            }
            catch (Exception ex)
            {
                Log.Warn($"ocr.next-failed {ex.GetType().Name}");
                done.TrySetResult(null);
            }
        });
        if (!queued)
        {
            done.TrySetResult(null);
        }

        return done.Task;
    }

    private static async Task<string?> RecognizeAsync(string path)
    {
        try
        {
            var engine = _engine;
            if (engine is null || !File.Exists(path))
            {
                return null;
            }

            if (!_logged)
            {
                _logged = true;
                Log.Info($"ocr.engine lang={engine.RecognizerLanguage?.LanguageTag}");
            }

            var file = await StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            // REVIEW R46：超过识字引擎的上限先按比例缩（和截图那边 OcrService.Fit 同一个口径）。以前整张解码，
            // 一张 1440 × 30000 的长截图解出来约 172 MB，超了上限也认不出来。
            // ponytail: 长图缩到上限后字会变小、认得差；要更准就按上限切成几段分别识、再拼起来。
            var max = OcrEngine.MaxImageDimension;
            var longest = Math.Max(decoder.PixelWidth, decoder.PixelHeight);
            using var bitmap = longest > max
                ? await decoder.GetSoftwareBitmapAsync(
                    BitmapPixelFormat.Bgra8,
                    BitmapAlphaMode.Premultiplied,
                    new BitmapTransform
                    {
                        ScaledWidth = (uint)Math.Max(1, Math.Round(decoder.PixelWidth * (double)max / longest)),
                        ScaledHeight = (uint)Math.Max(1, Math.Round(decoder.PixelHeight * (double)max / longest)),
                        InterpolationMode = BitmapInterpolationMode.Fant,
                    },
                    ExifOrientationMode.IgnoreExifOrientation,
                    ColorManagementMode.DoNotColorManage)
                : await decoder.GetSoftwareBitmapAsync();
            var result = await engine.RecognizeAsync(bitmap);
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
