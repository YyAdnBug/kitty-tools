// 剪贴板列表的顺序（照 mac：copied_at DESC, rowid DESC，内存和库读回来的一致）。纯函数，配单测。
namespace KittyTools.Core;

public static class ClipOrder
{
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
