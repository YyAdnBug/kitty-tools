// 动效：mac 的七条弹簧在 Windows 上的做法（参数和规则的纯数据在 Core 的 MotionCurves）。
// 用 Composition 的 Spring 动画（DampingRatio = 1 − bounce、Period = duration）；
// 读 UISettings.AnimationsEnabled，系统关了动画效果时只留淡入淡出。
// 各界面只用下面四个现成的用法，不要自己拼 Composition：
//   Entrance  入场：透明度 0→1 + 下落 6 px
//   Appear    小东西出现：从 0.85 放大到 1（带淡入）
//   SlideTo   选中高亮滑动（把一块高亮挪到目标位置）
//   HeightChange 高度变化，顶边不动
using System.Numerics;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Windows.UI.ViewManagement;

namespace KittyTools;

internal static class Motion
{
    private static bool? _animationsEnabled;

    /// <summary>系统「动画效果」开关（辅助功能 › 视觉效果）。</summary>
    public static bool Reduced
    {
        get
        {
            _animationsEnabled ??= ReadAnimationsEnabled();
            return _animationsEnabled == false;
        }
    }

    /// <summary>系统设置改了之后重新读一次（设置窗打开时顺手调）。</summary>
    public static void Refresh() => _animationsEnabled = ReadAnimationsEnabled();

    private static bool ReadAnimationsEnabled()
    {
        try
        {
            return new UISettings().AnimationsEnabled;
        }
        catch
        {
            return true;
        }
    }

    /// <summary>入场：透明度 0→1（0.12 s）+ 内容下落 6 px（glide 弹簧）。系统关了动画就只淡入。</summary>
    public static void Entrance(FrameworkElement element, MotionCurve curve = MotionCurve.Glide)
        => WhenReady(element, visual =>
        {
            var compositor = visual.Compositor;
            visual.Opacity = 0f;
            StartFade(visual, 1f, MotionCurves.FadeInSeconds);

            var spring = MotionCurves.Effective(curve, Reduced);
            if (spring is null)
            {
                return;
            }

            element.Translation = Vector3.Zero;
            var drop = compositor.CreateSpringVector3Animation();
            drop.DampingRatio = (float)spring.Value.DampingRatio;
            drop.Period = spring.Value.Period;
            drop.InitialValue = new Vector3(0, -6, 0);
            drop.FinalValue = Vector3.Zero;
            visual.StartAnimation("Translation", drop);
        });

    /// <summary>小东西出现：从 0.85 放大到 1（pop），同时淡入。系统关了动画就只淡入。</summary>
    public static void Appear(FrameworkElement element)
        => WhenReady(element, visual =>
        {
            visual.Opacity = 0f;
            StartFade(visual, 1f, MotionCurves.FadeInSeconds);

            var spring = MotionCurves.Effective(MotionCurve.Pop, Reduced);
            if (spring is null)
            {
                return;
            }

            var center = new Vector3(
                (float)(element.ActualSize.X / 2), (float)(element.ActualSize.Y / 2), 0);
            visual.CenterPoint = center;
            var scale = visual.Compositor.CreateSpringVector3Animation();
            scale.DampingRatio = (float)spring.Value.DampingRatio;
            scale.Period = spring.Value.Period;
            scale.InitialValue = new Vector3(0.85f, 0.85f, 1);
            scale.FinalValue = Vector3.One;
            visual.StartAnimation("Scale", scale);
        });

    /// <summary>选中高亮滑动：把一块高亮从当前位置挪到目标位置（glide；减弱动画时直接跳过去）。</summary>
    public static void SlideTo(FrameworkElement element, double x, double y, MotionCurve curve = MotionCurve.Glide)
        => WhenReady(element, visual =>
        {
            var target = new Vector3((float)x, (float)y, 0);
            var spring = MotionCurves.Effective(curve, Reduced);
            if (spring is null)
            {
                element.Translation = target;
                return;
            }

            element.Translation = target;
            var slide = visual.Compositor.CreateSpringVector3Animation();
            slide.DampingRatio = (float)spring.Value.DampingRatio;
            slide.Period = spring.Value.Period;
            slide.InitialValue = element.Translation;
            slide.FinalValue = target;
            visual.StartAnimation("Translation", slide);
        });

    /// <summary>
    /// 高度变化（顶边不动）：把新内容按 old/new 的比例从顶边压一下再弹回 1。
    /// 布局高度本身动不了，用 Y 向缩放近似；减弱动画时不做。
    /// </summary>
    public static void HeightChange(FrameworkElement element, double oldHeight, double newHeight)
    {
        if (Reduced || oldHeight <= 0 || newHeight <= 0 || Math.Abs(oldHeight - newHeight) < 1)
        {
            return;
        }

        WhenReady(element, visual =>
        {
            var spring = MotionCurves.Of(MotionCurve.Settle);
            if (spring is null)
            {
                return;
            }

            visual.CenterPoint = new Vector3((float)(element.ActualSize.X / 2), 0, 0);
            var from = (float)Math.Clamp(oldHeight / newHeight, 0.6, 1.4);
            var scale = visual.Compositor.CreateSpringVector3Animation();
            scale.DampingRatio = (float)spring.Value.DampingRatio;
            scale.Period = spring.Value.Period;
            scale.InitialValue = new Vector3(1, from, 1);
            scale.FinalValue = Vector3.One;
            visual.StartAnimation("Scale", scale);
        });
    }

    /// <summary>
    /// 单独一次淡入 / 淡出（轻提示的内容晚 60 ms 淡入用）。<paramref name="delayMs"/> 是延迟。
    /// 减弱动画时保留这段淡变（PLAN-v2 §3.3：关了动画效果只留淡入淡出）。
    /// </summary>
    public static void Fade(FrameworkElement? element, float to, double seconds, int delayMs = 0)
    {
        if (element is null)
        {
            return;
        }

        WhenReady(element, visual =>
        {
            var fade = visual.Compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(1f, to);
            fade.Duration = TimeSpan.FromSeconds(seconds);
            if (delayMs > 0)
            {
                fade.DelayTime = TimeSpan.FromMilliseconds(delayMs);
            }

            visual.StartAnimation("Opacity", fade);
        });
    }

    /// <summary>出错时左右抖一下（±6 DIP，四下，0.36 s）；减弱动画时不做。</summary>
    public static void Shake(FrameworkElement element)
    {
        if (Reduced)
        {
            return;
        }

        WhenReady(element, visual =>
        {
            var shake = visual.Compositor.CreateVector3KeyFrameAnimation();
            shake.Duration = TimeSpan.FromSeconds(0.36);
            var offsets = new[] { 0f, -6f, 6f, -4f, 4f, 0f };
            for (var i = 0; i < offsets.Length; i++)
            {
                shake.InsertKeyFrame(
                    i / (float)(offsets.Length - 1),
                    new Vector3(offsets[i], element.Translation.Y, 0));
            }

            visual.StartAnimation("Translation", shake);
        });
    }

    private static void StartFade(Visual visual, float target, double seconds)
    {
        var fade = visual.Compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(1f, target);
        fade.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Opacity", fade);
    }

    /// <summary>元素还没进可视树时等它 Loaded；已经有了就直接做。</summary>
    private static void WhenReady(FrameworkElement element, Action<Visual> apply)
    {
        void Run()
        {
            try
            {
                apply(ElementCompositionPreview.GetElementVisual(element));
            }
            catch (Exception ex)
            {
                Log.Warn($"motion.failed {ex.GetType().Name}");
            }
        }

        if (element.XamlRoot is not null)
        {
            Run();
            return;
        }

        void OnLoaded(object sender, RoutedEventArgs args)
        {
            element.Loaded -= OnLoaded;
            Run();
        }

        element.Loaded += OnLoaded;
    }
}
