// 品牌色与深浅色。默认品牌粉 #FF4D7E；浅色背景上的强调文字用深一档 #D12A5F。
// 设置里可以换成「跟随系统」；跟随时监听 UISettings.ColorValuesChanged，系统一改强调色就重算。
// Light1–3 / Dark1–3 在 HSL 里调亮度（纯函数在 Core 的 AccentRamp），不是每个通道加减同一个常数。
using Microsoft.UI.Xaml;
using Windows.UI;
using Windows.UI.ViewManagement;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class Theme
{
    public static readonly Color BrandPink = Color.FromArgb(255, 0xFF, 0x4D, 0x7E);
    public static readonly Color BrandPinkDeep = Color.FromArgb(255, 0xD1, 0x2A, 0x5F);

    private static UISettings? _systemSettings;

    public static ElementTheme ElementTheme => SettingsService.Current.Theme switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    /// <summary>启动时调一次：系统强调色改了（设置里选「跟随系统」时）重算资源。</summary>
    public static void WatchSystemAccent()
    {
        if (_systemSettings is not null)
        {
            return;
        }

        try
        {
            var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _systemSettings = new UISettings();
            _systemSettings.ColorValuesChanged += (_, _) =>
            {
                // 事件在后台线程上：回 UI 线程再改资源字典。
                dispatcher?.TryEnqueue(() =>
                {
                    if (SettingsService.Current.Accent == "system")
                    {
                        ApplyAccent();
                    }
                });
            };
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.accent-watch-failed {ex.GetType().Name}");
        }
    }

    public static void ApplyAccent()
    {
        var resources = Application.Current.Resources;
        Color accent;
        if (SettingsService.Current.Accent == "system")
        {
            try
            {
                accent = new UISettings().GetColorValue(UIColorType.Accent);
            }
            catch
            {
                accent = BrandPink;
            }
        }
        else
        {
            accent = BrandPink;
        }

        resources["SystemAccentColor"] = accent;
        var ramp = new AccentRamp.Rgb(accent.R, accent.G, accent.B);
        var steps = AccentRamp.Steps;
        resources["SystemAccentColorLight1"] = Ramp(ramp, steps[0]);
        resources["SystemAccentColorLight2"] = Ramp(ramp, steps[1]);
        resources["SystemAccentColorLight3"] = Ramp(ramp, steps[2]);
        resources["SystemAccentColorDark1"] = Ramp(ramp, steps[3]);
        resources["SystemAccentColorDark2"] = Ramp(ramp, steps[4]);
        resources["SystemAccentColorDark3"] = Ramp(ramp, steps[5]);
    }

    public static void ApplyTo(FrameworkElement element)
    {
        element.RequestedTheme = ElementTheme;
    }

    private static Color Ramp(AccentRamp.Rgb color, double amount)
    {
        var scaled = AccentRamp.Scale(color, amount);
        return Color.FromArgb(255, scaled.R, scaled.G, scaled.B);
    }
}
