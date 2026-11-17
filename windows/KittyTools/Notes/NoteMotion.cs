// 便签那叠的动效（R108，照 mac NoteDeckView 的出场、探出、倾斜、让位、打开的便签出场；曲线和时长在 Core 的 MotionCurves / NoteDeckLayout）。
// 只动窗口里的内容（Composition 的手递 visual：Translation、RotationAngleInDegrees、Opacity），窗口本身不挪：
// 动画在合成器线程上跑，主线程正忙着排便签正文的那一下也不掉帧；画面上的变换不改布局和点击区（同 mac「只转画面」）。
// 曲线照 Shell/Motion.cs 的做法采样成关键帧（this.StartingValue 起：被打断时从现在的值接着走）；单独一份是为了不碰全 App 共用的 Motion.cs。
// 系统关了动画效果（Motion.Reduced）时：位移、倾斜直接设到终点，淡入淡出也不做（同 mac：标签直接出现 / 消失）。
using System.Globalization;
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;

namespace KittyTools;

internal static class NoteMotion
{
    private const int Steps = 24;

    /// <summary>这一下动不动画：系统开着动画效果，曲线不是 Instant。</summary>
    public static bool Animates(MotionCurve curve) => MotionCurves.Effective(curve, Motion.Reduced) is not null;

    /// <summary>元素的手递 visual（要动 Translation 的先打开它）。拿不到返回 null（调用方当没有动画）。</summary>
    private static Visual? VisualOf(UIElement element, bool translation)
    {
        try
        {
            if (translation)
            {
                ElementCompositionPreview.SetIsTranslationEnabled(element, true);
            }

            return ElementCompositionPreview.GetElementVisual(element);
        }
        catch (Exception ex)
        {
            Log.Warn($"notes.motion-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>位移直接设成 value（停掉在跑的）。</summary>
    public static void SetTranslation(UIElement element, Vector3 value)
    {
        if (VisualOf(element, translation: true) is { } visual)
        {
            visual.StopAnimation("Translation");
            visual.Properties.InsertVector3("Translation", value);
        }
    }

    /// <summary>沿 curve 挪到 target（从现在的值接着走），晚 delay 开始；不动画时直接设。</summary>
    public static void TranslateTo(UIElement element, Vector3 target, MotionCurve curve, TimeSpan delay = default)
    {
        if (VisualOf(element, translation: true) is not { } visual)
        {
            return;
        }

        if (MotionCurves.Effective(curve, Motion.Reduced) is not { } spec)
        {
            visual.StopAnimation("Translation");
            visual.Properties.InsertVector3("Translation", target);
            return;
        }

        var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
        animation.SetVector3Parameter("target", target);
        Fill(visual.Compositor, animation, spec, delay);
        visual.StartAnimation("Translation", animation);
    }

    /// <summary>位移按 fadeOut 那条 easeIn 走到 target（收回时标签滑回边外，同 mac：收回不用弹簧）；不动画时直接设。</summary>
    public static void TranslateOut(UIElement element, Vector3 target, double seconds)
    {
        if (VisualOf(element, translation: true) is not { } visual)
        {
            return;
        }

        visual.StopAnimation("Translation");
        if (Motion.Reduced)
        {
            visual.Properties.InsertVector3("Translation", target);
            return;
        }

        var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
        animation.InsertKeyFrame(1f, target, EaseIn(visual.Compositor));
        animation.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Translation", animation);
    }

    /// <summary>绕 center（元素自己的坐标）转到 degrees；animated 是 false 或不动画时直接设。</summary>
    public static void RotateTo(UIElement element, float degrees, Vector2 center, MotionCurve curve, bool animated)
    {
        if (VisualOf(element, translation: false) is not { } visual)
        {
            return;
        }

        visual.CenterPoint = new Vector3(center, 0);
        if (!animated || MotionCurves.Effective(curve, Motion.Reduced) is not { } spec)
        {
            visual.StopAnimation("RotationAngleInDegrees");
            visual.RotationAngleInDegrees = degrees;
            return;
        }

        var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        animation.SetScalarParameter("target", degrees);
        Fill(visual.Compositor, animation, spec, TimeSpan.Zero);
        visual.StartAnimation("RotationAngleInDegrees", animation);
    }

    /// <summary>透明度直接设（停掉在跑的）。</summary>
    public static void SetOpacity(UIElement element, float value)
    {
        if (VisualOf(element, translation: false) is { } visual)
        {
            visual.StopAnimation("Opacity");
            visual.Opacity = value;
        }
    }

    /// <summary>透明度淡到 to（seconds 秒，easeIn：淡出用；否则 easeOut），晚 delay 开始；系统关了动画效果时直接设。</summary>
    public static void FadeTo(UIElement element, float to, double seconds, bool easeIn, TimeSpan delay = default)
    {
        if (VisualOf(element, translation: false) is not { } visual)
        {
            return;
        }

        visual.StopAnimation("Opacity");
        if (Motion.Reduced)
        {
            visual.Opacity = to;
            return;
        }

        var compositor = visual.Compositor;
        var animation = compositor.CreateScalarKeyFrameAnimation();
        animation.InsertKeyFrame(1f, to, easeIn ? EaseIn(compositor) : EaseOut(compositor));
        animation.Duration = TimeSpan.FromSeconds(Math.Max(0.001, seconds));
        if (delay > TimeSpan.Zero)
        {
            animation.DelayTime = delay;
        }

        visual.StartAnimation("Opacity", animation);
    }

    private static CompositionEasingFunction EaseIn(Compositor compositor)
        => compositor.CreateCubicBezierEasingFunction(new Vector2(0.42f, 0), new Vector2(1, 1));

    private static CompositionEasingFunction EaseOut(Compositor compositor)
        => compositor.CreateCubicBezierEasingFunction(new Vector2(0, 0), new Vector2(0.58f, 1));

    /// <summary>弹簧曲线（Core 的 SpringEase）采样成 Steps 个关键帧：this.StartingValue + (target − this.StartingValue) × p。</summary>
    private static void Fill(Compositor compositor, KeyFrameAnimation animation, SpringSpec spec, TimeSpan delay)
    {
        animation.Duration = spec.Period;
        if (delay > TimeSpan.Zero)
        {
            animation.DelayTime = delay;
        }

        var linear = compositor.CreateLinearEasingFunction();
        for (var step = 1; step <= Steps; step++)
        {
            var t = step / (double)Steps;
            var progress = SpringEase.Progress(t, spec.Bounce).ToString("0.####", CultureInfo.InvariantCulture);
            animation.InsertExpressionKeyFrame((float)t, $"this.StartingValue + (target - this.StartingValue) * {progress}", linear);
        }
    }
}
