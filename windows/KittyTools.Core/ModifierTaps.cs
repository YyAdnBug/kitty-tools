// 连按两下修饰键（PLAN-v18 L9 / D6，mac ModifierTaps.swift 026db987）：一个纯状态机，后台的 Raw Input 监听（ModifierTapListener）和
// 设置页的录制框各喂一份。只认 Ctrl、Alt、Shift 三个（不认 Win：会开关开始菜单）。
// - 每一下按住不超过 MaxHold、第一下松开到第二下按下不超过 MaxGap，第二下**松开**时才算（避开「单按一下 Ctrl 紧接着 Ctrl+C」）；
// - 不分左右：左 Ctrl、右 Ctrl 都是 Ctrl；
// - 按着时又按了别的修饰键（含 Win）、或者中间按了普通键（Interrupt），全松开之前都不算。
// 快捷键里记成「这个修饰键自己的虚拟键、不带修饰键」（HotKeyRules.IsDoubleTap），写法「Ctrl+Ctrl」。纯函数，配单测（ModifierTapsTests）。
namespace KittyTools.Core;

public enum TapKey
{
    Control,
    Alt,
    Shift,
}

public readonly record struct ModifierTap(TapKey Key, long Since);

public sealed class ModifierTaps
{
    /// <summary>每一下最多按住多久、两下之间最多隔多久（毫秒；同 mac 0.3 s，固定）。</summary>
    public const long MaxHold = 300;

    public const long MaxGap = 300;

    private (TapKey Key, long At)? _down;
    private (TapKey Key, long Down, long Up)? _first;
    private bool _spoiled;

    public static uint VirtualKey(TapKey key) => key switch
    {
        TapKey.Control => 0x11,
        TapKey.Alt => 0x12,
        _ => 0x10,
    };

    public static TapKey? FromVirtualKey(uint virtualKey) => virtualKey switch
    {
        0x11 or 0xA2 or 0xA3 => TapKey.Control,
        0x12 or 0xA4 or 0xA5 => TapKey.Alt,
        0x10 or 0xA0 or 0xA1 => TapKey.Shift,
        _ => null,
    };

    /// <summary>修饰键变了一次（held：变化之后按着的三种；other：还按着 Win；time：毫秒）。连按成了返回它。</summary>
    public ModifierTap? Handle(IReadOnlyCollection<TapKey> held, bool other, long time)
    {
        if (held.Count == 0 && !other)
        {
            var spoiled = _spoiled;
            var down = _down;
            _down = null;
            _spoiled = false;
            if (spoiled || down is not { } pressed)
            {
                return null;
            }

            if (time - pressed.At > MaxHold)
            {
                _first = null;
                return null;
            }

            if (_first is { } first && first.Key == pressed.Key)
            {
                _first = null;
                return new ModifierTap(pressed.Key, first.Down);
            }

            _first = (pressed.Key, pressed.At, time);
            return null;
        }

        if (_spoiled || held.Count != 1 || other)
        {
            Spoil();
            return null;
        }

        var key = held.First();
        if (_down is { } current)
        {
            // 同一个键还按着（另一侧也按下 / 松开了一个、按住的自动重复）：不算新的一下
            if (current.Key != key)
            {
                Spoil();
            }

            return null;
        }

        if (_first is { } previous && (previous.Key != key || time - previous.Up > MaxGap))
        {
            _first = null;
        }

        _down = (key, time);
        return null;
    }

    /// <summary>中间按了普通键（Ctrl+C 这种）：这一串作废；还按着修饰键时全松开之前都不算。</summary>
    public void Interrupt(bool modifiersHeld)
    {
        _first = null;
        _down = null;
        _spoiled = modifiersHeld;
    }

    private void Spoil()
    {
        _spoiled = true;
        _down = null;
        _first = null;
    }
}
