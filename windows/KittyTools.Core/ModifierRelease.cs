// 发 Ctrl+V / Ctrl+C 之前要补发哪些修饰键的抬起（纯函数，配单测）。
// PLAN §5.5：热键里的 Alt / Shift 可能还按着，这时直接发 Ctrl+V 会变成 Ctrl+Alt+V。
// - 先等修饰键松开，最多 300 ms；还按着就在 Ctrl+V / Ctrl+C 这组输入的前面补发它们的抬起。
// - 补发 Alt 抬起之前先敲一下没分配的虚拟键 vkE8，免得目标窗口激活菜单栏。
// 修饰键状态在调用方函数开头读一次，作为参数传进来。
namespace KittyTools.Core;

public enum ModifierKey
{
    Shift,
    LeftWindows,
    RightWindows,
    Control,
    Alt,
}

public static class ModifierRelease
{
    /// <summary>「先敲一下」的虚拟键：没分配给任何功能，专门用来吸收 Alt 的菜单栏激活。</summary>
    public const int TapVirtualKey = 0xE8;

    /// <summary>
    /// 还按着的修饰键，按要补发的顺序。Alt 一定在最后（它前面要先敲 vkE8），
    /// Win 在 Ctrl 之前：先松 Win 免得目标窗口把后面的键当成系统组合。
    /// </summary>
    public static IReadOnlyList<ModifierKey> Plan(
        bool control,
        bool alt,
        bool shift,
        bool leftWindows,
        bool rightWindows)
    {
        var plan = new List<ModifierKey>(5);
        if (shift)
        {
            plan.Add(ModifierKey.Shift);
        }

        if (leftWindows)
        {
            plan.Add(ModifierKey.LeftWindows);
        }

        if (rightWindows)
        {
            plan.Add(ModifierKey.RightWindows);
        }

        if (control)
        {
            plan.Add(ModifierKey.Control);
        }

        if (alt)
        {
            plan.Add(ModifierKey.Alt);
        }

        return plan;
    }

    /// <summary>发这个键的抬起之前，要不要先敲一下 vkE8。</summary>
    public static bool NeedsAltGuard(ModifierKey key) => key == ModifierKey.Alt;

    /// <summary>对应的虚拟键码。</summary>
    public static int VirtualKey(ModifierKey key) => key switch
    {
        ModifierKey.Shift => 0x10,
        ModifierKey.Control => 0x11,
        ModifierKey.Alt => 0x12,
        ModifierKey.LeftWindows => 0x5B,
        _ => 0x5C,
    };
}
