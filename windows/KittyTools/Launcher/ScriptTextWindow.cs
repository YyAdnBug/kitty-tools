// 脚本命令的全文窗口（PLAN-v18 L1，mac 在启动器面板里原地显示；Windows 的启动器是失焦就收的浮层，挪到一扇普通窗口）：
// - 看全文（下载来的第一次跑之前，mac B5）：脚本原文，看不见的字（零宽、双向控制符…）换成「⟦U+200B⟧」标出来；有不放行的字时
//   「运行」是灰的、写原因（ScriptText.Revealed）。「运行」= 确认过：去掉下载标记、跑；「取消」/ Esc 不跑。不能跳过（D9 / 三轮评审）。
// - 全部输出（mode full）：边跑边追加，去掉颜色码；「复制全部」「再运行」(Ctrl+R)「停止」。
// 等宽字体、能选中、能滚动；跟着浅深色。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace KittyTools;

internal sealed class ScriptTextWindow : Window
{
    private readonly TextBox _text;
    private readonly TextBlock _status;
    private readonly StackPanel _buttons;

    private ScriptTextWindow(string title)
    {
        Title = title;
        _text = new TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
            FontSize = 13,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(_text, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(_text, ScrollBarVisibility.Auto);
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Theme.SecondaryText(), VerticalAlignment = VerticalAlignment.Center };
        _buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var bottom = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 10, 0, 0) };
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bottom.Children.Add(_status);
        Grid.SetColumn(_buttons, 1);
        bottom.Children.Add(_buttons);
        var root = new Grid { Padding = new Thickness(16), RequestedTheme = Theme.ElementTheme, Background = Theme.Brush("SolidBackgroundFillColorBaseBrush", Theme.CardBackground() is Microsoft.UI.Xaml.Media.SolidColorBrush card ? card.Color : Microsoft.UI.Colors.White) };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(_text);
        Grid.SetRow(bottom, 1);
        root.Children.Add(bottom);
        root.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape)
            {
                e.Handled = true;
                Close();
            }
        };
        Content = root;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(820 * Displays.SystemScale), (int)(600 * Displays.SystemScale)));
    }

    private Button AddButton(string text, Action run, bool accent = false)
    {
        var button = new Button { Content = text, MinWidth = 88 };
        if (accent)
        {
            button.Style = Application.Current.Resources["AccentButtonStyle"] as Style;
        }

        button.Click += (_, _) => run();
        _buttons.Children.Add(button);
        return button;
    }

    /// <summary>下载来的脚本第一次跑之前：看全文；点了「运行」才 run（调用方去掉标记、跑）。</summary>
    public static void Review(ScriptCommand script, string text, Action run)
    {
        var (shown, blocked) = ScriptText.Revealed(text);
        var window = new ScriptTextWindow($"看一眼再运行：{script.Title}");
        window._text.Text = shown;
        window._status.Text = blocked
            ? "里面有看不见的字（标成 ⟦U+…⟧）：显示出来的和真会跑的不一样，不能运行。用编辑器删掉它们再试"
            : $"这个脚本是从网上下载的（{script.FileName}）。看过、确认没问题再运行；运行后以后不再问";
        if (blocked)
        {
            window._status.Foreground = Theme.Caution();
        }

        var runButton = window.AddButton("运行", () =>
        {
            window.Close();
            run();
        }, accent: true);
        runButton.IsEnabled = !blocked;
        window.AddButton("取消", window.Close);
        AutomationProperties.SetName(window._text, "脚本全文");
        window.Activate();
        Log.Info($"script.review blocked={blocked}");
    }

    /// <summary>全部输出那一页（mode full）：返回追加输出的回调和「跑完了」的回调。</summary>
    public static (Action<string> Append, Action<string> Done) Output(ScriptCommand script, Action stop, Action rerun)
    {
        var window = new ScriptTextWindow(script.Title);
        var raw = new System.Text.StringBuilder();
        window._status.Text = "正在运行…";
        var stopButton = window.AddButton("停止", stop);
        window.AddButton("复制全部", () =>
        {
            if (ClipboardWriter.WriteText(ScriptText.Payload(raw.ToString())))
            {
                ClipboardService.Instance?.MarkOwnWrite();
                ClipboardService.Instance?.Store.RecordOwnText(ScriptText.Payload(raw.ToString()));
                window._status.Text = "已复制";
            }
        });
        window.AddButton("再运行", () =>
        {
            window.Close();
            rerun();
        });
        ((Grid)window.Content).KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.R && InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            {
                e.Handled = true;
                window.Close();
                rerun();
            }
        };
        window.Activate();
        var queue = window.DispatcherQueue;
        void Append(string piece) => queue.TryEnqueue(() =>
        {
            raw.Append(piece);
            window._text.Text = ScriptText.Clean(raw.ToString());
            window._text.Select(window._text.Text.Length, 0);
        });
        void Done(string status) => queue.TryEnqueue(() =>
        {
            window._status.Text = status;
            stopButton.IsEnabled = false;
        });
        return (Append, Done);
    }
}
