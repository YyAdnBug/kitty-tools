// 服务方块（PLAN-v7 §2.1，18 / 24 两档，照 mac ServiceTile）：有官方 logo 用 logo（选哪张见 Core 的 ServiceBadge.Logo），
// 自带底色的满版图直接裁圆角，只有图形的垫白底、四周留 14%，0.5 发丝线；认不出是谁就用品牌色 + 首字。
// logo 是从 mac 的 Assets.xcassets/ServiceLogo 拷来的（mac 是 SVG 的四张在 Mac 上渲成 128 px PNG），只用图片素材，不引依赖。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace KittyTools.Ui;

internal static class ServiceTile
{
    public static Border Create(TranslateServiceConfig service, double size = 18)
    {
        var tile = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size * 0.225),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var logo = ServiceBadge.Logo(service.Kind, service.Protocol, service.BaseUrl, service.Name);
        if (logo is not null)
        {
            var source = new BitmapImage(new Uri($"ms-appx:///Resources/ServiceLogo/{logo}.png"));
            if (ServiceBadge.IsFullBleed(logo))
            {
                // 用画刷铺底才裁得出圆角（Border 不裁子元素）。
                tile.Background = new ImageBrush { ImageSource = source, Stretch = Stretch.UniformToFill };
            }
            else
            {
                tile.Background = new SolidColorBrush(Colors.White);
                tile.Padding = new Thickness(size * 0.14);
                tile.Child = new Image { Source = source, Stretch = Stretch.Uniform };
            }

            tile.BorderBrush = Theme.Brush("Kitty.Hairline", Color.FromArgb(20, 0, 0, 0));
            tile.BorderThickness = new Thickness(0.5);
            return tile;
        }

        var vendor = ServiceBadge.Vendor(service.Kind, service.Protocol);
        var brush = Theme.ServiceBadge(vendor) as SolidColorBrush;
        tile.Background = brush ?? new SolidColorBrush(Theme.Family.Launcher);
        tile.Child = new TextBlock
        {
            Text = ServiceBadge.Letter(service.Kind, service.Protocol, service.Name),
            FontSize = size * 0.55,
            Foreground = new SolidColorBrush(Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return tile;
    }
}
