// 动效：mac 的七条弹簧在 Windows 上的做法（参数和规则的纯数据在 Core 的 MotionCurves）。
// 位移走 CurveTo：把 Core 的 SpringEase 曲线采样成 Composition 关键帧（合成器里跑，不占主线程）。
// 读 UISettings.AnimationsEnabled，系统关了动画效果时只留淡入淡出。
// 不做「从小放到大」的缩放（0.1.0 用户定：Windows 版全 App 不要这种效果，截图卡片、钉图、轻提示原来都有）。
// 各界面只用下面三个现成的用法，不要自己拼 Composition：
//   Entrance  入场：透明度 0→1 + 下落 6 px
//   Appear    小东西出现：只淡入
//   SlideTo   选中高亮滑动（把一块高亮挪到目标位置）
// 另有 FadeIn / Fade 两个淡变（底栏就地提示）。
using System.Globalization;
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

    /// <summary>
    /// 入场：透明度 0→1（0.12 s）+ 内容下落 6 px（glide 弹簧）。系统关了动画就只淡入。rise 是起点的竖直偏移：默认 −6 往下落，
    /// 截图工具栏在选区上方时传 6 往上升（从靠选区那条边长出来）。
    /// </summary>
    public static void Entrance(FrameworkElement element, MotionCurve curve = MotionCurve.Glide, float rise = -6)
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

            EnableTranslation(element);
            visual.Properties.InsertVector3("Translation", new Vector3(0, rise, 0));
            visual.StartAnimation("Translation", CurveTo(compositor, Vector3.Zero, spring.Value));
        });

    /// <summary>小东西出现：只淡入（不再从 0.85 放大，0.1.0 用户反馈）。</summary>
    public static void Appear(FrameworkElement element)
        => WhenReady(element, visual =>
        {
            visual.Opacity = 0f;
            StartFade(visual, 1f, MotionCurves.FadeInSeconds);
        });

    /// <summary>
    /// 选中高亮滑动：把一块高亮从当前位置（正在滑的话从滑到的地方）挪到目标位置；
    /// Instant 或减弱动画时直接跳过去，并停掉还在跑的那一段。
    /// </summary>
    public static void SlideTo(FrameworkElement element, double x, double y, MotionCurve curve = MotionCurve.Glide)
        => WhenReady(element, visual =>
        {
            var target = new Vector3((float)x, (float)y, 0);
            EnableTranslation(element);
            var spring = MotionCurves.Effective(curve, Reduced);
            if (spring is null)
            {
                visual.StopAnimation("Translation");
                visual.Properties.InsertVector3("Translation", target);
                return;
            }

            visual.StartAnimation("Translation", CurveTo(visual.Compositor, target, spring.Value));
        });

    /// <summary>
    /// 弹簧曲线采样成关键帧（Core 的 SpringEase，时长 = 曲线的 duration）：每一帧是
    /// this.StartingValue + (target − this.StartingValue) × p，被打断时从当前值接着走。
    /// ponytail: 不用 CreateSpring*Animation——第七版第 3 批实测轻提示几何上的 Composition 弹簧 2 秒多还在
    /// 一像素一像素地爬；采样 24 帧肉眼看不出折线。要换回真弹簧先用 --notice-anim-test 量。
    /// </summary>
    public static Vector3KeyFrameAnimation CurveTo(Compositor compositor, Vector3 target, SpringSpec spec)
    {
        var animation = compositor.CreateVector3KeyFrameAnimation();
        animation.SetVector3Parameter("target", target);
        FillCurve(compositor, animation, spec);
        return animation;
    }

    /// <inheritdoc cref="CurveTo(Compositor, Vector3, SpringSpec)"/>
    public static Vector2KeyFrameAnimation CurveTo(Compositor compositor, Vector2 target, SpringSpec spec)
    {
        var animation = compositor.CreateVector2KeyFrameAnimation();
        animation.SetVector2Parameter("target", target);
        FillCurve(compositor, animation, spec);
        return animation;
    }

    private static void FillCurve(Compositor compositor, KeyFrameAnimation animation, SpringSpec spec)
    {
        const int steps = 24;
        animation.Duration = spec.Period;
        var linear = compositor.CreateLinearEasingFunction();
        for (var step = 1; step <= steps; step++)
        {
            var t = step / (double)steps;
            var progress = SpringEase.Progress(t, spec.Bounce).ToString("0.####", CultureInfo.InvariantCulture);
            animation.InsertExpressionKeyFrame(
                (float)t, $"this.StartingValue + (target - this.StartingValue) * {progress}", linear);
        }
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

    /// <summary>
    /// 从完全透明淡入（底栏就地提示、轻提示的内容）。<paramref name="delayMs"/> 期间保持透明。
    /// 不能用 Fade(…, 0, 0) 先清零：Composition 的关键帧动画时长至少 1 ms，0 会抛异常。
    /// </summary>
    public static void FadeIn(FrameworkElement element, double seconds, int delayMs = 0)
        => WhenReady(element, visual =>
        {
            visual.Opacity = 0f;
            var fade = visual.Compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(0f, 0f);
            fade.InsertKeyFrame(1f, 1f);
            fade.Duration = TimeSpan.FromSeconds(Math.Max(0.001, seconds));
            if (delayMs > 0)
            {
                fade.DelayTime = TimeSpan.FromMilliseconds(delayMs);
                fade.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
            }

            visual.StartAnimation("Opacity", fade);
        });

    /// <summary>
    /// 要在合成器里动 handoff visual 的 "Translation"，得先打开它；不开的话 StartAnimation 抛 ArgumentException
    /// （第七版之前入场的下落和高亮滑动一直是这样失败的，日志里的 motion.failed，只剩淡入 / 直接跳）。
    /// 打开之后它和 XAML 的 UIElement.Translation 是叠加的两份：只写合成器这份（Properties 里的 "Translation"），
    /// XAML 那份别碰，否则偏移翻倍（实测高亮往下错了一行的一半）。
    /// </summary>
    private static void EnableTranslation(UIElement element)
        => ElementCompositionPreview.SetIsTranslationEnabled(element, true);

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
