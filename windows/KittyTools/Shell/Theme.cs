// 品牌色。第一版用品牌粉 #FF4D7E；浅色背景上的强调文字用深一档 #D12A5F。
using Windows.UI;

namespace KittyTools;

internal static class Theme
{
    public static readonly Color BrandPink = Color.FromArgb(255, 0xFF, 0x4D, 0x7E);
    public static readonly Color BrandPinkDeep = Color.FromArgb(255, 0xD1, 0x2A, 0x5F);
}
