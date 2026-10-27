// 截图遮罩里一块屏的标注、选中的那条和撤销 / 重做栈（纯逻辑，配单测 AnnotationGeometryTests；照 mac SelectionView
// 「标注」一节，PLAN-v9-annotate B1、B2）。标注是不可变的，栈里存列表的浅拷贝；选中记 Id，撤销后那条不在了就取消选中。
// 每次改动一步：画一条、挪一次、改一次样式、删一条；没变不记。拖动途中用 Replace 跟手、不记，松手时 RecordUndo(按下前的)。
namespace KittyTools.Core;

public sealed class AnnotationDocument
{
    private readonly List<Annotation[]> _undo = new();
    private readonly List<Annotation[]> _redo = new();
    private Annotation[] _items = Array.Empty<Annotation>();

    public IReadOnlyList<Annotation> Items => _items;

    public Guid? SelectedId { get; set; }

    public Annotation? Selected => SelectedId is { } id ? Find(id) : null;

    public bool CanUndo => _undo.Count > 0;

    public bool CanRedo => _redo.Count > 0;

    public Annotation? Find(Guid id) => Array.Find(_items, annotation => annotation.Id == id);

    /// <summary>改成 next，变了就记一步撤销（返回 true）；没变不记。</summary>
    public bool Commit(IEnumerable<Annotation> next)
    {
        var list = next.ToArray();
        if (list.SequenceEqual(_items))
        {
            return false;
        }

        _undo.Add(_items);
        _redo.Clear();
        _items = list;
        return true;
    }

    /// <summary>换掉同 Id 的那条（拖动、改大小时跟手），不记撤销。</summary>
    public void Replace(Annotation annotation)
    {
        var index = Array.FindIndex(_items, item => item.Id == annotation.Id);
        if (index < 0)
        {
            return;
        }

        var next = (Annotation[])_items.Clone();
        next[index] = annotation;
        _items = next;
    }

    /// <summary>放在最上面、先不记撤销（单击放序号接着就能拖，松手时 RecordUndo 一共记一步）。</summary>
    public void AppendLive(Annotation annotation) => _items = _items.Append(annotation).ToArray();

    /// <summary>一次拖动（挪、改大小）松手时按按下前的样子记一步撤销；没变不记。</summary>
    public bool RecordUndo(IReadOnlyList<Annotation> before)
    {
        if (before.SequenceEqual(_items))
        {
            return false;
        }

        _undo.Add(before.ToArray());
        _redo.Clear();
        return true;
    }

    /// <summary>撤销一步；栈空返回 false（调用方出提示音）。</summary>
    public bool Undo() => Step(_undo, _redo);

    public bool Redo() => Step(_redo, _undo);

    /// <summary>删掉选中的那条（记一步撤销）。</summary>
    public bool DeleteSelected()
    {
        if (SelectedId is not { } id || Find(id) is null)
        {
            return false;
        }

        SelectedId = null;
        return Commit(_items.Where(annotation => annotation.Id != id));
    }

    /// <summary>改选中那条的样式（记一步撤销），返回改完的样式；没选中返回 null。</summary>
    public AnnotationStyle? RestyleSelected(Func<AnnotationStyle, AnnotationStyle> change)
    {
        if (Selected is not { } selected)
        {
            return null;
        }

        var restyled = selected with { Style = change(selected.Style) };
        Commit(_items.Select(annotation => annotation.Id == selected.Id ? restyled : annotation));
        return restyled.Style;
    }

    /// <summary>整份换掉（截图历史里接着改），撤销栈清空。</summary>
    public void Load(IEnumerable<Annotation> annotations)
    {
        _items = annotations.ToArray();
        _undo.Clear();
        _redo.Clear();
        SelectedId = null;
    }

    public void Reset() => Load(Array.Empty<Annotation>());

    private bool Step(List<Annotation[]> from, List<Annotation[]> to)
    {
        if (from.Count == 0)
        {
            return false;
        }

        to.Add(_items);
        _items = from[^1];
        from.RemoveAt(from.Count - 1);
        if (SelectedId is { } id && Find(id) is null)
        {
            SelectedId = null;
        }

        return true;
    }
}
