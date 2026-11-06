// 便签的正文编辑器（PLAN-v13 第 4 批，照 mac Notes/NoteTextView.swift 的行为；规矩在 mac-overlay-panel §3「便签正文的编辑器」）：
// 全部便签窗口、屏幕边缘那叠、浮动便签的正文都是它；快速记一条用普通的多行输入框。
// **WinUI 的 RichEditBox**（PLAN-v13 §3.1：输入法、读屏、拼写、选区、滚动都是系统的），在它上面做 mac 那一套：
// - **存的是纯文本**（Note.Body）；样式是显示时改的格式（字号、粗斜体、划线、颜色、隐藏、段落的行距和缩进），只改格式、不改字。
//   编辑器里的字和存的字差两处：换行一律是 RichEdit 的段落符 \r（读出来换回 \n）；图片令牌换成一个 U+FFFC（RichEdit 的图片对象），
//   按出现的顺序对应 _images 里的那一张（改字时按改前改后的差把这张表跟着挪：删掉的那段里的图拿掉，我们自己插的图排进去）。
// - **样式只重排受影响的行**（NoteStyles 的 Pending / LinesCovering / NeighborLines，代码块的角色变了的行另算），组字期间只攒着。
//   整段换字（切到另一条便签）先排开头一屏，其余的停手后一段段补（同 mac 手测反馈第 6 批）。
// - **Markdown 的标记只在「该露的行」露出来**：拿着焦点时选区碰到的那几行淡淡显示，别的行 CharacterFormat.Hidden 藏起来。
// - **撤销 / 重做自己管**（NoteUndo）：RichEdit 自己的撤销栈关掉（UndoLimit = 0），它会把改格式也记进去。
// - 任务方框是存着的那五个字本身（Segoe UI Symbol 画，按状态上色）：点方框切换（mac 自己画圆角方框，MAC-DIFF 记了）。
// - 上限：会让正文超过 Note.MaxBodyBytes 的那一次改动退回（响一声），组字期间不判断。
// ponytail: 每次改字都整篇读一遍字（GetText）再和上一份比出改了哪一段：1 MB 的正文每个字一两毫秒；真卡了改成接 TOM 的改动通知。
// ponytail: 字号、行高按 0.75 磅 / DIP 换算（XAML 的 FontSize 是 DIP，TOM 的 Size 是磅）；Windows 上核验字号和设置里的一致。
// ponytail: 引用块没有左边那条竖线，只缩进 + 色条色的字（RichEdit 画不了段落旁的竖线；MAC-DIFF 记了）。
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;

namespace KittyTools;

internal sealed partial class NoteEditor
{
    /// <summary>磅 / DIP（TOM 的字号、行距、缩进是磅）。</summary>
    private const float PointsPerDip = 0.75f;

    /// <summary>整段换字时当场排多少个字（扩到整行），其余停手后补。</summary>
    private const int EagerStyleLength = 4000;

    /// <summary>后补时一次排多少个字。</summary>
    private const int StyleChunk = 8000;

    private const char ObjectChar = '\uFFFC';

    private readonly RichEditBox _box;
    private readonly Grid _root;
    private readonly NoteStyles.Pending _pending = new();
    private readonly NoteUndo<NoteImages.Image> _undo = new();
    private readonly List<NoteImages.Image> _images = new();
    private readonly Dictionary<Guid, byte[]> _imageBytes = new();
    private string _text = string.Empty;
    private string _published = string.Empty;
    private IReadOnlyList<NoteMarkdown.CodeBlock> _blocks = Array.Empty<NoteMarkdown.CodeBlock>();

    /// <summary>正在自己改正文 / 格式（不算用户打字）。可以嵌套；只读时这一会儿临时放开 RichEdit 的只读（它只读时拒绝 SetText、改格式）。</summary>
    private bool _applying
    {
        get => _applyingDepth > 0;
        set
        {
            _applyingDepth = Math.Max(_applyingDepth + (value ? 1 : -1), 0);
            if (_readOnly)
            {
                _box.IsReadOnly = _applyingDepth == 0;
            }
        }
    }

    /// <summary>只读（最近删除里的便签）：用户改不了，自己的命令（回车续行、Ctrl+T、粘贴、撤销、图片宽度……）也都不做、不交出去。</summary>
    public bool ReadOnly
    {
        get => _readOnly;
        set
        {
            if (value && !_readOnly)
            {
                // 换成只读的那条之前，先把这条还没交出去的交出去
                PublishPending();
            }

            _readOnly = value;
            _box.IsReadOnly = value;
        }
    }

    /// <summary>上次排的时候代码块里每一行的角色（现在的位置：改字时跟着挪）；mac 记在字上的 roleKey。</summary>
    private List<(NoteRange Range, NoteMarkdown.Role Role)> _roles = new();
    private HashSet<int> _shownLines = new();
    private int _styledUntil;
    private int _applyingDepth;
    private bool _readOnly;
    private bool _composing;

    // 组字这一回的第一下改字之前的样子（撤销只记这一份；确认后超了 1 MB 就退回它）
    private NoteUndo<NoteImages.Image>.State? _composeStart;

    // 刚按下的 Backspace / Delete（没有选区时认改了哪一个字：几个图片的 U+FFFC 长得一样，光比头尾分不出删的是哪一张）
    private VirtualKey? _deleteKey;
    private bool _restyleQueued;
    private NoteRange _lastSelection;
    private NotePaper _paper = NotePaper.All[0];
    private bool _dark;
    private bool _contrast;
    private double _fontSize = 15;
    private bool _markdown = true;
    private NoteSpacing _spacing = NoteSpacing.Standard;

    public NoteEditor()
    {
        _box = new RichEditBox
        {
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            IsSpellCheckEnabled = false,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            Padding = new Thickness(16, 8, 16, 16),
            // Ctrl+B / I / U 这些 RichEdit 自带的格式键关掉：便签的格式是 Markdown 标记（Ctrl+B 等由我们接），存的是纯文本
            DisabledFormattingAccelerators = DisabledFormattingAccelerators.All,
            ClipboardCopyFormat = RichEditClipboardFormat.PlainText,
            SelectionFlyout = null,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(_box, ScrollBarVisibility.Auto);
        // 默认样式拿到焦点 / 悬停时会换成白底黑字、加一道下划线：都换成透明 + 纸上的墨（纸由外面那层画）
        foreach (var key in new[]
                 {
                     "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused",
                     "TextControlBackgroundDisabled", "TextControlBorderBrush", "TextControlBorderBrushPointerOver",
                     "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled",
                 })
        {
            _box.Resources[key] = new SolidColorBrush(Colors.Transparent);
        }

        _box.Document.UndoLimit = 0;
        _box.TextChanging += OnTextChanging;
        _box.SelectionChanged += (_, _) => OnSelectionChanged();
        _box.GotFocus += (_, _) => SyncMarkers();
        _box.LostFocus += (_, _) =>
        {
            _undo.Break();
            SyncMarkers();
            Publish();
        };
        _box.TextCompositionStarted += (_, _) =>
        {
            _composing = true;
            _composeStart = null;
        };
        _box.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            var start = _composeStart;
            _composeStart = null;
            // 组字中不查上限：确认之后超了 1 MB 就整回退到这一回之前（同 mac settle）
            if (start is not null && System.Text.Encoding.UTF8.GetByteCount(Body) > Note.MaxBodyBytes)
            {
                DispatcherQueueSafe(() => Restore(start));
                Overflowed?.Invoke();
                SystemSound.Beep();
                return;
            }

            Settle();
            QueueRestOfStyling();
        };
        _box.PreviewKeyDown += OnPreviewKeyDown;
        _box.Paste += OnPaste;
        _box.AddHandler(UIElement.PointerPressedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler(OnPointerPressed), handledEventsToo: true);
        _box.ContextFlyout = BuildContextMenu();
        _root = new Grid();
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_box, 1);
        _root.Children.Add(_box);
        NoteEditing.Register(this);
    }

    /// <summary>这个编辑器在不在这扇窗口里（foreground 是前台窗口的句柄）：同步「正在编辑的先不换」只算前台窗口里拿着焦点的。</summary>
    public bool IsInWindow(Windows.Win32.Foundation.HWND foreground)
    {
        if (_box.XamlRoot?.ContentIslandEnvironment is not { } island)
        {
            return false;
        }

        return (Windows.Win32.Foundation.HWND)Microsoft.UI.Win32Interop.GetWindowFromWindowId(island.AppWindowId) == foreground;
    }

    /// <summary>放进窗口里的那一块（查找条 + 正文）。</summary>
    public FrameworkElement View => _root;

    public RichEditBox Box => _box;

    /// <summary>这一份是哪条便签的（那叠按它找「这条便签的正文框」）。</summary>
    public string? NoteId { get; private set; }

    /// <summary>正文变了（存的形式；组字期间不报）。</summary>
    public event Action<string, string>? BodyChanged;

    /// <summary>Esc（查找条开着时先关它）、Ctrl+W：交给外面收起。</summary>
    public event Action? CloseRequested;

    /// <summary>会超上限的那一次改动被退回了。</summary>
    public event Action? Overflowed;

    /// <summary>图片文件在哪（NoteImageStore）；null = 图都画成空位。</summary>
    public NoteImageStore? Images { get; set; }

    /// <summary>正文框里挂着没确认的组字（输入法拼音打到一半）。</summary>
    public bool IsComposing => _composing;

    public bool HasFocus => _box.FocusState != FocusState.Unfocused;

    public void Focus() => _box.Focus(FocusState.Programmatic);

    /// <summary>现在的正文（存的形式）。</summary>
    public string Body => Stored(_text, _images);

    // ---- 载入、外观 ----

    /// <summary>换成这条便签的正文（切到另一条、别处改了这条）。和上次交出去的一样就不动（正在打的字不被同一份旧字盖掉）。</summary>
    public void Load(Note note)
    {
        if (NoteId == note.Id && note.Body == _published)
        {
            return;
        }

        var sameNote = NoteId == note.Id;
        if (!sameNote)
        {
            // 换一条之前把上一条还没交出去的那点交出去（组字中也交：换走之后就没机会了）
            PublishPending();
            _imageBytes.Clear();
        }

        NoteId = note.Id;
        _published = note.Body;
        // 外面换了正文（同步、导入）也清：撤销回去会把别的电脑改的悄悄退回去（同 mac replaceAll 时 removeAllActions）
        _undo.Clear();

        var (text, images) = EditorForm(note.Body);
        var selection = sameNote ? Selection : new NoteRange(0, 0);
        Replace(text, images, new NoteRange(Math.Min(selection.Location, text.Length), 0));
    }

    /// <summary>不显示哪条了（窗口收起、编辑卡收回）：先交出去，再放掉——藏着的编辑器还拿着编号的话，空白便签删不掉。</summary>
    public void Release()
    {
        if (NoteId is null)
        {
            return;
        }

        PublishPending();
        NoteId = null;
        _published = string.Empty;
        _undo.Clear();
        _imageBytes.Clear();
        _composeStart = null;
        Replace(string.Empty, Array.Empty<NoteImages.Image>(), new NoteRange(0, 0));
    }

    /// <summary>编辑器里的 U+FFFC 和图片表对得上（对不上时交出去的正文会把图片令牌整个丢掉、再被同步带走：宁可这一下不交，
    /// 记一笔日志；PLAN-v13 复查，RichEdit 把占位的 U+FFFC 洗掉之类的情况在 Windows 上核验）。</summary>
    private bool Aligned()
    {
        if (_text.AsSpan().Count(ObjectChar) == _images.Count)
        {
            return true;
        }

        Log.Warn($"notes.editor-images-misaligned objects={_text.AsSpan().Count(ObjectChar)} images={_images.Count}");
        return false;
    }

    private void PublishPending()
    {
        if (_readOnly || NoteId is not { } id || !Aligned())
        {
            return;
        }

        var body = Body;
        if (body != _published)
        {
            _published = body;
            BodyChanged?.Invoke(id, body);
        }
    }

    /// <summary>纸色、深浅、增强对比度；字号、Markdown 开关、行距（设置 › 便签）。变了就整篇重排。</summary>
    public void Configure(NotePaper paper, bool dark, bool contrast, double fontSize, bool markdown, NoteSpacing spacing)
    {
        if (paper == _paper && dark == _dark && contrast == _contrast && fontSize.Equals(_fontSize) && markdown == _markdown &&
            spacing == _spacing)
        {
            return;
        }

        (_paper, _dark, _contrast, _fontSize, _markdown, _spacing) = (paper, dark, contrast, fontSize, markdown, spacing);
        _box.Foreground = new SolidColorBrush(Ink(1));
        _box.SelectionHighlightColor = new SolidColorBrush(Shade(new NoteShade(_paper.Tone(_dark).Strip, 0.35)));
        _box.FontSize = fontSize;
        foreach (var key in new[] { "TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused" })
        {
            _box.Resources[key] = new SolidColorBrush(Ink(1));
        }

        RestyleAll();
    }

    /// <summary>存的正文 → 编辑器里的字（换行都是 \n，令牌换成 U+FFFC）和那几张图。软换行 U+2028 / U+0085 换成普通换行（同 mac unifyLineBreaks）。</summary>
    private static (string Text, List<NoteImages.Image> Images) EditorForm(string body)
    {
        var text = body.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Replace('\u2028', '\n')
            .Replace('\u0085', '\n').Replace('\u2029', '\n');
        var images = new List<NoteImages.Image>();
        var matches = NoteImages.Matches(text);
        if (matches.Count == 0)
        {
            // 正文里本来就有的 U+FFFC（别处贴来的字）：编辑器里会被当成图，换成空格
            return (text.Replace(ObjectChar, ' '), images);
        }

        var builder = new System.Text.StringBuilder(text.Length);
        var last = 0;
        foreach (var (range, image) in matches)
        {
            builder.Append(text.AsSpan(last, range.Location - last).ToString().Replace(ObjectChar, ' ')).Append(ObjectChar);
            images.Add(image);
            last = range.End;
        }

        builder.Append(text[last..].Replace(ObjectChar, ' '));
        return (builder.ToString(), images);
    }

    /// <summary>编辑器里的字 → 存的正文：每个 U+FFFC 换回它那张图的令牌。</summary>
    private static string Stored(string text, IReadOnlyList<NoteImages.Image> images)
    {
        if (images.Count == 0)
        {
            return text;
        }

        var builder = new System.Text.StringBuilder(text.Length + images.Count * 64);
        var index = 0;
        foreach (var ch in text)
        {
            if (ch == ObjectChar && index < images.Count)
            {
                builder.Append(NoteImages.Token(images[index++]));
            }
            else if (ch != ObjectChar)
            {
                builder.Append(ch);
            }
        }

        return builder.ToString();
    }

    /// <summary>整篇换成这些字（换便签、撤销、外面换了正文）：先放字（图先是一个占位的 U+FFFC），排开头一屏，再一张张换成图。</summary>
    private void Replace(string text, IReadOnlyList<NoteImages.Image> images, NoteRange selection)
    {
        _applying = true;
        try
        {
            _box.Document.SetText(TextSetOptions.None, PlainForm(text));
            PlacePlaceholders(0, text);
            _text = ReadText();
            _images.Clear();
            _images.AddRange(images);
            _blocks = NoteMarkdown.CodeBlocks(_text);
            _roles = RolesOf(_blocks);
            _pending.Take();
            _shownLines.Clear();
            _styledUntil = 0;
            StyleRange(0, Math.Min(EagerStyleLength, _text.Length));
            SetSelection(selection);
        }
        finally
        {
            _applying = false;
        }

        _ = LoadImagesAsync();
        QueueRestOfStyling();
        SyncMarkers();
    }

    private string ReadText()
    {
        _box.Document.GetText(TextGetOptions.None, out var raw);
        // RichEdit 的段落符是 \r；它总会在末尾补一个段落符，GetText(None) 也带着它（Windows 核验：空文档读出来是 "\r"、
        // SetText("a\r") 读出来是 "a\r\r"）：去掉那一个，不然每读一次正文末尾多一个换行
        if (raw.EndsWith('\r'))
        {
            raw = raw[..^1];
        }

        return raw.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
    }

    public NoteRange Selection
    {
        get
        {
            var selection = _box.Document.Selection;
            var start = Math.Clamp(Math.Min(selection.StartPosition, selection.EndPosition), 0, _text.Length);
            var end = Math.Clamp(Math.Max(selection.StartPosition, selection.EndPosition), start, _text.Length);
            return NoteRange.Of(start, end);
        }
    }

    private void SetSelection(NoteRange range)
    {
        var start = Math.Clamp(range.Location, 0, _text.Length);
        var end = Math.Clamp(range.End, start, _text.Length);
        _box.Document.Selection.SetRange(start, end);
    }

    /// <summary>选中的字（存的形式里的那一段：图片换回令牌）；划词翻译读它。</summary>
    public string SelectedText
    {
        get
        {
            var selection = Selection;
            if (selection.Length == 0)
            {
                return string.Empty;
            }

            var before = _text.AsSpan(0, selection.Location).Count(ObjectChar);
            var part = _text.Substring(selection.Location, selection.Length);
            var count = part.AsSpan().Count(ObjectChar);
            return Stored(part, _images.Skip(before).Take(count).ToList());
        }
    }

    // ---- 改字 ----

    private void OnTextChanging(RichEditBox sender, RichEditBoxTextChangingEventArgs args)
    {
        if (_applying || !args.IsContentChanging)
        {
            return;
        }

        var old = _text;
        var now = ReadText();
        if (now == old)
        {
            return;
        }

        // 改了哪一段：共同的头、共同的尾之间
        var prefix = 0;
        var max = Math.Min(old.Length, now.Length);
        while (prefix < max && old[prefix] == now[prefix])
        {
            prefix++;
        }

        var suffix = 0;
        while (suffix < max - prefix && old[old.Length - 1 - suffix] == now[now.Length - 1 - suffix])
        {
            suffix++;
        }

        // 光比头尾分不出删的是哪一张图（U+FFFC 都一样）：按改之前的选区 / 刚按的 Backspace、Delete 定位，对得上就用它
        (prefix, suffix) = Anchored(old, now, prefix, suffix);
        _deleteKey = null;

        var removed = old.Substring(prefix, old.Length - prefix - suffix);
        var inserted = now.Substring(prefix, now.Length - prefix - suffix);
        // 图片表跟着挪：删掉的那段里的图拿掉；新冒出来的 U+FFFC 是别处来的（拖进来的富文本里的对象）：拿掉（我们自己插图走 InsertImages）
        var at = old.AsSpan(0, prefix).Count(ObjectChar);
        var gone = removed.AsSpan().Count(ObjectChar);
        var previousImages = _images.ToList();
        _images.RemoveRange(Math.Min(at, _images.Count), Math.Min(gone, Math.Max(_images.Count - at, 0)));
        var foreign = new List<int>();
        for (var index = 0; index < inserted.Length; index++)
        {
            if (inserted[index] == ObjectChar)
            {
                foreign.Add(prefix + index);
            }
        }

        if (!_composing && now.Length > old.Length && System.Text.Encoding.UTF8.GetByteCount(Stored(now, _images)) > Note.MaxBodyBytes)
        {
            // 超上限的那一次退回（只退让正文变长了的那一次）
            _images.Clear();
            _images.AddRange(previousImages);
            DispatcherQueueSafe(() => Restore(new NoteUndo<NoteImages.Image>.State(old, previousImages, NoteRange.Of(prefix, prefix))));
            Overflowed?.Invoke();
            SystemSound.Beep();
            return;
        }

        // 撤销：打字（连删带打、输入法确认、剪切、拖动）按 NoteUndo 的口径分组；组字时只记这一回第一下之前的样子（中间的拼音不进撤销）
        var before = new NoteUndo<NoteImages.Image>.State(old, previousImages, _lastSelection);
        if (!_composing || _composeStart is null)
        {
            _undo.Typing(before, _lastSelection.Location, inserted.Length > 0 && inserted.All(char.IsWhiteSpace), NoteStore.Now);
            if (_composing)
            {
                _composeStart = before;
            }
        }

        _undo.TypedTo(prefix + inserted.Length);
        _text = now;
        ShiftRoles(prefix, prefix + removed.Length, inserted.Length - removed.Length);
        _pending.Record(new NoteRange(prefix, inserted.Length), inserted.Length - removed.Length);
        if (foreign.Count > 0)
        {
            DispatcherQueueSafe(() => RemoveForeignObjects(foreign));
        }

        if (!_composing)
        {
            Settle();
        }
    }

    /// <summary>改之前的选区 / 刚按的删除键给的那一段（对得上才用，不然照比头尾的结果）。</summary>
    private (int Prefix, int Suffix) Anchored(string old, string now, int prefix, int suffix)
    {
        bool Fits(int p, int s)
            => p >= 0 && s >= 0 && p + s <= old.Length && p + s <= now.Length
               && old.AsSpan(0, p).SequenceEqual(now.AsSpan(0, p))
               && old.AsSpan(old.Length - s).SequenceEqual(now.AsSpan(now.Length - s));

        var selection = _lastSelection;
        if (selection.End > old.Length)
        {
            return (prefix, suffix);
        }

        (int, int)? candidate = null;
        if (selection.Length > 0)
        {
            candidate = (selection.Location, old.Length - selection.End);
        }
        else if (_deleteKey is { } key && old.Length > now.Length)
        {
            var removed = old.Length - now.Length;
            candidate = key == VirtualKey.Back
                ? (selection.Location - removed, old.Length - selection.Location)
                : (selection.Location, old.Length - selection.Location - removed);
        }

        return candidate is var (p, s) && Fits(p, s) ? (p, s) : (prefix, suffix);
    }

    /// <summary>一次编辑收尾：排受影响的行、交出去（组字期间不做）。</summary>
    private void Settle()
    {
        if (_composing || _restyleQueued)
        {
            return;
        }

        _restyleQueued = true;
        // 晚一拍：TextChanging 里改格式会和 RichEdit 正在做的那一下撞（同 mac「选区变化可能在一次改字还没收尾时就来」）
        DispatcherQueueSafe(() =>
        {
            _restyleQueued = false;
            if (_composing)
            {
                return;
            }

            RestyleEdited();
            SyncMarkers();
            Publish();
        });
    }

    private void Publish()
    {
        if (_composing || _readOnly || NoteId is not { } id || !Aligned())
        {
            return;
        }

        var body = Body;
        if (body == _published)
        {
            return;
        }

        _published = body;
        BodyChanged?.Invoke(id, body);
    }

    private void RemoveForeignObjects(List<int> positions)
    {
        _applying = true;
        try
        {
            foreach (var position in positions.OrderByDescending(value => value))
            {
                if (position < _text.Length && _text[position] == ObjectChar)
                {
                    _box.Document.GetRange(position, position + 1).SetText(TextSetOptions.None, string.Empty);
                }
            }

            _text = ReadText();
        }
        finally
        {
            _applying = false;
        }

        RestyleAll();
        Publish();
    }

    /// <summary>在一段字上做一次改动（NoteTasks / NoteMarkdown 给的 Change；位置相对 baseOffset）：一步撤销。</summary>
    private void ApplyChange(NoteTasks.Change change, int baseOffset)
    {
        if (_readOnly)
        {
            return;
        }

        // 先在内存里算出改完的字和图片表：被换掉的那段里的图按顺序给换上来的那段里的 U+FFFC（加标记包住一张图时还是它），
        // 多出来的拿掉；超了 1 MB 就不改（同打字，PLAN-v13 复查）
        var old = _text;
        var images = _images.ToList();
        var next = new System.Text.StringBuilder(old);
        var placeholders = false;
        foreach (var replacement in change.Replacements.Reverse())
        {
            var start = baseOffset + replacement.Range.Location;
            var at = old.AsSpan(0, start).Count(ObjectChar);
            var gone = old.AsSpan(start, replacement.Range.Length).Count(ObjectChar);
            var kept = replacement.Text.AsSpan().Count(ObjectChar);
            var removed = images.Skip(at).Take(gone).ToList();
            images.RemoveRange(Math.Min(at, images.Count), Math.Min(gone, Math.Max(images.Count - at, 0)));
            images.InsertRange(Math.Min(at, images.Count), removed.Take(kept));
            placeholders |= kept > 0;
            next.Remove(start, replacement.Range.Length).Insert(start, replacement.Text);
        }

        if (next.Length > old.Length && System.Text.Encoding.UTF8.GetByteCount(Stored(next.ToString(), images)) > Note.MaxBodyBytes)
        {
            Overflowed?.Invoke();
            SystemSound.Beep();
            return;
        }

        _undo.Command(Snapshot());
        _applying = true;
        try
        {
            foreach (var replacement in change.Replacements.Reverse())
            {
                var start = baseOffset + replacement.Range.Location;
                _box.Document.GetRange(start, start + replacement.Range.Length)
                    .SetText(TextSetOptions.None, PlainForm(replacement.Text));
                PlacePlaceholders(start, replacement.Text);
            }
        }
        finally
        {
            _applying = false;
        }

        _images.Clear();
        _images.AddRange(images);
        _text = ReadText();
        if (placeholders)
        {
            // 换上来的 U+FFFC 是字、不是图：一张张换回图
            _ = LoadImagesAsync();
        }

        if (change.Replacements.Count > 0)
        {
            var from = baseOffset + change.Replacements[0].Range.Location;
            var to = baseOffset + change.Replacements[^1].Range.End;
            ShiftRoles(from, to, _text.Length - old.Length);
        }

        var first = change.Replacements.Count > 0 ? baseOffset + change.Replacements[0].Range.Location : baseOffset;
        var last = change.Replacements.Count > 0
            ? baseOffset + change.Replacements[^1].Range.End + (_text.Length - old.Length)
            : baseOffset;
        _pending.Record(NoteRange.Of(first, Math.Max(last, first)), _text.Length - old.Length);
        SetSelection(new NoteRange(baseOffset + change.Selection.Location, change.Selection.Length));
        Settle();
    }

    /// <summary>在光标处插一段字（剪贴板 / 启动器粘贴落进便签、划词翻译替换回便签）：一步撤销。</summary>
    public void InsertText(string text)
    {
        var selection = Selection;
        var clean = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Replace(ObjectChar, ' ');
        ApplyChange(new NoteTasks.Change(
            new[] { new NoteTasks.Replacement(new NoteRange(0, selection.Length), clean) },
            new NoteRange(clean.Length, 0)), selection.Location);
    }

    // ---- 撤销 ----

    private NoteUndo<NoteImages.Image>.State Snapshot() => new(_text, _images.ToList(), Selection);

    public void Undo()
    {
        if (_readOnly)
        {
            return;
        }

        if (_undo.Undo(Snapshot()) is { } state)
        {
            Restore(state);
        }
        else
        {
            SystemSound.Beep();
        }
    }

    public void Redo()
    {
        if (_readOnly)
        {
            return;
        }

        if (_undo.Redo(Snapshot()) is { } state)
        {
            Restore(state);
        }
        else
        {
            SystemSound.Beep();
        }
    }

    private void Restore(NoteUndo<NoteImages.Image>.State state)
    {
        Replace(state.Text, state.Images, state.Selection);
        Publish();
    }

    // ---- 样式 ----

    private Color Ink(double opacity) => Shade(new NoteShade(_paper.Tone(_dark).Ink, opacity));

    /// <summary>带透明度的颜色先叠在纸上（RichEdit 的颜色不认透明度）。</summary>
    private Color Shade(NoteShade shade)
    {
        var mixed = NotePaper.Mix(shade.Rgb, _paper.Tone(_dark).Paper, shade.Opacity);
        return Color.FromArgb(255, (byte)(mixed >> 16), (byte)(mixed >> 8), (byte)mixed);
    }

    private static Color Rgb(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    /// <summary>编辑之后：排改过的行和挨着的行，再加代码块角色变了的行（和整篇排一遍逐字一样，同 mac restyleEdited）。</summary>
    private void RestyleEdited()
    {
        _blocks = NoteMarkdown.CodeBlocks(_text);
        if (_pending.Take() is not { } edited)
        {
            return;
        }

        var ranges = new List<NoteRange> { NoteStyles.NeighborLines(NoteStyles.LinesCovering(edited, _text), _text) };
        if (_roles.Count > 0 || _blocks.Count > 0)
        {
            ranges.AddRange(NoteStyles.RoleChanges(_text, _roles, _blocks));
        }

        _box.Document.BatchDisplayUpdates();
        try
        {
            foreach (var range in NoteStyles.Merged(ranges))
            {
                StyleRange(range.Location, range.End);
            }
        }
        finally
        {
            _box.Document.ApplyDisplayUpdates();
        }

        _roles = RolesOf(_blocks);
    }

    /// <summary>代码块里每一行（整行连换行）和它的角色，从前到后。</summary>
    private List<(NoteRange Range, NoteMarkdown.Role Role)> RolesOf(IReadOnlyList<NoteMarkdown.CodeBlock> blocks)
    {
        var roles = new List<(NoteRange Range, NoteMarkdown.Role Role)>();
        foreach (var block in blocks)
        {
            var location = block.Range.Location;
            while (location < Math.Min(block.Range.End, _text.Length))
            {
                var (start, end, _) = NoteText.Line(_text, location);
                if (NoteMarkdown.RoleAt(start, blocks) is { } role)
                {
                    roles.Add((NoteRange.Of(start, end), role));
                }

                location = Math.Max(end, location + 1);
            }
        }

        return roles;
    }

    /// <summary>改了 [from, to)（改之前的位置）、长度变了 delta：记着的角色跟着挪，压在改的那段上的去掉（那几行反正要重排）。</summary>
    private void ShiftRoles(int from, int to, int delta)
    {
        if (_roles.Count == 0)
        {
            return;
        }

        var shifted = new List<(NoteRange Range, NoteMarkdown.Role Role)>(_roles.Count);
        foreach (var (range, role) in _roles)
        {
            if (range.End <= from)
            {
                shifted.Add((range, role));
            }
            else if (range.Location >= to)
            {
                shifted.Add((new NoteRange(range.Location + delta, range.Length), role));
            }
        }

        _roles = shifted;
    }

    /// <summary>整篇重排（换纸色 / 字号 / 开关）：开头一屏当场，其余停手后补。</summary>
    private void RestyleAll()
    {
        _blocks = NoteMarkdown.CodeBlocks(_text);
        _roles = RolesOf(_blocks);
        _styledUntil = 0;
        StyleRange(0, Math.Min(EagerStyleLength, _text.Length));
        QueueRestOfStyling();
    }

    private void QueueRestOfStyling()
    {
        if (_styledUntil >= _text.Length)
        {
            return;
        }

        DispatcherQueueSafe(() =>
        {
            if (_composing)
            {
                // 组字中不排、也不再排队（不然整个组字过程都在空转）：确认之后 TextCompositionEnded 再接着排
                return;
            }

            if (_pending.Range is not null)
            {
                QueueRestOfStyling();
                return;
            }

            StyleRange(_styledUntil, Math.Min(_styledUntil + StyleChunk, _text.Length));
            QueueRestOfStyling();
        }, low: true);
    }

    /// <summary>把 [start, end) 碰到的每一行（整行）照现在的字排一遍。</summary>
    private void StyleRange(int start, int end)
    {
        var lines = NoteText.LineRange(_text, NoteRange.Of(start, Math.Max(end, start)));
        var location = lines.Location;
        _applying = true;
        try
        {
            do
            {
                var (lineStart, lineEnd, contentsEnd) = NoteText.Line(_text, location);
                StyleLine(lineStart, contentsEnd, lineEnd);
                if (lineEnd <= location)
                {
                    break;
                }

                location = lineEnd;
            }
            while (location < lines.End);

            _styledUntil = Math.Max(_styledUntil, lines.End);
        }
        finally
        {
            _applying = false;
        }
    }

    private double LineSize(NoteStyles.Shape shape) => shape.Kind switch
    {
        NoteStyles.ShapeKind.Heading => NoteStyles.HeadingSize(shape.Level, _fontSize),
        NoteStyles.ShapeKind.Code => NoteStyles.CodeSize(_fontSize),
        _ => _fontSize,
    };

    /// <summary>一行：先铺回基础样式（字体、字号、墨、不粗不斜不划线不藏），再一段段写；段落上定行高、段前段后、缩进。</summary>
    private void StyleLine(int start, int contentsEnd, int end)
    {
        var line = _text[start..contentsEnd];
        var role = NoteMarkdown.RoleAt(start, _blocks);
        var spans = role is { } inBlock ? NoteStyles.BlockSpans(line, inBlock) : NoteStyles.Spans(line, _markdown);
        var shape = NoteStyles.ShapeOf(line, _markdown, role);
        var shown = _shownLines.Contains(start);
        var whole = _box.Document.GetRange(start, Math.Max(end, contentsEnd));
        var size = LineSize(shape);
        var baseFormat = whole.CharacterFormat;
        baseFormat.Name = shape.Kind == NoteStyles.ShapeKind.Code ? "Cascadia Mono" : "Segoe UI Variable Text";
        baseFormat.Size = (float)(size * PointsPerDip);
        baseFormat.ForegroundColor = shape.Kind == NoteStyles.ShapeKind.Quote ? Shade(_paper.QuoteBar(_dark, _contrast)) : Ink(1);
        baseFormat.BackgroundColor = shape.Kind == NoteStyles.ShapeKind.Code ? Shade(_paper.CodeFill(_dark)) : Colors.Transparent;
        baseFormat.Bold = shape.Kind == NoteStyles.ShapeKind.Heading ? FormatEffect.On : FormatEffect.Off;
        baseFormat.Italic = FormatEffect.Off;
        baseFormat.Strikethrough = FormatEffect.Off;
        baseFormat.Underline = UnderlineType.None;
        baseFormat.Hidden = FormatEffect.Off;
        var paragraph = whole.ParagraphFormat;
        var lineHeight = NoteStyles.LineHeight(shape.Kind == NoteStyles.ShapeKind.Code ? _fontSize : size, _spacing);
        // 有图的行按「至少」：定死的行高不会为图长高，图会被压在一行里（mac 有图的行跟着图高）
        var hasImage = _text.AsSpan(start, Math.Max(contentsEnd - start, 0)).Contains(ObjectChar);
        paragraph.SetLineSpacing(hasImage ? LineSpacingRule.AtLeast : LineSpacingRule.Exactly, (float)(lineHeight * PointsPerDip));
        var before = shape.Kind switch
        {
            NoteStyles.ShapeKind.Heading => size * NoteStyles.HeadingBefore,
            NoteStyles.ShapeKind.Quote or NoteStyles.ShapeKind.Code when IsBlockEdge(start, shape, above: true) => _fontSize * NoteStyles.BlockMargin,
            _ => 0,
        };
        var after = shape.Kind switch
        {
            NoteStyles.ShapeKind.Heading => size * NoteStyles.HeadingAfter,
            NoteStyles.ShapeKind.Quote or NoteStyles.ShapeKind.Code when IsBlockEdge(start, shape, above: false) => _fontSize * NoteStyles.BlockMargin,
            _ => 0,
        };
        paragraph.SpaceBefore = (float)(before * PointsPerDip);
        paragraph.SpaceAfter = (float)(after * PointsPerDip);
        var indent = shape.Kind switch
        {
            NoteStyles.ShapeKind.Quote => NoteStyles.QuoteIndent,
            NoteStyles.ShapeKind.Code => NoteStyles.CodeInset,
            _ => 0,
        };
        paragraph.SetIndents(0, (float)(indent * PointsPerDip), (float)(indent * PointsPerDip));

        foreach (var run in NoteStyles.Runs(spans))
        {
            var range = _box.Document.GetRange(start + run.Range.Location, start + run.Range.End);
            var format = range.CharacterFormat;
            var look = run.Look;
            if (look.Heading > 0)
            {
                format.Size = (float)(NoteStyles.HeadingSize(look.Heading, _fontSize) * PointsPerDip);
                format.Bold = FormatEffect.On;
            }

            if (look.IsBold)
            {
                format.Bold = FormatEffect.On;
            }

            if (look.IsItalic)
            {
                format.Italic = FormatEffect.On;
            }

            if (look.IsStruck || look.IsDone)
            {
                format.Strikethrough = FormatEffect.On;
            }

            if (look.IsCode || look.IsCodeBlock || look.IsFence)
            {
                format.Name = "Cascadia Mono";
                format.Size = (float)(NoteStyles.CodeSize(look.Heading > 0 ? NoteStyles.HeadingSize(look.Heading, _fontSize) : _fontSize) * PointsPerDip);
                format.BackgroundColor = Shade(_paper.CodeFill(_dark));
            }

            var ink = look.Color is { } color
                ? Shade(NotePaper.TextColor(color, _dark, look.IsDone, _contrast))
                : look.IsDone
                    ? Shade(_paper.FadedInk(_dark, _contrast))
                    : look.IsBullet || look.IsFence
                        ? Shade(_paper.SecondaryInk(_dark, _contrast))
                        : (Color?)null;
            if (ink is { } value)
            {
                format.ForegroundColor = value;
            }

            if (look.Link is not null)
            {
                format.Underline = UnderlineType.Single;
            }

            if (look.BoxState is { } state)
            {
                format.Name = "Segoe UI Symbol";
                format.Size = (float)(_fontSize * NoteStyles.BoxScale * PointsPerDip);
                format.Strikethrough = FormatEffect.Off;
                // 紧急：方框就是这个字本身，画成 mac 那个方框的红底色（TaskUrgentMark 是 mac 红底上感叹号的颜色，Windows 核验时照它画成了白 / 黑）
                format.ForegroundColor = state == NoteTaskState.Urgent
                    ? Shade(NotePaper.TextColor(NoteColor.Red, _dark, faded: false, _contrast))
                    : NoteTasks.IsClosed(state)
                        ? Shade(_paper.TaskDone(_dark, _contrast))
                        : Shade(_paper.TaskStroke(_dark, _contrast));
            }

            if (look.IsMarker)
            {
                if (shown)
                {
                    format.ForegroundColor = Shade(_paper.MarkerInk(_dark, _contrast));
                }
                else
                {
                    format.Hidden = FormatEffect.On;
                }
            }
        }
    }

    /// <summary>引用块、代码块的第一行 / 最后一行（段前段后只留在整块的两头）。</summary>
    private bool IsBlockEdge(int start, NoteStyles.Shape shape, bool above)
    {
        int neighbor;
        if (above)
        {
            if (start == 0)
            {
                return true;
            }

            neighbor = NoteText.Line(_text, start - 1).Start;
        }
        else
        {
            var (_, end, contentsEnd) = NoteText.Line(_text, start);
            if (end == contentsEnd)
            {
                return true;
            }

            neighbor = end;
        }

        var (lineStart, _, lineContents) = NoteText.Line(_text, neighbor);
        var other = NoteStyles.ShapeOf(_text[lineStart..lineContents], _markdown, NoteMarkdown.RoleAt(lineStart, _blocks));
        return other.Kind != shape.Kind;
    }

    // ---- 标记藏 / 露 ----

    private void OnSelectionChanged()
    {
        if (_applying)
        {
            return;
        }

        // 光标跳走过的话下一下打字另起一组：NoteUndo.Typing 拿「改之前的光标」和上一下打完的位置比
        _lastSelection = Selection;
        SyncMarkers();
    }

    /// <summary>该露标记的行：拿着焦点时选区碰到的每一行。和上次不一样的那几行重排（只动这几行）。</summary>
    private void SyncMarkers()
    {
        if (_composing || _pending.Range is not null || _restyleQueued)
        {
            return;
        }

        var wanted = new HashSet<int>();
        if (HasFocus && _markdown)
        {
            var selection = Selection;
            var lines = NoteText.LineRange(_text, selection);
            // 只要选区碰到的那几行（从 lines.Location 一行行往下走到 lines.End；同 StyleRange）
            var location = lines.Location;
            do
            {
                var (lineStart, lineEnd, _) = NoteText.Line(_text, location);
                wanted.Add(lineStart);
                if (lineEnd <= location)
                {
                    break;
                }

                location = lineEnd;
            }
            while (location < lines.End);

            if (selection.Location == _text.Length)
            {
                wanted.Add(NoteText.Line(_text, selection.Location).Start);
            }
        }

        if (wanted.SetEquals(_shownLines))
        {
            return;
        }

        var changed = new HashSet<int>(wanted);
        changed.SymmetricExceptWith(_shownLines);
        _shownLines = wanted;
        var selectionBefore = Selection;
        foreach (var start in changed.Order())
        {
            if (start > _text.Length)
            {
                continue;
            }

            var (lineStart, end, contentsEnd) = NoteText.Line(_text, start);
            _applying = true;
            try
            {
                StyleLine(lineStart, contentsEnd, end);
            }
            finally
            {
                _applying = false;
            }
        }

        // 改格式不动选区（RichEdit 有时把光标推到隐藏字的另一边）
        if (Selection != selectionBefore)
        {
            _applying = true;
            SetSelection(selectionBefore);
            _applying = false;
        }
    }

    private void DispatcherQueueSafe(Action action, bool low = false)
        => _box.DispatcherQueue?.TryEnqueue(
            low ? Microsoft.UI.Dispatching.DispatcherQueuePriority.Low : Microsoft.UI.Dispatching.DispatcherQueuePriority.Normal,
            () =>
            {
                try
                {
                    action();
                }
                catch (Exception ex)
                {
                    Log.Warn($"notes.editor-step-failed {ex.GetType().Name}");
                }
            });
}
