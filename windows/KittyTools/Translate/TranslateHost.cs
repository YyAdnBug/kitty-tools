// 翻译浮窗的入口：划词 / 输入 / 复制即译 / 截图翻译 / 剪贴板里的「翻译」，还有不开浮窗的「划词翻译并替换」。
// 划词取到词之前不显示浮窗（先显示会抢走原窗口的焦点，选区就没了）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class TranslateHost
{
    private static TranslateWindow? _window;
    private static bool _copyTranslateHooked;
    private static bool _selectionBusy;

    /// <summary>正在跑的「划词翻译并替换」：再按一次热键取消。</summary>
    private static CancellationTokenSource? _replace;

    public static bool IsVisible => _window?.IsVisible == true;

    /// <summary>UI 截图自检用；正常入口不碰。</summary>
    public static Microsoft.UI.Xaml.Window? WindowForProbe => _window;

    /// <summary>正在「备份剪贴板 → Ctrl+C → 还原」取词：忙时忽略重复热键，截图也让路（第二版 §2 第 4 条）。</summary>
    public static bool IsSelectionBusy => _selectionBusy;

    public static void Initialize() => ApplyCopyTranslate();

    public static void ApplyCopyTranslate()
    {
        var service = ClipboardService.Instance;
        if (service is null || _copyTranslateHooked == SettingsService.Current.CopyTranslate)
        {
            return;
        }

        if (SettingsService.Current.CopyTranslate)
        {
            service.TextCopied += OnTextCopied;
        }
        else
        {
            service.TextCopied -= OnTextCopied;
        }

        _copyTranslateHooked = SettingsService.Current.CopyTranslate;
    }

    /// <summary>设置里换了第一 / 第二语言：浮窗收着的话，下次输入翻译照新语言重译（mac languageChanged）。</summary>
    public static void MarkLanguagesChanged() => _window?.MarkLanguagesChanged();

    public static void ToggleInput()
    {
        _window ??= new TranslateWindow();
        _window.ToggleInput();
    }

    public static void ShowInput(bool missedSelection = false)
    {
        OverlayHost.Hide(restoreForeground: false);
        _window ??= new TranslateWindow();
        _window.ShowInput(missedSelection);
    }

    public static async void ShowSelection()
    {
        // 连按两次 Alt+E 时两次「备份剪贴板 → Ctrl+C → 还原」会交错，第二次备份到的是第一次
        // Ctrl+C 的结果，用户原来的剪贴板就丢了。忙时直接忽略（同 mac：忙时忽略重复热键）。
        if (_selectionBusy || ScreenshotSession.IsActive)
        {
            Log.Info("translate.selection-busy");
            return;
        }

        _selectionBusy = true;
        try
        {
            OverlayHost.Hide(restoreForeground: false);
            _window?.Hide(restoreForeground: false);
            // 取词时的前台：替换原文要粘回它，粘之前核对进程还是不是它（PLAN-v9-translate B7）。
            var source = Foreground.Get();
            var target = Foreground.IsOurs(source) ? null : new ReplaceTarget(string.Empty, source, Foreground.PidOf(source));
            var text = await SelectionReader.ReadAsync(CancellationToken.None);
            _window ??= new TranslateWindow();
            if (string.IsNullOrWhiteSpace(text))
            {
                _window.ShowInput(missedSelection: true);
            }
            else
            {
                _window.ShowSelection(text, target is null ? null : target with { Text = text });
            }
        }
        catch (Exception ex)
        {
            Log.Error("translate.selection-failed", ex);
        }
        finally
        {
            _selectionBusy = false;
        }
    }

    public static void ShowText(string text, bool fromCopy = false)
    {
        OverlayHost.Hide(restoreForeground: false);
        _window ??= new TranslateWindow();
        _window.ShowText(text, fromCopy);
    }

    /// <summary>剪贴板面板里的 Ctrl+T：剪贴板面板留着，浮窗只露出（PLAN §7.4）。</summary>
    public static void ShowTextKeepOverlay(string text)
    {
        _window ??= new TranslateWindow();
        _window.ShowTextPassive(text);
    }

    /// <summary>
    /// 截图翻译：原文按设置记进剪贴板历史、或当成复制一次（F6）；浮窗照「浮窗位置」放（跟随鼠标 / 上次位置，D2 照 mac）。
    /// </summary>
    public static void ShowRecognized(string text)
    {
        if (SettingsService.Current.TranslateCopyRecognized && ClipboardWriter.WriteText(text))
        {
            ClipboardService.Instance?.MarkOwnWrite();
        }

        // 原文记进剪贴板历史（PLAN §9.4）；没开「复制识别出的原文」时不覆盖剪贴板。
        ClipboardService.Instance?.Store.RecordOwnText(text);
        _window ??= new TranslateWindow();
        _window.ShowText(text, fromCopy: false);
    }

    public static void Hide(bool restoreForeground = false) => _window?.Hide(restoreForeground);

    public static void AuditAccessibility() => _window?.AuditAccessibility();

    /// <summary>启动 3 秒后预建翻译浮窗（第二版 §4.2）。</summary>
    public static void Prewarm()
    {
        try
        {
            _window ??= new TranslateWindow();
            Log.Info("translate.prewarmed");
        }
        catch (Exception ex)
        {
            Infrastructure.Log.Warn($"translate.prewarm-failed {ex.GetType().Name}");
        }
    }

    /// <summary>打开设置 › 翻译；serviceId 不为空时直达那个服务的详情（错误卡的「打开设置」，F14）。</summary>
    public static void OpenSettings(string? serviceId = null)
    {
        _window?.Hide(restoreForeground: false);
        ShellRuntime.Instance?.ShowSettings(welcome: false, page: "translate", service: serviceId);
    }

    /// <summary>
    /// 划词翻译并替换（静默，照 mac translateAndReplace，PLAN-v9-translate F7）：取词 → 第一个启用的服务翻译（等完整结果）→
    /// 补回原选区首尾的空白 → 粘回替换选区。不开浮窗，用轻提示报进度和结果；翻译期间再按一次热键取消。默认不设快捷键。
    /// 等结果的几秒里前台换了程序、或自家窗口到了前台，就只复制不粘（免得粘进别处）。
    /// </summary>
    public static async void TranslateAndReplace()
    {
        if (_replace is { } running)
        {
            running.Cancel();
            _replace = null;
            NoticeHost.Show("已取消划词翻译并替换", string.Empty, NoticeTone.Normal);
            return;
        }

        if (_selectionBusy || ScreenshotSession.IsActive)
        {
            return;
        }

        // 自家浮层在前台时先收起、把前台还给原来的程序：不然读到的、粘进去的都是自己。
        // ponytail: 固定着的翻译浮窗也一起收了，替换完不再露出来（mac 会露回去）；要的话给浮窗加一个不抢焦点的重新露出。
        OverlayHost.Hide(restoreForeground: true);
        if (_window is { IsVisible: true } window && Foreground.IsOurs(Foreground.Get()))
        {
            window.Hide(restoreForeground: true);
        }

        var source = Foreground.Get();
        var pid = Foreground.PidOf(source);
        string? text;
        _selectionBusy = true;
        try
        {
            text = await SelectionReader.ReadAsync(CancellationToken.None);
        }
        finally
        {
            // 取完词就放开，等网络时不挡别的热键。
            _selectionBusy = false;
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            NoticeHost.Show("没有选中文字", string.Empty, NoticeTone.Warning);
            return;
        }

        var cts = new CancellationTokenSource();
        _replace = cts;
        NoticeHost.Show("翻译中…", "再按一次快捷键取消", NoticeTone.Normal,
            new NoticeAction("取消", () =>
            {
                if (_replace == cts)
                {
                    TranslateAndReplace();
                }
            }));
        try
        {
            var result = TranslateSession.Rewrap(await TranslateCoordinator.TranslateOnceAsync(text, cts.Token), text);
            if (cts.IsCancellationRequested)
            {
                return;
            }

            var now = Foreground.Get();
            if (source == default || Foreground.IsOurs(now) || Foreground.PidOf(now) != pid)
            {
                if (ClipboardWriter.WriteText(result))
                {
                    ClipboardService.Instance?.MarkOwnWrite();
                    ClipboardService.Instance?.Store.RecordOwnText(result);
                }

                NoticeHost.Show("已复制译文", "前台已不是取词的程序，没有替换", NoticeTone.Normal);
                return;
            }

            // 失败时 Paster 自己会说原因（切不回去 / 管理员窗口 / 剪贴板被占）。
            if (Paster.Paste(source, () => ClipboardWriter.WriteText(result), ClipboardService.Instance))
            {
                ClipboardService.Instance?.Store.RecordOwnText(result);
                NoticeHost.Show("已替换为译文", TranslateSession.Excerpt(result), NoticeTone.Normal);
            }
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            // 取消时提示已经换成「已取消」了。
        }
        catch (Exception ex)
        {
            if (!cts.IsCancellationRequested)
            {
                // 重试 = 再划一次：前台还是取词的程序（点提示不激活本 App），选区多半还在。
                NoticeHost.Show("翻译失败", ex.Message, NoticeTone.Error, new NoticeAction("重试", TranslateAndReplace));
            }
        }
        finally
        {
            if (_replace == cts)
            {
                _replace = null;
            }

            cts.Dispose();
        }
    }

    private static void OnTextCopied(string text)
    {
        // REVIEW R57：翻译功能关着就别弹浮窗（托盘里那个开关这时候也是藏着的，关不掉）。
        if (!Features.IsOn(Feature.Translate))
        {
            return;
        }

        if (!SettingsService.Current.CopyTranslate || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        // 去重跟最近一次翻译的原文比，不管它是从哪个入口来的（F18，mac worthTranslating 的 translated）。
        var (first, second) = TranslateServiceStore.Instance?.Languages ?? (Lang.ZhHans, Lang.En);
        if (!CopyTranslateRules.WorthTranslating(text, _window?.TranslatedSource, first, second))
        {
            return;
        }

        ShowText(text, fromCopy: true);
    }
}
