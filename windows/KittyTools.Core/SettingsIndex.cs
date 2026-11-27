// 设置项登记表（PLAN-v28 X3，照 mac Settings/SettingsIndex.swift，纯数据 + 匹配、排序的纯函数配单测）：设置里的每一行登记一项——
// 在哪一页、在页里哪儿（外面 / 推进去的子页 / 「高级」）、标题（和页面上那一行同一个字）、额外的搜索词、读写哪些设置（App 的 Settings 属性名）。
// - 侧栏搜索时最上面一组「设置项（N）」列对上的行（Matching），选一项就打开那一页 / 子页 / 高级、滚到那一行、描两秒强调色；
//   剪贴板面板、翻译浮窗这些地方的「设置…」也经它直达那一行。
// - 子页和「高级」最后一行的「恢复默认」只管登记在那里的设置（ResetKeys）；会当场删数据的上限和功能开关不管。
// - 视图上每一行调 Anchor("<id>", …)；单测读 App 的源码，查每一项都挂了、只挂了一次（SettingsIndexTests）。
// 新加一行设置：这里加一项、那一行挂上锚。
namespace KittyTools.Core;

/// <summary>
/// 设置里的一行。Sub：null = 页面上；"advanced" = 那一页的「高级」；别的 = 那一页推进去的子页（SettingsIndex.Subpages 里的名字）。
/// Keys：这一行读写的设置（App Settings 的属性名），只给恢复默认用；按钮、状态行和用户自己攒的列表空着。
/// </summary>
public sealed record SettingsItem(string Id, string Page, string? Sub, string Title, IReadOnlyList<string> Keywords, IReadOnlyList<string> Keys);

/// <summary>推进去的子页：所在页、名字（窗口里认它）、标题。</summary>
public sealed record SettingsSubpage(string Page, string Name, string Title);

public static class SettingsIndex
{
    public const string Advanced = "advanced";

    /// <summary>侧栏「设置项」那一组最多列几条。</summary>
    public const int ResultLimit = 12;

    /// <summary>页名（侧栏的那几个字）。</summary>
    public static readonly IReadOnlyDictionary<string, string> PageTitles = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["general"] = "通用",
        ["clipboard"] = "剪贴板",
        ["launcher"] = "启动器",
        ["translate"] = "翻译",
        ["screenshot"] = "截图",
        ["record"] = "录制",
        ["notes"] = "便签",
        ["reminders"] = "提醒",
        ["statusScreen"] = "状态屏",
        ["keepAwake"] = "保持唤醒",
        ["hotkeys"] = "快捷键",
        ["about"] = "关于",
        ["plugins"] = "插件",
    };

    /// <summary>
    /// 推进去的子页（「高级」另算，见 <see cref="Advanced"/>）。功能、插件、应用、网页搜索、命令和别名、怎么写脚本是原来就有的；
    /// 同步、备份与导出导入、截图历史、查词与朗读、翻译历史、屏幕边缘是 PLAN-v28 X2 新的。
    /// </summary>
    public static readonly IReadOnlyList<SettingsSubpage> Subpages = new[]
    {
        new SettingsSubpage("general", "features", "功能"),
        new SettingsSubpage("general", "sync", "同步"),
        new SettingsSubpage("general", "backup", "备份与导出导入"),
        new SettingsSubpage("screenshot", "history", "截图历史"),
        new SettingsSubpage("translate", "lookup", "查词与朗读"),
        new SettingsSubpage("translate", "history", "翻译历史"),
        new SettingsSubpage("launcher", "apps", "应用"),
        new SettingsSubpage("launcher", "web", "网页搜索与快捷链接"),
        new SettingsSubpage("launcher", "scripts", "脚本命令"),
        new SettingsSubpage("launcher", "script-guide", "怎么写脚本"),
        new SettingsSubpage("launcher", "commands", "命令和别名"),
        new SettingsSubpage("notes", "deck", "屏幕边缘"),
    };

    /// <summary>子页的上一层（怎么写脚本 → 脚本命令；别的都回到页本身 = null）。</summary>
    public static string? Parent(string page, string sub) => (page, sub) switch
    {
        ("launcher", "script-guide") => "scripts",
        _ => null,
    };

    public static SettingsSubpage? Subpage(string page, string sub)
        => Subpages.FirstOrDefault(subpage => subpage.Page == page && subpage.Name == sub);

    /// <summary>恢复默认不碰的上限：改回默认可能当场删掉历史（它们改小时自己会先问，撤销也回不来）。</summary>
    public static readonly IReadOnlySet<string> Limits = new HashSet<string>(StringComparer.Ordinal)
    {
        "ClipboardRetentionDays", "ClipboardImageBudgetMB", "ShotHistoryDays", "ShotHistoryMegabytes", "TranslateHistoryLimit",
    };

    /// <summary>登记的全部行（顺序 = 页面上的先后；搜索同一档里按它排）。</summary>
    public static readonly IReadOnlyList<SettingsItem> Items = Build();

    private static readonly Dictionary<string, SettingsItem> ById = Items.ToDictionary(item => item.Id, StringComparer.Ordinal);

    /// <summary>每项认的词算一次就够（每打一个字都要扫一遍全部）。</summary>
    private static readonly Dictionary<string, List<string>> WordsById = Items.ToDictionary(item => item.Id, item => ComputeWords(item).ToList(), StringComparer.Ordinal);

    private static readonly Dictionary<string, List<string>> PageWordsById = Items
        .GroupBy(item => item.Page)
        .ToDictionary(group => group.Key, group => group.SelectMany(item => WordsById[item.Id].Prepend(item.Title)).Distinct().ToList(), StringComparer.Ordinal);

    public static SettingsItem? Find(string id) => ById.GetValueOrDefault(id);

    /// <summary>侧栏结果第二行写的位置：外面的只写页名；子页「截图 › 截图历史」；高级「剪贴板 · 高级」。</summary>
    public static string Location(SettingsItem item) => Location(item.Page, item.Sub);

    public static string Location(string page, string? sub)
    {
        var title = PageTitles.GetValueOrDefault(page, page);
        if (sub is null)
        {
            return title;
        }

        return sub == Advanced ? $"{title} · 高级" : $"{title} › {Subpage(page, sub)?.Title ?? sub}";
    }

    /// <summary>某一处（页面上 / 子页 / 高级）登记的行。</summary>
    public static IEnumerable<SettingsItem> In(string page, string? sub)
        => Items.Where(item => item.Page == page && item.Sub == sub);

    /// <summary>这一页有没有「高级」。</summary>
    public static bool HasAdvanced(string page) => Items.Any(item => item.Page == page && item.Sub == Advanced);

    /// <summary>
    /// 这一处的「恢复默认」管哪些设置：登记在这里的行读写的（按登记的先后、去重），去掉会删数据的上限和功能开关（feature.*）。
    /// 哪些能写回默认（这台电脑自己的面板大小、文件夹这些没有默认值）由 App 那边再筛。
    /// </summary>
    public static List<string> ResetKeys(string page, string? sub)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return In(page, sub)
            .SelectMany(item => item.Keys)
            .Where(key => !Limits.Contains(key) && !key.StartsWith("feature.", StringComparison.Ordinal) && seen.Add(key))
            .ToList();
    }

    /// <summary>
    /// 对上了哪一档（越小越靠前）：0 标题以它开头、1 标题里有、2 只有搜索词里有；null 没对上。
    /// 子页的名字算在这个子页第一行的搜索词里（搜「截图历史」落进那个子页）。
    /// </summary>
    public static int? Rank(SettingsItem item, string query)
    {
        var text = query.Trim();
        if (text.Length == 0)
        {
            return null;
        }

        if (item.Title.StartsWith(text, StringComparison.CurrentCultureIgnoreCase))
        {
            return 0;
        }

        if (item.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase))
        {
            return 1;
        }

        return Words(item).Any(word => word.Contains(text, StringComparison.CurrentCultureIgnoreCase)) ? 2 : null;
    }

    /// <summary>这一行认的搜索词（登记的 + 它是子页第一行时子页的名字、「高级」第一行时「高级」）。</summary>
    public static IReadOnlyList<string> Words(SettingsItem item)
        => WordsById.TryGetValue(item.Id, out var words) ? words : ComputeWords(item).ToList();

    private static IEnumerable<string> ComputeWords(SettingsItem item)
    {
        foreach (var word in item.Keywords)
        {
            yield return word;
        }

        if (item.Sub is { } sub && sub != Advanced && Items.First(other => other.Page == item.Page && other.Sub == sub) == item &&
            Subpage(item.Page, sub) is { } subpage)
        {
            yield return subpage.Title;
        }

        if (item.Sub == Advanced && Items.First(other => other.Page == item.Page && other.Sub == Advanced) == item)
        {
            yield return "高级";
        }
    }

    /// <summary>
    /// 搜索对上的行（侧栏最上面那一组）：标题打头的 &gt; 标题里有的 &gt; 只有搜索词里有的，同一档按侧栏的页序、页里按登记的先后。
    /// pages：侧栏此刻有的页（按侧栏顺序；没添加的插件、关着时也照列）；不在里面的页的行不列。shown：这台电脑上此刻有没有这一行（多屏才有的那种）。
    /// </summary>
    public static List<SettingsItem> Matching(string query, IReadOnlyList<string> pages, Func<SettingsItem, bool>? shown = null, int limit = ResultLimit)
    {
        var text = query.Trim();
        if (text.Length == 0)
        {
            return new List<SettingsItem>();
        }

        return Items
            .Select((item, index) => (Item: item, Index: index, Page: IndexOf(pages, item.Page), Rank: Rank(item, text)))
            .Where(hit => hit.Rank is not null && hit.Page >= 0 && (shown?.Invoke(hit.Item) ?? true))
            .OrderBy(hit => hit.Rank)
            .ThenBy(hit => hit.Page)
            .ThenBy(hit => hit.Index)
            .Take(limit)
            .Select(hit => hit.Item)
            .ToList();
    }

    /// <summary>某一页的行认的全部字（侧栏筛页时并进页的关键词：页的词对上、或者这页的任一行对上都算这一页）。</summary>
    public static IReadOnlyList<string> PageWords(string page)
        => PageWordsById.TryGetValue(page, out var words) ? words : Array.Empty<string>();

    private static int IndexOf(IReadOnlyList<string> pages, string page)
    {
        for (var index = 0; index < pages.Count; index++)
        {
            if (pages[index] == page)
            {
                return index;
            }
        }

        return -1;
    }

    // ponytail: 一项一行排成表，好对着页面看；行多了再按页拆成几个文件。
    private static List<SettingsItem> Build()
    {
        var items = new List<SettingsItem>();

        void Row(string id, string? sub, string title, string keywords = "", params string[] keys)
        {
            var page = id[..id.IndexOf('.')];
            var words = keywords.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            items.Add(new SettingsItem(id, page, sub, title, words, keys));
        }

        const string A = Advanced;

        // 通用
        Row("general.features", null, "功能", "模块,关闭,停用,启用,不用");
        Row("general.appearance", null, "外观", "浅色,深色,暗黑,主题,跟随系统", "Theme");
        Row("general.accent", null, "强调色", "主题色,颜色", "Accent");
        Row("general.login", null, "登录时自动打开", "开机,登录,自启,启动");
        Row("general.microphone", null, "麦克风", "权限,授权,隐私");
        Row("general.sync", "sync", "在几台电脑之间同步", "OneDrive,云盘,WebDAV,服务器,多台,几台,另一台,同步文件夹");
        Row("general.syncSettings", "sync", "设置与快捷键", "同步设置,同步快捷键");
        Row("general.syncPeers", "sync", "其他电脑", "同步,另一台,电脑");
        Row("general.transfer", "backup", "设置与数据", "导出,导入,迁移,换电脑,配置");
        Row("general.backup", "backup", "每天自动备份", "备份");
        Row("general.restore", "backup", "已有的备份", "从备份恢复,恢复");
        Row("general.mirror", "backup", "另存一份到", "备份,文件夹,OneDrive");
        Row("general.uninstall", null, "从这台电脑移除 Kitty Tools…", "卸载,移除,删除");
        Row("general.squeeze", A, "呼出面板时挤压弹开", "挤压,弹开,动画,动效", "PanelSqueezeEntrance");
        Row("general.notice", A, "提示显示在", "提示,轻提示,通知,灵动岛,刘海,顶部,底部", "NoticePosition");
        Row("general.dataFolder", A, "数据目录", "数据,资源管理器,文件夹,目录");

        // 剪贴板
        Row("clipboard.retention", null, "保留普通历史", "历史,天数,保留,永久", "ClipboardRetentionDays");
        Row("clipboard.imageBudget", null, "图片最多占用", "图片,占用,空间", "ClipboardImageBudgetMB");
        Row("clipboard.imageUsage", null, "图片当前占用", "占用");
        Row("clipboard.pasteOnClick", null, "单击条目直接粘贴", "单击,双击,点击,粘贴", "ClipboardPasteOnClick");
        Row("clipboard.pastePlain", null, "默认粘贴为纯文本", "纯文本,格式", "ClipboardPastePlain");
        Row("clipboard.snippetExpand", null, "打关键词展开片段", "片段,关键词,展开,自动展开,缩写,文本扩展,文字替换", "ClipboardSnippetExpand");
        Row("clipboard.blockSensitive", null, "不记录疑似密钥和银行卡号", "密钥,银行卡,密码,敏感,隐私", "ClipboardBlockSensitive");
        Row("clipboard.autoClear", null, "自动清空普通历史", "清空,退出,锁屏", "ClipboardClearOnQuit", "ClipboardClearOnLock");
        Row("clipboard.clearNow", null, "立即清空普通历史…", "清空");
        Row("clipboard.excludedApps", null, "不记录这些应用里的复制", "排除,不记录,应用,程序");
        Row("clipboard.lens", A, "显示透镜", "透镜,预览", "ClipboardShowLens");
        Row("clipboard.imageRows", A, "列表里直接显示图片", "图片,缩略图,预览,大图", "ClipboardImageRows");
        Row("clipboard.linkPreview", A, "链接显示网页标题和图片", "链接,网页,标题", "LinkPreviews");
        Row("clipboard.panelPosition", A, "面板位置", "位置,跟随鼠标,上次位置,屏幕上方", "ClipboardPanelPosition");
        Row("clipboard.panelSize", A, "面板大小", "宽度,行数,恢复默认大小");
        Row("clipboard.ocr", A, "识别图片中的文字，用于搜索", "识别,文字,OCR", "ClipboardImageOcr");

        // 启动器
        Row("launcher.frequent", null, "空搜索框里列出常用", "常用,最近,使用记录,收藏", "LauncherShowsFrequent");
        Row("launcher.browsers", null, "浏览器书签与历史", "书签,浏览历史,浏览器,Edge,Chrome,Firefox,Brave");
        Row("launcher.fileSearch", null, "建了索引的位置", "文件,文件搜索,open,find,索引,Windows 搜索");
        Row("launcher.everything", null, "装了 Everything 并且它在运行时用它搜", "Everything,文件搜索", "LauncherUseEverything");
        Row("launcher.apps", null, "应用", "别名,应用别名,便携,隐藏的应用,应用文件夹");
        Row("launcher.webSearch", null, "网页搜索与快捷链接", "搜索,引擎,快捷链接,关键词,兜底");
        Row("launcher.scripts", null, "脚本命令", "脚本,AI,新建脚本,导入");
        Row("launcher.scriptsEnabled", "scripts", "启用脚本命令", "脚本", "LauncherScripts");
        Row("launcher.commands", null, "命令和别名", "命令,别名,系统命令");
        Row("launcher.keys", null, "启动器里的按键", "按键,速查");
        Row("launcher.romanInput", A, "呼出时切到英文输入法", "英文,输入法", "LauncherRomanInput");
        Row("launcher.panelPosition", A, "面板位置", "位置,跟随鼠标,上次位置,屏幕上方", "LauncherPanelPosition");
        Row("launcher.panelSize", A, "面板大小", "宽度,行数,恢复默认大小");
        Row("launcher.clearUsage", A, "清空使用记录…", "使用记录,清空,常用");

        // 翻译
        Row("translate.first", null, "第一语言", "语言", "TranslateFirstLanguage");
        Row("translate.second", null, "第二语言", "语言", "TranslateSecondLanguage");
        Row("translate.services", null, "翻译服务", "服务,密钥,智谱,OpenAI,Anthropic,DeepL,Google,百度,有道,微软,火山,腾讯,AI,模型");
        Row("translate.copyToTranslate", null, "复制即译", "复制", "CopyTranslate");
        Row("translate.autoCopy", null, "自动复制译文", "自动复制", "TranslateAutoCopy");
        Row("translate.panelPosition", null, "浮窗位置", "位置,鼠标,屏幕上方", "TranslateWindowPosition");
        Row("translate.keys", null, "翻译浮窗里的按键", "按键,速查");
        Row("translate.wordMode", "lookup", "查单个词时大模型按词典回答", "查词,词典,单词,音标,例句", "TranslateWordLookup");
        Row("translate.pronunciation", "lookup", "英文单词发音", "发音,真人发音,美音,英音,有道", "TranslateWordRecording", "TranslateWordAccent");
        Row("translate.speechSpeed", "lookup", "朗读速度", "朗读,速度,喇叭", "TranslateSpeechSpeed");
        Row("translate.history", "history", "记录翻译历史", "历史", "TranslateHistoryEnabled");
        Row("translate.historyLimit", "history", "历史最多保留", "历史,条数", "TranslateHistoryLimit");
        Row("translate.historyExport", "history", "导出和清空", "导出,CSV,Anki,清空,生词本");
        Row("translate.fontScale", A, "译文字号", "字号,大小", "TranslateFontScale");
        Row("translate.panelSize", A, "面板大小", "宽度,恢复默认大小");
        Row("translate.removeNewlines", A, "翻译前把同一段里的换行接起来", "换行,PDF", "TranslateJoinLines");
        Row("translate.overlay", A, "截图翻译时把译文直接盖回截图上", "截图翻译,盖回,原位", "TranslateScreenshotOverlay");
        Row("translate.copyRecognized", A, "截图翻译时复制识别出的原文", "截图翻译,原文", "TranslateCopyRecognized");

        // 截图
        Row("screenshot.saveFolder", null, "快速保存到", "保存,存储,目录,文件夹");
        Row("screenshot.copyAs", null, "截图拷贝为", "拷贝,复制,文件,PNG,对拷线,远程", "ScreenshotCopyAs");
        Row("screenshot.corners", null, "截图圆角", "圆角,直角", "ScreenshotCornerRadius");
        Row("screenshot.placement", null, "截完图放哪", "缩略图,角落", "ShotPlacement");
        Row("screenshot.shutter", null, "截图时播放快门声", "快门,声音", "ScreenshotShutterSound");
        Row("screenshot.history", "history", "保留截图历史", "历史", "ShotHistory");
        Row("screenshot.historyDays", "history", "保留", "天数,保留多久", "ShotHistoryDays");
        Row("screenshot.historySize", "history", "最多占用", "占用,空间", "ShotHistoryMegabytes");
        Row("screenshot.historyOpen", "history", "打开或清空截图历史", "打开,清空,现在清空");
        Row("screenshot.keys", null, "框选、标注、长截图和录屏的按键", "按键,速查");
        Row("screenshot.editKeys", null, "改按键", "快捷键,改键");
        Row("screenshot.cursor", A, "截图带上鼠标指针", "指针,鼠标指针,光标", "ScreenshotCursor");
        Row("screenshot.hideDesktop", A, "截图、录屏时隐藏桌面图标", "桌面图标,隐藏", "CaptureHideDesktopIcons");
        Row("screenshot.windowShadow", A, "窗口截图带阴影", "阴影,窗口", "ScreenshotWindowShadow");
        Row("screenshot.delay", A, "延时截图等几秒", "延时,倒数", "ScreenshotDelay");
        Row("screenshot.hint", A, "框选时显示操作提示", "提示", "ScreenshotShowsHint");
        Row("screenshot.loupe", A, "框选时的放大镜", "放大镜,取色,色值", "ScreenshotLoupe");
        Row("screenshot.toolbar", A, "工具栏位置", "工具栏,靠右,居中,录制条", "ScreenshotToolbarAlign");
        Row("screenshot.keepsColors", A, "框选时保持屏幕原色", "原色,压暗,取色", "ScreenshotKeepsColors");
        Row("screenshot.elements", A, "悬停时识别", "元素,识别,悬停,网页,浏览器", "ScreenshotFindsElements", "ScreenshotFindsWebElements");
        Row("screenshot.pinText", A, "钉图上的字可以直接选", "钉图,选字", "PinSelectsText");
        Row("screenshot.joinLines", A, "识字后把同一段里的换行接起来", "识字,换行,二维码,条码", "OcrJoinLines");

        // 录制
        Row("record.saveFolder", null, "保存到", "保存,文件夹");
        Row("record.sharpness", null, "清晰度", "分辨率,画质,文件大小", "RecordSharpness");
        Row("record.countdown", null, "开始前倒数", "倒数", "RecordCountdown");
        Row("record.cursor", null, "显示光标", "光标,指针", "RecordCursor");
        Row("record.systemSound", null, "系统声音", "声音,录屏", "RecordSystemSound");
        Row("record.microphone", null, "麦克风", "录屏,声音", "RecordMicrophone");
        Row("record.microphoneDevice", null, "录哪个麦克风", "麦克风,输入,设备");
        Row("record.audioSource", null, "来源", "录音,系统声音,麦克风,来源", "AudioSource");
        Row("record.keys", null, "录屏和录音的按键", "按键,速查");
        Row("record.frameRate", A, "帧率", "fps", "RecordFps");
        Row("record.clicks", A, "显示点按", "点按,鼠标", "RecordClicks");
        Row("record.keysShown", A, "显示按键", "按键,胶囊", "RecordKeys");
        Row("record.keysMode", A, "显示按键时", "只显示快捷键", "RecordKeysShortcutsOnly");
        Row("record.hideDesktop", A, "截图、录屏时隐藏桌面图标", "桌面图标,隐藏", "CaptureHideDesktopIcons");
        Row("record.startsImmediately", A, "按快捷键后立即开始录音", "立即开始,控制条", "RecordInstantStart");

        // 便签
        Row("notes.fontSize", null, "正文字号", "字号,字体大小", "NotesFontSize");
        Row("notes.lineSpacing", null, "行距", "行高,间距", "NotesLineSpacing");
        Row("notes.markdown", null, "Markdown 样式", "Markdown,粗体,斜体,链接,代码块", "NotesMarkdown");
        Row("notes.openAll", null, "打开全部便签…", "全部便签,归档,最近删除");
        Row("notes.deckEnabled", "deck", "在屏幕边缘显示便签", "屏幕边缘,边缘,药丸,标签", "NotesDeckEnabled");
        Row("notes.deckEdge", "deck", "位置", "左边,右边,换边", "NotesDeckEdge");
        Row("notes.deckDisplay", "deck", "显示器", "屏幕,主显示器,所有显示器");
        Row("notes.deckStyle", "deck", "样式", "标签,色块", "NotesDeckStyle");
        Row("notes.deckSize", "deck", "大小", "药丸", "NotesDeckSize");
        Row("notes.deckSense", "deck", "感应范围", "感应,鼠标", "NotesDeckSense");
        Row("notes.deckAlwaysFanned", "deck", "一直展开", "展开", "NotesDeckAlwaysFanned");
        Row("notes.deckHidesPill", "deck", "不显示药丸", "药丸", "NotesDeckHidesPill");
        Row("notes.deckPreview", "deck", "悬停预览", "预览", "NotesDeckPreview");
        Row("notes.deckOpensOnHover", "deck", "悬停即打开", "悬停", "NotesDeckOpensOnHover");
        Row("notes.deckOverFullScreen", "deck", "盖在全屏程序上", "全屏", "NotesDeckOverFullScreen");
        Row("notes.deckNoteSize", "deck", "便签大小", "大小", "NotesDeckNoteSize");
        Row("notes.export", null, "导出为 Markdown", "导出,备份,Markdown");
        Row("notes.import", null, "从 Markdown 导入", "导入,Markdown");
        Row("notes.keys", null, "便签的按键", "按键,速查");

        // 不重排的页（PLAN-v28 §1.8）：行不挪，登记进搜索
        Row("reminders.list", null, "提醒", "定时,闹钟,喝水,休息,每天,每周,工作日,间隔");
        Row("reminders.snooze", null, "「稍后」推多久", "稍后,推迟", "RemindersSnoozeMinutes");
        Row("statusScreen.list", null, "状态", "告示,清洁,擦屏幕,请勿触碰,马上回来");
        Row("statusScreen.entersFirst", null, "按快捷键直接进入排在最前面的状态", "进入,快捷键", "StatusScreenHotKeyEntersFirst");
        Row("statusScreen.animations", null, "告示上的动画", "动画,表情", "StatusScreenAnimations");
        Row("statusScreen.exitHint", null, "有人碰键盘或鼠标时显示怎么退出", "退出,Esc", "StatusScreenExitHint");
        Row("keepAwake.now", null, "保持唤醒", "awake,防息屏,防止睡眠,不睡眠,咖啡因");
        Row("keepAwake.display", null, "屏幕也不熄", "屏幕,熄屏", "KeepAwakeDisplay");
        Row("keepAwake.schedule", null, "按时段自动保持唤醒", "定时,时段,工作日,全天");
        Row("hotkeys.shotTools", null, "截图时：标注工具", "截图,标注");
        Row("hotkeys.shotOutput", null, "截图时：出图和操作", "截图,钉图,长截图,识字");
        Row("hotkeys.panels", null, "面板里的按键", "速查");
        Row("hotkeys.blocked", null, "在这些应用里停用", "停用,屏蔽,不响应,游戏,全屏");
        Row("about.autoCheck", null, "自动检查更新", "更新", "AutoCheckUpdates");
        Row("about.installOnQuit", null, "在后台下载新版本，退出时安装", "更新,下载", "UpdateInstallOnQuit");

        return items;
    }
}
