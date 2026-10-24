// 一次翻译会话：按设置里的源 / 目标解析方向，给每个启用的服务开一张卡并发流式请求；
// 只认第一张卡写自动复制。取消 = 停掉全部请求，半截译文不算完成。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal enum CardState
{
    Waiting,
    Running,
    Done,
    Failed,
    Truncated,
}

internal sealed class TranslateCard
{
    public required TranslateServiceConfig Service { get; init; }

    public CardState State { get; set; } = CardState.Waiting;

    public string Text { get; set; } = string.Empty;

    public bool Thinking { get; set; }

    public TranslateError? Error { get; set; }
}

internal sealed class TranslateCoordinator
{
    private readonly List<TranslateCard> _cards = new();
    private readonly Dictionary<string, CancellationTokenSource> _runs = new();
    private TranslateRequest? _request;
    private string? _copiedSource;

    public event Action? Changed;

    public event Action<string>? Notice;

    public IReadOnlyList<TranslateCard> Cards => _cards;

    public string SourceText { get; private set; } = string.Empty;

    public Lang? Detected { get; private set; }

    public Lang Target { get; private set; } = Lang.En;

    public Lang? FixedSource { get; private set; }

    public Lang? AbandonedTarget { get; private set; }

    public string? TranslatedSource { get; private set; }

    public bool IsRunning => _cards.Any(card => card.State is CardState.Waiting or CardState.Running);

    /// <summary>原文改过（只多了首尾空白不算）之后才显示「翻译 ↵」。</summary>
    public bool NeedsTranslate
        => SourceText.Trim().Length > 0 &&
           !string.Equals(SourceText.Trim(), TranslatedSource?.Trim(), StringComparison.Ordinal);

    public void SetSource(string text)
    {
        SourceText = text;
        Changed?.Invoke();
    }

    /// <summary>用当前原文开新会话。fromCopy：复制即译带来的（自动复制要跳过）。</summary>
    public void Translate(string text, bool fromCopy = false)
    {
        Cancel();
        SourceText = text;
        _copiedSource = fromCopy ? text.Trim() : null;
        TranslatedSource = null;
        AbandonedTarget = null;
        _cards.Clear();

        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            Changed?.Invoke();
            return;
        }

        if (System.Text.Encoding.UTF8.GetByteCount(trimmed) > CopyTranslateRules.MaxSourceBytes)
        {
            Notice?.Invoke("原文太长（上限 32 KB），请分段翻译");
            Changed?.Invoke();
            return;
        }

        var store = TranslateServiceStore.Instance;
        if (store is null)
        {
            return;
        }

        var (first, second) = store.Languages;
        Detected = Langs.Detect(trimmed, new[] { first, second });
        var chosenTarget = Langs.FromCode(SettingsService.Current.TranslateTarget);
        FixedSource = Langs.FromCode(SettingsService.Current.TranslateSource);
        var plan = Langs.Resolve(FixedSource, chosenTarget, Detected, first, second);
        Target = plan.To;
        AbandonedTarget = plan.FellBack ? chosenTarget : null;
        _request = new TranslateRequest(trimmed, plan.From, plan.To);
        TranslatedSource = trimmed;

        var enabled = store.Enabled.ToList();
        if (enabled.Count == 0)
        {
            Notice?.Invoke("没有启用的翻译服务，去设置 › 翻译里打开一个");
            Changed?.Invoke();
            return;
        }

        foreach (var service in enabled)
        {
            _cards.Add(new TranslateCard { Service = service });
        }

        Changed?.Invoke();
        foreach (var card in _cards)
        {
            _ = RunAsync(card);
        }
    }

    public void Retry(string serviceId)
    {
        var card = _cards.FirstOrDefault(item => item.Service.Id == serviceId);
        if (card is not null)
        {
            _ = RunAsync(card);
        }
    }

    public void Cancel()
    {
        foreach (var source in _runs.Values)
        {
            source.Cancel();
            source.Dispose();
        }

        _runs.Clear();
        foreach (var card in _cards)
        {
            if (card.State is CardState.Waiting or CardState.Running)
            {
                card.State = CardState.Failed;
                card.Error = TranslateError.Interrupted;
                card.Thinking = false;
            }
        }

        Changed?.Invoke();
    }

    /// <summary>按浮窗上选的源 / 目标和本地检测定这次的请求（纯逻辑，配单测的部分在 Core）。</summary>
    public static (LangPlan Plan, Lang? Detected) Plan(
        string text,
        Lang? fixedSource,
        Lang? chosenTarget,
        Lang first,
        Lang second)
    {
        var detected = Langs.Detect(text, new[] { first, second });
        return (Langs.Resolve(fixedSource, chosenTarget, detected, first, second), detected);
    }

    private async Task RunAsync(TranslateCard card)
    {
        if (_request is not { } request || TranslateServiceStore.Instance is not { } store)
        {
            return;
        }

        if (_runs.Remove(card.Service.Id, out var previous))
        {
            previous.Cancel();
            previous.Dispose();
        }

        var cts = new CancellationTokenSource();
        _runs[card.Service.Id] = cts;
        card.State = CardState.Waiting;
        card.Text = string.Empty;
        card.Error = null;
        card.Thinking = false;
        Changed?.Invoke();

        string latest = string.Empty;
        try
        {
            await foreach (var piece in TranslateServiceStore.Translate(
                               card.Service, request, cts.Token).WithCancellation(cts.Token))
            {
                latest = piece;
                card.State = CardState.Running;
                card.Text = piece;
                card.Thinking = piece.Length == 0;
                Changed?.Invoke();
            }

            if (cts.IsCancellationRequested)
            {
                return;
            }

            card.State = CardState.Done;
            card.Text = latest;
            card.Thinking = false;
            Changed?.Invoke();
            if (ReferenceEquals(card, _cards.FirstOrDefault()))
            {
                Finished(latest);
            }
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            // 取消不算完成：不复制、不写任何地方。
        }
        catch (TranslateError error) when (error == TranslateError.Truncated && latest.Length > 0)
        {
            card.State = CardState.Truncated;
            card.Text = latest;
            card.Thinking = false;
            card.Error = error;
            Changed?.Invoke();
        }
        catch (TranslateError error)
        {
            card.State = CardState.Failed;
            card.Text = latest;
            card.Thinking = false;
            card.Error = error;
            Changed?.Invoke();
        }
        catch (Exception)
        {
            card.State = CardState.Failed;
            card.Error = new TranslateError("翻译失败，请重试", TranslateErrorKind.Service);
            card.Thinking = false;
            Changed?.Invoke();
        }
        finally
        {
            if (_runs.TryGetValue(card.Service.Id, out var current) && current == cts)
            {
                _runs.Remove(card.Service.Id);
            }

            cts.Dispose();
        }
    }

    /// <summary>只认第一张卡：设置开了自动复制、且不是复制即译带来又没改过的原文时才复制。</summary>
    private void Finished(string text)
    {
        if (text.Length == 0 || !SettingsService.Current.TranslateAutoCopy)
        {
            return;
        }

        if (_copiedSource is not null && SourceText.Trim() == _copiedSource)
        {
            return;
        }

        if (!ClipboardWriter.WriteText(text))
        {
            return;
        }

        ClipboardService.Instance?.MarkOwnWrite();
        ClipboardService.Instance?.Store.RecordOwnText(text);
        Notice?.Invoke("已复制译文");
    }
}
