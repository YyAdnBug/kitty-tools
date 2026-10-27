// PLAN-v7 §2.1：Segoe Fluent Icons 的码点只放这一处，按动作用名字取。
// 同一个动作全 App 用同一个图标（托盘、快捷键页、启动器、截图工具栏、剪贴板操作菜单）。
// 不再拿 ↖ ▭ ✎ ■ 这种 Unicode 字符当图标。
namespace KittyTools;

internal static class Glyphs
{
    public const string Copy = "\uE8C8";
    public const string Paste = "\uE77F";
    public const string Cut = "\uE8C6";
    public const string Delete = "\uE74D";
    public const string Save = "\uE74E";
    public const string Favorite = "\uE734";
    public const string FavoriteFilled = "\uE735";
    public const string Pin = "\uE718";
    public const string Unpin = "\uE77A";
    public const string Settings = "\uE713";
    public const string Search = "\uE721";
    public const string Close = "\uE711";
    public const string Add = "\uE710";
    public const string ChevronDown = "\uE70D";
    public const string ChevronUp = "\uE70E";
    public const string ChevronLeft = "\uE76B";
    public const string ChevronRight = "\uE76C";
    public const string More = "\uE712";
    public const string Undo = "\uE7A7";
    public const string Redo = "\uE7A6";
    public const string Camera = "\uE722";
    // 下面几项对着 mac 的符号挑（HotKeyCenter.symbol）。E7B8 是个收纳盒，以前误当成截图用了。
    /// <summary>剪贴板历史（mac doc.on.clipboard）：剪贴板夹子，和「复制」那两张叠着的纸分开。</summary>
    public const string ClipboardHistory = "\uE77F";
    /// <summary>截图（mac camera.viewfinder）：剪刀 + 虚线框。</summary>
    public const string Screenshot = "\uE924";
    /// <summary>识字（mac text.viewfinder）：一段字。</summary>
    public const string Ocr = "\uF714";
    /// <summary>截图翻译（mac translate）：「A字」。</summary>
    public const string Translate = "\uE8C1";
    public const string ScreenshotTranslate = Translate;
    /// <summary>输入 / 划词翻译（mac character.bubble）：带字的气泡。</summary>
    public const string TextTranslate = "\uE8BD";

    // 截图的标注工具，对着 mac Annotation.Tool.symbol 挑。以前矩形是文档（E7C3）、箭头是 ⇄（E8AB）、
    // 马赛克是任务视图（E7C4）。
    /// <summary>矩形（mac rectangle）：圆角矩形框。</summary>
    public const string ToolRectangle = "\uE7FB";
    /// <summary>箭头（mac arrow.up.right）。</summary>
    public const string ToolArrow = "\uE8AD";
    /// <summary>画笔（mac scribble.variable）：一道涂鸦线。</summary>
    public const string ToolPen = "\uF463";
    /// <summary>文字（mac t.square；Fluent 里没有方框里的 T，用单个「A」）。</summary>
    public const string ToolText = "\uE97E";
    /// <summary>马赛克（mac checkerboard.rectangle）：网格。</summary>
    public const string ToolMosaic = "\uE80A";

    // PLAN-v9 第 5b 批补的五种（mac circle / line.diagonal / highlighter / 1.circle / circle.square.fill）。
    /// <summary>椭圆：空心圆环。</summary>
    public const string ToolEllipse = "\uEA3A";
    /// <summary>直线：Fluent 没有斜线，用横线（E738）转 −45° 画（见 SelectionOverlayWindow.BuildToolbar）。</summary>
    public const string ToolLine = "\uE738";
    /// <summary>荧光笔。</summary>
    public const string ToolHighlighter = "\uE7E6";
    /// <summary>聚光灯：亮度（太阳）。序号没有合适的字形，工具栏上直接画带圈的 1。</summary>
    public const string ToolSpotlight = "\uE706";

    public const string Play = "\uE768";
    public const string Pause = "\uE769";
    public const string Stop = "\uE71A";
    public const string Record = "\uE7C8";
    public const string Microphone = "\uE720";
    public const string Volume = "\uE767";
    public const string Folder = "\uE8B7";
    public const string OpenInNewWindow = "\uE8A7";
    public const string Link = "\uE71B";
    public const string CommandPrompt = "\uE756";
    public const string Globe = "\uE774";
    public const string Calculator = "\uE8EF";
    public const string Clock = "\uE823";
    public const string Info = "\uE946";
    public const string Warning = "\uE7BA";
    public const string Error = "\uEA39";
    public const string Check = "\uE73E";
    public const string App = "\uE71D";
    public const string Process = "\uE9F5";
    public const string Port = "\uE968";
    public const string History = "\uE81C";
    public const string Edit = "\uE70F";
    public const string SaveAs = "\uE792";
    public const string Star = "\uE734";
    public const string Keyboard = "\uE765";
    public const string Palette = "\uE790";
    public const string Language = "\uE8C1";
    public const string Image = "\uEB9F";
    public const string File = "\uE8A5";
    public const string Code = "\uE943";
    public const string Text = "\uE8D2";
    public const string Up = "\uE74A";
    public const string Down = "\uE74B";
    public const string Refresh = "\uE72C";
    public const string Update = "\uE895";
    public const string Shutdown = "\uE7E8";
    public const string Lock = "\uE72E";
    public const string Sleep = "\uE708";
    public const string Recycle = "\uE74D";
}
