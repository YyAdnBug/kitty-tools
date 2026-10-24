// 撤销栈的纯函数（配单测）。剪贴板删除后还没提交时，同内容再复制一次 = 自动撤销：
// 从撤销栈里把那条拿回来，调用方再按「最新」插回列表最前面（同 ClipboardStore.Record 的做法）。
namespace KittyTools.Core;

public static class UndoStack
{
    /// <summary>
    /// 在撤销栈里找第一条匹配的条目并拿出来（那一批因此空了就整批删掉）。
    /// 找不到返回 null。调用方负责把它插回列表最前面并更新复制时间。
    /// </summary>
    public static T? Take<T>(IList<List<T>> batches, Func<T, bool> match)
        where T : class
    {
        for (var batchIndex = 0; batchIndex < batches.Count; batchIndex++)
        {
            var batch = batches[batchIndex];
            var index = batch.FindIndex(item => match(item));
            if (index < 0)
            {
                continue;
            }

            var entry = batch[index];
            batch.RemoveAt(index);
            if (batch.Count == 0)
            {
                batches.RemoveAt(batchIndex);
            }

            return entry;
        }

        return null;
    }
}
