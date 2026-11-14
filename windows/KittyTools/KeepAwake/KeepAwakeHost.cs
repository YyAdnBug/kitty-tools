// 保持唤醒（PLAN-v20 K1，第一个插件；照 mac KeepAwake/KeepAwake.swift，f48c5d2e）的执行层：手动开的一段（无限期 / 到某一刻）和设置里的
// 定时，哪个在生效就让系统别睡。Windows 的做法（D2）：电源请求 PowerCreateRequest + PowerSetRequest（SystemRequired，屏幕也不熄时
// 再加 DisplayRequired），原因串「Kitty Tools：保持唤醒」在 powercfg /requests 里看得到；句柄式，进程退出系统自动收回，不挂在哪条线程上。
// 合上盖子照样睡（看系统「合上盖子时」的设置，这里管不了）。
// - 手动的一段不跨重启（免得忘了一直亮着）；定时那一段开着就跟着时段走，手动开的优先（时段结束时手动的还没到点就接着）。
// - 没开、没在时段里时什么都不跑：只有一个等到「下一次要变」的计时器（手动那段到点、时段的下一个边界），醒来（PBT_APMRESUMESUSPEND）、
//   改系统时间 / 时区（WM_TIMECHANGE）、设置变了（定时、屏幕熄不熄）重新算一遍（ShellRuntime 调 Evaluate）。
// - 插件移除 = Stop()：停掉、不再听；手动开着一段时说一声。开始 / 结束 / 到点 / 进出时段在底部轻提示说一声（mac 在刘海岛）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;

namespace KittyTools;

internal static partial class KeepAwakeHost
{
    private const int PowerRequestDisplayRequired = 0;
    private const int PowerRequestSystemRequired = 1;
    private const uint PowerRequestContextVersion = 0;
    private const uint PowerRequestContextSimpleString = 1;

    /// <summary>手动开的那一段到什么时候（UTC；DateTime.MaxValue = 无限期）；null = 没开。</summary>
    private static DateTime? _sessionEnd;

    /// <summary>上次算的时候定时是什么样（定时被改了引起的进出时段不说：人正看着设置页）。</summary>
    private static KeepAwakeSchedule? _lastSchedule;

    private static IntPtr _request;
    private static bool? _requestDisplay;
    private static DispatcherQueueTimer? _wake;

    public static bool IsRunning { get; private set; }

    /// <summary>定时那一段此刻生效着。</summary>
    public static bool InSchedule { get; private set; }

    /// <summary>手动开着一段（托盘、主界面、快捷键的「停止」看这个）。</summary>
    public static bool HasSession => _sessionEnd is not null;

    /// <summary>正在保持唤醒（手动的或定时的）。</summary>
    public static bool IsActive => _sessionEnd is not null || InSchedule;

    public static bool IsIndefinite => _sessionEnd == DateTime.MaxValue;

    /// <summary>状态变了（托盘、主界面、设置页跟着换字）。</summary>
    public static event Action? Changed;

    public static KeepAwakeSchedule Schedule => KeepAwakeSchedule.Decode(SettingsService.Current.KeepAwakeSchedule);

    private static TimeZoneInfo Zone => TimeZoneInfo.Local;

    /// <summary>「还剩 1 小时 12 分」「无限期」「定时 · 到 18:00」「没开」：托盘、启动器、设置页现在那一行。</summary>
    public static string Status()
    {
        var now = DateTime.UtcNow;
        if (_sessionEnd is { } end)
        {
            return KeepAwakePlan.Remaining(IsIndefinite ? null : end, now);
        }

        return InSchedule ? "定时 · " + ScheduleUntil(now) : "没开";
    }

    /// <summary>定时那一段管到哪：「到 18:00」；一直在时段里（每天全天）的是「一直开着」。</summary>
    private static string ScheduleUntil(DateTime now)
        => Schedule.NextChange(now, Zone) is { } until ? "到 " + KeepAwakePlan.Moment(until, now, Zone) : "一直开着";

    // ---- 起停（插件添加 / 移除）

    public static void Start()
    {
        if (IsRunning)
        {
            return;
        }

        IsRunning = true;
        Evaluate(announcing: false);
        Log.Info("keep-awake.start");
    }

    public static void Stop()
    {
        if (!IsRunning)
        {
            return;
        }

        // 手动开着一段时移除插件：说一声，不悄悄停
        if (_sessionEnd is not null)
        {
            NoticeHost.Show("已停止保持唤醒", "插件移除了，电脑会照常睡", NoticeTone.Normal);
        }

        IsRunning = false;
        _lastSchedule = null;
        _sessionEnd = null;
        InSchedule = false;
        _wake?.Stop();
        Apply(false);
        Changed?.Invoke();
        Log.Info("keep-awake.stop");
    }

    // ---- 手动的一段

    /// <summary>开一段：until 是结束的时刻（UTC），null = 无限期；已经开着的换成这一段。</summary>
    public static void Begin(DateTime? until, string label)
    {
        if (!IsRunning)
        {
            return;
        }

        _sessionEnd = until ?? DateTime.MaxValue;
        Evaluate(announcing: false);
        var screen = SettingsService.Current.KeepAwakeDisplay ? "屏幕也不熄" : "屏幕照常熄";
        NoticeHost.Show("保持唤醒 · " + label, until is null ? "直到你停止 · " + screen : screen, NoticeTone.Normal);
        Log.Info($"keep-awake.begin indefinite={until is null}");
    }

    /// <summary>停掉手动的那一段（定时的时段里照样保持唤醒，说清楚）。</summary>
    public static void End()
    {
        if (_sessionEnd is null)
        {
            return;
        }

        _sessionEnd = null;
        Evaluate(announcing: false);
        NoticeHost.Show("已停止保持唤醒", InSchedule ? "定时还在，" + ScheduleUntil(DateTime.UtcNow) : "电脑会照常睡", NoticeTone.Normal);
        Log.Info("keep-awake.end");
    }

    /// <summary>快捷键、主界面那一格、启动器的内置动作：开着就停，没开就开无限期。</summary>
    public static void Toggle()
    {
        if (_sessionEnd is not null)
        {
            End();
        }
        else
        {
            Begin(null, "无限期");
        }
    }

    // ---- 重新算

    /// <summary>
    /// 看手动那段到点了没、在不在时段里，让电源请求跟上；排下一次要变的时刻。announcing：这次进出时段要不要说——定时被改了引起的不说
    /// （人正看着设置页），开始时那一下不说；手动那段到点总要说（不是人点的）。醒来、改时间、设置变了都调它。
    /// </summary>
    public static void Evaluate(bool announcing = true)
    {
        if (!IsRunning)
        {
            return;
        }

        var now = DateTime.UtcNow;
        var plan = Schedule;
        var edited = _lastSchedule is null || !_lastSchedule.Equals(plan);
        _lastSchedule = plan;
        var inside = plan.Contains(now, Zone);
        var enteredOrLeft = inside != InSchedule;
        InSchedule = inside;
        var expired = false;
        if (_sessionEnd is { } end && end <= now)
        {
            _sessionEnd = null;
            expired = true;
        }

        if (expired)
        {
            NoticeHost.Show("保持唤醒到点了", inside ? "定时还在，" + ScheduleUntil(now) : "电脑会照常睡", NoticeTone.Normal);
        }
        else if (announcing && enteredOrLeft && !edited && _sessionEnd is null)
        {
            NoticeHost.Show(inside ? "按时段保持唤醒" : "时段结束，不再保持唤醒", inside ? plan.Summary : "电脑会照常睡", NoticeTone.Normal);
        }

        Apply(IsActive);
        var next = new[] { _sessionEnd == DateTime.MaxValue ? null : _sessionEnd, plan.NextChange(now, Zone) }
            .OfType<DateTime>().DefaultIfEmpty(DateTime.MaxValue).Min();
        if (next == DateTime.MaxValue)
        {
            _wake?.Stop();
        }
        else
        {
            _wake ??= CreateTimer();
            _wake.Stop();
            // 计时器按经过的时间算（睡着时不走）：醒来另有 Evaluate 兜底；太远的先睡一天再算
            _wake.Interval = TimeSpan.FromMilliseconds(Math.Clamp((next - now).TotalMilliseconds + 50, 50, TimeSpan.FromDays(1).TotalMilliseconds));
            _wake.Start();
        }

        Changed?.Invoke();
    }

    private static DispatcherQueueTimer CreateTimer()
    {
        var timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Evaluate();
        return timer;
    }

    /// <summary>电源请求跟上：要开、开着的屏幕档位不对就换（先起新的再还旧的，中间不留空档）；不要了就还掉。</summary>
    private static void Apply(bool on)
    {
        var display = SettingsService.Current.KeepAwakeDisplay;
        if (!on)
        {
            Release(ref _request);
            _requestDisplay = null;
            return;
        }

        if (_requestDisplay == display && _request != IntPtr.Zero)
        {
            return;
        }

        var next = Create(display);
        if (next == IntPtr.Zero)
        {
            return;
        }

        Release(ref _request);
        _request = next;
        _requestDisplay = display;
        Log.Info($"keep-awake.request display={display}");
    }

    private static unsafe IntPtr Create(bool display)
    {
        fixed (char* reason = "Kitty Tools：保持唤醒")
        {
            var context = new ReasonContext { Version = PowerRequestContextVersion, Flags = PowerRequestContextSimpleString, Reason = (IntPtr)reason };
            var handle = PowerCreateRequest(&context);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            {
                Log.Warn($"keep-awake.create-failed {Marshal.GetLastWin32Error()}");
                return IntPtr.Zero;
            }

            var ok = PowerSetRequest(handle, PowerRequestSystemRequired) && (!display || PowerSetRequest(handle, PowerRequestDisplayRequired));
            if (!ok)
            {
                Log.Warn($"keep-awake.set-failed {Marshal.GetLastWin32Error()}");
                CloseHandle(handle);
                return IntPtr.Zero;
            }

            return handle;
        }
    }

    private static void Release(ref IntPtr handle)
    {
        if (handle == IntPtr.Zero)
        {
            return;
        }

        // 关句柄就撤掉这个请求的全部类型（PowerClearRequest 是给同一个句柄换类型用的）
        CloseHandle(handle);
        handle = IntPtr.Zero;
    }

    /// <summary>REASON_CONTEXT 只用「简单字符串」那一种：版本、标志、一个字符串指针（联合体里别的字段不读）。</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public IntPtr Reason;
        private IntPtr _detail1;
        private IntPtr _detail2;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static unsafe partial IntPtr PowerCreateRequest(ReasonContext* context);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PowerSetRequest(IntPtr request, int type);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(IntPtr handle);
}
