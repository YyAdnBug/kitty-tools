// 全局热键。默认键在 SettingsDefaults；注册失败 = 被别的程序占了，
// Windows 能查出来，设置 › 快捷键里那一行标红，托盘菜单里不写这个键。
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

    public event Action<string>? Pressed;

    public void RegisterAll(Settings settings)
    {
        UnregisterAll();

        var id = 1;
        foreach (var definition in SettingsDefaults.DefaultHotKeys)
        {
            var binding = SettingsDefaults.BindingFor(settings, definition.Action);
            if (binding.VirtualKey == 0)
            {
                id++;
                continue;
            }

            var validation = HotKeyRules.Validate(binding.VirtualKey, binding.Modifiers);
            if (!validation.Ok)
            {
                _failures[definition.Action] = validation.Reason ?? "组合无效";
                id++;
                continue;
            }

            var nativeModifiers = HOT_KEY_MODIFIERS.MOD_NOREPEAT;
            if ((binding.Modifiers & HotKeyModifiers.Control) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_CONTROL;
            if ((binding.Modifiers & HotKeyModifiers.Alt) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_ALT;
            if ((binding.Modifiers & HotKeyModifiers.Shift) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_SHIFT;
            if ((binding.Modifiers & HotKeyModifiers.Win) != 0) nativeModifiers |= HOT_KEY_MODIFIERS.MOD_WIN;

            if (PInvoke.RegisterHotKey(HiddenWindow.Hwnd, id, nativeModifiers, binding.VirtualKey))
            {
                _idToAction[id] = definition.Action;
                _registered.Add(definition.Action);
            }
            else
            {
                var error = Marshal.GetLastWin32Error();
                _failures[definition.Action] = error == 1409 ? "被占用" : $"注册失败（{error}）";
                Log.Warn($"hotkey.failed {definition.Action} {error}");
            }

            id++;
        }
    }

    public void UnregisterAll()
    {
        foreach (var id in _idToAction.Keys)
        {
            PInvoke.UnregisterHotKey(HiddenWindow.Hwnd, id);
        }

        _idToAction.Clear();
        _registered.Clear();
        _failures.Clear();
    }

    public void OnHotKey(int id)
    {
        if (_idToAction.TryGetValue(id, out var action))
        {
            Pressed?.Invoke(action);
        }
    }

    public bool IsRegistered(string action) => _registered.Contains(action);

    public string? ShortcutFor(string action)
    {
        if (!_registered.Contains(action))
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
