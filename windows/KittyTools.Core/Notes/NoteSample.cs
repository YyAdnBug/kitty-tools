// 示例便签（PLAN-v13 第 2 批，照 mac Notes/NoteSample.swift）：这台电脑从没放过示例、便签库里又一条都没有时，放一条讲怎么用的便签——
// 屏幕边缘从一开始就有药丸可看、可点。只放一次：放过没有记在设置里（NotesSampleAdded，这台电脑自己的状态、不导出）；
// 删掉之后不再出现。库里已经有便签（哪怕只在归档、最近删除里）就只记「放过了」、不放。屏幕边缘的总开关关着时这次不放也不记。
namespace KittyTools.Core.Notes;

public static class NoteSample
{
    public enum Step
    {
        /// <summary>不放、也不记。</summary>
        Skip,
        /// <summary>不放，记成放过了。</summary>
        Mark,
        /// <summary>放一条，记成放过了。</summary>
        Add,
    }

    public static Step Next(bool wasAdded, bool isDeckEnabled, int count)
    {
        if (wasAdded)
        {
            return Step.Skip;
        }

        if (count > 0)
        {
            return Step.Mark;
        }

        return isDeckEnabled ? Step.Add : Step.Skip;
    }

    /// <summary>示例的正文：标题留空、第一行就是标题。edgeName：「右」/「左」；hotKey：「快速记一条」现在的快捷键（「Alt + N」），没设键是 null。</summary>
    public static string Body(string edgeName, string? hotKey)
    {
        var capture = hotKey is null ? "在托盘菜单或启动器里选「快速记一条」随手记" : $"按 {hotKey} 随手记一条";
        return "欢迎使用便签\n" +
               $"鼠标靠到屏幕{edgeName}边缘，这一叠就会展开，点一张标签打开它。\n" +
               $"☐ {capture}\n" +
               "☐ 拖动标签调整顺序\n" +
               "☐ 点图钉固定，点别处时它也不收\n" +
               "用不着这条了，点「⋯」里的「删除」。";
    }
}
