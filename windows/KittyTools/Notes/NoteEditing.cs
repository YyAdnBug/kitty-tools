// 现在开着的便签编辑器（PLAN-v13 第 3 批，照 mac NoteSyncer.editingNotes / NoteStore.imagesArrived）：同步、仓库要问的两件事——
// - 哪几条正在编辑（同步这一轮先不换、不写出去；空白便签先不删）：拿着焦点、而且窗口在前台的那几个，再加挂着没确认组字的；
// - 同步拿下来了几张图：引用它们的编辑器把占位换成图。
// 编辑器建的时候登记（弱引用，窗口关了自己掉出去）。
using KittyTools.Core.Notes;

namespace KittyTools;

internal static class NoteEditing
{
    private static readonly List<WeakReference<NoteEditor>> Editors = new();

    public static void Register(NoteEditor editor)
    {
        Editors.RemoveAll(reference => !reference.TryGetTarget(out _));
        Editors.Add(new WeakReference<NoteEditor>(editor));
    }

    private static IEnumerable<NoteEditor> Live()
    {
        foreach (var reference in Editors.ToList())
        {
            if (reference.TryGetTarget(out var editor))
            {
                yield return editor;
            }
        }
    }

    /// <summary>正在编辑的便签编号。</summary>
    public static IReadOnlySet<string> Ids()
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var foreground = Windows.Win32.PInvoke.GetForegroundWindow();
        foreach (var editor in Live())
        {
            if (editor.NoteId is not { } id)
            {
                continue;
            }

            if (editor.IsComposing || (editor.HasFocus && editor.IsInWindow(foreground)))
            {
                ids.Add(id);
            }
        }

        return ids;
    }

    /// <summary>这一条正在编辑吗（仓库删空白便签前问）。</summary>
    public static bool IsEditing(string id) => Ids().Contains(id);

    /// <summary>这一条的正文框里挂着没确认的组字吗。</summary>
    public static bool IsComposing(string id) => Live().Any(editor => editor.NoteId == id && editor.IsComposing);

    /// <summary>这一条现在开在哪个编辑器里吗（空白便签不删）。</summary>
    public static bool IsOpen(string id) => Live().Any(editor => editor.NoteId == id && editor.View.IsLoaded);

    public static void ImagesArrived(IReadOnlySet<Guid> ids)
    {
        foreach (var editor in Live())
        {
            editor.ImagesArrived(ids);
        }
    }

    /// <summary>这一条在哪个编辑器里开着（划词翻译、从剪贴板 / 启动器粘贴落进便签用）：拿着焦点的那个。</summary>
    public static NoteEditor? Focused()
    {
        var foreground = Windows.Win32.PInvoke.GetForegroundWindow();
        return Live().FirstOrDefault(editor => editor.HasFocus && editor.IsInWindow(foreground));
    }
}
