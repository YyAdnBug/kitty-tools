// 截图时的键（PLAN-v18 S3 / D4，mac SelectionView + EditorToolbar 1818d4cb 29c2d080）：按键照 设置 › 快捷键「截图时」查（Core ShotKeys），
// 工具栏悬停提示写现在的键；工具栏上右键一颗钮出「改「…」的快捷键…」，点了以后钮里亮粉底、等下一个键——Esc 只取消改键、不退出截图，
// 固定的键、截图里重复的、和全局快捷键一样的不收（顶部提示原因、接着等），收下就存设置、提示一声。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools;

internal sealed partial class SelectionOverlayWindow
{
    /// <summary>工具栏上有键的钮：id → (钮, 提示里的名字)，改了键重写悬停提示。</summary>
    private readonly Dictionary<string, (Button Button, string Tip)> _shotButtons = new();
    /// <summary>右键「改…的快捷键」之后在等新键的那一项和它的钮。</summary>
    private ShotKeyEntry? _rebinding;
    private Button? _rebindButton;

    private Button ShotButton(string glyph, string tip, string automationName, string shotId, double width = 32)
    {
        var button = ToolbarButton(glyph, ShotTip(tip, shotId), automationName, width);
        AttachRebind(button, shotId, tip);
        return button;
    }

    /// <summary>悬停提示：「名字（键）」；长截图写全向下 / 向上 / 自动滚；复制带上 Enter。</summary>
    private static string ShotTip(string tip, string shotId)
    {
        var stored = SettingsService.Current.ScreenshotKeys;
        string? Key(string id) => ShotKeys.Current(id, stored)?.Display;
        return shotId switch
        {
            "scroll" => $"{tip}（{string.Join(" · ", new[]
            {
                Key("scroll") is { } down ? $"{down} 向下 · Shift+{down} 向上" : null,
                Key("autoScroll") is { } auto ? $"{auto} 自动滚" : null,
            }.OfType<string>())}）".Replace("（）", string.Empty),
            "copy" => Key("copy") is { } copy ? $"复制（Enter · {copy} · 双击选区）" : "复制（Enter · 双击选区）",
            _ => ShotKeys.Tip(tip, shotId, stored),
        };
    }

    private void AttachRebind(Button button, string shotId, string tip)
    {
        if (ShotKeys.Find(shotId) is not { } entry)
        {
            return;
        }

        _shotButtons[shotId] = (button, tip);
        ToolTipService.SetToolTip(button, ShotTip(tip, shotId));
        var change = new MenuFlyoutItem { Text = $"改「{entry.Title}」的快捷键…" };
        change.Click += (_, _) => BeginRebind(entry, button);
        button.ContextFlyout = new MenuFlyout { Items = { change } };
    }

    private void BeginRebind(ShotKeyEntry entry, Button button)
    {
        EndRebind();
        CommitText();
        _rebinding = entry;
        _rebindButton = button;
        button.Background = new SolidColorBrush(Accent);
        _canvas.Focus(FocusState.Programmatic);
        Flash($"按下新的键给「{entry.Title}」（Esc 取消）", 60_000);
        Announce($"按下新的键给「{entry.Title}」");
    }

    private void EndRebind()
    {
        if (_rebindButton is { } button)
        {
            button.Background = new SolidColorBrush(Colors.Transparent);
        }

        _rebinding = null;
        _rebindButton = null;
    }

    /// <summary>等新键时按下的一个键：Esc 取消；修饰键自己不算；不行的说原因接着等；行就存下。</summary>
    private void RebindKey(Windows.System.VirtualKey key, bool control, bool alt, bool shift)
    {
        if (_rebinding is not { } entry)
        {
            return;
        }

        if (key == Windows.System.VirtualKey.Escape)
        {
            EndRebind();
            Flash("没改", 1500);
            return;
        }

        if (HotKeyRules.IsModifierKey((uint)key))
        {
            return;
        }

        var modifiers = (control ? HotKeyModifiers.Control : 0) | (alt ? HotKeyModifiers.Alt : 0) | (shift ? HotKeyModifiers.Shift : 0);
        var binding = new ShotKeyBinding((uint)key, modifiers);
        if (ShotKeys.Problem(binding, entry.Id, SettingsService.Current.ScreenshotKeys, SettingsWindow.GlobalBindings()) is { } problem)
        {
            Beep();
            Flash(problem, 60_000);
            Announce(problem);
            return;
        }

        SettingsService.Current.ScreenshotKeys = ShotKeys.Set(SettingsService.Current.ScreenshotKeys, entry.Id, binding);
        SettingsService.Save();
        EndRebind();
        foreach (var (id, (button, tip)) in _shotButtons)
        {
            ToolTipService.SetToolTip(button, ShotTip(tip, id));
        }

        var said = $"「{entry.Title}」改成 {binding.Display}";
        Flash(said, 2000);
        Announce(said);
        Log.Info($"screenshot.shot-key-rebound {entry.Id}");
    }

    /// <summary>截图自检：照右键菜单那条路开始等某个钮的新键（null = 停）。</summary>
    internal void ShowProbeRebind(string? shotId)
    {
        if (shotId is null)
        {
            EndRebind();
            _flash = null;
            _canvas.Invalidate();
        }
        else if (ShotKeys.Find(shotId) is { } entry && _shotButtons.TryGetValue(shotId, out var target))
        {
            BeginRebind(entry, target.Button);
        }
    }

    /// <summary>截图时的一个键对应的动作；这时用不上（模式不对、没有选区）返回 false，键不算处理过。</summary>
    private bool RunShotKey(string id, bool up)
    {
        var capture = _session.Mode == ScreenshotMode.Capture;
        if (AnnotationKinds.Parse(id) is { } tool)
        {
            // 录屏没有标注（mac：数字键是截图的）
            if (!capture || !_session.HasSelection)
            {
                return false;
            }

            SelectTool(tool);
            return true;
        }

        switch (id)
        {
            case "copy":
                _ = _session.CopySelectionAsync();
                return true;
            case "save" or "saveAs":
                _ = _session.SaveSelectionAsync(saveAs: id == "saveAs");
                return true;
            case "pin":
                _ = PinSelectionAsync();
                return true;
            case "recognize":
                _ = _session.RecognizedSelectionAsync();
                return true;
            case "translate":
                _ = _session.TranslateSelectionAsync();
                return true;
            case "scroll" or "autoScroll" when _session.HasSelection:
                // 长截图（第三版 §7）：向下，加 Shift 向上；自动滚同样
                _session.BeginScrolling(up: up, autoScroll: id == "autoScroll");
                return true;
            case "record" when capture && _session.SelectionScreen == _screen && _session.HasSelection:
                // S5：截图调整时切到录屏（工具栏原地换成录制条）
                SwitchToRecording();
                return true;
            case "crop" when capture && _session.HasSelection:
                ToggleCrop();
                return true;
            case "undo":
                Undo();
                return true;
            case "redo":
                Redo();
                return true;
            case "lastRegion":
                // S5：跳到上次截的区域（录屏、识字、翻译也认）
                SelectLastRegion();
                return true;
            case "pickColor":
                _session.CopyColor(_screen.HexAt((int)_cursor.X, (int)_cursor.Y));
                return true;
            default:
                return false;
        }
    }
}
