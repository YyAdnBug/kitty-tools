// 翻译会话（照 mac TranslateCoordinator，PLAN-v9-translate 8a）：一段原文 → 预处理（去首尾空白、换行统一成 \n；开着「把同一段里的
// 换行接起来」就接）→ 检测语种、解析源 / 目标 → 所有启用的服务并行翻译（大模型逐字流式）。新会话取消旧会话的全部请求；单张卡可单独重试。
// 按列表顺序第一个翻成功的服务（主结果，TranslateSession.Primary）定下来时写历史、按设置自动复制一次：排在前面的出错了就往后取，
// 前面的还在跑就先等。截断的不算完成。被取消的请求一个字都不再写回卡片（每次跑一个号，旧号写不进新卡）。
// 替换原文只给划词来的会话（Replace）；静默的「划词翻译并替换」走 TranslateOnceAsync（只用第一个启用的服务、不开浮窗）。
// 流式的片段合并成 33 ms 刷一次窗口（REVIEW R45）；换状态（出完、出错、重试）照旧当场刷。
// ponytail: 读流、解析 JSON 还在 UI 线程上（每段很小）；量出来还卡再挪进线程池，只把累积好的字交回来。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32.Foundation;

namespace KittyTools;

internal sealed class TranslateCard
{
    public required TranslateServiceConfig Service { get; init; }

    public CardState State { get; set; } = CardState.Waiting;

    /// <summary>到目前为止的译文；出错时是空的（出错只显示错误行）。</summary>
    public string Text { get; set; } = string.Empty;

    /// <summary>生成中、还没有正文：模型在思考（卡片上「思考中」）。</summary>
    public bool Thinking => State == CardState.Running && Text.Length == 0;

    public TranslateError? Error { get; set; }
}

/// <summary>划词来的会话：取到的原文（不去首尾空白，替换时照它补回）、取词时的前台窗口和它的进程（粘之前核对）。</summary>
internal sealed record ReplaceTarget(string Text, HWND Window, uint ProcessId);

internal sealed class TranslateCoordinator
{
    /// <summary>复制后卡上的对勾留多久（mac Style.copiedHold）。</summary>
    public static readonly TimeSpan CopiedHold = TimeSpan.FromSeconds(1.2);

    private readonly List<TranslateCard> _cards = new();
    private readonly Dictionary<string, (int Run, CancellationTokenSource Cts)> _runs = new();
    private int _runCounter;
    private TranslateRequest? _request;

    /// <summary>复制即译带来的原文（去首尾空白）：没改过就不自动复制（免得盖掉刚复制的原文）；别的入口开会话时清掉。</summary>
    private string? _copiedSource;

    /// <summary>这次会话已经按哪个服务写过历史 / 自动复制过：主结果定下来时只做一次。</summary>
    private string? _recordedPrimary;

    private int _copyTick;

    /// <summary>流式片段的刷新合并成一拍（33 ms，一次性的计时器）：以前每来一段就把所有卡片、窗口高度重算一遍。</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _streamTimer;

    public event Action? Changed;

    /// <summary>复制了一张卡（服务 id）：卡上换对勾、整张卡闪一下。</summary>
    public event Action<string>? Copied;

    /// <summary>给读屏的播报（焦点一直在原文框，卡上的对勾、星标读屏看不到）。</summary>
    public event Action<string>? Announce;

    public IReadOnlyList<TranslateCard> Cards => _cards;

    /// <summary>流式片段来了：33 ms 之内再来的并进同一拍，拍子到了用当时最新的字刷一次。没有 UI 线程（单测）就当场刷。</summary>
    private void ChangedSoon()
    {
        if (_streamTimer is null)
        {
            if (Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread() is not { } queue)
            {
                Changed?.Invoke();
                return;
            }

            _streamTimer = queue.CreateTimer();
            _streamTimer.Interval = TimeSpan.FromMilliseconds(33);
            _streamTimer.IsRepeating = false;
            _streamTimer.Tick += (_, _) => Changed?.Invoke();
        }

        if (!_streamTimer.IsRunning)
        {
            _streamTimer.Start();
        }
    }

    public string SourceText { get; private set; } = string.Empty;

    /// <summary>划词没取到文字、当输入翻译打开的：原文框占位换成「没取到选中的文字…」，开始输入就恢复。</summary>
    public bool MissedSelection { get; private set; }

    /// <summary>最近一次翻译的原文（去首尾空白）；复制即译拿它去重。</summary>
    public string? TranslatedSource { get; private set; }

    /// <summary>本地检测出的原文语种（偏向第一 / 第二语言；纯数字等认不出时为 null）。</summary>
    public Lang? Detected { get; private set; }

    /// <summary>实际译成的语言。</summary>
    public Lang? Target { get; private set; }

    /// <summary>这次用的固定源语言（null = 自动检测）；方向标签按这次的值，不看浮窗上此刻的选择。</summary>
    public Lang? FixedSource { get; private set; }

    /// <summary>选的固定目标正好是原文语言、这次改按「自动」译了：记下原来选的目标（「原文已是 X，改译成 Y」）。</summary>
    public Lang? AbandonedTarget { get; private set; }

    public ReplaceTarget? Replace { get; private set; }

    /// <summary>刚被复制的卡（Ctrl+1–9、卡上的复制、自动复制），卡上短暂显示对勾。</summary>
    public string? CopiedCard { get; private set; }

    /// <summary>结果区的提示（原文太长这类）；有它就不画卡片。</summary>
    public string? Notice { get; private set; }

    /// <summary>这次原文是单个词、大模型按词典格式回答（结果是释义：不自动复制、不给「替换原文」）。</summary>
    public bool IsWordLookup { get; private set; }

    /// <summary>浮窗收着时在设置里换了第一 / 第二语言：卡片还是旧语言的，下次 ResumeInput 照新语言重译。</summary>
    public bool LanguageChanged { get; set; }

    public bool IsRunning => _cards.Any(card => card.State is CardState.Waiting or CardState.Running);

    /// <summary>原文改过还没重新翻译：原文框右下角出「翻译 ↩」。</summary>
    public bool NeedsTranslate => TranslateSession.IsEdited(SourceText, TranslatedSource);

    /// <summary>主结果：按列表顺序第一个翻成功的卡（写历史、自动复制、收藏、替换原文都认它）。</summary>
    public TranslateCard? Primary
    {
        get
        {
            var index = TranslateSession.Primary(_cards.Select(card => (card.State, card.Text)).ToList());
            return index >= 0 ? _cards[index] : null;
        }
    }

    /// <summary>这次翻译收藏了没有（星标）。</summary>
    public bool IsFavorite
        => _request is { } request && TranslationHistory.Instance?.IsFavorite(request.Text, request.To.Code()) == true;

    /// <summary>替换原文这时能不能用：划词来的、主结果出来了、不是查词。</summary>
    public bool CanReplace => Replace is not null && !IsWordLookup && Primary is not null;

    public void SetSource(string text)
    {
        SourceText = text;
        if (text.Length > 0)
        {
            MissedSelection = false;
        }

        Changed?.Invoke();
    }

    /// <summary>清空上一次的内容等输入（划词没取到文字、浮窗里的「清空」）。输入翻译热键不走这里（保留上次的，见 ResumeInput）。</summary>
    public void BeginInput(bool missedSelection = false)
    {
        Cancel();
        SourceText = string.Empty;
        MissedSelection = missedSelection;
        TranslatedSource = null;
        Replace = null;
        _copiedSource = null;
        _request = null;
        _cards.Clear();
        IsWordLookup = false;
        Detected = null;
        Target = null;
        FixedSource = null;
        AbandonedTarget = null;
        Notice = null;
        Changed?.Invoke();
    }

    /// <summary>输入翻译再打开浮窗：保留上次的原文和结果（调用方把原文全选）；上次收起时被中断的卡重新跑。收着时换过语言的整个重译。</summary>
    public void ResumeInput()
    {
        Notice = null;
        MissedSelection = false;
        if (LanguageChanged && SourceText.Trim().Length > 0)
        {
            Start();
            return;
        }

        foreach (var card in _cards.Where(card => card.State == CardState.Failed && card.Error == TranslateError.Interrupted).ToList())
        {
            _ = RunAsync(card);
        }

        Changed?.Invoke();
    }

    /// <summary>开新会话。replace：划词来的（浮窗里给「替换原文」）；fromCopy：复制即译带来的（不自动复制）。</summary>
    public void Translate(string text, ReplaceTarget? replace = null, bool fromCopy = false)
    {
        SourceText = text;
        Replace = replace;
        _copiedSource = fromCopy ? text.Trim() : null;
        Start();
    }

    /// <summary>用当前原文开新会话（Enter、Ctrl+R、换了语言）。</summary>
    public void Start()
    {
        LanguageChanged = false;
        Cancel();
        Notice = null;
        MissedSelection = false;
        TranslatedSource = SourceText.Trim();
        var text = Preprocess(SourceText, SettingsService.Current.TranslateJoinLines);
        if (text.Length == 0)
        {
            Changed?.Invoke();
            return;
        }

        if (System.Text.Encoding.UTF8.GetByteCount(text) > CopyTranslateRules.MaxSourceBytes)
        {
            Notice = "原文太长（上限 32 KB），请分段翻译";
            _cards.Clear();
            Changed?.Invoke();
            return;
        }

        var plan = PlanFor(text, wordMode: true);
        Detected = plan.Detected;
        FixedSource = plan.FixedSource;
        Target = plan.Request.To;
        AbandonedTarget = plan.AbandonedTarget;
        _request = plan.Request;
        IsWordLookup = plan.Request.IsWord;
        _recordedPrimary = null;
        _cards.Clear();
        if (TranslateServiceStore.Instance is { } store)
        {
            _cards.AddRange(store.Enabled.Select(service => new TranslateCard { Service = service }));
        }

        Changed?.Invoke();
        foreach (var card in _cards.ToList())
        {
            _ = RunAsync(card);
        }
    }

    public void Retry(string serviceId)
    {
        if (_cards.FirstOrDefault(card => card.Service.Id == serviceId) is { } card)
        {
            _ = RunAsync(card);
        }
    }

    /// <summary>停掉还在跑的服务，没出完的卡标成中断（不然隐藏的浮窗里骨架、彗星、光标停不下来）。</summary>
    public void Cancel()
    {
        foreach (var (_, cts) in _runs.Values)
        {
            cts.Cancel();
            cts.Dispose();
        }

        _runs.Clear();
        foreach (var card in _cards.Where(card => card.State is CardState.Waiting or CardState.Running))
        {
            card.State = CardState.Failed;
            card.Error = TranslateError.Interrupted;
            card.Text = string.Empty;
        }

        Changed?.Invoke();
    }

    /// <summary>
    /// Ctrl+1–9 / 卡上的复制 / 自动复制：复制这张卡当前的译文（流式中也能复制已出来的部分）；返回是否复制了（没有字时调用方出提示音）。
    /// announces：播报「已复制译文」；自动复制不播，免得打断朗读。
    /// </summary>
    public bool CopyCard(string id, bool announces = true)
    {
        if (_cards.FirstOrDefault(card => card.Service.Id == id) is not { Text.Length: > 0 } card)
        {
            return false;
        }

        if (!ClipboardWriter.WriteText(card.Text))
        {
            NoticeHost.Show("没能复制", "剪贴板被别的程序占着", NoticeTone.Error);
            return true;
        }

        // 译文是本 App 给出的新文字：同时记进剪贴板历史。
        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(card.Text);
        CopiedCard = id;
        if (announces)
        {
            Announce?.Invoke("已复制译文");
        }

        var tick = ++_copyTick;
        Copied?.Invoke(id);
        _ = ClearCopiedAsync(tick);
        return true;
    }

    /// <summary>Ctrl+D / 星标：收藏或取消这次翻译（主结果定下来后才能收藏）；返回是否做了。关着历史时取消收藏 = 删掉这条。</summary>
    public bool ToggleFavorite()
    {
        if (_request is not { } request || Primary is not { } primary || TranslationHistory.Instance is not { } history)
        {
            return false;
        }

        var favorite = !IsFavorite;
        if (!favorite && !SettingsService.Current.TranslateHistoryEnabled)
        {
            history.Remove(request.Text, request.To.Code());
        }
        else
        {
            history.SetFavorite(request.Text, request.From?.Code(), request.To.Code(), primary.Text, primary.Service.Name, favorite);
        }

        Announce?.Invoke(favorite ? "已收藏" : "已取消收藏");
        Changed?.Invoke();
        return true;
    }

    /// <summary>
    /// 静默替换（划词翻译并替换）：不开浮窗、不动当前会话，只用第一个启用的服务、等完整结果；记历史（开着的话）。
    /// 不接行、不用单词模式：要替换回去的是译文、段落得保住。
    /// </summary>
    public static async Task<string> TranslateOnceAsync(string source, CancellationToken cancellationToken)
    {
        var text = Preprocess(source, joinLines: false);
        if (text.Length == 0 || System.Text.Encoding.UTF8.GetByteCount(text) > CopyTranslateRules.MaxSourceBytes)
        {
            throw new TranslateError("原文为空或太长");
        }

        if (TranslateServiceStore.Instance?.Enabled.FirstOrDefault() is not { } service)
        {
            throw TranslateError.Config("没有启用的翻译服务");
        }

        var request = PlanFor(text, wordMode: false).Request;
        var latest = string.Empty;
        await foreach (var piece in TranslateServiceStore.Translate(service, request, cancellationToken)
                           .WithCancellation(cancellationToken))
        {
            latest = piece;
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (latest.Length == 0)
        {
            throw TranslateError.EmptyResult;
        }

        var settings = SettingsService.Current;
        if (settings.TranslateHistoryEnabled)
        {
            TranslationHistory.Instance?.Add(
                request.Text, request.From?.Code(), request.To.Code(), latest, service.Name, settings.TranslateHistoryLimit);
        }

        return latest;
    }

    /// <summary>UI 截图自检（--ui-snapshots）：直接摆出一组卡片（不发请求）。正常入口不碰。</summary>
    internal void ShowProbe(string source, Lang detected, Lang target, IReadOnlyList<TranslateCard> cards)
    {
        Cancel();
        SourceText = source;
        TranslatedSource = source.Trim();
        MissedSelection = false;
        Replace = null;
        Notice = null;
        Detected = detected;
        Target = target;
        FixedSource = null;
        AbandonedTarget = null;
        IsWordLookup = false;
        _request = new TranslateRequest(source.Trim(), null, target);
        _recordedPrimary = null;
        _cards.Clear();
        _cards.AddRange(cards);
        Changed?.Invoke();
    }

    /// <summary>去首尾空白、换行统一成 \n（输入框给的是 \r）；开着就把同一段里的换行接起来（段间空一行，同识字）。</summary>
    private static string Preprocess(string source, bool joinLines)
    {
        var text = source.ReplaceLineEndings("\n").Trim();
        return joinLines ? OcrText.JoiningLines(text, "\n\n") : text;
    }

    /// <summary>按浮窗上选的源 / 目标（全局记住的）和检测结果定这次的请求；wordMode：单个词时让大模型按词典格式回答。</summary>
    private static (TranslateRequest Request, Lang? Detected, Lang? FixedSource, Lang? AbandonedTarget) PlanFor(
        string text, bool wordMode)
    {
        var settings = SettingsService.Current;
        var (first, second) = Langs.Pair(settings.TranslateFirstLanguage, settings.TranslateSecondLanguage);
        var detected = Langs.Detect(text, new[] { first, second });
        var chosenTarget = Langs.FromCode(settings.TranslateTarget);
        var fixedSource = Langs.FromCode(settings.TranslateSource);
        var plan = Langs.Resolve(fixedSource, chosenTarget, detected, first, second);
        var isWord = wordMode && settings.TranslateWordLookup && WordLookup.IsWord(text);
        return (new TranslateRequest(text, plan.From, plan.To, isWord), detected, fixedSource,
            plan.FellBack ? chosenTarget : null);
    }

    private async Task RunAsync(TranslateCard card)
    {
        if (_request is not { } request)
        {
            return;
        }

        var id = card.Service.Id;
        if (_runs.Remove(id, out var previous))
        {
            previous.Cts.Cancel();
            previous.Cts.Dispose();
        }

        // 重跑的正是记过历史的那个：出来了照常再记一次、再复制一次。
        if (_recordedPrimary == id)
        {
            _recordedPrimary = null;
        }

        var run = ++_runCounter;
        var cts = new CancellationTokenSource();
        _runs[id] = (run, cts);
        card.State = CardState.Waiting;
        card.Text = string.Empty;
        card.Error = null;
        Changed?.Invoke();

        // 取消后流里缓冲的增量照样会交出来：每一段都先看还是不是自己的，不然标成「已中断」的卡被改回生成中。
        bool Current() => !cts.IsCancellationRequested && _runs.TryGetValue(id, out var entry) && entry.Run == run;

        var latest = string.Empty;
        try
        {
            // R12 调试用：让请求停在等待状态，量等待动画期间的 CPU（KITTY_TRANSLATE_FAKE_DELAY_MS）。
            if (int.TryParse(Environment.GetEnvironmentVariable("KITTY_TRANSLATE_FAKE_DELAY_MS"), out var fakeDelay) &&
                fakeDelay > 0)
            {
                await Task.Delay(fakeDelay, cts.Token);
            }

            await foreach (var piece in TranslateServiceStore.Translate(card.Service, request, cts.Token)
                               .WithCancellation(cts.Token))
            {
                if (!Current())
                {
                    return;
                }

                latest = piece;
                card.State = CardState.Running;
                card.Text = piece;
                ChangedSoon();
            }

            // 取消时流会正常结束而不是抛错：半截结果不能当成完成。
            if (!Current())
            {
                return;
            }

            card.State = CardState.Done;
            card.Text = latest;
            _streamTimer?.Stop();
            Changed?.Invoke();
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception ex)
        {
            if (!Current())
            {
                return;
            }

            // 截断：半截照常显示、另写一行说明；不写历史、不自动复制（主结果不认它）。
            var error = ex as TranslateError ?? new TranslateError("翻译失败，请重试");
            var truncated = error == TranslateError.Truncated && latest.Length > 0;
            card.State = truncated ? CardState.Truncated : CardState.Failed;
            card.Text = truncated ? latest : string.Empty;
            card.Error = error;
            _streamTimer?.Stop();
            Changed?.Invoke();
        }
        finally
        {
            if (_runs.TryGetValue(id, out var current) && current.Run == run)
            {
                _runs.Remove(id);
            }

            cts.Dispose();
        }

        // 这一张成了、或者没成让后面已经出来的那张轮上：都在这里定主结果。
        SettlePrimary();
    }

    /// <summary>主结果定下来（或换成了另一个服务的）时写历史、自动复制，同一个服务只做一次：后面的服务再出来不各复制一次。</summary>
    private void SettlePrimary()
    {
        if (_request is not { } request || Primary is not { } primary || primary.Service.Id == _recordedPrimary)
        {
            return;
        }

        _recordedPrimary = primary.Service.Id;
        var settings = SettingsService.Current;
        if (settings.TranslateHistoryEnabled)
        {
            TranslationHistory.Instance?.Add(
                request.Text, request.From?.Code(), request.To.Code(), primary.Text, primary.Service.Name,
                settings.TranslateHistoryLimit);
        }

        // 单词模式的结果是释义，不自动复制；复制即译带来、还没改过的原文也不复制。
        if (TranslateSession.AutoCopies(settings.TranslateAutoCopy, request.IsWord, _copiedSource, TranslatedSource))
        {
            CopyCard(primary.Service.Id, announces: false);
        }

        Changed?.Invoke();
    }

    private async Task ClearCopiedAsync(int tick)
    {
        await Task.Delay(CopiedHold);
        if (tick == _copyTick)
        {
            CopiedCard = null;
            Changed?.Invoke();
        }
    }
}
