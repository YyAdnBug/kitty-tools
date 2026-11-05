// 颜色菜单末尾的「其他颜色…」（PLAN-v13 第 5 批，照 mac Notes/NoteColorPicker.swift）：mac 打开系统取色面板，Windows 用 WinUI 的
// ColorPicker 放在一个浮层里（PLAN-v13 §3.4）。边拖边变（仓库 SetColor 的 live：同打字攒着等停手再落盘），关掉时落盘、
// 记进这台电脑「最近用过」的 8 个（设置里 NotesRecentColors，不导出）。挑的正好是哪种预设的浅纸就是那种预设（Note.Picked）。
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace KittyTools;

internal static class NoteColorFlyout
{
    public static void Show(string noteId, FrameworkElement? anchor)
    {
        if (anchor is null || NoteStore.Instance is not { } store || store.Book.Find(noteId) is not { } note)
        {
            return;
        }

        var tone = NotePaper.Of(note).Light;
        var picker = new ColorPicker
        {
            Color = Windows.UI.Color.FromArgb(255, (byte)(tone.Paper >> 16), (byte)(tone.Paper >> 8), (byte)tone.Paper),
            IsAlphaEnabled = false,
            IsMoreButtonVisible = false,
            IsColorSliderVisible = true,
            IsColorChannelTextInputVisible = false,
            IsHexInputVisible = true,
        };
        int? last = null;
        picker.ColorChanged += (_, args) =>
        {
            var rgb = args.NewColor.R << 16 | args.NewColor.G << 8 | args.NewColor.B;
            last = rgb;
            store.SetColor(noteId, Note.Picked(rgb), live: true);
        };
        var flyout = new Flyout { Content = picker, Placement = FlyoutPlacementMode.Bottom, ShouldConstrainToRootBounds = false };
        flyout.Closed += (_, _) =>
        {
            store.Flush();
            if (last is { } rgb && Note.CustomRgb(Note.Picked(rgb)) is not null)
            {
                SettingsService.Current.NotesRecentColors = NotePaper.Remembered(rgb, SettingsService.Current.NotesRecentColors);
                SettingsService.Save();
            }
        };
        flyout.ShowAt(anchor);
    }
}
