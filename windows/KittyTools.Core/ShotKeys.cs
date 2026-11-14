// 截图时的快捷键（PLAN-v18 S3 / D4，mac ShotKeys.swift c2db05e8 5b4fdd22 1818d4cb 29c2d080）：工具栏上看得到的都能改——十种标注工具、
// 复制、保存、另存为、钉图、识字、截图翻译、长截图（自动滚）、录屏、裁剪、撤销、重做，加上同样是单字母的「上次区域」「取色」。
// Esc、Enter、Backspace、Delete、Tab、空格、方向键（带什么修饰键都算）、Ctrl+D（复制标注）、Ctrl+W（关掉）、Ctrl+= / Ctrl+-（字号一档）、
// Ctrl+Shift+Z（重做的另一个键）固定不改。长截图 / 自动滚加 Shift 是往上滚（跟着改过的键走）。
// 存在设置的 ScreenshotKeys（id → 「Ctrl+S」写法，同全局快捷键的导出写法；空串 = 清除了，没存过 = 默认），跟着导出导入（shotKeys），
// Windows 本来就不同步快捷键（MAC-DIFF）。设置在 设置 › 快捷键「截图时」两组；工具栏右键一颗钮也能改；悬停提示、速查表都按这里写键。
namespace KittyTools.Core;

public readonly record struct ShotKeyBinding(uint VirtualKey, HotKeyModifiers Modifiers)
{
    public string Display => HotKeyRules.Format(VirtualKey, Modifiers);
}

public sealed record ShotKeyEntry(string Id, string Title, AnnotationKind? Tool, ShotKeyBinding Default);

public static class ShotKeys
{
    private const uint VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12;

    private static ShotKeyBinding Key(char key, HotKeyModifiers modifiers = HotKeyModifiers.None) => new(key, modifiers);

    /// <summary>设置页的两组：十种标注工具（1–0），出图和别的（原来写死的那一套）。</summary>
    public static readonly ShotKeyEntry[] All = AnnotationKinds.All
        .Select(kind => new ShotKeyEntry(
            AnnotationKinds.StorageName(kind), AnnotationKinds.Title(kind), kind, Key(AnnotationKinds.Key(kind)[0])))
        .Concat(new ShotKeyEntry[]
        {
            new("copy", "复制", null, Key('C', HotKeyModifiers.Control)),
            new("save", "快速保存", null, Key('S', HotKeyModifiers.Control)),
            new("saveAs", "另存为…", null, Key('S', HotKeyModifiers.Control | HotKeyModifiers.Shift)),
            new("pin", "钉在屏幕上", null, Key('P')),
            new("recognize", "识字", null, Key('O')),
            new("translate", "截图翻译", null, Key('T')),
            new("scroll", "长截图（加 Shift 向上）", null, Key('S')),
            new("autoScroll", "自动滚动长截图（加 Shift 向上）", null, Key('A')),
            new("record", "切到录屏", null, Key('R')),
            new("crop", "裁剪", null, Key('X')),
            new("undo", "撤销", null, Key('Z', HotKeyModifiers.Control)),
            new("redo", "重做", null, Key('Y', HotKeyModifiers.Control)),
            new("lastRegion", "选中上次的区域", null, Key('D')),
            new("pickColor", "复制放大镜里的色值", null, Key('C')),
        })
        .ToArray();

    public static IEnumerable<ShotKeyEntry> Tools => All.Where(entry => entry.Tool is not null);

    public static IEnumerable<ShotKeyEntry> Others => All.Where(entry => entry.Tool is null);

    public static ShotKeyEntry? Find(string id) => All.FirstOrDefault(entry => entry.Id == id);

    public static string IdFor(AnnotationKind kind) => AnnotationKinds.StorageName(kind);

    /// <summary>现在的键：没存过 = 默认，存了空串 = 清除了（null），读不出来、不能用的也当清除了。</summary>
    public static ShotKeyBinding? Current(string id, IReadOnlyDictionary<string, string>? stored)
    {
        if (Find(id) is not { } entry)
        {
            return null;
        }

        if (stored is null || !stored.TryGetValue(id, out var text))
        {
            return entry.Default;
        }

        return HotKeyRules.TryParse(text, out var key, out var modifiers) && IsUsable(new ShotKeyBinding(key, modifiers))
            ? new ShotKeyBinding(key, modifiers)
            : null;
    }

    /// <summary>存一个键（null = 清除；和默认一样时删掉这一项，回到「没存过」）。返回新的一份。</summary>
    public static Dictionary<string, string> Set(IReadOnlyDictionary<string, string>? stored, string id, ShotKeyBinding? binding)
    {
        var result = stored is null ? new Dictionary<string, string>() : new Dictionary<string, string>(stored);
        if (Find(id) is not { } entry)
        {
            return result;
        }

        if (binding == entry.Default)
        {
            result.Remove(id);
        }
        else
        {
            result[id] = binding?.Display ?? string.Empty;
        }

        return result;
    }

    /// <summary>
    /// 这一下按键对应哪个动作：先比完整的组合；长截图 / 自动滚带 Shift 没对上时去掉 Shift 再比一次（Up = 往上滚）。
    /// </summary>
    public static (string Id, bool Up)? Matching(uint virtualKey, HotKeyModifiers modifiers, IReadOnlyDictionary<string, string>? stored)
    {
        var pressed = new ShotKeyBinding(virtualKey, modifiers);
        foreach (var entry in All)
        {
            if (Current(entry.Id, stored) == pressed)
            {
                return (entry.Id, false);
            }
        }

        if ((modifiers & HotKeyModifiers.Shift) != 0)
        {
            var unshifted = pressed with { Modifiers = modifiers & ~HotKeyModifiers.Shift };
            foreach (var id in new[] { "scroll", "autoScroll" })
            {
                if (Current(id, stored) == unshifted)
                {
                    return (id, true);
                }
            }
        }

        return null;
    }

    /// <summary>十种工具都是默认的 1–0（速查表那一行照旧写「1–0」，改过就逐个列）。</summary>
    public static bool ToolsAreDefault(IReadOnlyDictionary<string, string>? stored)
        => Tools.All(entry => Current(entry.Id, stored) == entry.Default);

    /// <summary>「名字（键）」：工具栏悬停提示；清除了就只写名字。</summary>
    public static string Tip(string name, string id, IReadOnlyDictionary<string, string>? stored)
        => Current(id, stored) is { } binding ? $"{name}（{binding.Display}）" : name;

    /// <summary>截图里另有用处、固定不改的键；修饰键自己、Win 组合也不收。</summary>
    public static bool IsReserved(ShotKeyBinding binding)
    {
        var key = binding.VirtualKey;
        var modifiers = binding.Modifiers;
        if (key is 0x1B or 0x0D or 0x08 or 0x2E or 0x09 or 0x20 or >= 0x25 and <= 0x28)
        {
            return true;
        }

        if (key is VkShift or VkControl or VkMenu or 0x14 or 0x5B or 0x5C or >= 0xA0 and <= 0xA5 || (modifiers & HotKeyModifiers.Win) != 0)
        {
            return true;
        }

        var control = modifiers == HotKeyModifiers.Control;
        // Ctrl+D 复制标注、Ctrl+W 关掉、Ctrl+= / Ctrl+-（主键盘和小键盘）换字号 / 缩放、Ctrl+0 / Ctrl+1 长图标注的适应 / 100 %；
        // Ctrl+Shift+Z 是重做的另一个键
        return (control && key is 0x44 or 0x57 or 0xBB or 0xBD or 0x6B or 0x6D or 0x30 or 0x31 or 0x60 or 0x61) ||
               (modifiers == (HotKeyModifiers.Control | HotKeyModifiers.Shift) && key == 0x5A);
    }

    /// <summary>文件里读进来的能不能用：有键、不带 Win、不是固定的键。</summary>
    public static bool IsUsable(ShotKeyBinding binding) => binding.VirtualKey is > 0 and < 0x100 && !IsReserved(binding);

    /// <summary>
    /// 给 id 录 binding 行不行：不行返回那一行下面的橙字（D4：固定的键、截图里重复、和全局快捷键一样——遮罩拿着焦点时
    /// RegisterHotKey 仍会先把键吃掉）。globals：开着的功能的全局快捷键（名字、组合）。
    /// </summary>
    public static string? Problem(
        ShotKeyBinding binding, string id, IReadOnlyDictionary<string, string>? stored,
        IEnumerable<(string Title, ShotKeyBinding Binding)> globals)
    {
        if (IsReserved(binding))
        {
            return "这个键在截图里另有用处（Esc、Enter、Backspace、Delete、Tab、空格、方向键、Ctrl+D、Ctrl+W、缩放），换一个";
        }

        if (All.FirstOrDefault(entry => entry.Id != id && Current(entry.Id, stored) == binding) is { } other)
        {
            return $"和截图里的「{other.Title}」重复";
        }

        if (globals.FirstOrDefault(global => global.Binding == binding) is { Title: { } title })
        {
            return $"和全局快捷键「{title}」重复";
        }

        return null;
    }

    /// <summary>导入：只收认得的 id、能读的写法、能用的键（空串 = 清除了，照收）。</summary>
    public static Dictionary<string, string> Sanitize(IEnumerable<KeyValuePair<string, string>> values)
    {
        var result = new Dictionary<string, string>();
        foreach (var (id, text) in values)
        {
            if (Find(id) is null)
            {
                continue;
            }

            if (text.Length == 0)
            {
                result[id] = string.Empty;
            }
            else if (HotKeyRules.TryParse(text, out var key, out var modifiers) && IsUsable(new ShotKeyBinding(key, modifiers)))
            {
                result[id] = new ShotKeyBinding(key, modifiers).Display;
            }
        }

        // 截图里重复的：按表的顺序，后面那个和前面撞了就丢掉它改的键（回到默认，mac 读文件时同样丢）
        var taken = new HashSet<ShotKeyBinding>();
        foreach (var entry in All)
        {
            if (Current(entry.Id, result) is { } binding && !taken.Add(binding) && result.Remove(entry.Id) &&
                Current(entry.Id, result) is { } fallback)
            {
                taken.Add(fallback);
            }
        }

        return result;
    }
}
