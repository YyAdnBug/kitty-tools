// 面板底栏（PLAN-v7 §2.2）：高 36、顶上一条 hairline、左右 16；右边是「动词 + 键帽」。
using KittyTools.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace KittyTools.Ui;

internal sealed partial class PanelFooter : Grid
{
    public PanelFooter()
    {
        Height = 36;
        Padding = new Thickness(16, 0, 16, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Left = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SetColumn(Left, 0);
        Children.Add(Left);

        Right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        SetColumn(Right, 1);
        Children.Add(Right);

        var hairline = new Border
        {
            Height = 1,
            Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Top,
        };
        SetColumnSpan(hairline, 2);
        Children.Add(hairline);
    }

    public StackPanel Left { get; }

    public StackPanel Right { get; }

    public TextBlock AddLeftText(string text)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            Foreground = Theme.Brush("TextFillColorSecondaryBrush", Color.FromArgb(255, 96, 96, 96)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Left.Children.Add(block);
        return block;
    }

    /// <summary>「动词 + 键帽」；primary 的键帽用强调色（粘贴 ↩）。</summary>
    public Button AddVerb(string verb, string? key, bool primary, Action action)
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };
        content.Children.Add(new TextBlock
        {
            Text = verb,
            FontSize = Theme.FontSize("Kitty.FontSize.Meta"),
            FontWeight = FontWeights.SemiBold,
            Foreground = primary
                ? new SolidColorBrush(Theme.AccentTextColor)
                : Theme.Brush("TextFillColorPrimaryBrush", Color.FromArgb(255, 32, 32, 32)),
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (!string.IsNullOrEmpty(key))
        {
            content.Children.Add(KeyCap.Create(key, primary));
        }

        var button = new Button
        {
            Content = content,
            Padding = new Thickness(4, 2, 4, 2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(button, string.IsNullOrEmpty(key) ? verb : $"{verb} {key}");
        button.Click += (_, _) => action();
        Right.Children.Add(button);
        return button;
    }

    public void AddSeparator()
    {
        Right.Children.Add(new Border
        {
            Width = 1,
            Height = 16,
            Background = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
        });
    }
}
