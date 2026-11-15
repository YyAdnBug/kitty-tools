// 录快捷键时和谁撞了（PLAN-v23 H3，照 mac HotKeyRecorder.save / saveCommand，纯函数配单测）：
// 全局动作的组合不许和别的全局动作一样——关着的功能的键也算（不然它重新打开时两个动作抢同一个组合，后注册的那个失败），
// 话里写明它关着；也不许和启动器某条命令的快捷键一样。命令那边反过来查（和全局、和别的命令）。连按两下存成（键，无修饰）照样比。
namespace KittyTools.Core;

/// <summary>一个全局动作此刻的键：OffFeature = 它的功能关着时那个功能的名字（开着为 null）。</summary>
public readonly record struct HotKeyOwner(string Action, string Title, uint VirtualKey, HotKeyModifiers Modifiers, string? OffFeature = null);

/// <summary>一条启动器命令此刻的键。</summary>
public readonly record struct CommandKeyOwner(string Id, string Title, uint VirtualKey, HotKeyModifiers Modifiers);

public static class HotKeyConflicts
{
    /// <summary>给全局动作 action 录 (virtualKey, modifiers)：撞了返回那一行下面的橙字，没撞 null。</summary>
    public static string? ForGlobal(
        string action, uint virtualKey, HotKeyModifiers modifiers, IEnumerable<HotKeyOwner> globals, IEnumerable<CommandKeyOwner> commands)
    {
        if (virtualKey == 0)
        {
            return null;
        }

        foreach (var other in globals)
        {
            if (other.Action != action && other.VirtualKey == virtualKey && other.Modifiers == modifiers)
            {
                return other.OffFeature is { } feature ? $"和「{other.Title}」重复（{feature}已关闭）" : $"和「{other.Title}」重复";
            }
        }

        foreach (var command in commands)
        {
            if (command.VirtualKey == virtualKey && command.Modifiers == modifiers)
            {
                return $"和启动器命令「{command.Title}」重复";
            }
        }

        return null;
    }

    /// <summary>给启动器命令 id 录：和全局动作（关着的也算）、和别的命令都不许一样。</summary>
    public static string? ForCommand(
        string id, uint virtualKey, HotKeyModifiers modifiers, IEnumerable<HotKeyOwner> globals, IEnumerable<CommandKeyOwner> commands)
    {
        if (virtualKey == 0)
        {
            return null;
        }

        foreach (var other in globals)
        {
            if (other.VirtualKey == virtualKey && other.Modifiers == modifiers)
            {
                return other.OffFeature is { } feature ? $"和全局快捷键「{other.Title}」重复（{feature}已关闭）" : $"和全局快捷键「{other.Title}」重复";
            }
        }

        foreach (var command in commands)
        {
            if (command.Id != id && command.VirtualKey == virtualKey && command.Modifiers == modifiers)
            {
                return $"和命令「{command.Title}」重复";
            }
        }

        return null;
    }
}
