// 图标格子最后一格「其他表情」（PLAN-v16 E1，mac 0aea7ec8 的 StatusPresetDetail 系统表情格）：状态和提醒的详情共用。
// 点了弹一个小浮层，里面一个拿着焦点的输入框，顺手叫出系统的表情面板（Win + .，往前台发这两个键：Windows 没有给桌面程序叫面板的公开接口）；
// 面板插进来的、粘贴或直接打的，正好一个表情字才收（StatusEmojiCatalog.IsCustom），收了就关浮层、焦点交回格子。系统表情由
// Segoe UI Emoji 画（StatusEmoji 的 Fallback），静态、不占包。面板没出来也能粘贴一个，是退路。
using System.Runtime.InteropServices;
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal static partial class EmojiChoice
{
    /// <summary>格子里这一格在 (值, 按钮) 表里的键（不会和表情 id、系统表情撞上）。</summary>
    public const string Key = "other-emoji:";

    /// <summary>格子里这一格亮不亮：其他表情那一格在选着系统表情时亮，别的格子按 id。</summary>
    public static bool Selected(string cell, string symbol)
        => cell == Key ? StatusEmojiCatalog.IsCustom(symbol) : cell == symbol;

    /// <summary>格子里那一格：选着系统表情时画那个字，没选时一个笑脸图标；picked 收到挑好的那个字。</summary>
    public static Button Create(Func<string> current, Action<string> picked)
    {
        var button = new Button
        {
            Width = 40,
            Height = 40,
            Padding = new Thickness(4),
            BorderThickness = new Thickness(2),
        };
        void Show()
        {
            var symbol = current();
            button.Content = StatusEmojiCatalog.IsCustom(symbol)
                ? new TextBlock { Text = symbol, FontFamily = new FontFamily("Segoe UI Emoji"), FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center }
                : new FontIcon { Glyph = Glyphs.Emoji, FontSize = 18 };
            AutomationProperties.SetName(button, StatusEmojiCatalog.IsCustom(symbol) ? $"其他表情：{symbol}" : "其他表情");
        }

        Show();
        ToolTipService.SetToolTip(button, "其他表情：从系统的表情面板挑一个");
        var box = new TextBox { Width = 220, PlaceholderText = "在弹出的面板里挑一个表情" };
        AutomationProperties.SetName(box, "其他表情");
        var hint = new TextBlock
        {
            Text = "也可以粘贴一个表情。没弹出面板时按 Win + 句号。",
            FontSize = 12,
            Foreground = Theme.SecondaryText(),
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 220,
        };
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(box);
        panel.Children.Add(hint);
        var flyout = new Flyout { Content = panel, Placement = FlyoutPlacementMode.Bottom };
        box.TextChanged += (_, _) =>
        {
            var text = box.Text.Trim();
            if (text.Length == 0)
            {
                return;
            }

            if (StatusEmojiCatalog.IsCustom(text))
            {
                picked(text);
                Show();
                flyout.Hide();
                button.Focus(FocusState.Programmatic);
                return;
            }

            // 只认正好一个表情字：别的清掉、提示一句
            box.Text = string.Empty;
            hint.Text = "只认一个表情，再挑一次。";
            hint.Foreground = Theme.Caution();
        };
        flyout.Opened += (_, _) =>
        {
            box.Text = string.Empty;
            box.Focus(FocusState.Programmatic);
            // 输入框拿到焦点之后再叫面板，面板插的字才落进它
            box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                // 浮层已经关了、焦点没落进输入框（点得太快、被别处抢走）就不发：不然面板会开在别的程序上
                if (flyout.IsOpen && box.FocusState != FocusState.Unfocused)
                {
                    OpenEmojiPanel();
                }
            });
        };
        button.Click += (_, _) => flyout.ShowAt(button);
        return button;
    }

    /// <summary>叫出系统的表情面板（Win + .）。用户点了「其他表情」才发，只发这两个键。</summary>
    private static void OpenEmojiPanel()
    {
        const byte win = 0x5B;
        const byte period = 0xBE;
        const uint keyUp = 0x0002;
        KeybdEvent(win, 0, 0, 0);
        KeybdEvent(period, 0, 0, 0);
        KeybdEvent(period, 0, keyUp, 0);
        KeybdEvent(win, 0, keyUp, 0);
    }

    [LibraryImport("user32.dll", EntryPoint = "keybd_event")]
    private static partial void KeybdEvent(byte virtualKey, byte scanCode, uint flags, nuint extraInfo);
}
