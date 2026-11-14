// 设置 › 快捷键「截图时」两组（PLAN-v18 S3 / D4，mac HotkeysTab「截图时：标注工具 / 出图和操作」）：全局快捷键下面，只在截图框选和
// 标注里有效、单个键也行。录制框和全局那几行共用一套（_recordingAction 带 shot: 前缀）；第二组底下「全部恢复默认」。
// 截图功能关着时不列，录屏那一行跟着录制功能、截图翻译那一行跟着翻译功能。键的存法、能录什么在 Core ShotKeys。
using KittyTools.Core;
using KittyTools.Infrastructure;
using KittyTools.Ui;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace KittyTools;

internal sealed partial class SettingsWindow
{
    private const string ShotPrefix = "shot:";

    private static bool IsShot(string action) => action.StartsWith(ShotPrefix, StringComparison.Ordinal);

    private static string ShotId(string action) => action[ShotPrefix.Length..];

    private void BuildShotKeys()
    {
        if (!Features.IsOn(Feature.Screenshot))
        {
            return;
        }

        _content.Children.Add(SettingsUi.Section("截图时：标注工具"));
        _content.Children.Add(SettingsUi.Footnote("只在截图框选和标注里有效，单个键也行"));
        foreach (var entry in ShotKeys.Tools)
        {
            _content.Children.Add(ShotKeyRow(entry));
        }

        _content.Children.Add(SettingsUi.Section("截图时：出图和操作"));
        foreach (var entry in ShotKeys.Others.Where(entry => entry.Id switch
                 {
                     "record" => Features.IsOn(Feature.Recording),
                     "translate" => Features.IsOn(Feature.Translate),
                     _ => true,
                 }))
        {
            _content.Children.Add(ShotKeyRow(entry));
        }

        var reset = new Button { Content = "全部恢复默认", IsEnabled = SettingsService.Current.ScreenshotKeys is { Count: > 0 } };
        reset.Click += (_, _) =>
        {
            SettingsService.Current.ScreenshotKeys = null;
            SettingsService.Save();
            BuildPage("hotkeys");
        };
        _content.Children.Add(reset);
        _content.Children.Add(SettingsUi.Footnote(
            "Enter 复制、Esc 退出、Backspace / Delete 删除标注、方向键微调、Ctrl+D 复制标注、Ctrl+= / Ctrl+- 换字号固定不改。截图工具栏上右键一颗钮也能改它的键。"));
    }

    private Border ShotKeyRow(ShotKeyEntry entry)
    {
        var action = ShotPrefix + entry.Id;
        var current = ShotKeys.Current(entry.Id, SettingsService.Current.ScreenshotKeys);
        var box = new Button
        {
            MinWidth = 180,
            MinHeight = 32,
            Padding = new Thickness(10, 2, 30, 2),
            HorizontalContentAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _hotKeyBoxes[action] = box;
        ShowBinding(box, action);
        box.Click += (_, _) =>
        {
            if (_recordingAction != action)
            {
                BeginRecording(action);
            }
        };
        box.LostFocus += (_, _) =>
        {
            if (_recordingAction == action)
            {
                StopRecording(action, null);
            }
        };
        var restore = new MenuFlyoutItem { Text = "恢复默认", IsEnabled = current != entry.Default };
        restore.Click += (_, _) => RestoreHotKey(action);
        box.ContextFlyout = new MenuFlyout { Items = { restore } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(box, "点一下后按新的键；右键可恢复默认");

        var clear = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 10 },
            Padding = new Thickness(6),
            Margin = new Thickness(0, 0, 3, 0),
            MinWidth = 0,
            MinHeight = 0,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Visibility = current is null ? Visibility.Collapsed : Visibility.Visible,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(clear, $"清除截图时「{entry.Title}」的键");
        ToolTipService.SetToolTip(clear, "清除");
        clear.Click += (_, _) => ClearHotKey(action);
        var recorder = new Grid { VerticalAlignment = VerticalAlignment.Center };
        recorder.Children.Add(box);
        recorder.Children.Add(clear);
        var card = SettingsUi.Card(entry.Title, string.Empty, recorder, leading: KindTile.Create("capture", ShotKeyGlyph(entry), 20));
        _hotKeyCards[action] = card;
        return card;
    }

    /// <summary>设置页那一行的符号（和截图工具栏上的钮一样）。</summary>
    internal static string ShotKeyGlyph(ShotKeyEntry entry) => entry.Tool is { } tool
        ? SelectionOverlayWindow.ToolGlyph(tool)
        : entry.Id switch
        {
            "copy" => Glyphs.Check,
            "save" => Glyphs.Save,
            "saveAs" => Glyphs.SaveAs,
            "pin" => Glyphs.Pin,
            "recognize" => Glyphs.Ocr,
            "translate" => Glyphs.Translate,
            "scroll" or "autoScroll" => Glyphs.LongScreenshot,
            "record" => Glyphs.Record,
            "crop" => Glyphs.Crop,
            "undo" => Glyphs.Undo,
            "redo" => Glyphs.Redo,
            "lastRegion" => Glyphs.History,
            "pickColor" => Glyphs.Eyedropper,
            _ => Glyphs.Keyboard,
        };

    /// <summary>开着的功能的全局快捷键（截图时的键不能和它们一样：遮罩拿着焦点时 RegisterHotKey 仍会先把键吃掉）。</summary>
    internal static IEnumerable<(string Title, ShotKeyBinding Binding)> GlobalBindings()
        => SettingsDefaults.DefaultHotKeys
            .Where(definition => Features.IsOnFor(definition.Action))
            .Select(definition => (definition.Action, SettingsDefaults.BindingFor(SettingsService.Current, definition.Action)))
            .Where(item => item.Item2.VirtualKey != 0)
            .Select(item => (SettingsDefaults.RowTitle(item.Action), new ShotKeyBinding(item.Item2.VirtualKey, item.Item2.Modifiers)));

    /// <summary>录下截图时的一个键：不行就在那一行下面写橙字、接着录。</summary>
    private void RecordShotKey(string action, uint key, HotKeyModifiers modifiers)
    {
        var id = ShotId(action);
        var binding = new ShotKeyBinding(key, modifiers);
        if (ShotKeys.Problem(binding, id, SettingsService.Current.ScreenshotKeys, GlobalBindings()) is { } problem)
        {
            SetHotKeyMessage(action, problem);
            return;
        }

        SettingsService.Current.ScreenshotKeys = ShotKeys.Set(SettingsService.Current.ScreenshotKeys, id, binding);
        SettingsService.Save();
        _recordingAction = null;
        BuildPage("hotkeys");
    }
}
