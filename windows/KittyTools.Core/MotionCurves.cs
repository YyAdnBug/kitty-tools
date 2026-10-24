// 动效的七条曲线（纯数据，配单测）：参数照 mac 的 Style.swift `Motion` 搬过来。
// duration / bounce 是感知参数；Windows 的 Composition 弹簧用
// DampingRatio = 1 − bounce、Period = duration（近似换算，肉眼对一下）。
// 减弱动态效果时：snap / glide 直接不做动画，其余只留 0.2 s 的淡入淡出。
namespace KittyTools.Core;

public enum MotionCurve
{
    /// <summary>按键连发、结果刷新、拖动、放大镜跟随、粘贴时收起面板：不做动画。</summary>
    Instant,
    /// <summary>键盘驱动的选中高亮、范围胶囊、键帽依次出现。</summary>
    Snap,
    /// <summary>指针驱动的位移：截图悬停洞、工具滑块、语言胶囊互换。</summary>
    Glide,
    /// <summary>高度变化、内容交叉淡变、列表插入删除、折叠。</summary>
    Settle,
    /// <summary>小东西出现：对勾、手柄、色块、钉图。</summary>
    Pop,
    /// <summary>刘海岛长出来、飞行卡片落地。</summary>
    Island,
    /// <summary>刘海岛缩回。</summary>
    Retract,
}

/// <summary>一条曲线的弹簧定义（duration 秒、bounce 0–1）。</summary>
public readonly record struct SpringSpec(double Duration, double Bounce)
{
    /// <summary>Composition 的 DampingRatio：bounce 越大越弹。</summary>
    public double DampingRatio => 1 - Bounce;

    public TimeSpan Period => TimeSpan.FromSeconds(Duration);
}

public static class MotionCurves
{
    /// <summary>减弱动态效果时，淡入淡出统一用这个时长。</summary>
    public const double ReducedFadeSeconds = 0.2;

    public const double FadeInSeconds = 0.12;

    public const double FadeOutSeconds = 0.10;

    public static SpringSpec? Of(MotionCurve curve) => curve switch
    {
        MotionCurve.Instant => null,
        MotionCurve.Snap => new SpringSpec(0.16, 0.15),
        MotionCurve.Glide => new SpringSpec(0.26, 0.10),
        MotionCurve.Settle => new SpringSpec(0.24, 0),
        MotionCurve.Pop => new SpringSpec(0.32, 0.25),
        MotionCurve.Island => new SpringSpec(0.42, 0.22),
        MotionCurve.Retract => new SpringSpec(0.34, 0),
        _ => null,
    };

    /// <summary>减弱动态效果时这条曲线还动不动（snap / glide 变成直接设值，其余只淡入淡出）。</summary>
    public static bool RunsWhenReduced(MotionCurve curve)
        => curve is not (MotionCurve.Instant or MotionCurve.Snap or MotionCurve.Glide);

    /// <summary>要用的弹簧；减弱动态效果时一律返回 null（调用方只做淡入淡出 / 直接设值）。</summary>
    public static SpringSpec? Effective(MotionCurve curve, bool reduced)
        => reduced || curve == MotionCurve.Instant ? null : Of(curve);
}
