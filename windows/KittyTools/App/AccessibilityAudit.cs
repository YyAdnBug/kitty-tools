// 无障碍自检（PLAN-v6 第 6 批）：遍历自己的可视树，数出「可交互但没有读屏名字」和
// 「可交互但键盘到不了」的控件。--a11y-audit 调它；结果只写日志，不含剪贴板内容。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class AccessibilityAudit
{
    public static void Run(DependencyObject root, string name)
    {
        var unnamed = 0;
        var unreachable = 0;
        var total = 0;
        Walk(root, ref total, ref unnamed, ref unreachable);
        Log.Info($"a11y.{name} total={total} unnamed={unnamed} unreachable={unreachable}");
    }

    private static void Walk(DependencyObject node, ref int total, ref int unnamed, ref int unreachable)
    {
        if (node is Control control && IsInteractive(control))
        {
            total++;
            if (string.IsNullOrWhiteSpace(ReadName(control)))
            {
                unnamed++;
                Log.Warn($"a11y.unnamed {control.GetType().Name} {Describe(control)}");
            }

            if (!control.IsTabStop || !control.IsEnabled)
            {
                unreachable++;
                Log.Warn($"a11y.unreachable {control.GetType().Name} {Describe(control)}");
            }
        }

        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var index = 0; index < count; index++)
        {
            Walk(VisualTreeHelper.GetChild(node, index), ref total, ref unnamed, ref unreachable);
        }
    }

    private static bool IsInteractive(Control control)
        => control is Button or ToggleButton or CheckBox or RadioButton or ComboBox or TextBox
            or ListViewItem or MenuFlyoutItem or ToggleSwitch;

    private static string? ReadName(Control control)
    {
        var name = AutomationProperties.GetName(control);
        if (!string.IsNullOrWhiteSpace(name))
        {
            return name;
        }

        return control switch
        {
            ContentControl { Content: string text } => text,
            TextBox { PlaceholderText.Length: > 0 } box => box.PlaceholderText,
            _ => null,
        };
    }

    private static string Describe(Control control)
        => control switch
        {
            FrameworkElement { Name.Length: > 0 } element => $"name={element.Name}",
            ContentControl { Content: string text } => $"text={text}",
            _ => "no-name",
        };
}
