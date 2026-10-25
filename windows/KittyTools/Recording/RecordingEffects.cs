// 录屏的点按圈 / 按键胶囊的当前状态（第四版第 3 批）：钩子回调往里记，录制线程每帧取一份画进画面。
// 时间用 Environment.TickCount64（毫秒），和录屏线程同一个时钟。
using KittyTools.Core;

namespace KittyTools;

internal static class RecordingEffects
{
    private static readonly object Gate = new();
    private static readonly List<ClickRing> Rings = new();
    private static Keycap? _keycap;

    public static void Clear()
    {
        lock (Gate)
        {
            Rings.Clear();
            _keycap = null;
        }
    }

    public static void Click(int x, int y, bool down, bool right)
    {
        lock (Gate)
        {
            var now = Environment.TickCount64;
            if (down)
            {
                Rings.Add(new ClickRing(x, y, right, now, 0));
            }
            else
            {
                var index = Rings.FindLastIndex(ring => ring.UpAt == 0 && ring.Right == right);
                if (index >= 0)
                {
                    Rings[index] = Rings[index] with { UpAt = now };
                }
            }

            if (Rings.Count > 16)
            {
                Rings.RemoveRange(0, Rings.Count - 16);
            }
        }
    }

    public static void Key(string text)
    {
        lock (Gate)
        {
            _keycap = new Keycap(text, Environment.TickCount64);
        }
    }

    /// <summary>当前还活着的圈和胶囊（过期的不返回）。</summary>
    public static (List<ClickRing> Rings, Keycap? Keycap) Snapshot()
    {
        lock (Gate)
        {
            var now = Environment.TickCount64;
            Rings.RemoveAll(ring => now - ring.DownAt > 4000);
            return (Rings.ToList(), _keycap);
        }
    }

    /// <summary>调试 / 自检：造一个点和一次按键，用来在录出来的画面里检查画得对不对。</summary>
    public static void InjectDemo(int width, int height)
    {
        lock (Gate)
        {
            var now = Environment.TickCount64;
            Rings.Add(new ClickRing(width / 3, height / 2, false, now, 0));
            Rings.Add(new ClickRing(width / 2, height / 2, true, now, 0));
            _keycap = new Keycap("Ctrl + Shift + S", now);
        }
    }
}
