// 操作菜单（PLAN-v7 §2.2）：Ctrl+K 菜单和右键菜单共用一份条目。
// 每项带图标、快捷键右对齐；危险项（删除 / 强制结束 / 清空）用 Kitty.Danger。
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace KittyTools.Ui;

internal sealed record ActionMenuItem(
    string Glyph,
    string Text,
    string? Shortcut,
    Action Invoke,
    bool Danger = false,
    bool Enabled = true);

internal static class ActionMenu
{
    public static MenuFlyout Build(IEnumerable<ActionMenuItem> items)
    {
        var menu = new MenuFlyout();
        foreach (var entry in items)
        {
            menu.Items.Add(Create(entry));
        }

        return menu;
    }

    public static MenuFlyoutItem Create(ActionMenuItem entry)
    {
        var item = new MenuFlyoutItem
        {
            Text = entry.Text,
            IsEnabled = entry.Enabled,
        };
        if (!string.IsNullOrEmpty(entry.Glyph))
        {
            item.Icon = new FontIcon { Glyph = entry.Glyph };
        }

        if (!string.IsNullOrEmpty(entry.Shortcut))
        {
            item.KeyboardAcceleratorTextOverride = entry.Shortcut;
        }

        if (entry.Danger)
        {
            var danger = Theme.Brush("Kitty.Danger", Theme.BrandPink);
            item.Foreground = danger;
            if (item.Icon is FontIcon icon)
            {
                icon.Foreground = danger;
            }
        }

        item.Click += (_, _) => entry.Invoke();
        return item;
    }
}
