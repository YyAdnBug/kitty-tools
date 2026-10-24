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

    public static bool IsVisible => _window?.IsVisible == true;

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

    public static void ShowText(string text, bool fromCopy = false)
    {
        OverlayHost.Hide(restoreForeground: false);
        _window ??= new TranslateWindow();
        _window.ShowText(text, fromCopy);
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
