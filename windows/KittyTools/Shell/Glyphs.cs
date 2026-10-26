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
    // \u4E0B\u9762\u51E0\u9879\u5BF9\u7740 mac \u7684\u7B26\u53F7\u6311\uFF08HotKeyCenter.symbol\uFF09\u3002E7B8 \u662F\u4E2A\u6536\u7EB3\u76D2\uFF0C\u4EE5\u524D\u8BEF\u5F53\u6210\u622A\u56FE\u7528\u4E86\u3002
    /// <summary>\u526A\u8D34\u677F\u5386\u53F2\uFF08mac doc.on.clipboard\uFF09\uFF1A\u526A\u8D34\u677F\u5939\u5B50\uFF0C\u548C\u300C\u590D\u5236\u300D\u90A3\u4E24\u5F20\u53E0\u7740\u7684\u7EB8\u5206\u5F00\u3002</summary>
    public const string ClipboardHistory = "\uE77F";
    /// <summary>\u622A\u56FE\uFF08mac camera.viewfinder\uFF09\uFF1A\u526A\u5200 + \u865A\u7EBF\u6846\u3002</summary>
    public const string Screenshot = "\uE924";
    /// <summary>\u8BC6\u5B57\uFF08mac text.viewfinder\uFF09\uFF1A\u4E00\u6BB5\u5B57\u3002</summary>
    public const string Ocr = "\uF714";
    /// <summary>\u622A\u56FE\u7FFB\u8BD1\uFF08mac translate\uFF09\uFF1A\u300CA\u5B57\u300D\u3002</summary>
    public const string Translate = "\uE8C1";
    public const string ScreenshotTranslate = Translate;
    /// <summary>\u8F93\u5165 / \u5212\u8BCD\u7FFB\u8BD1\uFF08mac character.bubble\uFF09\uFF1A\u5E26\u5B57\u7684\u6C14\u6CE1\u3002</summary>
    public const string TextTranslate = "\uE8BD";
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
