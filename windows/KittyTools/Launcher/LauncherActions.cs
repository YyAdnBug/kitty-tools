// 本 App 自己的动作：剪贴板历史、输入翻译、截图、截图翻译、识字、设置、退出。
// 名字和拼音都能搜到；退出排在最后（同系统命令），避免回车误退。
using KittyTools.Core;

namespace KittyTools;

internal static class LauncherActions
{
    public const string Clipboard = "action:clipboard";
    public const string Translate = "action:translate";
    public const string Screenshot = "action:screenshot";
    public const string ScreenshotTranslate = "action:screenshot-translate";
    public const string Ocr = "action:ocr";
    public const string Settings = "action:settings";
    public const string Quit = "action:quit";

    public static List<LauncherItem> Items() => new()
    {
        Item(Clipboard, "剪贴板历史", "Clipboard history"),
        Item(Translate, "输入翻译", "Translate"),
        Item(Screenshot, "截图", "Screenshot"),
        Item(ScreenshotTranslate, "截图翻译", "Screenshot translation"),
        Item(Ocr, "识字", "Text recognition"),
        Item(Settings, "设置", "Settings"),
        Item(Quit, "退出 Kitty Tools", "Quit Kitty Tools", priority: 1),
    };

    public static LauncherItem? Find(string target) => Items().FirstOrDefault(item => item.Target == target);

    public static void Execute(string target)
    {
        switch (target)
        {
            case Clipboard:
                OverlayHost.Show(OverlayKind.Clipboard);
                break;
            case Translate:
                TranslateHost.ShowInput();
                break;
            case Screenshot:
                NoticeHost.Show("截图", "第 5 批接上", NoticeTone.Normal);
                break;
            case ScreenshotTranslate:
                NoticeHost.Show("截图翻译", "第 5 批接上", NoticeTone.Normal);
                break;
            case Ocr:
                NoticeHost.Show("识字", "第 5 批接上", NoticeTone.Normal);
                break;
            case Settings:
                ShellRuntime.Instance?.ShowSettings(welcome: false);
                break;
            case Quit:
                ShellRuntime.Instance?.Exit();
                break;
        }
    }

    private static LauncherItem Item(string target, string title, string english, int priority = 0)
    {
        var pinyin = Pinyin.For(title);
        return new LauncherItem
        {
            Kind = LauncherKind.Action,
            Target = target,
            Title = title,
            Subtitle = "Kitty Tools",
            Names = new[]
            {
                LauncherMatch.Fold(title),
                LauncherMatch.Fold(english),
                pinyin?.Full,
            }.Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
            Initials = new[]
            {
                LauncherMatch.Initials(english),
                pinyin?.Initials,
            }.Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            Priority = priority,
        };
    }
}
