// 便签各扇窗的截图自检（PLAN-v13 第 5–7 批，Windows 核验时加的）：`--notes-ui-probe=<目录>`（只在测试档）
// 往这个测试档的便签库里放几条示例便签，依次打开快速记一条、全部便签窗口（便签墙、编辑卡、列表）、裁切对话框、
// 屏幕边缘那叠（药丸、扇出的标签列、预览卡、打开的便签）、浮动便签，每扇用 WindowShot 只抓它自己（WGC）。
// 浅色 / 深色靠 KITTY_APP_THEME=light|dark 各跑一次。不发按键、不点鼠标：那叠用 NoteDeckBay 的方法直接走状态机，
// 跑的时候 NoteDeckBay.ProbeHold 挡住「鼠标不在那叠上就收回」。窗口会拿前台，跑完就退。
using System.Text;
using KittyTools.Core.Notes;
using KittyTools.Infrastructure;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace KittyTools;

internal static class NotesUiProbe
{
    public const string ArgumentPrefix = "--notes-ui-probe";

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
            ? Path.Combine(Path.GetTempPath(), "kitty-notes-ui-probe")
            : Path.GetFullPath(path);
    }

    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var report = new StringBuilder("# 便签窗口截图自检\n\n");
        var theme = Theme.EffectiveTheme == ElementTheme.Dark ? "dark" : "light";
        await Task.Delay(1500);
        try
        {
            if (NoteStore.Instance is not { } store)
            {
                report.Append("- 便签库没开（NoteStore.Instance 是 null）\n");
                return;
            }

            var ids = Seed(store);
            report.Append($"- 示例便签 {ids.Count} 条\n");
            await Task.Delay(800);

            // 快速记一条
            NoteCaptureWindow.Toggle();
            await Task.Delay(900);
            await Shoot(NoteCaptureWindow.ProbeInstance, directory, $"notes-capture-{theme}", report);
            NoteCaptureWindow.HideIfOpen();
            await Task.Delay(300);

            // 全部便签窗口：便签墙、编辑卡、列表
            NotesWindow.ShowWindow();
            await Task.Delay(500);
            if (NotesWindow.ProbeInstance is { } notes)
            {
                notes.AppWindow.MoveAndResize(new RectInt32(40, 40, 1100, 760));
                if (!notes.ProbeWall)
                {
                    notes.ProbeToggleLayout();
                }

                await Task.Delay(1200);
                await Shoot(notes, directory, $"notes-wall-{theme}", report);
                notes.ProbeExpand(ids[2]);
                await Task.Delay(1000);
                await Shoot(notes, directory, $"notes-wall-card-{theme}", report);
                notes.ProbeCollapse();
                notes.ProbeToggleLayout();
                NotesWindow.ShowNote(ids[2]);
                await Task.Delay(1200);
                await Shoot(notes, directory, $"notes-list-{theme}", report);

                // 裁切对话框（第 7 批）：挂在全部便签窗口上，拍完关窗口
                var png = Path.Combine(directory, "crop-source.png");
                await File.WriteAllBytesAsync(png, await Gradient(480, 300));
                if (await NoteImageStore.ReadSizeAsync(png) is { } size && notes.Content?.XamlRoot is { } root)
                {
                    _ = NoteImageCrop.AskAsync(root, await File.ReadAllBytesAsync(png), size);
                    await Task.Delay(1000);
                    await Shoot(notes, directory, $"notes-crop-{theme}", report);
                }

                notes.ProbeToggleLayout();
                notes.Close();
                await Task.Delay(500);
            }
            else
            {
                report.Append("- 全部便签窗口没开出来\n");
            }

            // 屏幕边缘那叠
            NoteDeckBay.ProbeHold = true;
            if (NoteDeck.ProbeBay is { } bay)
            {
                await ShootBay(bay, directory, $"notes-deck-rest-{theme}", report);
                bay.PillEntered(altDown: false);
                await Task.Delay(900);
                await ShootBay(bay, directory, $"notes-deck-fanned-{theme}", report);
                bay.Hover(ids[1], inside: true);
                await Task.Delay(900);
                await ShootBay(bay, directory, $"notes-deck-preview-{theme}", report);
                bay.Hover(ids[1], inside: false);
                bay.TapTab(ids[1]);
                await Task.Delay(1200);
                await ShootBay(bay, directory, $"notes-deck-open-{theme}", report);
                bay.CloseSheet(byKeyboard: true);
                await Task.Delay(600);
            }
            else
            {
                report.Append("- 那叠没建出来（屏幕边缘关着、或者没有显示器）\n");
            }

            NoteDeckBay.ProbeHold = false;

            // 浮动便签
            NoteFloats.Float(ids[3], from: null, dragging: false);
            await Task.Delay(1200);
            var index = 0;
            foreach (var window in NoteFloats.ProbeWindows.ToList())
            {
                await Shoot(window, directory, $"notes-float-{index++}-{theme}", report);
            }

            NoteFloats.Tuck(ids[3]);
        }
        catch (Exception ex)
        {
            report.Append($"- 自检中途出错：{ex.GetType().Name} {ex.Message}\n");
        }
        finally
        {
            NoteDeckBay.ProbeHold = false;
            await File.WriteAllTextAsync(Path.Combine(directory, $"report-{theme}.md"), report.ToString());
            NoteStore.Instance?.Flush();
            Environment.Exit(0);
        }
    }

    /// <summary>放几条示例便签（库里已经有就照用），返回它们的编号。</summary>
    private static List<string> Seed(NoteStore store)
    {
        if (store.Book.Active.Count >= 6)
        {
            return store.Book.Active.Select(note => note.Id).ToList();
        }

        var samples = new (string Title, string Body, int Color, bool Pinned)[]
        {
            ("周末要做的", "# 周末\n☐ 买菜\n◧ 打扫房间\n▣ 交水电费\n☑ 洗车\n☒ 看电影", 0, true),
            ("会议纪要", "**结论**：下周一上线\n- 前端改两处\n- 后端加一个接口\n> 记得同步给测试", 4, true),
            ("读书笔记", "*思考，快与慢*\n系统 1 快、直觉；系统 2 慢、费力。\n[重点]{red}：锚定效应", 3, false),
            ("灵感", "做一个能把剪贴板里的表格直接变成 Markdown 的小工具", 5, false),
            ("代码片段", "```\ngit log --oneline -5\n```\n看最近五条提交", 7, false),
            ("购物清单", "☐ 牛奶\n☐ 面包\n☑ 鸡蛋", 1, false),
            (string.Empty, "没有标题的一条：摘要就是正文的第一行", 2, false),
            ("旅行", "## 行李\n☐ 护照\n☐ 充电器\n☐ 雨伞", 6, false),
        };
        var ids = new List<string>();
        foreach (var (title, body, color, pinned) in samples)
        {
            var note = store.Create(body, title);
            store.SetColor(note.Id, color);
            if (pinned)
            {
                store.SetPinned(note.Id, true);
            }

            ids.Add(note.Id);
        }

        store.Flush();
        return ids;
    }

    private static async Task ShootBay(NoteDeckBay bay, string directory, string name, StringBuilder report)
    {
        foreach (var (part, window) in bay.ProbeWindows().ToList())
        {
            if (window.AppWindow.IsVisible)
            {
                await Shoot(window, directory, $"{name}-{part}", report);
                // PLAN-v16 V1：窗口的实际位置和大小（物理像素）；药丸、标签列不该被系统的最小宽撑大、伸到屏幕外面
                var at = window.AppWindow.Position;
                var size = window.AppWindow.Size;
                var screen = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(window.AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).OuterBounds;
                var inside = at.X >= screen.X && at.Y >= screen.Y &&
                             at.X + size.Width <= screen.X + screen.Width && at.Y + size.Height <= screen.Y + screen.Height;
                // 截图拍的是整扇窗口，伸到屏幕外的那截照样拍得到：只能这样查（2026-11-08 标签列就是这么漏掉的）
                report.Append($"  - {part} 窗口 {at.X},{at.Y} {size.Width} × {size.Height}{(inside ? string.Empty : " **伸到屏幕外**")}\n");
            }
        }
    }

    private static async Task Shoot(Window? window, string directory, string name, StringBuilder report)
    {
        if (window is null)
        {
            report.Append($"- {name}：没有窗口\n");
            return;
        }

        var ok = await WindowShot.SaveAsync(WinRT.Interop.WindowNative.GetWindowHandle(window), Path.Combine(directory, name + ".png"));
        report.Append($"- {name}：{(ok ? "好了" : "没拍到")}\n");
    }

    private static async Task<byte[]> Gradient(int width, int height)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var at = (y * width + x) * 4;
                pixels[at] = (byte)(255 * x / width);
                pixels[at + 1] = (byte)(255 * y / height);
                pixels[at + 2] = 180;
                pixels[at + 3] = 255;
            }
        }

        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            (uint)width, (uint)height, 96, 96, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        var bytes = new byte[stream.Size];
        await System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(stream).ReadExactlyAsync(bytes);
        return bytes;
    }
}
