// 服务方块（PLAN-v7 §2.1，18 / 22 两档）：有官方 logo 用 logo，没有就用品牌色 + 首字母。
// logo 是从 mac 的 Assets.xcassets/ServiceLogo 拷来的 PNG（只用图片素材，不引依赖）。
using KittyTools.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace KittyTools.Ui;

internal static class ServiceTile
{
    public static Border Create(string vendor, string? name, double size = 18)
    {
        var tile = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size * 0.225),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var logo = LogoName(vendor);
        if (logo is not null)
        {
            try
            {
                tile.Background = new SolidColorBrush(Colors.Transparent);
                tile.Child = new Image
                {
                    Source = new BitmapImage(new Uri($"ms-appx:///Resources/ServiceLogo/{logo}.png")),
                    Stretch = Stretch.UniformToFill,
                };
                return tile;
            }
            catch
            {
                // 缺图 / 解码失败：下面用首字母兜底。
            }
        }

        var brush = Theme.ServiceBadge(vendor) as SolidColorBrush;
        tile.Background = brush ?? new SolidColorBrush(Theme.Family.Launcher);
        tile.Child = new TextBlock
        {
            Text = ServiceBadge.Letter(KindOf(vendor), ProtocolOf(vendor), name ?? string.Empty),
            FontSize = size * 0.55,
            Foreground = new SolidColorBrush(Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return tile;
    }

    private static string KindOf(string vendor) => vendor.StartsWith("ai:", StringComparison.Ordinal) ? "ai" : vendor;

    private static string? ProtocolOf(string vendor)
        => vendor.StartsWith("ai:", StringComparison.Ordinal) ? vendor[3..] : null;

    /// <summary>vendor → Resources/ServiceLogo 里的文件名；没有官方 PNG 的返回 null。</summary>
    private static string? LogoName(string vendor) => vendor switch
    {
        "zhipu" => "zhipu",
        "baidu" => "baidu",
        "youdao" => "youdao",
        "google" => "google",
        "microsoft" or "ai:azure" => "microsoft",
        "volcengine" => "volcengine",
        "tencent" => "tencent",
        "ai:anthropic" or "anthropic" => "anthropic",
        "ai:gemini" or "gemini" => "gemini",
        "ai:doubao" or "doubao" => "doubao",
        "ai:kimi" or "kimi" => "kimi",
        "ai:qwen" or "qwen" => "qwen",
        "ai:mistral" or "mistral" => "mistral",
        "ai:ollama" or "ollama" => "ollama",
        "ai:grok" or "grok" => "grok",
        "ai:openrouter" or "openrouter" => "openrouter",
        "ai:minimax" or "minimax" => "minimax",
        _ => null,
    };
}
