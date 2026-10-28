// 剪贴板列表的顺序（照 mac：copied_at DESC, rowid DESC，内存和库读回来的一致）。纯函数，配单测。
namespace KittyTools.Core;

/// <summary>点一下列表里的一行做什么（mac ClipboardPanelModel.click）。</summary>
public enum ClipClick
{
    Select,
    Check,
    Range,
    Paste,
}

public static class ClipOrder
{
    /// <summary>
    /// Ctrl 单击 = 勾选、Shift 单击 = 整段选；双击 = 粘贴；打开「单击条目直接粘贴」后不带修饰键的单击也是粘贴。
    /// 不是鼠标点的（读屏激活这一行，clicks = 0）照旧只选中（mac clickPastesOnlyWhenAsked）。
    /// </summary>
    public static ClipClick Click(bool control, bool shift, int clicks, bool pastesOnClick)
        => control ? ClipClick.Check
            : shift ? ClipClick.Range
            : clicks >= 2 || (clicks == 1 && pastesOnClick) ? ClipClick.Paste
            : ClipClick.Select;

    /// <summary>a 应该排在 b 前面（更新的在前；同一时刻 rowid 大的在前）。</summary>
    public static bool Before(long timeA, long idA, long timeB, long idB)
        => timeA != timeB ? timeA > timeB : idA > idB;

    /// <summary>把（time, id）插进按上面顺序排好的列表时该放的下标。</summary>
    public static int InsertIndex<T>(IReadOnlyList<T> items, Func<T, long> time, Func<T, long> id, long newTime, long newId)
    {
        int low = 0, high = items.Count;
        while (low < high)
        {
            var mid = (low + high) / 2;
            if (Before(time(items[mid]), id(items[mid]), newTime, newId))
            {
                low = mid + 1;
            }
            else
            {
                high = mid;
            }
        }

        return low;
    }
}
