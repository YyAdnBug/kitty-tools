// 系统设置页：一张静态表（ms-settings: 链接 + 中文名 + 英文名），中文 / 英文 / 拼音都能搜到。
using KittyTools.Core;

namespace KittyTools;

internal static class SettingsPages
{
    private static readonly (string Uri, string Title, string English)[] Table =
    {
        ("display", "显示", "Display"),
        ("sound", "声音", "Sound"),
        ("bluetooth", "蓝牙", "Bluetooth"),
        ("network", "网络", "Network"),
        ("wifi", "WLAN", "Wi-Fi"),
        ("battery", "电池", "Battery"),
        ("powersleep", "电源和睡眠", "Power and sleep"),
        ("storagesense", "存储", "Storage"),
        ("defaultapps", "默认应用", "Default apps"),
        ("appsfeatures", "已安装的应用", "Installed apps"),
        ("notifications", "通知", "Notifications"),
        ("personalization", "个性化", "Personalization"),
        ("personalization-background", "背景", "Background"),
        ("personalization-colors", "颜色", "Colors"),
        ("taskbar", "任务栏", "Taskbar"),
        ("mouse", "鼠标", "Mouse"),
        ("keyboard", "键盘", "Keyboard"),
        ("dateandtime", "日期和时间", "Date and time"),
        ("regionlanguage", "语言和区域", "Language and region"),
        ("windowsupdate", "Windows 更新", "Windows Update"),
        ("privacy", "隐私和安全性", "Privacy and security"),
        ("nightlight", "夜间模式", "Night light"),
        ("display-project", "投影", "Project"),
        ("easeofaccess", "辅助功能", "Accessibility"),
        ("gaming", "游戏", "Gaming"),
        ("accounts", "账户", "Accounts"),
        ("about", "关于", "About"),
    };

    public static List<LauncherItem> Items()
    {
        var items = new List<LauncherItem>(Table.Length);
        foreach (var (uri, title, english) in Table)
        {
            var pinyin = Pinyin.For(title);
            var compact = new string(english.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
            items.Add(new LauncherItem
            {
                Kind = LauncherKind.Setting,
                Target = "ms-settings:" + uri,
                Title = title,
                Subtitle = "系统设置",
                Names = new[]
                {
                    LauncherMatch.Fold(title),
                    LauncherMatch.Fold(english),
                    compact,
                    pinyin?.Full,
                }.Where(name => !string.IsNullOrEmpty(name)).Select(name => name!).Distinct().ToList(),
                Initials = new[]
                {
                    LauncherMatch.Initials(english),
                    pinyin?.Initials,
                }.Where(value => !string.IsNullOrEmpty(value)).Select(value => value!).Distinct().ToList(),
            });
        }

        return items;
    }

    public static LauncherItem? Find(string target) => Items().FirstOrDefault(item => item.Target == target);
}
