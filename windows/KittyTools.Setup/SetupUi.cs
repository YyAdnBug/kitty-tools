// 安装程序的界面（PLAN-setup S2）：系统的任务对话框（comctl32 v6 的 TaskDialogIndirect），一个窗口里换页
// （TDM_NAVIGATE_PAGE）：安装、进度、完成、出错、卸载确认都是一页；选文件夹用系统的 IFileOpenDialog（CsWin32）。
// 任务对话框不是 COM，结构体照 commctrl.h 手写：pack(1)，两个图标联合体按指针宽度占位；
// 换页时系统还要读页面里的字符串，所以每页的内存都留到对话框关掉再一起放。
// 系统深色模式下任务对话框画成什么样由系统决定，不另外处理（PLAN-setup §5）。
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.System.Com;
using Windows.Win32.UI.Shell;

namespace KittyTools.Setup;

internal enum PageIcon
{
    None,
    Warning,
    Error,
}

/// <summary>任务对话框的一页。</summary>
internal sealed class Page
{
    public required string Instruction { get; init; }

    public string? Content { get; init; }

    public IReadOnlyList<(int Id, string Text)> Buttons { get; init; } = [];

    public int DefaultButton { get; init; }

    /// <summary>左下角的复选框（任务对话框的 verification）；null 就不显示。</summary>
    public string? Checkbox { get; init; }

    public bool Checked { get; init; }

    /// <summary>进度页：显示进度条，按钮全灰，Esc 和右上角都关不掉。</summary>
    public bool Progress { get; init; }

    public PageIcon Icon { get; init; }

    /// <summary>按了按钮（Esc、右上角关闭是 IdCancel），第二个参数是复选框。返回 true 留着对话框（换了页或者要重选），false 关掉。</summary>
    public Func<int, bool, bool>? Clicked { get; init; }

    /// <summary>每 200 ms 左右在界面线程上调一次（进度页靠它看后台做到哪了）。</summary>
    public Action? Tick { get; init; }
}

internal static unsafe partial class SetupUi
{
    public const int IdCancel = 2;

    private const string Title = "Kitty Tools";

    // TASKDIALOG_FLAGS
    private const int AllowDialogCancellation = 0x0008;
    private const int VerificationFlagChecked = 0x0100;
    private const int ShowProgressBar = 0x0200;
    private const int CallbackTimer = 0x0800;

    // TASKDIALOG_NOTIFICATIONS
    private const uint Created = 0;
    private const uint Navigated = 1;
    private const uint ButtonClicked = 2;
    private const uint Timer = 4;
    private const uint Destroyed = 5;
    private const uint VerificationClicked = 8;

    // TASKDIALOG_MESSAGES（WM_USER + n）
    private const uint NavigatePage = 0x0400 + 101;
    private const uint SetProgressBarPos = 0x0400 + 106;
    private const uint EnableButton = 0x0400 + 111;

    // TD_WARNING_ICON / TD_ERROR_ICON：MAKEINTRESOURCEW(-1) / (-2)
    private const nint WarningIcon = 0xFFFF;
    private const nint ErrorIcon = 0xFFFE;

    private const int OkButtonFlag = 0x0001;
    private const int Cancelled = unchecked((int)0x800704C7);

    private static readonly Guid FileOpenDialogClsid = new("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7");

    private static readonly delegate* unmanaged[Stdcall]<nint, uint, nint, nint, nint, int> CallbackPointer = &Callback;

    private static readonly List<nint> Allocations = [];
    private static Page? _page;
    private static bool _checked;
    private static nint _hwnd;

    /// <summary>显示对话框，直到某一页的 Clicked 返回 false。对话框起不来（comctl32 v6 没生效等）返回 false。</summary>
    public static bool Run(Page first)
    {
        _page = first;
        _checked = first.Checked;
        try
        {
            // 按了哪个按钮、复选框勾没勾都在回调里记，这里三个出参都不要。
            var result = TaskDialogIndirect(Build(first), null, null, null);
            if (result < 0)
            {
                SetupLog.Write($"ui.taskdialog 0x{result:X8}");
                return false;
            }

            return true;
        }
        catch (EntryPointNotFoundException)
        {
            SetupLog.Write("ui.taskdialog missing (comctl32 v6)");
            return false;
        }
        finally
        {
            foreach (var memory in Allocations)
            {
                NativeMemory.Free((void*)memory);
            }

            Allocations.Clear();
            _page = null;
            _hwnd = 0;
        }
    }

    /// <summary>出错时单独弹一页（还没有对话框的时候用）。</summary>
    public static void ShowError(string instruction, string content)
        => Run(new Page
        {
            Instruction = instruction,
            Content = content,
            Icon = PageIcon.Error,
            Buttons = [(IdCancel, "关闭")],
            Clicked = (_, _) => false,
        });

    /// <summary>换页。只能在 Clicked / Tick 里调（也就是对话框开着、在界面线程上）。</summary>
    public static void Navigate(Page page)
    {
        _page = page;
        _checked = page.Checked;
        SendMessage(_hwnd, NavigatePage, 0, (nint)Build(page));
    }

    public static void SetProgress(int percent) => SendMessage(_hwnd, SetProgressBarPos, Math.Clamp(percent, 0, 100), 0);

    /// <summary>叠在当前对话框上的一句提示（比如选的位置不能用），点「确定」回到原来那页。</summary>
    public static void Warn(string instruction, string content)
    {
        try
        {
            _ = TaskDialog(_hwnd, 0, Title, instruction, content, OkButtonFlag, WarningIcon, out _);
        }
        catch (EntryPointNotFoundException)
        {
            SetupLog.Write("ui.warn missing (comctl32 v6)");
        }
    }

    /// <summary>系统的选文件夹框，挂在当前对话框上；取消或出错返回 null。start 存在的话打开时停在那里。</summary>
    public static string? PickFolder(string? start)
    {
        IFileOpenDialog* dialog = null;
        var clsid = FileOpenDialogClsid;
        var iid = typeof(IFileOpenDialog).GUID;
        var created = PInvoke.CoCreateInstance(&clsid, null, CLSCTX.CLSCTX_INPROC_SERVER, &iid, (void**)&dialog);
        if (created.Failed || dialog is null)
        {
            SetupLog.Write($"ui.picker-create 0x{created.Value:X8}");
            return null;
        }

        try
        {
            dialog->SetOptions(
                FILEOPENDIALOGOPTIONS.FOS_PICKFOLDERS | FILEOPENDIALOGOPTIONS.FOS_FORCEFILESYSTEM |
                FILEOPENDIALOGOPTIONS.FOS_PATHMUSTEXIST);
            fixed (char* title = "选择安装位置")
            fixed (char* ok = "选这个文件夹")
            {
                dialog->SetTitle(new PCWSTR(title));
                dialog->SetOkButtonLabel(new PCWSTR(ok));
            }

            if (start is not null && Directory.Exists(start))
            {
                IShellItem* folder = null;
                var itemIid = typeof(IShellItem).GUID;
                fixed (char* path = start)
                {
                    if (PInvoke.SHCreateItemFromParsingName(new PCWSTR(path), null, &itemIid, (void**)&folder).Succeeded &&
                        folder is not null)
                    {
                        dialog->SetFolder(folder);
                        folder->Release();
                    }
                }
            }

            var shown = dialog->Show((HWND)_hwnd);
            if (shown.Failed)
            {
                if (shown.Value != Cancelled)
                {
                    SetupLog.Write($"ui.picker-show 0x{shown.Value:X8}");
                }

                return null;
            }

            IShellItem* result = null;
            if (dialog->GetResult(&result).Failed || result is null)
            {
                return null;
            }

            try
            {
                PWSTR name;
                if (result->GetDisplayName(SIGDN.SIGDN_FILESYSPATH, &name).Failed)
                {
                    return null;
                }

                try
                {
                    return name.ToString();
                }
                finally
                {
                    PInvoke.CoTaskMemFree(name.Value);
                }
            }
            finally
            {
                result->Release();
            }
        }
        finally
        {
            dialog->Release();
        }
    }

    private static TaskDialogConfig* Build(Page page)
    {
        IReadOnlyList<(int Id, string Text)> buttons = page.Buttons.Count > 0 ? page.Buttons : [(IdCancel, "关闭")];
        var array = (TaskDialogButton*)Allocate(sizeof(TaskDialogButton) * buttons.Count);
        for (var index = 0; index < buttons.Count; index++)
        {
            array[index].ButtonId = buttons[index].Id;
            array[index].ButtonText = Text(buttons[index].Text);
        }

        var config = (TaskDialogConfig*)Allocate(sizeof(TaskDialogConfig));
        config->Size = (uint)sizeof(TaskDialogConfig);
        config->Flags = CallbackTimer |
                        (page.Progress ? ShowProgressBar : AllowDialogCancellation) |
                        (page.Checked ? VerificationFlagChecked : 0);
        config->WindowTitle = Text(Title);
        config->MainIcon = page.Icon switch
        {
            PageIcon.Warning => WarningIcon,
            PageIcon.Error => ErrorIcon,
            _ => 0,
        };
        config->MainInstruction = Text(page.Instruction);
        config->Content = Text(page.Content);
        config->ButtonCount = (uint)buttons.Count;
        config->Buttons = array;
        config->DefaultButton = page.DefaultButton;
        config->VerificationText = Text(page.Checkbox);
        config->Callback = CallbackPointer;
        return config;
    }

    /// <summary>清零的一块内存，对话框关掉时统一释放。</summary>
    private static void* Allocate(int bytes)
    {
        var memory = NativeMemory.AllocZeroed((nuint)bytes);
        Allocations.Add((nint)memory);
        return memory;
    }

    private static char* Text(string? text)
    {
        if (text is null)
        {
            return null;
        }

        var memory = (char*)Allocate((text.Length + 1) * sizeof(char));
        text.AsSpan().CopyTo(new Span<char>(memory, text.Length));
        return memory; // 最后一个字符已经是清零的 \0
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static int Callback(nint hwnd, uint notification, nint wParam, nint lParam, nint data)
    {
        const int Close = 0; // S_OK：按钮照常关掉对话框
        const int Stay = 1; // S_FALSE：不关
        try
        {
            var page = _page;
            switch (notification)
            {
                case Created:
                case Navigated:
                    _hwnd = hwnd;
                    if (page is { Progress: true })
                    {
                        foreach (var (id, _) in page.Buttons)
                        {
                            SendMessage(hwnd, EnableButton, id, 0);
                        }
                    }

                    break;
                case ButtonClicked:
                    if (page is null)
                    {
                        return Close;
                    }

                    if (page.Progress)
                    {
                        return Stay;
                    }

                    return page.Clicked is { } clicked && clicked((int)wParam, _checked) ? Stay : Close;
                case VerificationClicked:
                    _checked = wParam != 0;
                    break;
                case Timer:
                    page?.Tick?.Invoke();
                    break;
                case Destroyed:
                    _hwnd = 0;
                    break;
            }
        }
        catch (Exception ex)
        {
            SetupLog.Write($"ui.callback {ex.GetType().Name} {ex.Message}");
        }

        return Close;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TaskDialogButton
    {
        public int ButtonId;
        public char* ButtonText;
    }

    /// <summary>TASKDIALOGCONFIG（commctrl.h 里在 pshpack1 里面）：64 位下 160 字节。</summary>
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TaskDialogConfig
    {
        public uint Size;
        public nint Parent;
        public nint Instance;
        public int Flags;
        public int CommonButtons;
        public char* WindowTitle;
        public nint MainIcon; // 联合体 hMainIcon / pszMainIcon
        public char* MainInstruction;
        public char* Content;
        public uint ButtonCount;
        public TaskDialogButton* Buttons;
        public int DefaultButton;
        public uint RadioButtonCount;
        public TaskDialogButton* RadioButtons;
        public int DefaultRadioButton;
        public char* VerificationText;
        public char* ExpandedInformation;
        public char* ExpandedControlText;
        public char* CollapsedControlText;
        public nint FooterIcon; // 联合体 hFooterIcon / pszFooterIcon
        public char* Footer;
        public delegate* unmanaged[Stdcall]<nint, uint, nint, nint, nint, int> Callback;
        public nint CallbackData;
        public uint Width;
    }

    [LibraryImport("comctl32.dll", EntryPoint = "TaskDialogIndirect")]
    private static partial int TaskDialogIndirect(TaskDialogConfig* config, int* button, int* radioButton, int* verificationChecked);

    [LibraryImport("comctl32.dll", EntryPoint = "TaskDialog", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int TaskDialog(
        nint owner, nint instance, string title, string instruction, string content, int commonButtons, nint icon, out int button);

    [LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    private static partial nint SendMessage(nint hwnd, uint message, nint wParam, nint lParam);
}
