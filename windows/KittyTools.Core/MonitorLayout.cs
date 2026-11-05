// 「工作区 + 缩放 → 窗口像素矩形」（纯函数，配单测）。
// 浮层、轻提示、翻译浮窗、截图遮罩都按目标显示器自己的缩放比例换算，不能拿窗口当前所在那块屏的 DPI
// （窗口要挪去的屏缩放不同时，尺寸会按错的 DPI 算：720 DIP 在 150% 屏上只占 480 DIP 宽）。
namespace KittyTools.Core;

public readonly record struct WorkArea(int Left, int Top, int Right, int Bottom)
{
    public int Width => Right - Left;

    public int Height => Bottom - Top;
}

public readonly record struct PixelRect(int X, int Y, int Width, int Height)
{
    public int Right => X + Width;

    public int Bottom => Y + Height;

    public bool IsEmpty => Width <= 0 || Height <= 0;
}

/// <summary>剪贴板面板、启动器这一次摆在哪（MonitorLayout.Placement）。</summary>
public enum PanelPlacement
{
    Top,
    Pointer,
    Last,
}

public static class MonitorLayout
{
    public const double ClipboardTopFraction = 0.2;
    public const double NoticeTopOffsetDip = 12;
    public const double NearPointerOffsetDip = 12;

    public static double ScaleOf(uint dpi) => Math.Max(1.0, dpi / 96.0);

    /// <summary>DIP → 目标显示器上的物理像素（四舍五入，最小 1）。</summary>
    public static int Pixels(double dip, double scale) => Math.Max(1, (int)Math.Round(dip * scale));

    /// <summary>浮层：宽 widthDip、高 heightDip，水平居中、顶边往下 topFraction。</summary>
    public static PixelRect Overlay(
        WorkArea work, double scale, double widthDip, double heightDip, double topFraction)
    {
        var width = Pixels(widthDip, scale);
        var height = Pixels(heightDip, scale);
        var x = work.Left + Math.Max(0, (work.Width - width) / 2);
        var y = work.Top + (int)Math.Round(work.Height * topFraction);
        return Clamp(new PixelRect(x, y, width, height), work);
    }

    /// <summary>轻提示：宽 widthDip、高 heightDip，水平居中、底边离工作区底边 bottomOffsetDip（任务栏上方）。</summary>
    public static PixelRect Notice(WorkArea work, double scale, double widthDip, double heightDip, double bottomOffsetDip)
    {
        var width = Pixels(widthDip, scale);
        var height = Pixels(heightDip, scale);
        var x = work.Left + Math.Max(0, (work.Width - width) / 2);
        var y = work.Bottom - height - (int)Math.Round(bottomOffsetDip * scale);
        return Clamp(new PixelRect(x, y, width, height), work);
    }

    /// <summary>跟随鼠标：鼠标右下 offsetDip；右边放不下翻到左边，下面放不下翻到上边；最后夹进工作区。</summary>
    public static PixelRect NearPointer(
        int cursorX,
        int cursorY,
        WorkArea work,
        double scale,
        double widthDip,
        double heightDip,
        double offsetDip = NearPointerOffsetDip)
    {
        var width = Pixels(widthDip, scale);
        var height = Pixels(heightDip, scale);
        var offset = (int)Math.Round(offsetDip * scale);
        var x = cursorX + offset;
        if (x + width > work.Right)
        {
            x = cursorX - width - offset;
        }

        var y = cursorY + offset;
        if (y + height > work.Bottom)
        {
            y = cursorY - height - offset;
        }

        return Clamp(new PixelRect(x, y, width, height), work);
    }

    /// <summary>
    /// 贴着某个矩形出现（截图翻译的浮窗，PLAN-v2 §3.8）：优先放右边，放不下换左边，再放不下放下边，
    /// 最后夹进工作区。锚点用物理像素（选区是像素坐标）。
    /// </summary>
    public static PixelRect NearRect(
        PixelRect anchor,
        WorkArea work,
        double scale,
        double widthDip,
        double heightDip,
        double gapDip = NearPointerOffsetDip)
    {
        var width = Pixels(widthDip, scale);
        var height = Pixels(heightDip, scale);
        var gap = (int)Math.Round(gapDip * scale);

        var x = anchor.Right + gap;
        if (x + width > work.Right)
        {
            x = anchor.X - width - gap;
        }

        var y = anchor.Y;
        if (x < work.Left || x + width > work.Right)
        {
            // 左右都放不下：放到选区下面，宽度还是按工作区夹。
            x = anchor.X;
            y = anchor.Bottom + gap;
            if (y + height > work.Bottom)
            {
                y = anchor.Y - height - gap;
            }
        }

        return Clamp(new PixelRect(x, y, width, height), work);
    }

    /// <summary>
    /// 剪贴板面板、启动器「面板位置」这一次怎么摆（PLAN-v12 N2，mac OverlayPanel.placement）：mouse 光标旁边 / last 上次拖到的地方
    /// （没拖过按屏幕上方）/ 其余（top、认不出来）屏幕上方。
    /// </summary>
    public static PanelPlacement Placement(string? position, bool hasUserFrame) => position switch
    {
        "mouse" => PanelPlacement.Pointer,
        "last" when hasUserFrame => PanelPlacement.Last,
        _ => PanelPlacement.Top,
    };

    /// <summary>
    /// 上次拖到的左上角 (x, y) 在 from 那块屏上，这次要出现在 to 那块屏（鼠标所在屏）：换算到同一相对位置（mac relocated），
    /// 再按这次的尺寸夹进 to。同一块屏原样（只夹）。
    /// </summary>
    public static PixelRect Relocate(int x, int y, WorkArea from, WorkArea to, int width, int height)
    {
        if (from != to && from.Width > 0 && from.Height > 0)
        {
            x = to.Left + (int)Math.Round((double)(x - from.Left) / from.Width * to.Width);
            y = to.Top + (int)Math.Round((double)(y - from.Top) / from.Height * to.Height);
        }

        return Clamp(new PixelRect(x, y, width, height), to);
    }

    /// <summary>把矩形夹进工作区；比工作区还大时贴左 / 上。</summary>
    public static PixelRect Clamp(PixelRect rect, WorkArea work)
    {
        var x = Math.Clamp(rect.X, work.Left, Math.Max(work.Left, work.Right - rect.Width));
        var y = Math.Clamp(rect.Y, work.Top, Math.Max(work.Top, work.Bottom - rect.Height));
        return rect with { X = x, Y = y };
    }
}
