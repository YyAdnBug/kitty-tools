// 品牌色与深浅色。默认品牌粉 #FF4D7E；浅色背景上的强调文字用深一档 #D12A5F。
// 设置里可以换成「跟随系统」。
using Microsoft.UI.Xaml;
using Windows.UI;
using Windows.UI.ViewManagement;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class Theme
{
    public static readonly Color BrandPink = Color.FromArgb(255, 0xFF, 0x4D, 0x7E);
    public static readonly Color BrandPinkDeep = Color.FromArgb(255, 0xD1, 0x2A, 0x5F);

    public static ElementTheme ElementTheme => SettingsService.Current.Theme switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

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
        resources["SystemAccentColorLight1"] = Lighten(accent, 0.12);
        resources["SystemAccentColorLight2"] = Lighten(accent, 0.24);
        resources["SystemAccentColorLight3"] = Lighten(accent, 0.36);
        resources["SystemAccentColorDark1"] = Lighten(accent, -0.12);
        resources["SystemAccentColorDark2"] = Lighten(accent, -0.24);
        resources["SystemAccentColorDark3"] = Lighten(accent, -0.36);
    }

    public static void ApplyTo(FrameworkElement element)
    {
        element.RequestedTheme = ElementTheme;
    }

    private static Color Lighten(Color color, double amount)
    {
        byte Channel(byte value) => (byte)Math.Clamp(value + (amount * 255), 0, 255);
        return Color.FromArgb(color.A, Channel(color.R), Channel(color.G), Channel(color.B));
    }
}
