// 便签正文的撤销 / 重做（PLAN-v13 第 4 批）：RichEditBox 把「改格式」也记进它自己的撤销栈（Ctrl+Z 会先撤掉样式），
// 所以编辑器把它关掉（UndoLimit = 0），改字之前记下「改之前的样子」放进这里，Ctrl+Z / Ctrl+Y 换回去。
// 一个状态 = 编辑器里的字（图片是 U+FFFC）+ 那几张图 + 选区。
// 分组照系统编辑器的手感（mac 用的是系统默认：连着打的字一组）：连着打的字一组；停手超过 1 秒、打了空白 / 换行之后又打字、
// 光标跳走过、做了一次命令（粘贴、Ctrl+T、加标记、换颜色、插图）都另起一组。最多留 200 步。
namespace KittyTools.Core.Notes;

public sealed class NoteUndo<TImage>
{
    public const int Limit = 200;

    public const long GroupMs = 1000;

    /// <summary>两个栈里的字一共最多这么多（一条 1 MB 的便签 200 步就是 400 MB）：超了从最旧的扔（PLAN-v13 复查）。</summary>
    public const long MaxChars = 8_000_000;

    public sealed record State(string Text, IReadOnlyList<TImage> Images, NoteRange Selection);

    private readonly List<State> _undo = new();
    private readonly List<State> _redo = new();
    private long? _lastTyping;
    private int _lastCaret = -1;
    private bool _lastWasSpace;

    public bool CanUndo => _undo.Count > 0;

    public bool CanRedo => _redo.Count > 0;

    /// <summary>打一个字（或删一个字）之前调：要不要另起一组由这里定。before = 改之前的样子；caret = 改之前的光标；
    /// isSpace = 打的是空白 / 换行；now = 毫秒。</summary>
    public void Typing(State before, int caret, bool isSpace, long now)
    {
        var continues = _lastTyping is { } last && now - last <= GroupMs && caret == _lastCaret && !(_lastWasSpace && !isSpace);
        if (!continues)
        {
            Push(before);
        }
        else
        {
            _redo.Clear();
        }

        _lastTyping = now;
        _lastWasSpace = isSpace;
        _lastCaret = -1;
    }

    /// <summary>打完那个字之后光标在哪（下一下接着打才算同一组）。</summary>
    public void TypedTo(int caret) => _lastCaret = caret;

    /// <summary>一次命令（粘贴、Ctrl+T、加标记、换颜色、插图、拖动）之前调：自己一组。</summary>
    public void Command(State before)
    {
        Push(before);
        Break();
    }

    /// <summary>光标跳走、失去焦点、外面换了正文：下一下打字另起一组。</summary>
    public void Break()
    {
        _lastTyping = null;
        _lastCaret = -1;
    }

    /// <summary>撤一步：current 是现在的样子（进重做栈），返回要换成的样子；没有可撤的给 null。</summary>
    public State? Undo(State current)
    {
        if (_undo.Count == 0)
        {
            return null;
        }

        var state = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _redo.Add(current);
        Break();
        return state;
    }

    public State? Redo(State current)
    {
        if (_redo.Count == 0)
        {
            return null;
        }

        var state = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _undo.Add(current);
        Break();
        return state;
    }

    /// <summary>换了一条便签 / 外面换了正文：两个栈都清掉（里面的样子不是这条的了）。</summary>
    public void Clear()
    {
        _undo.Clear();
        _redo.Clear();
        Break();
    }

    private void Push(State state)
    {
        // 字、选区、图片都一样才算没变（改图片宽度、裁切时字一样、图片不一样，各是一步）
        if (_undo.Count > 0 && _undo[^1].Text == state.Text && _undo[^1].Selection == state.Selection
            && _undo[^1].Images.SequenceEqual(state.Images))
        {
            _redo.Clear();
            return;
        }

        _undo.Add(state);
        _redo.Clear();
        var total = _undo.Sum(item => (long)item.Text.Length);
        while (_undo.Count > 1 && (_undo.Count > Limit || total > MaxChars))
        {
            total -= _undo[0].Text.Length;
            _undo.RemoveAt(0);
        }
    }
}
