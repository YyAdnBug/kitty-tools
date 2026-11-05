// 提醒的执行层（PLAN-v12 N6，照 mac Reminders/ReminderCenter.swift）：只挂一个计时器，指向最近要响的那一刻；醒来、解锁、改系统时间、
// 列表变了、退出状态屏时重新看一遍（Core 的 ReminderCheck.Check）。到点的挂在屏幕底部的提示上直到处理（NoticeHost.Pin），
// 几条同时到点合成一条，错过的（晚了超过 5 分钟：睡着、锁着屏、App 没开）合成一条「错过了 N 个提醒」。
// 「知道了」（或提示上的 ×）：一次的从列表里删掉，间隔的从这一刻重新数；「稍后」推 N 分钟（设置 › 提醒）。
// 间隔提醒碰上锁屏、醒来、5 分钟没碰键盘鼠标，算休息过了，回来重新数：有开着的间隔提醒时每分钟看一眼空闲了多久，没有就不看。
// 方式：几条一起到点时按最显眼的那条（状态屏 > 全屏 > 边框 > 轻提醒）；轻提醒挂在提示上，边框 = 四边的光 + 提示，全屏 = ReminderScreen，
// 进入状态屏 = 到点直接进那个状态、算处理了（进不去时退成全屏、写原因）。正在录屏、录音时全都降成轻提醒、也不出声；
// 在状态屏里、锁着屏、暂停着时一条都不响，退出 / 解锁 / 到时间后再看。
// 声音：提示音（Windows 的通知声；mac 的 14 种提示音名照存）或朗读标题，只响一声。催促：挂着没理的，每隔 N 分钟再响一声、提示晃一下，
// 第 3 次换成全屏，之后不再催。
// 状态（每条处理到哪一刻、推到几点、暂停到几点）存在 Settings.RemindersState：这台电脑自己的，不导出、不同步；间隔的锚点只在内存里。
// 起停跟着功能开关（ShellRuntime.ApplyFeatures）；关掉时挂着的收掉，数据和状态不动。
// ponytail: 已经出来的边框 / 全屏，之后才开始录屏的不收（会录进去）；要的话在录屏开始时调一次 Present。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static partial class ReminderCenter
{
    /// <summary>多久没碰键盘鼠标算离开了。</summary>
    private const double AwaySeconds = 5 * 60;

    private static bool _running;
    private static List<Reminder> _list = new();
    private static string _signature = string.Empty;
    private static ReminderState _state = new();
    private static readonly Dictionary<string, DateTime> Anchors = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, ReminderSchedule> AnchorRules = new(StringComparer.Ordinal);
    private static readonly List<string> Firing = new();
    private static readonly List<string> Missed = new();
    private static string _mode = Reminder.Light;
    private static string? _note;
    private static int _nags;
    private static bool _locked;
    private static bool _away;
    private static DispatcherQueueTimer? _wake;
    private static DispatcherQueueTimer? _idlePoll;
    private static DispatcherQueueTimer? _nagTimer;

    private static TimeZoneInfo Zone => TimeZoneInfo.Local;

    private static int SnoozeMinutes
        => Reminders.SnoozeChoices.Contains(SettingsService.Current.RemindersSnoozeMinutes)
            ? SettingsService.Current.RemindersSnoozeMinutes
            : Reminders.SnoozeChoices[0];

    private static bool IsRecording => RecordingHost.IsRecording || AudioHost.IsRecording;

    /// <summary>设置里的列表（收拾过；没存过是示例）。</summary>
    public static List<Reminder> List => Reminders.Load(SettingsService.Current.Reminders);

    public static void Start()
    {
        if (_running)
        {
            return;
        }

        _running = true;
        _list = List;
        _signature = Signature(SettingsService.Current.Reminders);
        _state = SettingsService.Current.RemindersState?.Copy() ?? new ReminderState();
        SettingsService.Changed += OnSettingsChanged;
        StatusScreenHost.Exited += Recheck;
        RestartIntervals(DateTime.UtcNow);
        Reconcile();
        Check();
        Log.Info($"reminder.start count={_list.Count} on={_list.Count(reminder => reminder.IsOn)}");
    }

    /// <summary>功能关掉：计时、监听都停，挂着的收掉；状态留着，打开后接着算（错过的照样告诉你）。</summary>
    public static void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        SettingsService.Changed -= OnSettingsChanged;
        StatusScreenHost.Exited -= Recheck;
        _wake?.Stop();
        _idlePoll?.Stop();
        _idlePoll = null;
        if (Firing.Count > 0 || Missed.Count > 0)
        {
            NoticeHost.Unpin();
        }

        HideSurfaces();
        Firing.Clear();
        Missed.Clear();
        Anchors.Clear();
        AnchorRules.Clear();
        _locked = false;
        _away = false;
    }

    // ---- 外面调的

    /// <summary>状态屏退出后：在里面时收着的再摆出来（Present 在状态屏里不摆），在里面时到点的这会儿再看。</summary>
    public static void Recheck()
    {
        if (_running && (Firing.Count > 0 || Missed.Count > 0))
        {
            Present();
        }

        Check();
    }

    /// <summary>暂停全部提醒到 untilUtc（托盘，null = 恢复）：这期间一条都不响，之后晚了 5 分钟以内照常响、更晚的合成「错过了」。</summary>
    public static void Pause(DateTime? untilUtc)
    {
        if (!_running)
        {
            return;
        }

        _state.PausedUntil = untilUtc is { } until ? ReminderTime.FromUtc(until) : null;
        SaveState();
        Check();
    }

    /// <summary>暂停到几点（还在暂停才有，UTC）。</summary>
    public static DateTime? PausedUntil
        => _state.PausedUntil is { } paused && ReminderTime.ToUtc(paused) > DateTime.UtcNow ? ReminderTime.ToUtc(paused) : null;

    /// <summary>下一条要响的是哪条、几点（托盘「下一个」）；正挂着的不算。</summary>
    public static (Reminder Reminder, DateTime At)? NextUp()
    {
        var now = DateTime.UtcNow;
        var showing = Firing.Concat(Missed).ToHashSet(StringComparer.Ordinal);
        return _list.Where(reminder => reminder.IsOn && !showing.Contains(reminder.Id))
            .Select(reminder => (Reminder: reminder, At: ReminderCheck.Due(reminder, _state, Anchors, Zone)))
            .Where(item => item.At is { } at && at > now)
            .OrderBy(item => item.At)
            .Select(item => ((Reminder Reminder, DateTime At)?)(item.Reminder, item.At!.Value))
            .FirstOrDefault();
    }

    /// <summary>加一条（启动器一句话建、托盘「N 分钟后提醒我」）：存进设置，执行层看着设置变化自己跟上。</summary>
    public static void Add(Reminder reminder)
    {
        var settings = SettingsService.Current;
        settings.Reminders = Reminders.Adding(reminder, Reminders.Load(settings.Reminders));
        SettingsService.Save();
        Log.Info($"reminder.added kind={reminder.Schedule.Kind}");
    }

    /// <summary>锁屏（WTS_SESSION_LOCK）：一条都不响，解锁后再看。</summary>
    public static void Locked() => _locked = true;

    /// <summary>解锁：间隔提醒算休息过了；锁着时到点的这会儿再看（晚了 5 分钟以内照常响）。</summary>
    public static void Unlocked()
    {
        _locked = false;
        _away = false;
        if (_running)
        {
            RestartIntervals(DateTime.UtcNow);
            Check();
        }
    }

    /// <summary>
    /// 醒来（PBT_APMRESUMESUSPEND）：间隔提醒算休息过了，再看一遍；锁没锁不碰（同 mac didWake 只清 isAway）——设了醒来要登录的，
    /// 睡前就锁了，醒来时锁屏界面还在，清掉的话提示音在锁屏上响、全屏倒数到 0 没人看见就把一次性的删了。解锁时（WTS 8）再清。
    /// </summary>
    public static void Resumed()
    {
        _away = false;
        if (_running)
        {
            RestartIntervals(DateTime.UtcNow);
            Check();
        }
    }

    /// <summary>系统时间改了、换了时区（WM_TIMECHANGE）：记在「将来」的时刻收回来，不然要等真实时间追上才响。</summary>
    public static void ClockChanged()
    {
        TimeZoneInfo.ClearCachedData();
        if (!_running)
        {
            return;
        }

        var pulled = _state.PulledBack(DateTime.UtcNow, Reminders.SnoozeChoices[^1] * 60);
        if (!pulled.SameAs(_state))
        {
            _state = pulled;
            SaveState();
        }

        Check();
    }

    // ---- 列表变了

    private static string Signature(IEnumerable<Reminder>? stored)
        => stored is null ? "\u0000" : string.Join('\u0001', Reminders.Sanitized(stored).Select(Reminders.Canonical));

    private static void OnSettingsChanged()
    {
        if (!_running)
        {
            return;
        }

        var signature = Signature(SettingsService.Current.Reminders);
        if (signature == _signature)
        {
            return;
        }

        _signature = signature;
        var old = _list;
        _list = List;
        // 删掉的、关掉的、改了时间的不再挂着（改了时间的按新时间再算）；还在的换上新标题。
        var before = (Firing.ToList(), Missed.ToList());
        var on = _list.Where(reminder => reminder.IsOn).Select(reminder => reminder.Id).ToHashSet(StringComparer.Ordinal);
        on.ExceptWith(ReminderCheck.Rescheduled(old, _list));
        Firing.RemoveAll(id => !on.Contains(id));
        Missed.RemoveAll(id => !on.Contains(id));
        Reconcile();
        if (!Firing.SequenceEqual(before.Item1) || !Missed.SequenceEqual(before.Item2) || Firing.Count > 0 || Missed.Count > 0)
        {
            Present();
        }

        Check();
    }

    /// <summary>状态跟上列表：每周 / 每月的处理记录、间隔的锚点（新开的、改了规则的从现在数）；空闲检查按有没有间隔提醒起停。</summary>
    private static void Reconcile()
    {
        var now = DateTime.UtcNow;
        var next = ReminderCheck.Reconciled(_state, _list, now);
        if (!next.SameAs(_state))
        {
            _state = next;
            SaveState();
        }

        var intervals = _list.Where(reminder => reminder.IsOn && reminder.Schedule.Kind == ReminderSchedule.Interval).ToList();
        var anchors = new Dictionary<string, DateTime>(StringComparer.Ordinal);
        var rules = new Dictionary<string, ReminderSchedule>(StringComparer.Ordinal);
        foreach (var reminder in intervals)
        {
            rules[reminder.Id] = reminder.Schedule.Copy();
            var same = AnchorRules.TryGetValue(reminder.Id, out var rule) && rule.SameAs(reminder.Schedule);
            // 正挂着的没有锚点（处理了才从那一刻数），规则没变就别给它补一个。
            if (same && (Firing.Contains(reminder.Id) || Missed.Contains(reminder.Id)))
            {
                continue;
            }

            anchors[reminder.Id] = same && Anchors.TryGetValue(reminder.Id, out var anchor) ? anchor : now;
        }

        Anchors.Clear();
        foreach (var (id, anchor) in anchors)
        {
            Anchors[id] = anchor;
        }

        AnchorRules.Clear();
        foreach (var (id, rule) in rules)
        {
            AnchorRules[id] = rule;
        }

        WatchIdle(intervals.Count > 0);
    }

    /// <summary>间隔提醒都从 at 重新数（启动、醒来、解锁、离开电脑回来），推过的也作废；正挂着的不动。</summary>
    private static void RestartIntervals(DateTime at)
    {
        var cleared = false;
        foreach (var reminder in _list.Where(reminder => reminder.IsOn && reminder.Schedule.Kind == ReminderSchedule.Interval))
        {
            if (Firing.Contains(reminder.Id) || Missed.Contains(reminder.Id))
            {
                continue;
            }

            Anchors[reminder.Id] = at;
            AnchorRules[reminder.Id] = reminder.Schedule.Copy();
            cleared |= _state.Snoozed.Remove(reminder.Id);
        }

        if (cleared)
        {
            SaveState();
        }
    }

    // ---- 看一遍

    private static void Check()
    {
        if (!_running)
        {
            return;
        }

        _wake?.Stop();
        var now = DateTime.UtcNow;
        // 到点前一刻才离开的，等不到下一次空闲检查：有间隔提醒要看时现读一次。
        if (!_away && _idlePoll is not null && IdleSeconds() >= AwaySeconds)
        {
            _away = true;
        }

        var paused = PausedUntil;
        var result = ReminderCheck.Check(
            _list, _state, Anchors, Firing.Concat(Missed).ToHashSet(StringComparer.Ordinal), now, Zone,
            held: _locked || StatusScreenHost.Active || paused is not null, away: _away);
        var fresh = result.Fire.Concat(result.Missed).ToList();
        if (fresh.Count > 0)
        {
            foreach (var id in fresh)
            {
                _state.Snoozed.Remove(id);
                // 一次性的不挪：没点「知道了」就退出了，下次打开还要告诉你。
                if (Find(id)?.Schedule.Kind != ReminderSchedule.Once && _state.Marks.TryGetValue(id, out var mark))
                {
                    mark.At = ReminderTime.FromUtc(now);
                }

                Anchors.Remove(id);
            }

            Firing.AddRange(result.Fire);
            Missed.AddRange(result.Missed);
            SaveState();
            var newly = result.Fire.Select(Find).Where(reminder => reminder is not null).Select(reminder => reminder!).ToList();
            if (newly.Count > 0)
            {
                _nags = 0;
            }

            Sound(newly);
            Log.Info($"reminder.fire fire={result.Fire.Count} missed={result.Missed.Count}");
            // 进了状态屏的只算这一批处理了：之前挂着没理的、这次一起算出来错过的照样留着。
            if (Escalate(newly))
            {
                Firing.RemoveAll(result.Fire.Contains);
                Finish(result.Fire);
                return;
            }

            Present();
            ScheduleNag();
        }

        // 暂停着的到点了要再看一眼（那时补响 / 合成错过的）。
        var next = new[] { result.Next, paused }.Where(at => at is not null).Select(at => at!.Value).DefaultIfEmpty(DateTime.MaxValue).Min();
        if (next == DateTime.MaxValue)
        {
            return;
        }

        var wait = Math.Clamp((next - now).TotalMilliseconds + 50, 50, TimeSpan.FromDays(1).TotalMilliseconds);
        _wake ??= CreateTimer(Check);
        _wake.Interval = TimeSpan.FromMilliseconds(wait);
        _wake.Start();
    }

    private static Reminder? Find(string id) => _list.FirstOrDefault(reminder => reminder.Id == id);

    // ---- 方式

    /// <summary>新到点的这几条要什么方式：比现在挂着的更显眼才换（只升不降）。要进状态屏的当场进；进成了返回 true，进不去退成全屏、记下原因。</summary>
    private static bool Escalate(IReadOnlyList<Reminder> newly)
    {
        if (newly.Count == 0)
        {
            return false;
        }

        var target = ReminderAlerts.Alert(newly, IsRecording);
        if (target == Reminder.Status)
        {
            var preset = newly.First(reminder => reminder.Alert == Reminder.Status).StatusID;
            if (StatusScreenHost.Enter(preset, quiet: true, fallbackToFirst: true) is not { } failure)
            {
                return true;
            }

            target = Reminder.Full;
            _note = $"没能进入状态屏：{failure}";
        }

        if (ReminderAlerts.Rank(target) > ReminderAlerts.Rank(_mode))
        {
            _mode = target;
        }

        return false;
    }

    /// <summary>把挂着的（到点的 + 错过的）按现在的方式摆出来：全屏 / 边框 + 提示 / 提示；只剩错过的一律在提示上；都没有了就全收掉。</summary>
    private static void Present()
    {
        // 在状态屏里先都收着（_mode、_note 不动）：全屏提醒和状态屏每秒都把自己提到最上面，会来回抢；拦截也让人点不到按钮。
        // 退出状态屏时 Recheck 再摆出来。mac 的状态屏层级更高、盖得住，Windows 两边都是置顶。
        if (StatusScreenHost.Active)
        {
            ReminderScreen.Dismiss();
            ReminderGlow.Dismiss();
            NoticeHost.Unpin();
            return;
        }

        var fired = Firing.Select(Find).Where(reminder => reminder is not null).Select(reminder => reminder!).ToList();
        var lost = Missed.Select(Find).Where(reminder => reminder is not null).Select(reminder => reminder!).ToList();
        if (ReminderAlerts.Notice(fired, lost) is not { } notice)
        {
            HideSurfaces();
            NoticeHost.Unpin();
            return;
        }

        if (fired.Count == 0)
        {
            HideSurfaces();
        }

        if (fired.Count > 0 && _mode == Reminder.Full)
        {
            ReminderGlow.Dismiss();
            NoticeHost.Unpin();
            ReminderScreen.Show(
                new ReminderScreen.Content(
                    notice.Title, notice.Detail, fired.FirstOrDefault(reminder => reminder.Symbol.Length > 0)?.Symbol ?? string.Empty,
                    ReminderAlerts.FullSeconds(fired), ReminderAlerts.SnoozeChoices(SnoozeMinutes), _note),
                Acknowledge,
                minutes => Snooze(minutes));
            return;
        }

        ReminderScreen.Dismiss();
        if (fired.Count > 0 && _mode == Reminder.Glow)
        {
            ReminderGlow.Show();
        }
        else
        {
            ReminderGlow.Dismiss();
        }

        // 第一个是主按钮（收着时露在行尾）。
        var actions = new List<NoticeAction> { new("知道了", Acknowledge) };
        if (fired.Count > 0)
        {
            actions.Add(new NoticeAction($"稍后 {SnoozeMinutes} 分钟", () => Snooze(null)));
        }

        NoticeHost.Pin(notice.Title, notice.Detail ?? string.Empty, Acknowledge, actions.ToArray());
    }

    private static void HideSurfaces()
    {
        ReminderScreen.Dismiss();
        ReminderGlow.Dismiss();
        _nagTimer?.Stop();
        _mode = Reminder.Light;
        _note = null;
        _nags = 0;
    }

    // ---- 催促

    /// <summary>挂着的里头有要催的（提示上、边框；全屏不催）：按最短的间隔排下一次。</summary>
    private static void ScheduleNag()
    {
        _nagTimer?.Stop();
        var minutes = Firing.Select(Find).Where(reminder => reminder is { NagMinutes: > 0 }).Select(reminder => reminder!.NagMinutes).ToList();
        if (_mode == Reminder.Full || minutes.Count == 0)
        {
            return;
        }

        _nagTimer ??= CreateTimer(Nag);
        _nagTimer.Interval = TimeSpan.FromMinutes(minutes.Min());
        _nagTimer.Start();
    }

    /// <summary>再响一声、提示晃一下；第 3 次（到点那次算第 1 次）换成全屏，之后不再催。锁着屏、在状态屏里、暂停着时等下一轮。</summary>
    private static void Nag()
    {
        if (!_running || Firing.Count == 0 || _mode == Reminder.Full)
        {
            return;
        }

        if (_locked || StatusScreenHost.Active || PausedUntil is not null)
        {
            ScheduleNag();
            return;
        }

        var fired = Firing.Select(Find).Where(reminder => reminder is not null).Select(reminder => reminder!).ToList();
        _nags++;
        Sound(fired);
        if (_nags >= 2)
        {
            if (IsRecording)
            {
                NoticeHost.Nudge();
            }
            else
            {
                _mode = Reminder.Full;
                Present();
            }

            return;
        }

        NoticeHost.Nudge();
        ScheduleNag();
    }

    // ---- 处理

    /// <summary>「知道了」：挂着的都算处理了。</summary>
    private static void Acknowledge()
    {
        var handled = Firing.Concat(Missed).ToList();
        Firing.Clear();
        Missed.Clear();
        Finish(handled);
    }

    /// <summary>「稍后」：到点的推 N 分钟（提示上是设置里定的那个，全屏上能另选）；一起挂着的错过的算处理了。</summary>
    private static void Snooze(int? minutes)
    {
        var until = ReminderTime.FromUtc(DateTime.UtcNow.AddMinutes(minutes ?? SnoozeMinutes));
        foreach (var id in Firing)
        {
            _state.Snoozed[id] = until;
        }

        var handled = Missed.ToList();
        Firing.Clear();
        Missed.Clear();
        Finish(handled);
    }

    /// <summary>处理完：一次的从列表里删掉（推过的不删，它还要再响），间隔的从这一刻重新数，提示收掉，再看一遍。</summary>
    private static void Finish(IReadOnlyList<string> handled)
    {
        if (!_running)
        {
            return;
        }

        var now = DateTime.UtcNow;
        var removed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in handled)
        {
            if (Find(id) is not { } reminder)
            {
                continue;
            }

            if (reminder.Schedule.Kind == ReminderSchedule.Once)
            {
                removed.Add(id);
            }
            else if (reminder.Schedule.Kind == ReminderSchedule.Interval)
            {
                Anchors[id] = now;
                AnchorRules[id] = reminder.Schedule.Copy();
            }
        }

        if (removed.Count > 0)
        {
            _list.RemoveAll(reminder => removed.Contains(reminder.Id));
            SettingsService.Current.Reminders = _list.Select(reminder => reminder.Copy()).ToList();
            _signature = Signature(SettingsService.Current.Reminders);
            _state = ReminderCheck.Reconciled(_state, _list, now);
        }

        SaveState();
        // 还有没处理的（进状态屏只处理了那一批）就照样摆着，都处理了才全收。
        if (Firing.Count == 0 && Missed.Count == 0)
        {
            HideSurfaces();
            NoticeHost.Unpin();
        }
        else
        {
            Present();
        }

        Check();
    }

    /// <summary>声音（只响一声）：几条一起到点时按第一条要出声的——提示音，或者把这几条的标题念出来。录屏录音时不出声。</summary>
    private static void Sound(IReadOnlyList<Reminder> reminders)
    {
        if (IsRecording || reminders.FirstOrDefault(reminder => reminder.Sound != Reminder.SoundNone) is not { } first)
        {
            return;
        }

        if (first.Sound == Reminder.SoundSpeak)
        {
            Speech.Speak(string.Join("，", reminders.Select(reminder => reminder.Title)), "zh-Hans");
        }
        else
        {
            PlayChime(first.Chime);
        }
    }

    /// <summary>放一个提示音（设置里选的时候试听也走这里）：%WINDIR%\Media 里对应的那个文件，没有就放系统的通知声。</summary>
    public static void PlayChime(string name)
    {
        const uint flags = 0x0001 /* SND_ASYNC */ | 0x0002 /* SND_NODEFAULT */;
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", Reminders.ChimeFile(name));
        if (!File.Exists(path) || !PlaySound(path, IntPtr.Zero, 0x00020000 /* SND_FILENAME */ | flags))
        {
            PlaySound("SystemNotification", IntPtr.Zero, 0x00010000 /* SND_ALIAS */ | flags);
        }
    }

    private static void SaveState()
    {
        SettingsService.Current.RemindersState = _state.Copy();
        SettingsService.Save();
    }

    // ---- 离开电脑

    /// <summary>有开着的间隔提醒时每分钟看一眼空闲了多久：离开 5 分钟以上先不响，回来从回来那一刻重新数。</summary>
    private static void WatchIdle(bool needed)
    {
        if (!needed)
        {
            _idlePoll?.Stop();
            _idlePoll = null;
            _away = false;
            return;
        }

        if (_idlePoll is not null)
        {
            return;
        }

        _idlePoll = CreateTimer(PollIdle);
        _idlePoll.Interval = TimeSpan.FromSeconds(60);
        _idlePoll.IsRepeating = true;
        _idlePoll.Start();
    }

    private static void PollIdle()
    {
        var idle = IdleSeconds();
        if (idle >= AwaySeconds)
        {
            if (!_away)
            {
                _away = true;
                Check();
            }
        }
        else if (_away)
        {
            _away = false;
            RestartIntervals(DateTime.UtcNow.AddSeconds(-idle));
            Check();
        }
    }

    /// <summary>离上一次碰键盘鼠标过了几秒（GetLastInputInfo，不要权限）。</summary>
    private static double IdleSeconds()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        return GetLastInputInfo(ref info) ? unchecked((uint)Environment.TickCount - info.Time) / 1000.0 : 0;
    }

    private static DispatcherQueueTimer CreateTimer(Action tick)
    {
        var timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) => tick();
        return timer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetLastInputInfo(ref LastInputInfo info);

    [LibraryImport("winmm.dll", EntryPoint = "PlaySoundW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PlaySound(string sound, IntPtr module, uint flags);
}
