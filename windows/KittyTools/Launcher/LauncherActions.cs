// 本 App 自己的动作：剪贴板历史、输入翻译、截图、截图翻译、识字、截图历史、录屏、设置、退出。
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
    public const string ShotHistory = "action:shot-history";
    public const string Record = "action:record";
    public const string Settings = "action:settings";
    public const string Quit = "action:quit";

    public static List<LauncherItem> Items() => new()
    {
        Item(Clipboard, "剪贴板历史", "Clipboard history"),
        Item(Translate, "输入翻译", "Translate"),
        Item(Screenshot, "截图", "Screenshot"),
        Item(ScreenshotTranslate, "截图翻译", "Screenshot translation"),
        Item(Ocr, "识字", "Text recognition"),
        Item(ShotHistory, "截图历史", "Screenshot history"),
        Item(Record, "录屏", "Screen recording"),
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
                StartScreenshotLater(ScreenshotMode.Capture);
                break;
            case ScreenshotTranslate:
                StartScreenshotLater(ScreenshotMode.Translate);
                break;
            case Ocr:
                StartScreenshotLater(ScreenshotMode.Ocr);
                break;
            case ShotHistory:
                ShotHistoryWindow.ShowWindow();
                break;
            case Record:
                StartLater(RecordingHost.Toggle);
                break;
            case Settings:
                ShellRuntime.Instance?.ShowSettings(welcome: false);
                break;
            case Quit:
                ShellRuntime.Instance?.Exit();
                break;
        }
    }

    private static void StartScreenshotLater(ScreenshotMode mode) => StartLater(() => ScreenshotSession.Start(mode));

    /// <summary>
    /// 启动器先收起再开截图 / 录屏：同一拍里开的话，冻结帧和录制的第一帧会拍到启动器自己
    /// （以前这三项一直是「第 5 批接上」的占位，PLAN-v8 顺手接上）。
    /// </summary>
    private static async void StartLater(Action start)
    {
        await Task.Delay(200);
        start();
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
