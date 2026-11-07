// 新功能标记的样子（PLAN-v16 G3，mac NewDot / NewTag）：自己画的界面里名字前的 6 px 强调色小圆点（主界面格子、设置侧栏行尾、收起的组标题后），
// 读屏念「新功能」。设置页里一节标题后的「新」小胶囊（mac NewTag）这一版没有条目用到，没做。
using KittyTools.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace KittyTools.Ui;

internal static class NewMark
{
    public static FrameworkElement Dot()
    {
        var dot = new Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = new SolidColorBrush(Theme.AccentColor),
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(dot, WhatsNew.Spoken);
        return dot;
    }
}
