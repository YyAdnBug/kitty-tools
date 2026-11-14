// 连按两下修饰键的全局监听（PLAN-v18 L9 / D6）：Raw Input（RIDEV_INPUTSINK，挂在 HiddenWindow 上，只听不拦），不用低级键盘钩子
// （回调慢了会被系统摘掉、杀毒软件敏感）。只在有动作设成连按两下时才注册键盘的 Raw Input，没设就一点开销都没有。
// 自己 SendInput 发的键（粘贴的 Ctrl+V 之类）hDevice 是 0，滤掉，不然连粘两次就算连按 Ctrl。
// 修饰键的按下 / 松开喂给 Core ModifierTaps；中间按了普通键就作废（避开「单按一下 Ctrl 紧接着 Ctrl+C」）。
// ponytail: 只听键盘，不听鼠标（听鼠标要收每一下移动）；两下 Ctrl 中间点了一下鼠标也算连按，要细就加鼠标的 Raw Input 只看按键位。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32.Foundation;

namespace KittyTools;

internal static unsafe partial class ModifierTapListener
{
    private const uint WmInput = 0x00FF;
    private const uint RidInput = 0x10000003;
    private const uint RimTypeKeyboard = 1;
    private const uint RidevInputSink = 0x00000100;
    private const uint RidevRemove = 0x00000001;

    private static readonly ModifierTaps Taps = new();
    private static readonly HashSet<TapKey> Held = new();
    private static IReadOnlyDictionary<TapKey, string> _actions = new Dictionary<TapKey, string>();
    private static Action<string>? _pressed;
    private static bool _win;
    private static bool _listening;

    /// <summary>设成连按两下的动作（键 → 动作 id）；空的就停掉 Raw Input。pressed 在界面线程上回调。</summary>
    public static void Set(IReadOnlyDictionary<TapKey, string> actions, Action<string> pressed)
    {
        _actions = new Dictionary<TapKey, string>(actions);
        _pressed = pressed;
        var wanted = _actions.Count > 0;
        if (wanted == _listening)
        {
            return;
        }

        var device = new RawInputDevice
        {
            UsagePage = 0x01,
            Usage = 0x06,
            Flags = wanted ? RidevInputSink : RidevRemove,
            Target = wanted ? (IntPtr)HiddenWindow.Hwnd.Value : IntPtr.Zero,
        };
        if (!RegisterRawInputDevices(&device, 1, (uint)sizeof(RawInputDevice)))
        {
            Log.Warn($"hotkey.double-tap-register-failed {Marshal.GetLastWin32Error()}");
            return;
        }

        _listening = wanted;
        Held.Clear();
        _win = false;
        Taps.Interrupt(modifiersHeld: false);
        if (wanted)
        {
            HiddenWindow.Message += OnMessage;
        }
        else
        {
            HiddenWindow.Message -= OnMessage;
        }

        Log.Info($"hotkey.double-tap listening={wanted} keys={_actions.Count}");
    }

    private static void OnMessage(uint msg, WPARAM wParam, LPARAM lParam)
    {
        if (msg != WmInput)
        {
            return;
        }

        // RAWINPUTHEADER（x64 / ARM64 是 24 字节）+ RAWKEYBOARD（16 字节）
        var buffer = stackalloc byte[64];
        var size = 64u;
        if (GetRawInputData(lParam.Value, RidInput, buffer, &size, 24) == uint.MaxValue || size < 40)
        {
            return;
        }

        var type = *(uint*)buffer;
        var device = *(IntPtr*)(buffer + 8);
        if (type != RimTypeKeyboard || device == IntPtr.Zero)
        {
            // 不是键盘，或者是程序发的键（SendInput 的 hDevice 是 0）
            return;
        }

        var flags = *(ushort*)(buffer + 26);
        var key = (uint)*(ushort*)(buffer + 30);
        var up = (flags & 1) != 0;
        Feed(key, up, Environment.TickCount64);
    }

    private static void Feed(uint key, bool up, long now)
    {
        if (key is 0x5B or 0x5C)
        {
            if (_win == !up)
            {
                return;
            }

            _win = !up;
        }
        else if (ModifierTaps.FromVirtualKey(key) is { } tap)
        {
            // 按住的自动重复：状态没变，不喂
            if (up ? !Held.Remove(tap) : !Held.Add(tap))
            {
                return;
            }
        }
        else
        {
            if (!up)
            {
                Taps.Interrupt(Held.Count > 0 || _win);
            }

            return;
        }

        if (Taps.Handle(Held, _win, now) is { } done && _actions.TryGetValue(done.Key, out var action))
        {
            _pressed?.Invoke(action);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RawInputDevice
    {
        public ushort UsagePage;
        public ushort Usage;
        public uint Flags;
        public IntPtr Target;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterRawInputDevices(RawInputDevice* devices, uint count, uint size);

    [LibraryImport("user32.dll")]
    private static partial uint GetRawInputData(IntPtr rawInput, uint command, void* data, uint* size, uint headerSize);
}
