// 品牌色与深浅色。默认品牌粉 #FF4D7E；浅色背景上的强调文字用深一档 #D12A5F。
// 设置里可以换成「跟随系统」；跟随时监听 UISettings.ColorValuesChanged，系统一改强调色就重算。
// Light1–3 / Dark1–3 在 HSL 里调亮度（纯函数在 Core 的 AccentRamp），不是每个通道加减同一个常数。
//
// 第二版 §3.1：除截图 HUD（Theme.Shot）和功能家族色（Theme.Family）之外，界面里的颜色一律走
// 主题资源（Theme.Brush 按 key 取 CardBackgroundFillColorDefaultBrush 这类内置主题资源，深色 /
// 高对比度自动跟着变）。写死的颜色只剩这个文件里的两组常量。
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;
using KittyTools.Core;
using KittyTools.Infrastructure;

namespace KittyTools;

internal static class Theme
{
    public static readonly Color BrandPink = Color.FromArgb(255, 0xFF, 0x4D, 0x7E);
    public static readonly Color BrandPinkDeep = Color.FromArgb(255, 0xD1, 0x2A, 0x5F);

    /// <summary>
    /// 截图家族的深色 HUD 皮肤（PLAN-v2 §3.1：这一套不跟深浅色变）。
    /// 只给截图遮罩的工具栏、尺寸胶囊、放大镜、标注颜色、轻提示的深色胶囊用。
    /// </summary>
    public static class Shot
    {
        public static readonly Color Accent = BrandPink;
        public static readonly Color Dim = Color.FromArgb(115, 0, 0, 0);
        public static readonly Color HandleFill = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color HudBackground = Color.FromArgb(255, 32, 32, 32);
        public static readonly Color HudBackgroundStrong = Color.FromArgb(235, 24, 24, 24);
        public static readonly Color HudText = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color HudTextMuted = Color.FromArgb(230, 255, 255, 255);
        public static readonly Color HudTextFaint = Color.FromArgb(90, 255, 255, 255);
        public static readonly Color LabelBackground = Color.FromArgb(225, 20, 20, 20);
        public static readonly Color Outline = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color Danger = Color.FromArgb(255, 235, 60, 60);
        public static readonly Color ToolbarSeparator = Color.FromArgb(60, 255, 255, 255);

        /// <summary>角落缩略图悬停时盖在图上的蒙层（mac Shot.cardScrim，black 0.35）。</summary>
        public static readonly Color CardScrim = Color.FromArgb(89, 0, 0, 0);

        /// <summary>HUD 小控件的内描边（white 0.14）和悬停、按下的底。</summary>
        public static readonly Color HudStroke = Color.FromArgb(36, 255, 255, 255);
        public static readonly Color HudHover = Color.FromArgb(245, 52, 52, 52);
        public static readonly Color HudPressed = Color.FromArgb(245, 40, 40, 40);

        /// <summary>样式托盘选项分段的轨道（mac HUD.chipFill，white 0.08）和选中的那段（HUD.selectedFill，white 0.18）。</summary>
        public static readonly Color ChipFill = Color.FromArgb(20, 255, 255, 255);
        public static readonly Color SelectedFill = Color.FromArgb(46, 255, 255, 255);

        // 标注的 8 色是内容色，在 Core 的 AnnotationPalette（照 mac，PLAN-v9-annotate D4）。
    }

    /// <summary>
    /// 轻提示胶囊的颜色：深色胶囊和截图的 HUD 一样不跟深浅色变，提示的语气靠底色区分。
    /// </summary>
    public static class Capsule
    {
        public static readonly Color Normal = Color.FromArgb(235, 32, 32, 32);
        public static readonly Color Warning = Color.FromArgb(240, 194, 65, 12);
        public static readonly Color Error = Color.FromArgb(240, 185, 28, 28);
        public static readonly Color Text = Color.FromArgb(255, 255, 255, 255);
        public static readonly Color TextMuted = Color.FromArgb(210, 255, 255, 255);
    }

    /// <summary>
    /// 功能家族色（PLAN-v7 §2.1）：只用在图标块上。颜色取苹果系统色，浅 / 深各一档。
    /// 启动器里每种行再细分一档浅色块（不透明度的衬底），也在这一处。
    /// </summary>
    public static class Family
    {
        public static Color Clipboard => Value(0x007AFF, 0x0A84FF);
        public static Color Launcher => Value(0xAF52DE, 0xBF5AF2);
        public static Color Capture => Value(0xFF2D55, 0xFF375F);
        public static Color Translate => Value(0x34C759, 0x30D158);
        public static Color Shortcut => Value(0xFF9500, 0xFF9F0A);
        public static Color General => Value(0x8E8E93, 0x98989D);
        public static Color Url => Value(0x30B0C7, 0x40C8E0);
        public static Color Search => Value(0x5856D6, 0x5E5CE6);

        /// <summary>状态屏：告示牌的木色（mac systemBrown）。</summary>
        public static Color StatusScreen => Value(0xA2845E, 0xAC8E68);

        /// <summary>提醒：自定义的琥珀色（mac 系统色用完了、红是危险色）。</summary>
        public static Color Reminders => Value(0xE69914, 0xF5AD38);

        /// <summary>便签：系统黄（mac Style.Family.notes = systemYellow）；色块上的符号用黑（mac onTile）。</summary>
        public static Color Notes => Value(0xFFCC00, 0xFFD60A);

        public static Color For(string key) => key switch
        {
            "clipboard" => Clipboard,
            "launcher" or "command" => Launcher,
            "capture" or "screenshot" or "recording" => Capture,
            "translate" => Translate,
            "shortcut" or "hotkey" or "calculator" => Shortcut,
            "url" => Url,
            "search" or "web" => Search,
            "statusScreen" => StatusScreen,
            "reminders" => Reminders,
            "notes" => Notes,
            _ => General,
        };

        /// <summary>图标块的衬底色：家族色压到 12% 左右（旧的淡底画法，过渡期保留）。</summary>
        public static Brush Tint(Color color, byte alpha = 28)
            => new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B));

        public static Brush Tint(string key, byte alpha = 28) => Tint(For(key), alpha);

        /// <summary>U3 的 24 图标块：家族色从上往下 0.95 → 0.75 的渐变（家族名见 KindTile.FamilyOf）。</summary>
        public static Brush Tile(string family)
        {
            var color = For(family);
            var gradient = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0),
                EndPoint = new Windows.Foundation.Point(0, 1),
            };
            gradient.GradientStops.Add(new GradientStop
            {
                Offset = 0,
                Color = Color.FromArgb(242, color.R, color.G, color.B),
            });
            gradient.GradientStops.Add(new GradientStop
            {
                Offset = 1,
                Color = Color.FromArgb(191, color.R, color.G, color.B),
            });
            return gradient;
        }
    }

    /// <summary>浅 / 深两档取一档。</summary>
    public static Color Value(uint light, uint dark)
        => ToColor(EffectiveTheme == ElementTheme.Dark ? dark : light);

    public static Color ToColor(uint rgb)
        => Color.FromArgb(255, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    /// <summary>代码里要拼颜色时走这里（Alpha 明确给）；界面文件不再直接写 Color.FromArgb。</summary>
    public static Color Argb(byte alpha, byte red, byte green, byte blue)
        => Windows.UI.Color.FromArgb(alpha, red, green, blue);

    /// <summary>当前强调色（跟随系统时读系统色）。</summary>
    public static Color AccentColor
    {
        get
        {
            if (SettingsService.Current.Accent == "system")
            {
                try
                {
                    return new UISettings().GetColorValue(UIColorType.Accent);
                }
                catch
                {
                    return BrandPink;
                }
            }

            var palette = AccentPalette.FromSetting(SettingsService.Current.Accent, EffectiveTheme == ElementTheme.Dark);
            return ToColor(AccentPalette.Value(palette, EffectiveTheme == ElementTheme.Dark));
        }
    }

    /// <summary>填充上的符号色（键帽主动作、图标）。</summary>
    public static Color OnAccentColor
    {
        get
        {
            var accent = AccentColor;
            var rgb = ((uint)accent.R << 16) | ((uint)accent.G << 8) | accent.B;
            return ToColor(AccentPalette.OnAccent(rgb));
        }
    }

    /// <summary>浅色背景上的强调文字（对比度 ≥ 4.5:1）。</summary>
    public static Color AccentTextColor
    {
        get
        {
            var accent = AccentColor;
            var rgb = ((uint)accent.R << 16) | ((uint)accent.G << 8) | accent.B;
            return ToColor(AccentPalette.AccentText(rgb, EffectiveTheme == ElementTheme.Dark));
        }
    }

    /// <summary>
    /// 按 key 取主题资源里的画刷，**按设置里选的那套深浅色**（REVIEW R4）：先找
    /// `ThemeDictionaries[Dark / Light / HighContrast]`，取不到再退回应用资源，最后用兜底色。
    /// 浅 / 深色时只取 Styles.xaml 的 `Kitty.*`（字面色）；WinUI 自己的（TextFillColor*、SystemFillColor*）直接给兜底色，
    /// 调用方按 EffectiveTheme 算好：那些画刷全 App 共用一份、颜色是 {ThemeResource} 绑着的，从代码里取按的是 App 的主题
    /// （跟系统，R15 实测 Default 也解出浅色），还会把那一份改掉——设置里选深色、系统是浅色时，模板里引用同一份的
    /// 开关圆点、输入框的字跟着变成浅色那套的黑（2026-11-01 用户截图）。高对比度时整个 App 都是 HC，对得上，照旧取系统的。
    /// 不跟深浅色变的常量（截图 HUD、胶囊、家族色）本来就不走这里。
    /// </summary>
    public static Brush Brush(string key, Color fallback)
    {
        var themeKey = ThemeKey;
        if (themeKey != "HighContrast" && !key.StartsWith("Kitty.", StringComparison.Ordinal))
        {
            return new SolidColorBrush(fallback);
        }

        try
        {
            if (Application.Current?.Resources is { } resources)
            {
                // 深色先找 Dark（Styles.xaml），再退回 Default。
                var keys = themeKey == "Default" ? new[] { "Dark", "Default" } : new[] { themeKey };
                foreach (var dictionaryKey in keys)
                {
                    if (FindTheme(resources, dictionaryKey, key, depth: 0) is { } themed &&
                        themed.TryGetValue(key, out var themedValue) &&
                        themedValue is Brush themedBrush)
                    {
                        return themedBrush;
                    }
                }
            }

            if (Application.Current?.Resources is { } fallbackResources &&
                fallbackResources.TryGetValue(key, out var value) &&
                value is Brush brush)
            {
                return brush;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.resource-missing {key} {ex.GetType().Name}");
        }

        return new SolidColorBrush(fallback);
    }

    /// <summary>PLAN-v7 §2.1：从 Styles.xaml 取字号；取不到给 14。</summary>
    public static double FontSize(string key)
        => Application.Current?.Resources.TryGetValue(key, out var value) == true && value is double size
            ? size
            : 14;

    /// <summary>PLAN-v7 §2.1：从 Styles.xaml 取圆角。</summary>
    public static CornerRadius Corner(string key)
        => Application.Current?.Resources.TryGetValue(key, out var value) == true && value is CornerRadius radius
            ? radius
            : new CornerRadius(4);

    /// <summary>PLAN-v7 §2.1：从 Styles.xaml 取样式。</summary>
    public static Style? Style(string key)
        => Application.Current?.Resources.TryGetValue(key, out var value) == true ? value as Style : null;

    /// <summary>Debug 自检：三套主题各取一次卡片底色，颜色要不一样（R15）。</summary>
    public static void VerifyThemeResources()
    {
        try
        {
            Log.Info($"theme.check effective={EffectiveTheme} card={((SolidColorBrush)CardBackground()).Color} " +
                     $"secondary={((SolidColorBrush)SecondaryText()).Color} accent={AccentColor}");
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.check-failed {ex.GetType().Name}");
        }
    }

    /// <summary>设置里选的外观（「跟随系统」时看系统的）。</summary>
    public static ElementTheme EffectiveTheme => ElementTheme switch
    {
        ElementTheme.Light => ElementTheme.Light,
        ElementTheme.Dark => ElementTheme.Dark,
        _ => Application.Current?.RequestedTheme == ApplicationTheme.Dark
            ? ElementTheme.Dark
            : ElementTheme.Light,
    };

    /// <summary>系统开着高对比度（便签纸上的次要字、标记按「增强对比度」那一档取，PLAN-v13）。</summary>
    public static bool IsHighContrast
    {
        get
        {
            try
            {
                return new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
            }
            catch
            {
                return false;
            }
        }
    }

    private static string ThemeKey
    {
        get
        {
            try
            {
                var settings = new Windows.UI.ViewManagement.AccessibilitySettings();
                if (settings.HighContrast)
                {
                    return "HighContrast";
                }
            }
            catch
            {
                // 读不到辅助功能设置就按普通深浅色。
            }

            return EffectiveTheme == ElementTheme.Dark ? "Default" : "Light";
        }
    }

    /// <summary>找某一套主题、并且里面真有这个 key 的字典（R15：不能碰到一个空字典就返回）。</summary>
    private static ResourceDictionary? FindTheme(
        ResourceDictionary dictionary, string themeKey, string resourceKey, int depth)
    {
        if (depth > 4)
        {
            return null;
        }

        try
        {
            if (dictionary.ThemeDictionaries.TryGetValue(themeKey, out var themed) &&
                themed is ResourceDictionary themedDictionary &&
                themedDictionary.ContainsKey(resourceKey))
            {
                return themedDictionary;
            }
        }
        catch
        {
            // 有的字典没有 ThemeDictionaries，忽略。
        }

        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (FindTheme(merged, themeKey, resourceKey, depth + 1) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    /// <summary>设置卡的底色（PLAN-v7：从 Styles.xaml 的 Kitty.Card 取，跟着当前深浅色）。</summary>
    public static Brush CardBackground()
        => Brush("Kitty.Card", EffectiveTheme == ElementTheme.Dark
            ? Color.FromArgb(0x0F, 255, 255, 255)
            : Color.FromArgb(0x8C, 255, 255, 255));

    /// <summary>主要文字（代码里要显式给前景时）：按设置里选的那套直接给颜色，高对比度取系统的（见 Brush）。</summary>
    public static Brush PrimaryText() => Brush("TextFillColorPrimaryBrush", Value(0x1A1A1A, 0xFFFFFF));

    /// <summary>次要文字。同 PrimaryText（R15）。</summary>
    public static Brush SecondaryText() => Brush("TextFillColorSecondaryBrush", Value(0x606060, 0xBEBEBE));

    /// <summary>三级文字（启动器的种类、分组标题）。同 PrimaryText（R15）。</summary>
    public static Brush TertiaryText() => Brush("TextFillColorTertiaryBrush", Value(0x808080, 0x969696));

    /// <summary>设置卡的实色近似（渐隐遮罩的终点）。</summary>
    public static Color CardColor()
        => ((SolidColorBrush)Brush("Kitty.CardSolid", EffectiveTheme == ElementTheme.Dark
            ? Color.FromArgb(255, 0x2B, 0x2B, 0x2B)
            : Color.FromArgb(255, 0xFB, 0xFB, 0xFB))).Color;

    /// <summary>翻译卡左上角服务徽标的底色（按厂商挑，AI 服务再按协议）。</summary>
    public static Brush ServiceBadge(string vendor)
    {
        var color = vendor switch
        {
            "zhipu" => Color.FromArgb(255, 16, 122, 87),
            "baidu" => Color.FromArgb(255, 41, 98, 255),
            "youdao" => Color.FromArgb(255, 216, 52, 45),
            "google" => Color.FromArgb(255, 66, 133, 244),
            "deepl" => Color.FromArgb(255, 15, 43, 124),
            "microsoft" => Color.FromArgb(255, 0, 120, 212),
            "volcengine" => Color.FromArgb(255, 22, 93, 255),
            "tencent" => Color.FromArgb(255, 0, 91, 234),
            "youdaoDict" => Color.FromArgb(255, 0xE1, 0x25, 0x1B),
            "apple" => Color.FromArgb(255, 0x5E, 0x5C, 0xE6),
            "ai:azure" => Color.FromArgb(255, 0, 120, 212),
            "ai:anthropic" => Color.FromArgb(255, 209, 128, 69),
            "ai:openai" => Color.FromArgb(255, 16, 163, 127),
            _ => Family.Launcher,
        };
        return new SolidColorBrush(color);
    }

    /// <summary>危险 / 错误色（快捷键被占用、错误卡）。</summary>
    public static Brush Critical() => Brush("SystemFillColorCriticalBrush", Value(0xC42B1C, 0xFF99A4));

    /// <summary>警告 / 设置问题色。</summary>
    public static Brush Caution() => Brush("SystemFillColorCautionBrush", Value(0x9D5D00, 0xFCE100));

    /// <summary>成功色（连接正常、已同步）。</summary>
    public static Brush Success() => Brush("SystemFillColorSuccessBrush", Value(0x0F7B0F, 0x6CCB5F));

    /// <summary>窗口标题栏跟着设置里的深浅色走（REVIEW R4）。</summary>
    public static void ApplyTitleBar(Microsoft.UI.Windowing.AppWindow window)
    {
        try
        {
            window.TitleBar.PreferredTheme = EffectiveTheme == ElementTheme.Dark
                ? Microsoft.UI.Windowing.TitleBarTheme.Dark
                : Microsoft.UI.Windowing.TitleBarTheme.Light;
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.titlebar-failed {ex.GetType().Name}");
        }
    }

    private static UISettings? _systemSettings;

    public static ElementTheme ElementTheme => SettingsService.Current.Theme switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    /// <summary>启动时调一次：系统强调色改了（设置里选「跟随系统」时）重算资源。</summary>
    public static void WatchSystemAccent()
    {
        if (_systemSettings is not null)
        {
            return;
        }

        try
        {
            var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _systemSettings = new UISettings();
            _systemSettings.ColorValuesChanged += (_, _) =>
            {
                // 事件在后台线程上：回 UI 线程再改资源字典。
                dispatcher?.TryEnqueue(() =>
                {
                    if (SettingsService.Current.Accent == "system")
                    {
                        ApplyAccent();
                    }
                });
            };
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.accent-watch-failed {ex.GetType().Name}");
        }
    }

    public static void ApplyAccent()
    {
        var resources = Application.Current.Resources;
        var accent = AccentColor;
        var accentText = AccentTextColor;
        var onAccent = OnAccentColor;
        resources["Kitty.Accent"] = new SolidColorBrush(accent);
        resources["Kitty.AccentText"] = new SolidColorBrush(accentText);
        resources["Kitty.OnAccent"] = new SolidColorBrush(onAccent);
        // 老控件还在用 SystemAccentColor*：照旧写，让系统控件也跟着变。
        resources["SystemAccentColor"] = accent;
        var ramp = new AccentRamp.Rgb(accent.R, accent.G, accent.B);
        var steps = AccentRamp.Steps;
        resources["SystemAccentColorLight1"] = Ramp(ramp, steps[0]);
        resources["SystemAccentColorLight2"] = Ramp(ramp, steps[1]);
        resources["SystemAccentColorLight3"] = Ramp(ramp, steps[2]);
        resources["SystemAccentColorDark1"] = Ramp(ramp, steps[3]);
        resources["SystemAccentColorDark2"] = Ramp(ramp, steps[4]);
        resources["SystemAccentColorDark3"] = Ramp(ramp, steps[5]);
        RefreshAccentBrushes(resources, accent, Ramp(ramp, steps[1]), Ramp(ramp, steps[2]), Ramp(ramp, steps[3]), Ramp(ramp, steps[4]), Ramp(ramp, steps[5]));
    }

    /// <summary>
    /// 主题字典里由强调色派生的画刷（开关的填充、侧栏选中条、链接字……）在第一次用时就按当时的颜色建好了，之后改
    /// SystemAccentColor* 它们不跟着变，要等新开的窗口（2026-11-12 用户反馈：换强调色后开关还是旧颜色）。这里把浅 / 深两套里
    /// 这些画刷的颜色就地改掉（透明度留着），开着的窗口当场变。对应关系照 WinUI 的 Common_themeresources（浅色用 Dark1–3、深色用 Light2–3）。
    /// </summary>
    private static void RefreshAccentBrushes(ResourceDictionary root, Color accent, Color light2, Color light3, Color dark1, Color dark2, Color dark3)
    {
        var light = new Dictionary<string, Color>
        {
            ["AccentFillColorDefaultBrush"] = dark1,
            ["AccentFillColorSecondaryBrush"] = dark1,
            ["AccentFillColorTertiaryBrush"] = dark1,
            ["AccentTextFillColorPrimaryBrush"] = dark2,
            ["AccentTextFillColorSecondaryBrush"] = dark3,
            ["AccentTextFillColorTertiaryBrush"] = dark1,
            ["AccentFillColorSelectedTextBackgroundBrush"] = accent,
        };
        var dark = new Dictionary<string, Color>
        {
            ["AccentFillColorDefaultBrush"] = light2,
            ["AccentFillColorSecondaryBrush"] = light2,
            ["AccentFillColorTertiaryBrush"] = light2,
            ["AccentTextFillColorPrimaryBrush"] = light3,
            ["AccentTextFillColorSecondaryBrush"] = light3,
            ["AccentTextFillColorTertiaryBrush"] = light2,
            ["AccentFillColorSelectedTextBackgroundBrush"] = accent,
        };
        var changed = 0;
        void Walk(ResourceDictionary dictionary)
        {
            foreach (var (themeKey, themed) in dictionary.ThemeDictionaries)
            {
                var table = themeKey as string == "Light" ? light : themeKey as string is "Dark" or "Default" ? dark : null;
                if (table is null || themed is not ResourceDictionary theme)
                {
                    continue;
                }

                foreach (var (key, color) in table)
                {
                    if (theme.TryGetValue(key, out var value) && value is SolidColorBrush brush)
                    {
                        brush.Color = color;
                        changed++;
                    }
                }
            }

            foreach (var merged in dictionary.MergedDictionaries)
            {
                Walk(merged);
            }
        }

        try
        {
            Walk(root);
        }
        catch (Exception ex)
        {
            Log.Warn($"theme.accent-brushes-failed {ex.GetType().Name}");
        }

        Log.Info($"theme.accent-brushes changed={changed}");
    }

    public static void ApplyTo(FrameworkElement element)
    {
        element.RequestedTheme = ElementTheme;
    }

    private static Color Ramp(AccentRamp.Rgb color, double amount)
    {
        var scaled = AccentRamp.Scale(color, amount);
        return Color.FromArgb(255, scaled.R, scaled.G, scaled.B);
    }
}
