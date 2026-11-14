// 全局热键。默认键在 SettingsDefaults；注册失败 = 被别的程序占了，
// Windows 能查出来，设置 › 快捷键里那一行标红，托盘菜单里不写这个键。
// 按应用停用（PLAN-v17）：HotKeyBlocker 在前台一变时算出规则交给 Apply，被停的动作注销、键原样到前台那个应用；
// 规则和上次一样就什么都不做，不一样只动变了的那几个 id（失败原因留着，设置页那几行橙字不闪）。
// 截图框选、录快捷键这些时候 UnregisterAll 停着全部热键，这期间前台变了只记规则，RegisterAll 时按那时的前台注册。
// 设成连按两下修饰键的（PLAN-v18 L9，HotKeyRules.IsDoubleTap）不走 RegisterHotKey，交给 ModifierTapListener（Raw Input）。
// 启动器每条命令的快捷键（PLAN-v18 L3）也在这里注册：动作名是「cmd:编号」，热键号从 1000 起、每条命令这次运行里一个固定的号、不复用；
// 停用名单选「全部」时连它们一起停（PLAN-v17 H3），只停几个的不管它们。
using System.Diagnostics;
using System.Runtime.InteropServices;
using KittyTools.Infrastructure;
using KittyTools.Core;
using Windows.Win32;
using Windows.Win32.UI.Input.KeyboardAndMouse;

namespace KittyTools;

internal sealed class HotKeyManager
{
    private readonly Dictionary<int, string> _idToAction = new();
    private readonly HashSet<string> _registered = new();
    private readonly Dictionary<string, string> _failures = new();
    /// <summary>因为停用规则才没注册的动作（不算失败；规则变了要补上）。</summary>
    private readonly HashSet<string> _blocked = new();
    /// <summary>设成连按两下的动作（键 → 动作 id）。</summary>
    private readonly Dictionary<TapKey, string> _taps = new();
    private HotKeyBlockRule? _rule;
    private bool _suspended = true;

    public event Action<string>? Pressed;

    /// <summary>启动器命令的快捷键按下了（命令编号）。</summary>
    public event Action<string>? CommandPressed;

    public const string CommandPrefix = "cmd:";

    /// <summary>每条命令的热键号（这次运行里固定、不复用：注销后再注册还是这个号）。</summary>
    private readonly Dictionary<string, int> _commandIds = new();
    private int _nextCommandId = 1000;

#if DEBUG
    internal int CommandHotKeyIdForProbe(string command) => CommandHotKeyId(command);
#endif

    private int CommandHotKeyId(string command)
    {
        if (!_commandIds.TryGetValue(command, out var id))
        {
            _commandIds[command] = id = _nextCommandId++;
        }

        return id;
    }

    /// <summary>上一次注册 / 注销用了多久（PLAN-v17 W5，报告用）。</summary>
    public double LastApplyMilliseconds { get; private set; }

    /// <summary>按设置注册全部热键（截图、录快捷键结束时也是它）；被前台规则停的动作跳过。</summary>
    public void RegisterAll(Settings settings)
    {
        UnregisterAll();
        _suspended = false;
        var started = Stopwatch.GetTimestamp();
        var id = 1;
        foreach (var definition in SettingsDefaults.DefaultHotKeys)
        {
            RegisterOne(id++, definition.Action, settings);
        }

        foreach (var (command, binding) in LauncherCommandKeys.Bindings())
        {
            RegisterBinding(CommandHotKeyId(command), CommandPrefix + command, binding, _rule?.BlocksCommands == true);
        }

        SyncTaps();
        LastApplyMilliseconds = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
    }

    /// <summary>停掉全部热键（截图框选、状态屏、录快捷键时）；之后 RegisterAll 按那时的前台规则注册回来。</summary>
    public void UnregisterAll()
    {
        foreach (var id in _idToAction.Keys)
        {
            PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, id);
        }

        _idToAction.Clear();
        _registered.Clear();
        _failures.Clear();
        _blocked.Clear();
        _taps.Clear();
        SyncTaps();
        _suspended = true;
    }

    /// <summary>
    /// 前台规则变了（HotKeyBlocker）：和上次一样什么都不做；停着时只记下，RegisterAll 时用。
    /// 不一样只注销新停的、补注册新放开的那几个。
    /// </summary>
    public void Apply(HotKeyBlockRule? rule)
    {
        if (Equals(rule, _rule))
        {
            return;
        }

        _rule = rule;
        if (_suspended)
        {
            return;
        }

        var started = Stopwatch.GetTimestamp();
        var settings = SettingsService.Current;
        var id = 1;
        foreach (var definition in SettingsDefaults.DefaultHotKeys)
        {
            var action = definition.Action;
            var blocks = rule?.Blocks(action) == true;
            if (blocks && _registered.Contains(action))
            {
                if (_taps.FirstOrDefault(pair => pair.Value == action) is { Value: not null } tap)
                {
                    _taps.Remove(tap.Key);
                }
                else
                {
                    PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, id);
                }

                _idToAction.Remove(id);
                _registered.Remove(action);
                _blocked.Add(action);
            }
            else if (!blocks && _blocked.Remove(action))
            {
                RegisterOne(id, action, settings);
            }

            id++;
        }

        // 命令的快捷键只跟着「全部」
        foreach (var (command, binding) in LauncherCommandKeys.Bindings())
        {
            var action = CommandPrefix + command;
            var hotKeyId = CommandHotKeyId(command);
            var blocks = rule?.BlocksCommands == true;
            if (blocks && _registered.Remove(action))
            {
                PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, hotKeyId);
                _idToAction.Remove(hotKeyId);
                _blocked.Add(action);
            }
            else if (!blocks && _blocked.Remove(action))
            {
                RegisterBinding(hotKeyId, action, binding, blocked: false);
            }
        }

        SyncTaps();
        LastApplyMilliseconds = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        Log.Info($"hotkey.block-applied rule={(rule is null ? "none" : rule.AllActions ? "all" : rule.Only.Count.ToString())} ms={LastApplyMilliseconds:F2}");
    }

    private void RegisterOne(int id, string action, Settings settings)
    {
        // 功能关掉了：热键不注册（第三版 §2.3）。
        if (!Features.IsOnFor(action))
        {
            return;
        }

        var binding = SettingsDefaults.BindingFor(settings, action);
        if (binding.VirtualKey == 0)
        {
            return;
        }

        RegisterBinding(id, action, binding, _rule?.Blocks(action) == true);
    }

    /// <summary>注册一个组合（全局动作、启动器命令共用）；blocked：名单里的应用在前台，不注册、不算失败。</summary>
    private void RegisterBinding(int id, string action, HotKeyBinding binding, bool blocked)
    {
        var validation = HotKeyRules.Validate(binding.VirtualKey, binding.Modifiers);
        if (!validation.Ok)
        {
            _failures[action] = validation.Reason ?? "组合无效";
            return;
        }

        // 名单里的应用在前台：不注册，键原样到它（不算失败）
        if (blocked)
        {
            _blocked.Add(action);
            return;
        }

        // 连按两下修饰键：不注册组合，交给 Raw Input 的监听（同一个键只认第一个动作）
        if (HotKeyRules.IsDoubleTap(binding.VirtualKey, binding.Modifiers) && !action.StartsWith(CommandPrefix, StringComparison.Ordinal) &&
            ModifierTaps.FromVirtualKey(binding.VirtualKey) is { } tap)
        {
            if (!_taps.TryAdd(tap, action))
            {
                _failures[action] = $"和「{SettingsDefaults.RowTitle(_taps[tap])}」重复";
                return;
            }

            _registered.Add(action);
            _failures.Remove(action);
            return;
        }

        var nativeModifiers = HOT_KEY_MODIFIERS.MOD_NOREPEAT;
        if ((binding.Modifiers & HotKeyModifiers.Control) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_CONTROL;
        if ((binding.Modifiers & HotKeyModifiers.Alt) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_ALT;
        if ((binding.Modifiers & HotKeyModifiers.Shift) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_SHIFT;
        if ((binding.Modifiers & HotKeyModifiers.Win) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_WIN;

        if (PInvoke.RegisterHotKey(HiddenWindow.Hwnd, id, nativeModifiers, binding.VirtualKey))
        {
            _idToAction[id] = action;
            _registered.Add(action);
            _failures.Remove(action);
        }
        else
        {
            var error = Marshal.GetLastWin32Error();
            _failures[action] = error == 1409 ? "被占用" : $"注册失败（{error}）";
            Log.Warn($"hotkey.failed {action} {error}");
        }
    }

    private void SyncTaps() => ModifierTapListener.Set(_taps, OnDoubleTap);

    private void OnDoubleTap(string action)
    {
        if (!_registered.Contains(action))
        {
            return;
        }

        Fire(action);
    }

    public void OnHotKey(int id)
    {
        if (_idToAction.TryGetValue(id, out var action))
        {
            Fire(action);
        }
    }

    private void Fire(string action)
    {
        // 全屏游戏（PLAN-v17 W2）：全屏进出系统不发通知，按下时再查一次；是就这一下不做事，并且全部停到下次前台变化（后面几下到游戏）
        if (HotKeyBlocker.FullscreenGameNow())
        {
            Log.Info("hotkey.fullscreen-swallowed");
            Apply(HotKeyBlockRule.All);
            return;
        }

        if (action.StartsWith(CommandPrefix, StringComparison.Ordinal))
        {
            CommandPressed?.Invoke(action[CommandPrefix.Length..]);
            return;
        }

        Pressed?.Invoke(action);
    }

    public bool IsRegistered(string action) => _registered.Contains(action);

    /// <summary>这个动作此刻因为停用名单没注册（托盘菜单照样写键，不当成失败）。</summary>
    public bool IsBlocked(string action) => _blocked.Contains(action);

    public string? ShortcutFor(string action)
    {
        if (!_registered.Contains(action) && !_blocked.Contains(action))
        {
            return null;
        }

        var binding = SettingsDefaults.BindingFor(SettingsService.Current, action);
        return HotKeyRules.Format(binding.VirtualKey, binding.Modifiers);
    }

    public string? FailureFor(string action) => _failures.GetValueOrDefault(action);

    public static string FormatFor(string action)
    {
        var binding = SettingsDefaults.BindingFor(SettingsService.Current, action);
        return binding.VirtualKey == 0
            ? "未设置"
            : HotKeyRules.Format(binding.VirtualKey, binding.Modifiers);
    }
}
