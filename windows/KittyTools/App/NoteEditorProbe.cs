// 便签正文编辑器的自检（PLAN-v13 第 4 批「要特别看的」7 条 + 审查方复查 VERIFY 1，Windows 核验时加的）：
// `--note-editor-probe=<目录>`（只在测试档）开一扇自己的窗口放一个 NoteEditor，用 TOM（SetText / TypeText / SetRange / 改格式）
// 走那几条 RichEdit 的行为，结果写 <目录>\report.md；再按浅色 / 深色 / 增强对比度各出一张正文的图（WindowShot，只抓这扇窗）。
// 不发按键：Ctrl+B 这类要真按键的那条（第 6 条）留给手测。窗口会拿一下前台（同 --ui-snapshots），跑完就退。
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace KittyTools;

internal static class NoteEditorProbe
{
    public const string ArgumentPrefix = "--note-editor-probe";

    private static readonly char ObjectChar = (char)0xFFFC;

    public static bool IsRequested(string[] args)
        => Paths.IsTestProfile && args.Any(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));

    public static string? DirectoryFrom(string[] args)
    {
        var argument = args.FirstOrDefault(arg => arg.StartsWith(ArgumentPrefix, StringComparison.OrdinalIgnoreCase));
        if (argument is null)
        {
            return null;
        }

        var path = argument.Contains('=') ? argument[(argument.IndexOf('=') + 1)..] : string.Empty;
        return string.IsNullOrWhiteSpace(path)
            ? Path.Combine(Path.GetTempPath(), "kitty-note-editor-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 便签编辑器自检（PLAN-v13 第 4 批的 7 条）\n\n");
        void Line(string text)
        {
            report.Append("- ").Append(text).Append('\n');
        }

        var images = Path.Combine(directory, "images");
        Directory.CreateDirectory(images);
        var paper = NotePaper.All[0];
        var editor = new NoteEditor { Images = new NoteImageStore(images) };
        var sink = new Button { Content = "焦点", Width = 1, Height = 1, Opacity = 0 };
        var root = new Grid { Background = Paper(paper, false) };
        root.Children.Add(sink);
        root.Children.Add(editor.View);
        var window = new Window { Title = Paths.ProductName + " 便签编辑器自检", Content = root };
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.MoveAndResize(new RectInt32(8, 8, 560, 720));
        window.Activate();
        await Task.Delay(600);
        var book = new NoteBook(() => "PROBE");
        var now = NoteStore.Now;
        var doc = editor.Box.Document;
        string Read()
        {
            doc.GetText(TextGetOptions.None, out var raw);
            return raw;
        }

        try
        {
            // 0. 裸的 RichEdit 行为（不经 NoteEditor）：SetText 对 U+FFFC、InsertImage 换不换掉那一个字、末尾的段落符
            var bare = new RichEditBox { Width = 300, Height = 120 };
            root.Children.Add(bare);
            await Task.Delay(300);
            var bd = bare.Document;
            string Codes(string text) => string.Join(" ", text.Select(ch => ((int)ch).ToString("X4")));
            string BareText()
            {
                bd.GetText(TextGetOptions.None, out var t);
                return t;
            }

            bd.SetText(TextSetOptions.None, "");
            Line($"0 空文档 GetText：[{Codes(BareText())}]");
            bd.SetText(TextSetOptions.None, "a");
            Line($"0 SetText(a)：[{Codes(BareText())}]");
            bd.SetText(TextSetOptions.None, "a\r");
            Line($"0 SetText(a\\r)：[{Codes(BareText())}]");
            bd.SetText(TextSetOptions.None, "a" + ObjectChar + "b");
            Line($"0 SetText(a FFFC b)：[{Codes(BareText())}]");
            var onePx = await PngBytes(1, 1);
            bd.GetRange(1, 2).InsertImage(1, 1, 1, VerticalCharacterAlignment.Baseline, "图片", new MemoryStream(onePx).AsRandomAccessStream());
            Line($"0 在 1..2 InsertImage(1×1)：[{Codes(BareText())}]");
            bd.GetRange(1, 2).InsertImage(40, 20, 16, VerticalCharacterAlignment.Baseline, "图片", new MemoryStream(await PngBytes(40, 20)).AsRandomAccessStream());
            Line($"0 再在 1..2 InsertImage(40×20)（换掉对象）：[{Codes(BareText())}]");
            bd.Selection.SetRange(0, 0);
            bd.GetRange(0, 0).InsertImage(1, 1, 1, VerticalCharacterAlignment.Baseline, "图片", new MemoryStream(onePx).AsRandomAccessStream());
            Line($"0 在空范围 0..0 InsertImage：[{Codes(BareText())}]");
            bd.GetRange(0, 4).GetText(TextGetOptions.None, out var part);
            Line($"0 GetRange(0,4).GetText：[{Codes(part)}]；Selection 现在 {bd.Selection.StartPosition}");
            root.Children.Remove(bare);

            editor.Configure(paper, dark: false, contrast: false, fontSize: 15, markdown: true, NoteSpacing.Standard);

            // 1. Hidden：标记藏着、GetText 带着藏着的字、光标停不停在藏着的字中间
            const string body1 = "# 标题\n**粗体** 和 *斜体*\n普通一行";
            editor.Load(book.Create(now, body1));
            sink.Focus(FocusState.Programmatic);
            await Task.Delay(400);
            var raw1 = Read();
            Line($"1 GetText(None) 带着藏着的字（去掉末尾段落符、\\r 换回 \\n 后和存的一样）：{raw1[..^1].Replace('\r', '\n') == body1}；末尾带段落符：{raw1.EndsWith('\r')}；NoteEditor.Body 和存的一样：{editor.Body == body1}");
            Line($"1 没焦点时「# 」Hidden={doc.GetRange(0, 2).CharacterFormat.Hidden}、「**」Hidden={doc.GetRange(5, 7).CharacterFormat.Hidden}");
            doc.Selection.SetRange(6, 6);
            Line($"1 SetRange(6) 落在藏着的「**」中间 → 读回 {doc.Selection.StartPosition}");
            doc.Selection.SetRange(4, 4);
            doc.Selection.Move(TextRangeUnit.Character, 1);
            Line($"1 从行尾 4 往右挪一个字 → {doc.Selection.StartPosition}（5 = 停在藏着的字前面，7 = 跳过了）");
            editor.Focus();
            await Task.Delay(200);
            doc.Selection.SetRange(9, 9);
            await Task.Delay(400);
            Line($"1 拿着焦点、光标在第二行：「**」Hidden={doc.GetRange(5, 7).CharacterFormat.Hidden}（该 Off）、第一行「# 」Hidden={doc.GetRange(0, 2).CharacterFormat.Hidden}（该 On）");
            await Shoot(window, Path.Combine(directory, "1-hidden-focused.png"));
            sink.Focus(FocusState.Programmatic);
            await Task.Delay(300);
            await Shoot(window, Path.Combine(directory, "1-hidden-unfocused.png"));

            // 2. 字号：TOM 的 Size 是磅、XAML 的 FontSize 是 DIP
            var plain = body1.IndexOf("普通", StringComparison.Ordinal);
            var size = doc.GetRange(plain, plain + 1).CharacterFormat.Size;
            doc.GetRange(plain, plain + 1).GetRect(PointOptions.ClientCoordinates, out var glyph, out _);
            var block = new TextBlock { Text = "普", FontSize = 15 };
            block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Line($"2 正文 15 DIP：Size={size:0.##} 磅（该 11.25）；屏上「普」宽 {glyph.Width:0.#}、高 {glyph.Height:0.#}；同字号 TextBlock 宽 {block.DesiredSize.Width:0.#}、高 {block.DesiredSize.Height:0.#}");

            // 3 / 5. 只改格式时 IsContentChanging；打字时 TextChanging 和 SelectionChanged 谁先来
            var events = new List<string>();
            void OnChanging(RichEditBox _, RichEditBoxTextChangingEventArgs args) => events.Add(args.IsContentChanging ? "TC+" : "TC-");
            void OnSelection(object _, RoutedEventArgs __) => events.Add("SC");
            editor.Box.TextChanging += OnChanging;
            editor.Box.SelectionChanged += OnSelection;
            doc.GetRange(plain, plain + 2).CharacterFormat.Italic = FormatEffect.On;
            await Task.Delay(200);
            Line($"3 只改格式：{(events.Count == 0 ? "没有 TextChanging" : string.Join(" ", events))}（不该有 TC+）");
            events.Clear();
            doc.Selection.SetRange(body1.Length, body1.Length);
            await Task.Delay(100);
            events.Clear();
            doc.Selection.TypeText("x");
            await Task.Delay(400);
            Line($"5 TypeText 的事件顺序：{string.Join(" ", events)}（TC+ 要在 SC 前）；交出去的正文末尾是 x：{editor.Body.EndsWith('x')}（末尾 [{string.Join(" ", editor.Body.TakeLast(3).Select(ch => ((int)ch).ToString("X4")))}]）");
            editor.Box.TextChanging -= OnChanging;
            editor.Box.SelectionChanged -= OnSelection;

            // 4 + 复查 VERIFY 1：占位的 U+FFFC、InsertImage 是替换还是插在前面、选区
            var id = Guid.NewGuid();
            await WritePng(Path.Combine(images, $"{NoteImages.IdText(id)}.png"), 160, 90);
            var token = NoteImages.Token(new NoteImages.Image(id, "png", null));
            var body4 = $"图片前\n{token}\n图片后";
            editor.Load(book.Create(now, body4));
            var placeholder = Read();
            Line($"4 刚放字：U+FFFC 有 {placeholder.Count(ch => ch == ObjectChar)} 个（该 1，被洗成空格就是 0），长度 {placeholder.TrimEnd('\r').Length}（该 9）");
            doc.Selection.SetRange(2, 2);
            await Task.Delay(1200);
            var placed = Read();
            Line($"4 换成图之后：U+FFFC {placed.Count(ch => ch == ObjectChar)} 个、长度 {placed.TrimEnd('\r').Length}（替换 = 9，插在前面 = 10）；选区 {doc.Selection.StartPosition}（该 2）；存的正文和原来一样：{editor.Body == body4}");
            await Shoot(window, Path.Combine(directory, "4-image.png"));

            // 6. DisabledFormattingAccelerators
            Line($"6 DisabledFormattingAccelerators={editor.Box.DisabledFormattingAccelerators}；Ctrl+B / I / U 能不能到 PreviewKeyDown 要真按键，留给手测");

            // 7. GetRangeFromPoint(ClientCoordinates) 的原点：第一个字的框 vs 内边距 (16, 8)
            editor.Load(book.Create(now, "普通的字\n第二行"));
            await Task.Delay(300);
            doc.GetRange(0, 1).GetRect(PointOptions.ClientCoordinates, out var first, out _);
            var hit = doc.GetRangeFromPoint(new Point(first.X + first.Width / 2, first.Y + first.Height / 2), PointOptions.ClientCoordinates);
            var second = doc.GetRangeFromPoint(new Point(16 + 4, 8 + first.Height * 1.5 + 2), PointOptions.ClientCoordinates);
            Line($"7 第一个字的框 ({first.X:0.#}, {first.Y:0.#}) {first.Width:0.#}×{first.Height:0.#}（内边距 16, 8：≈(16, 8) = 相对 RichEditBox，≈(0, 0) = 相对里面的 ScrollViewer）；" +
                 $"点它的中心 → {hit.StartPosition}（该 0）；按相对 RichEditBox 点第二行开头 → {second.StartPosition}（该 5）");

            editor.Load(book.Create(now, string.Join("\n", Enumerable.Range(1, 80).Select(i => $"第 {i} 行"))));
            await Task.Delay(400);
            doc.Selection.SetRange(Read().Length - 1, Read().Length - 1);
            doc.Selection.ScrollIntoView(PointOptions.None);
            await Task.Delay(400);
            var lastStart = Read().TrimEnd('\r').LastIndexOf('第');
            doc.GetRange(lastStart, lastStart + 1).GetRect(PointOptions.ClientCoordinates, out var last, out _);
            var back = doc.GetRangeFromPoint(new Point(last.X + 2, last.Y + last.Height / 2), PointOptions.ClientCoordinates);
            Line($"7 滚到底之后最后一行「第」的框 ({last.X:0.#}, {last.Y:0.#})（在框里 = 相对看得见的那块），点回去 → {back.StartPosition}（该 {lastStart}）");
            if (FindScroller(editor.Box) is { } scroller)
            {
                var at = scroller.TransformToVisual(editor.Box).TransformPoint(new Point(0, 0));
                scroller.ChangeView(null, 0, null, true);
                await Task.Delay(300);
                doc.GetRange(0, 1).GetRect(PointOptions.ClientCoordinates, out var top0, out _);
                scroller.ChangeView(null, 500, null, true);
                await Task.Delay(300);
                doc.GetRange(0, 1).GetRect(PointOptions.ClientCoordinates, out var top500, out _);
                var mid = doc.GetRangeFromPoint(new Point(2, 11), PointOptions.ClientCoordinates);
                // 编辑器自己的换算（OnPointerPressed 用的 TextPoint）：滚了 500 时，相对 RichEditBox 的 (16 + 2, 8 + 11) 是看得见的第一行，
                // 该落在第 500 / 22 ≈ 22 行附近；没滚时同一个点该是 0
                var scrolledHit = doc.GetRangeFromPoint(editor.TextPoint(new Point(16 + 2, 8 + 11)), PointOptions.ClientCoordinates).StartPosition;
                var scrolledLine = Read()[..scrolledHit].Count(ch => ch == '\r') + 1;
                scroller.ChangeView(null, 0, null, true);
                await Task.Delay(300);
                var topHit = doc.GetRangeFromPoint(editor.TextPoint(new Point(16 + 2, 8 + 11)), PointOptions.ClientCoordinates).StartPosition;
                var secondHit = doc.GetRangeFromPoint(editor.TextPoint(new Point(16 + 4, 8 + 22 + 11)), PointOptions.ClientCoordinates).StartPosition;
                Line($"7 换算后（TextPoint）：没滚点第一行开头 → {topHit}（该 0）、第二行开头 → {secondHit}（该 6）；滚 500 后点看得见的第一行 → 第 {scrolledLine} 行（该 ≈ 23）");
                Line($"7 里面的 ScrollViewer：在 RichEditBox 的 ({at.X:0.#}, {at.Y:0.#})、Padding {scroller.Padding}、滚了 {scroller.VerticalOffset:0}；" +
                     $"第一个字的 y：没滚 {top0.Y:0.#}、滚 500 后 {top500.Y:0.#}（−500 = 相对看得见的那块）；滚着时点 (2, 11) → {mid.StartPosition}");
            }
            else
            {
                Line("7 没找到里面的 ScrollViewer");
            }

            // 正文样式的图（第 4 批截图）：标题 / 粗斜体 / 任务五态 / 颜色 / 代码块 / 图片，浅色、深色、增强对比度
            var sample = string.Join("\n",
                "# 周末要做的", "## 买东西", "**粗体**、*斜体*、~~划掉~~、`行内代码`、[红字]{red}、[蓝字]{blue}",
                "☐ 待办", "◧ 进行中", "▣ 紧急", "☑ 做完了", "☒ 不做了", "> 引用一句话", "```", "let x = 1", "```", token, "最后一行");
            foreach (var (name, dark, contrast) in new[] { ("light", false, false), ("dark", true, false), ("contrast", false, true) })
            {
                root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
                root.Background = Paper(paper, dark);
                editor.Configure(paper, dark, contrast, 15, markdown: true, NoteSpacing.Standard);
                editor.Load(book.Create(now, sample));
                sink.Focus(FocusState.Programmatic);
                await Task.Delay(1200);
                await Shoot(window, Path.Combine(directory, $"editor-{name}.png"));
            }

            Line($"日志里的 notes.editor-images-misaligned：去看 Log（自检本身没法读）");
        }
        catch (Exception ex)
        {
            Line($"自检中途出错：{ex.GetType().Name} {ex.Message}");
        }

        await File.WriteAllTextAsync(Path.Combine(directory, "report.md"), report.ToString());
        window.Close();
        Environment.Exit(0);
    }

    private static ScrollViewer? FindScroller(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is ScrollViewer scroller)
            {
                return scroller;
            }

            if (FindScroller(child) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    private static SolidColorBrush Paper(NotePaper paper, bool dark)
    {
        var rgb = paper.Tone(dark).Paper;
        return new SolidColorBrush(Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
    }

    private static async Task Shoot(Window window, string path)
        => await WindowShot.SaveAsync(WinRT.Interop.WindowNative.GetWindowHandle(window), path);

    private static async Task WritePng(string path, int width, int height)
        => await File.WriteAllBytesAsync(path, await PngBytes(width, height));

    private static async Task<byte[]> PngBytes(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var at = (y * width + x) * 4;
                pixels[at] = (byte)(255 * x / width);
                pixels[at + 1] = (byte)(255 * y / height);
                pixels[at + 2] = 200;
                pixels[at + 3] = 255;
            }
        }

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)width, (uint)height, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        var bytes = new byte[stream.Size];
        await stream.AsStreamForRead().ReadExactlyAsync(bytes);
        return bytes;
    }
}
