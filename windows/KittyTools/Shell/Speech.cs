// 朗读（第三版 §3.3；PLAN-v14 V5–V7 照 mac Speaker）：再点同一段就停，浮窗收起时停止，朗读中的那段按钮填实。
// - 句子（Toggle）：Windows.Media.SpeechSynthesis 合成、MediaPlayer 播放；声音按语言挑系统里装了的，同一语言有多个时优先
//   名字里带 Natural / Neural 的。
// - 英文单词（ToggleWord）：开着「英文单词用真人发音」（默认开）时放有道词典的真人录音（美 / 英，一个普通的 GET，3 秒超时、
//   要 200 + audio/*、≤ 1 MB），按「词 + 口音」在内存里记最近 32 个；关着、取不到时用系统的美式 / 英式声音念，不报错。
//   中文版 Windows 常常没装英式声音：en-GB 没有就用 en-US，再没有用系统默认（替用户定的，都不提示）。
// 日志只记 speech.recording-failed reason=…，不记词、不记地址。
using System.Net.Http.Headers;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class Speech
{
    private static SpeechSynthesizer? _synthesizer;
    private static MediaPlayer? _player;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _dispatcher;
    private static CancellationTokenSource? _download;

    /// <summary>真人录音单独一个 3 秒超时的客户端（翻译请求的是 30 秒）。</summary>
    private static readonly HttpClient Recordings = CreateClient();

    /// <summary>ponytail: 录音记最近 32 个（几 KB 一个），满了整个清掉；要更多再换成按使用时间淘汰（同 mac）。</summary>
    private static readonly Dictionary<string, byte[]> Cache = new();

    /// <summary>
    /// 正在读的那段的标识（读完、停了是 null）：句子是文字本身，单词是 SpeechText.Key(词, 口音)。朗读按钮按它画成「填实 + 动」，
    /// 再点同一段就停（mac Speaker.speaking / toggle，PLAN-v9-translate B20）。Changed 总在 UI 线程上发。
    /// </summary>
    public static string? Speaking { get; private set; }

    public static event Action? Changed;

    /// <summary>设置 › 翻译「英文单词发音」：美音（默认）/ 英音。</summary>
    public static Accent PreferredAccent => SpeechText.ParseAccent(SettingsService.Current.TranslateWordAccent);

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue(
            "KittyTools",
            typeof(Speech).Assembly.GetName().Version?.ToString(3) ?? "0"));
        return client;
    }

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

    /// <summary>读一个英文单词：真人录音，取不到用系统的美式 / 英式声音。accent 为 null 用设置里的「发音」。</summary>
    public static async void ToggleWord(string word, Accent? accent = null)
    {
        var chosen = accent ?? PreferredAccent;
        var key = SpeechText.Key(word, chosen);
        if (Speaking == key)
        {
            Stop();
            return;
        }

        Stop();
        if (word.Length == 0)
        {
            return;
        }

        var fallbackVoice = chosen == Accent.Uk ? "en-GB" : "en-US";
        if (!SettingsService.Current.TranslateWordRecording || SpeechText.RecordingUrl(word, chosen) is not { } url)
        {
            SpeakAs(word, fallbackVoice, key, exact: true);
            return;
        }

        _dispatcher ??= Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        Speaking = key;
        Changed?.Invoke();
        var cts = new CancellationTokenSource();
        _download = cts;
        if (!Cache.TryGetValue(key, out var data))
        {
            data = await FetchAsync(url, cts.Token);
        }

        // 下载完了：取消源用不着了（Stop 只取消还挂在 _download 上的那个）
        var cancelled = cts.IsCancellationRequested;
        if (ReferenceEquals(_download, cts))
        {
            _download = null;
        }

        cts.Dispose();
        if (cancelled || Speaking != key)
        {
            return;
        }

        if (data is null)
        {
            SpeakAs(word, fallbackVoice, key, exact: true);
            return;
        }

        if (Cache.Count >= 32)
        {
            Cache.Clear();
        }

        Cache[key] = data;
        try
        {
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(data);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            if (Speaking != key)
            {
                stream.Dispose();
                return;
            }

            Player().Source = MediaSource.CreateFromStream(stream, "audio/mpeg");
            Player().Play();
        }
        catch (Exception ex)
        {
            Log.Info($"speech.recording-failed reason=play {ex.GetType().Name}");
            SpeakAs(word, fallbackVoice, key, exact: true);
        }
    }

    /// <summary>下载录音：要 200 和音频类型、非空、不超过 1 MB；不成就 null（调用方退回系统声音，不报错）。</summary>
    private static async Task<byte[]?> FetchAsync(Uri url, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await Recordings.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                Log.Info("speech.recording-failed reason=status");
                return null;
            }

            if (response.Content.Headers.ContentType?.MediaType?.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) != true ||
                response.Content.Headers.ContentLength is > 1 << 20)
            {
                Log.Info("speech.recording-failed reason=type");
                return null;
            }

            var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (data.Length == 0 || data.Length > 1 << 20)
            {
                Log.Info("speech.recording-failed reason=type");
                return null;
            }

            return data;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception ex)
        {
            Log.Info($"speech.recording-failed reason={(ex is TaskCanceledException ? "timeout" : "network")}");
            return null;
        }
    }

    /// <summary>把这段文字读出来（先停掉上一段）；语言用语言代码。</summary>
    public static void Speak(string text, string? languageCode)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        Stop();
        SpeakAs(text, languageCode, text, exact: false);
    }

    /// <summary>
    /// 系统声音念 text，Speaking 记成 key。exact：口音要对上（en-GB 没有退 en-US，再没有用系统默认）；
    /// 否则同一语言里挑（第三版 §3.3）。
    /// </summary>
    private static async void SpeakAs(string text, string? languageCode, string key, bool exact)
    {
        try
        {
            _dispatcher ??= Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _synthesizer ??= new SpeechSynthesizer();
            var voice = exact ? ExactVoice(languageCode) : VoiceFor(languageCode);
            _synthesizer.Voice = voice ?? SpeechSynthesizer.DefaultVoice;
            Speaking = key;
            Changed?.Invoke();
            var stream = await _synthesizer.SynthesizeTextToStreamAsync(text);
            if (Speaking != key)
            {
                // 合成的时候又点了停 / 换了一段。
                return;
            }

            Player().Source = MediaSource.CreateFromStream(stream, stream.ContentType);
            Player().Play();
        }
        catch (Exception ex)
        {
            Speaking = null;
            Changed?.Invoke();
            Log.Warn($"speech.failed {ex.GetType().Name}");
            NoticeHost.Show("朗读失败", "系统里没有可用的语音", NoticeTone.Warning);
        }
    }

    /// <summary>事件只挂一次（以前每读一次多挂一个）；它们在后台线程上来，回 UI 线程再改状态。</summary>
    private static MediaPlayer Player()
    {
        if (_player is null)
        {
            _player = new MediaPlayer();
            _player.MediaEnded += (_, _) => Finished();
            _player.MediaFailed += (_, _) => Finished();
        }

        return _player;
    }

    public static void Stop()
    {
        _download?.Cancel();
        _download = null;
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

            return Preferred(candidates);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>口音要对上的声音：en-GB → en-US → null（系统默认）。</summary>
    private static VoiceInformation? ExactVoice(string? languageCode)
    {
        try
        {
            var voices = SpeechSynthesizer.AllVoices.ToList();
            foreach (var code in languageCode == "en-GB" ? new[] { "en-GB", "en-US" } : new[] { languageCode ?? "en-US" })
            {
                var matches = voices.Where(voice => string.Equals(voice.Language, code, StringComparison.OrdinalIgnoreCase)).ToList();
                if (matches.Count > 0)
                {
                    return Preferred(matches);
                }
            }
        }
        catch
        {
            // 取不到声音列表：交给系统默认。
        }

        return null;
    }

    private static VoiceInformation Preferred(List<VoiceInformation> candidates)
        => candidates.FirstOrDefault(voice =>
               voice.DisplayName.Contains("Natural", StringComparison.OrdinalIgnoreCase) ||
               voice.DisplayName.Contains("Neural", StringComparison.OrdinalIgnoreCase)) ??
           candidates[0];

    private static string? Base(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return null;
        }

        var lower = code.ToLowerInvariant();
        return lower.Length >= 2 ? lower[..2] : lower;
    }
}
