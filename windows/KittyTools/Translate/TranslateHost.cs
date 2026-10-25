// 翻译浮窗的入口：划词 / 输入 / 复制即译 / 剪贴板里的「翻译」。
// 划词取到词之前不显示浮窗（先显示会抢走原窗口的焦点，选区就没了）。
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class TranslateHost
{
    private static TranslateWindow? _window;
    private static bool _copyTranslateHooked;
    private static string? _lastCopyTranslated;
    private static bool _selectionBusy;

    public static bool IsVisible => _window?.IsVisible == true;

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
            var text = await SelectionReader.ReadAsync(CancellationToken.None);
            _window ??= new TranslateWindow();
            if (string.IsNullOrWhiteSpace(text))
            {
                _window.ShowInput(missedSelection: true);
            }
            else
            {
                _window.ShowSelection(text);
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

    /// <summary>截图翻译：浮窗贴着选区出现（PLAN-v2 §3.8），锚点是选区的全局像素矩形。</summary>
    public static void ShowTextNear(string text, Core.PixelRect anchor)
    {
        _window ??= new TranslateWindow();
        _window.ShowTextNear(text, anchor);
    }

    public static void Hide(bool restoreForeground = false) => _window?.Hide(restoreForeground);

    public static void OpenSettings()
    {
        _window?.Hide(restoreForeground: false);
        ShellRuntime.Instance?.ShowSettings(welcome: false, page: "translate");
    }

    private static void OnTextCopied(string text)
    {
        if (!SettingsService.Current.CopyTranslate || string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var (first, second) = TranslateServiceStore.Instance?.Languages ?? (Lang.ZhHans, Lang.En);
        var autoTarget = Langs.FromCode(SettingsService.Current.TranslateTarget) is null;
        if (!CopyTranslateRules.WorthTranslating(text, _lastCopyTranslated, first, second, autoTarget))
        {
            return;
        }

        _lastCopyTranslated = text.Trim();
        ShowText(text, fromCopy: true);
    }
}
