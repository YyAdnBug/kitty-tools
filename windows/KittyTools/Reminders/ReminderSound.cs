// 提醒的提示音（PLAN-v16 E2，mac Reminders/ReminderSound.swift）：系统的（%WINDIR%\Media 里那几个，Reminders.WindowsChimes）｜ 自己选过的文件。
// 编号：系统的是 mac 的声音名（两边认得），自己选的是「file:文件名」——选的时候拷一份进数据目录的 reminder-sounds\（20 MB 以内、放得出来才收；
// 同名同内容用已有的，同名不同内容加数字）。编号跟着提醒导出、同步，文件不跟：别的电脑上没有时放默认的、详情页说一句。编号按不可信输入认
// （Reminders.ChimeFileName 只认一段文件名），绝不拼出目录外的路径。自己选的文件最多放 30 秒，只在「知道了」「稍后」、关掉功能、开始录屏 /
// 录音时停；试听在关掉编辑框时停。没有提醒在用的文件在提醒开始运行时清掉。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace KittyTools;

internal static partial class ReminderSound
{
    private static MediaPlayer? _player;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _cutoff;
    private static bool _previewing;

    public static string Folder => Path.Combine(Paths.DataDirectory, Reminders.ChimeFolder);

    /// <summary>这台电脑上有没有这个声音（系统的都有；自己选的看文件在不在）。</summary>
    public static bool Exists(string id)
        => Reminders.ChimeFileName(id) is { } name ? File.Exists(Path.Combine(Folder, name)) : Reminders.WindowsChimes.Any(chime => chime.Name == id);

    /// <summary>自己选过的文件（编号，按菜单里的叫法排：「下课铃」在「下课铃 2」前面）。编辑框打开时读一次。</summary>
    public static List<string> Files()
    {
        try
        {
            if (!Directory.Exists(Folder))
            {
                return new List<string>();
            }

            return Directory.EnumerateFiles(Folder)
                .Select(path => Reminders.ChimeFilePrefix + Path.GetFileName(path))
                .Where(id => Reminders.ChimeFileName(id) is not null)
                .OrderBy(id => Path.GetFileNameWithoutExtension(id), StringComparer.CurrentCulture)
                .ThenBy(id => id, StringComparer.Ordinal)
                .ToList();
        }
        catch (Exception ex)
        {
            Log.Warn($"reminder.sound-list-failed {ex.GetType().Name}");
            return new List<string>();
        }
    }

    /// <summary>选的文件拷进 reminder-sounds\，返回编号；失败抛 InvalidOperationException（消息给用户看）。</summary>
    public static async Task<string> ImportAsync(string source)
    {
        var info = new FileInfo(source);
        if (!info.Exists || info.Length == 0)
        {
            throw new InvalidOperationException("放不了这个文件，换一个 mp3、m4a、wav 或 aiff");
        }

        if (info.Length > Reminders.MaxChimeBytes)
        {
            throw new InvalidOperationException("文件太大，选一个 20 MB 以内的短音频");
        }

        var extension = info.Extension.TrimStart('.').ToLowerInvariant();
        if (!Reminders.ChimeFileExtensions.Contains(extension) || !await CanPlayAsync(source))
        {
            throw new InvalidOperationException("放不了这个文件，换一个 mp3、m4a、wav 或 aiff");
        }

        try
        {
            Directory.CreateDirectory(Folder);
            var stem = Reminders.ChimeStem(Path.GetFileNameWithoutExtension(source));
            for (var index = 1; index <= 99; index++)
            {
                var name = Reminders.ChimeCandidate(stem, extension, index);
                var target = Path.Combine(Folder, name);
                if (File.Exists(target))
                {
                    // 同名：内容一样就用它（盘不分大小写，编号用盘上真实的名字），不一样接着试下一个名字
                    if (SameContent(target, source))
                    {
                        return Reminders.ChimeFilePrefix + Path.GetFileName(Directory.GetFiles(Folder, name).FirstOrDefault() ?? target);
                    }

                    continue;
                }

                File.Copy(source, target);
                return Reminders.ChimeFilePrefix + name;
            }
        }
        catch (Exception ex) when (ex is not InvalidOperationException)
        {
            Log.Warn($"reminder.sound-import-failed {ex.GetType().Name}");
        }

        throw new InvalidOperationException("没能存下这个文件");
    }

    private static bool SameContent(string a, string b)
    {
        var first = new FileInfo(a);
        var second = new FileInfo(b);
        if (first.Length != second.Length)
        {
            return false;
        }

        return File.ReadAllBytes(a).AsSpan().SequenceEqual(File.ReadAllBytes(b));
    }

    /// <summary>放得出来才收：媒体播放器打开得了（3 秒内）。</summary>
    private static async Task<bool> CanPlayAsync(string path)
    {
        var player = new MediaPlayer { AutoPlay = false, IsMuted = true };
        var done = new TaskCompletionSource<bool>();
        player.MediaOpened += (_, _) => done.TrySetResult(true);
        player.MediaFailed += (_, _) => done.TrySetResult(false);
        try
        {
            player.Source = MediaSource.CreateFromUri(new Uri(path));
            var winner = await Task.WhenAny(done.Task, Task.Delay(3000));
            return winner == done.Task && done.Task.Result;
        }
        catch
        {
            return false;
        }
        finally
        {
            player.Dispose();
        }
    }

    /// <summary>清掉没有提醒在用的文件（提醒开始运行时）：换了声音、删了提醒留下的拷贝。</summary>
    public static void Purge(IEnumerable<string> keeping)
    {
        try
        {
            if (!Directory.Exists(Folder))
            {
                return;
            }

            var used = keeping.Select(Reminders.ChimeFileName).Where(name => name is not null).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var path in Directory.EnumerateFiles(Folder))
            {
                if (!used.Contains(Path.GetFileName(path)))
                {
                    File.Delete(path);
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"reminder.sound-purge-failed {ex.GetType().Name}");
        }
    }

    /// <summary>放一声（换掉正在放的）：自己选的文件放它（最多 30 秒），系统的放 %WINDIR%\Media 里那个，都没有放系统的通知声。</summary>
    public static void Play(string id, bool preview = false)
    {
        Stop();
        if (Reminders.ChimeFileName(id) is { } name && File.Exists(Path.Combine(Folder, name)))
        {
            try
            {
                _player ??= new MediaPlayer();
                _player.Source = MediaSource.CreateFromUri(new Uri(Path.Combine(Folder, name)));
                _player.Play();
                _previewing = preview;
                var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
                if (queue is not null)
                {
                    _cutoff ??= queue.CreateTimer();
                    _cutoff.Interval = TimeSpan.FromSeconds(Reminders.MaxChimeSeconds);
                    _cutoff.IsRepeating = false;
                    _cutoff.Tick -= OnCutoff;
                    _cutoff.Tick += OnCutoff;
                    _cutoff.Start();
                }

                return;
            }
            catch (Exception ex)
            {
                Log.Warn($"reminder.sound-play-failed {ex.GetType().Name}");
            }
        }

        PlaySystem(id);
    }

    private static void OnCutoff(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => Stop();

    /// <summary>停下（「知道了」「稍后」、关掉功能、开始录屏 / 录音）。</summary>
    public static void Stop()
    {
        _cutoff?.Stop();
        _previewing = false;
        try
        {
            if (_player is not null)
            {
                _player.Pause();
                _player.Source = null;
            }
        }
        catch
        {
            // 已经停掉的跳过。
        }
    }

    /// <summary>自检用：自己选的文件这会儿在放。</summary>
    internal static bool IsPlayingForProbe => _player?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;

    /// <summary>编辑框关掉：只停试听。</summary>
    public static void StopPreview()
    {
        if (_previewing)
        {
            Stop();
        }
    }

    private static void PlaySystem(string name)
    {
        const uint flags = 0x0001 /* SND_ASYNC */ | 0x0002 /* SND_NODEFAULT */;
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", Reminders.ChimeFile(name));
        if (!File.Exists(path) || !PlaySound(path, IntPtr.Zero, 0x00020000 /* SND_FILENAME */ | flags))
        {
            PlaySound("SystemNotification", IntPtr.Zero, 0x00010000 /* SND_ALIAS */ | flags);
        }
    }

    [LibraryImport("winmm.dll", EntryPoint = "PlaySoundW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PlaySound(string? sound, IntPtr module, uint flags);
}
