// 剪贴板采集：收到 WM_CLIPBOARDUPDATE 后按 PLAN §6.1 的顺序判断
// （自家写入 → 隐私格式 → 来源 → 排除的应用 → 内容），再交给 ClipboardStore。
// 图片解码放后台，结果回 UI 线程再入库（库和列表只在 UI 线程用）。
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Win32;

namespace KittyTools;

internal sealed class ClipboardService
{
    private Database? _database;
    private long _ownSequence;
    private bool _selectionPaused;

    public static ClipboardService? Instance { get; private set; }

    public ClipboardStore Store { get; private set; } = null!;

    public Database Database => _database!;

    /// <summary>用户在托盘菜单暂停记录：不存盘，重启后恢复记录。</summary>
    public bool Paused { get; set; }

    /// <summary>新文本入库后回调（复制即译在第 3 批接上）。</summary>
    public event Action<string>? TextCopied;

    public static ClipboardService Start(Database database, ImageStore images)
    {
        var service = new ClipboardService
        {
            _database = database,
            Store = new ClipboardStore(database, images),
        };
        service.Store.Load();
        service.Store.EnforceLimits();
        service._ownSequence = PInvoke.GetClipboardSequenceNumber();
        Instance = service;
        Log.Info($"clipboard.ready items={service.Store.Count}");
        return service;
    }

    public void OnClipboardUpdate()
    {
        if (Paused || _selectionPaused)
        {
            return;
        }

        var sequence = PInvoke.GetClipboardSequenceNumber();
        if (sequence == _ownSequence)
        {
            return;
        }

        if (ClipboardFormats.IsPrivate())
        {
            Log.Info("clipboard.skip-private");
            return;
        }

        var (exe, name, pid) = ClipboardFormats.Source();
        if (IsExcluded(exe))
        {
            Log.Info("clipboard.skip-excluded");
            return;
        }

        var read = ClipboardFormats.Read();
        if (read is null)
        {
            return;
        }

        var ownWindow = pid == (uint)Environment.ProcessId;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        switch (read.Kind)
        {
            case ClipKind.Text:
                var text = read.Text ?? string.Empty;
                if (SettingsService.Current.ClipboardBlockSensitive && SensitiveText.LooksSensitive(text))
                {
                    Log.Info("clipboard.skip-sensitive");
                    return;
                }

                Store.Record(new ClipEntry
                {
                    Kind = ClipKind.Text,
                    Text = text,
                    SourceExe = exe,
                    SourceName = name,
                    CopiedAt = now,
                }, read.Html, read.Rtf);
                Log.Info($"clipboard.record kind=text count={Store.Count}");
                if (!ownWindow)
                {
                    TextCopied?.Invoke(text);
                }

                break;
            case ClipKind.Files:
                Store.Record(new ClipEntry
                {
                    Kind = ClipKind.Files,
                    FilePaths = read.FilePaths,
                    SourceExe = exe,
                    SourceName = name,
                    CopiedAt = now,
                });
                Log.Info($"clipboard.record kind=files count={Store.Count}");
                break;
            case ClipKind.Image when read.ImageData is not null:
                _ = SaveImageAsync(read, exe, name);
                break;
        }
    }

    /// <summary>本 App 刚写进剪贴板：监听收到同一个序号就跳过。</summary>
    public void MarkOwnWrite() => _ownSequence = PInvoke.GetClipboardSequenceNumber();

    /// <summary>划词取词期间暂停（那次 Ctrl+C 和还原都不是用户的复制）。</summary>
    public void PauseForSelection() => _selectionPaused = true;

    public void ResumeAfterSelection()
    {
        _selectionPaused = false;
        _ownSequence = PInvoke.GetClipboardSequenceNumber();
    }

    public int EnforceLimits() => Store.EnforceLimits();

    public void CommitDeletion() => Store.CommitDeletion();

    public bool IsExcluded(string? exePath)
        => ClipboardSourceRules.IsExcluded(exePath, SettingsService.Current.ClipboardExcludedApps);

    private async Task SaveImageAsync(ClipboardRead read, string? exe, string? name)
    {
        var data = read.ImageData!;
        var png = read.ImageIsPng;
        var decoded = await Task.Run(async () =>
            png ? await ImageCodec.ReadPngAsync(data) : await ImageCodec.DibToPngAsync(data));
        if (decoded is not { } image)
        {
            Log.Warn("clipboard.image-decode-failed");
            return;
        }

        Store.RecordImage(image.Png, image.Width, image.Height, exe, name);
        Log.Info($"clipboard.record kind=image count={Store.Count}");
    }
}
