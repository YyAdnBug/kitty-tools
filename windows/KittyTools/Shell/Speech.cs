// 朗读（第三版 §3.3）：Windows.Media.SpeechSynthesis 合成，MediaPlayer 播放。
// 声音按语言挑系统里装了的；同一语言有多个时优先名字里带 Natural / Neural 的。
// 浮窗收起时停止；再点同一段就停（Toggle），朗读中的那段按钮填实。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace KittyTools;

internal static class Speech
{
    private static SpeechSynthesizer? _synthesizer;
    private static MediaPlayer? _player;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _dispatcher;

    /// <summary>
    /// 正在读的那段（读完、停了是 null）：朗读按钮按它画成「填实 + 动」，再点同一段就停（mac Speaker.speaking / toggle，
    /// PLAN-v9-translate B20）。Changed 总在 UI 线程上发。
    /// </summary>
    public static string? Speaking { get; private set; }

    public static event Action? Changed;

    /// <summary>朗读按钮：正在读这一段就停，否则从头读它（先停掉别的）。</summary>
    public static void Toggle(string text, string? languageCode)
    {
        if (Speaking == text)
        {
            Stop();
            return;
        }

        Speak(text, languageCode);
    }

    /// <summary>把这段文字读出来（先停掉上一段）；语言用语言代码。</summary>
    public static async void Speak(string text, string? languageCode)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        try
        {
            Stop();
            _dispatcher ??= Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _synthesizer ??= new SpeechSynthesizer();
            if (VoiceFor(languageCode) is { } voice)
            {
                _synthesizer.Voice = voice;
            }

            Speaking = text;
            Changed?.Invoke();
            var stream = await _synthesizer.SynthesizeTextToStreamAsync(text);
            if (Speaking != text)
            {
                // 合成的时候又点了停 / 换了一段。
                return;
            }

            if (_player is null)
            {
                // 事件只挂一次（以前每读一次多挂一个）；它们在后台线程上来，回 UI 线程再改状态。
                _player = new MediaPlayer();
                _player.MediaEnded += (_, _) => Finished();
                _player.MediaFailed += (_, _) => Finished();
            }

            _player.Source = MediaSource.CreateFromStream(stream, stream.ContentType);
            _player.Play();
        }
        catch (Exception ex)
        {
            Speaking = null;
            Changed?.Invoke();
            Log.Warn($"speech.failed {ex.GetType().Name}");
            NoticeHost.Show("朗读失败", "系统里没有可用的语音", NoticeTone.Warning);
        }
    }

    public static void Stop()
    {
        try
        {
            _player?.Pause();
            if (_player is not null)
            {
                _player.Source = null;
            }
        }
        catch
        {
            // 已经停掉的跳过。
        }

        if (Speaking is not null)
        {
            Speaking = null;
            Changed?.Invoke();
        }
    }

    private static void Finished() => _dispatcher?.TryEnqueue(() =>
    {
        Speaking = null;
        Changed?.Invoke();
    });

    /// <summary>按语言代码挑声音：同一语言里优先 Natural / Neural，其次第一个。</summary>
    public static VoiceInformation? VoiceFor(string? languageCode)
    {
        try
        {
            var voices = SpeechSynthesizer.AllVoices.ToList();
            if (voices.Count == 0)
            {
                return null;
            }

            var baseCode = Base(languageCode);
            var candidates = baseCode is null
                ? voices
                : voices.Where(voice => Base(voice.Language) == baseCode).ToList();
            if (candidates.Count == 0)
            {
                return voices[0];
            }

            return candidates.FirstOrDefault(voice =>
                       voice.DisplayName.Contains("Natural", StringComparison.OrdinalIgnoreCase) ||
                       voice.DisplayName.Contains("Neural", StringComparison.OrdinalIgnoreCase)) ??
                   candidates[0];
        }
        catch
        {
            return null;
        }
    }

    private static string? Base(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return null;
        }

        var lower = code.ToLowerInvariant();
        return lower.Length >= 2 ? lower[..2] : lower;
    }

    /// <summary>语言代码（Lang.Code()）→ BCP-47 前缀。</summary>
    public static string TagFor(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return "en";
        }

        return code.Replace('_', '-');
    }
}
