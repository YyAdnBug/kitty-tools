// 状态屏的一次会话（PLAN-v12 N5，照 mac StatusScreen/StatusScreen.swift）：进入（拦截、每屏一扇窗、保持唤醒、自动结束）、
// 退出判断（按住 Esc 或用鼠标按住退出提示两秒，Core 的 ExitHold）、挡下的触碰（计数、标题晃一下、退出提示浮出 3 秒、告示样式冒眼睛）、
// 退出密码（Core 的 Passcode，存在凭据管理器）、锁屏时让开（窗口收起、拦截暂停、屏幕常亮降成只防睡眠）、解锁 / 到时间 / 按住满了时退出。
// 定位是告示加防误触，不是安全措施：Ctrl+Alt+Del、Win+L 拦不住；忘了密码就锁屏再解锁（解锁即结束）。
// 入口：托盘、主界面、启动器直接 Enter；全局快捷键默认先出选状态的面板（StatusPicker），设置里开了「直接进入」就进排在最前面的那个。
// 退出之后拦截留到按着的键松开才撤（最多 2 秒），不然按住的 Esc 连发会落进前台程序。
// 进入后鼠标指针藏起来，挪一下就回来（mac setHiddenUntilMouseMoves；PLAN-v12 第 7 批）。
// **测试和自检绝不能真的进入**：RunProbeAsync 用 InputBlock 的 Probe 模式（只吞带标记的注入事件，真的键盘鼠标照常放行），
// 只在自检档里、由 --status-screen-probe 打开（ShellRuntime）。
using System.Runtime.InteropServices;
using KittyTools.Core;
using KittyTools.Infrastructure;
using Microsoft.UI.Dispatching;
using Windows.Win32;

namespace KittyTools;

internal static partial class StatusScreenHost
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsDisplayRequired = 0x00000002;

    private static readonly List<StatusScreenPanel> Panels = new();
    private static readonly Random Random = new();

    private static StatusPreset? _preset;
    private static DateTime _startedAt;
    private static long _startedTick;
    private static int _elapsed;
    private static int _touches;
    private static ExitHold _hold = new();
    private static Passcode? _passcode;
    private static bool _asking;
    private static bool _showsHint;
    private static bool _holding;
    private static bool _animates;
    private static bool _locked;
    private static bool _probe;
    private static Peek? _peek;
    private static PeekEdge? _lastPeekEdge;
    private static (int X, int Y, long At)? _lastMouse;
    private static double _travelled;

    private static DispatcherQueueTimer? _tickTimer;
    private static DispatcherQueueTimer? _autoEndTimer;
    private static DispatcherQueueTimer? _holdTimer;
    private static DispatcherQueueTimer? _hintTimer;
    private static DispatcherQueueTimer? _promptTimer;
    private static DispatcherQueueTimer? _peekTimer;
    private static DispatcherQueueTimer? _lingerTimer;

    /// <summary>在状态屏里（退出的那一刻就不算了：拦截可能还在等按着的键松开）。热键、复制即译在这期间不响应。</summary>
    public static bool Active { get; private set; }

    /// <summary>退出之后（App 退出时不发）：在状态屏里时到点的提醒这会儿再出（mac onExit，提醒 C11）。</summary>
    public static event Action? Exited;

    /// <summary>设置里的状态列表（收拾过的；没存过 = 自带的三个）。</summary>
    public static List<StatusPreset> Presets => StatusPresets.Load(SettingsService.Current.StatusScreenPresets);

    // ---- 退出密码（凭据管理器；不进设置文件、不跟导出和备份走）

    private static string PasscodeTarget => Credentials.Target(Passcode.Account);

    /// <summary>读不到就当没设：宁可少一道验证，也不把人关在里面。</summary>
    public static Passcode? LoadPasscode()
    {
        try
        {
            return Passcode.Parse(Credentials.Get(PasscodeTarget));
        }
        catch (Exception ex)
        {
            Log.Warn($"status.passcode-read-failed {ex.GetType().Name}");
            return null;
        }
    }

    /// <summary>存（null = 移除）。返回之后以读回来的为准。</summary>
    public static void SavePasscode(string? text)
    {
        if (text is null)
        {
            Credentials.Delete(PasscodeTarget);
        }
        else if (Passcode.Parse(text) is not null)
        {
            Credentials.Set(PasscodeTarget, text);
        }

        Log.Info($"status.passcode-saved set={LoadPasscode() is not null}");
    }

    // ---- 进入

    /// <summary>按 id 进入（托盘、主界面、启动器的状态项；提醒的「进入状态屏」找不到时用排在最前面的那个）。返回进不去的原因。</summary>
    public static string? Enter(string id, bool quiet = false, bool fallbackToFirst = false)
    {
        var presets = Presets;
        var preset = presets.FirstOrDefault(item => item.Id == id) ?? (fallbackToFirst ? presets.FirstOrDefault() : null);
        return preset is null ? "找不到这个状态" : Enter(preset, quiet: quiet);
    }

    /// <summary>
    /// 进入一个状态。正在截图框选 / 长截图时不进（响一声）；正在录屏 / 录音时提示「先停止这一段」（录制条会被盖住、退出前停不了）；
    /// 拦截建不起来、窗口建不出来都不进。probe：自检（只拦带标记的注入事件，不记「上次进入」）。
    /// 返回进不去的原因（null = 进去了 / 本来就在里面）；quiet：不响、不出提示（提醒「进入状态屏」进不去时退成全屏、把原因写在全屏上）。
    /// </summary>
    public static string? Enter(StatusPreset preset, bool probe = false, bool quiet = false)
    {
        if (Active)
        {
            return null;
        }

        if (!probe && !Features.IsOn(Feature.StatusScreen))
        {
            return "状态屏在 设置 › 通用 › 功能 里关着";
        }

        if (ScreenshotSession.IsActive || ScrollingCapture.Active)
        {
            if (!quiet)
            {
                SystemSound.Beep();
            }

            return "正在截图";
        }

        if (RecordingHost.IsRecording || RecordingCountdown.Active)
        {
            if (!quiet)
            {
                NoticeHost.Show("正在录屏", "先停止这一段再进入状态屏", NoticeTone.Warning);
            }

            return "正在录屏";
        }

        if (AudioHost.IsRecording || AudioHost.IsArmed)
        {
            if (!quiet)
            {
                NoticeHost.Show("正在录音", "先停止这一段再进入状态屏", NoticeTone.Warning);
            }

            return "正在录音";
        }

        // 上一次退出后还在等按键松开的拦截：先撤，不叠两个。
        EndLinger();
        // 密码趁键盘鼠标还没被拦先读好。
        var passcode = probe ? null : LoadPasscode();
        _hold = new ExitHold();
        if (!InputBlock.Start(OnInput, OnMouseMoved, probe))
        {
            if (!quiet)
            {
                NoticeHost.Show("没能进入状态屏", "键盘鼠标的拦截没建起来", NoticeTone.Error);
            }

            return "键盘鼠标的拦截没建起来";
        }

        Active = true;
        _probe = probe;
        _preset = preset;
        _passcode = passcode;
        _asking = false;
        _showsHint = false;
        _holding = false;
        _locked = false;
        _touches = 0;
        _peek = null;
        _lastPeekEdge = null;
        _lastMouse = null;
        _travelled = 0;
        _startedAt = DateTime.Now;
        _startedTick = Environment.TickCount64;
        _elapsed = 0;
        _animates = StatusScreenRules.Animates(SettingsService.Current.StatusScreenAnimations, Motion.Reduced);
        HidePanels();
        try
        {
            ArrangePanels();
        }
        catch (Exception ex)
        {
            Log.Error("status.panels-failed", ex);
            Exit(StatusExitReason.Quit);
            if (!quiet)
            {
                NoticeHost.Show("没能进入状态屏", "屏幕上的告示没建起来", NoticeTone.Error);
            }

            return "屏幕上的告示没建起来";
        }

        if (!probe)
        {
            HideCursor();
        }

        SetPower(preset.Power);
        _tickTimer = Timer(1000, repeating: true, Tick);
        if (preset.AutoEndMinutes > 0)
        {
            _autoEndTimer = Timer(preset.AutoEndMinutes * 60_000, repeating: false, () => Exit(StatusExitReason.AutoEnd));
        }

        ScheduleIdlePeek();
        Panels.FirstOrDefault()?.Announce($"状态屏：{preset.Title}。" + StatusScreenRules.ExitWording(passcode is not null));
        if (!probe)
        {
            // 真进来了才记：选状态的面板下次默认选中它。
            SettingsService.Current.StatusScreenLastPreset = preset.Id;
            SettingsService.Save();
        }

        Log.Info($"status.enter style={preset.Style} power={preset.Power} auto={preset.AutoEndMinutes} screens={Panels.Count} probe={probe}");
        return null;
    }

    /// <summary>收起剪贴板、启动器、翻译浮窗、主界面、选状态的面板（固定的也收）。</summary>
    private static void HidePanels()
    {
        OverlayHost.Hide(restoreForeground: false);
        TranslateHost.Hide(restoreForeground: false);
        HomePanel.Hide(restoreForeground: false);
        StatusPicker.Hide();
    }

    /// <summary>每块屏一扇（进入时、显示器变了时）；鼠标所在那块拿前台。</summary>
    private static void ArrangePanels()
    {
        foreach (var panel in Panels)
        {
            panel.Close();
        }

        Panels.Clear();
        if (_preset is not { } preset)
        {
            return;
        }

        PInvoke.GetCursorPos(out var cursor);
        var footer = Footer();
        foreach (var (bounds, scale) in ScreenCapture.Monitors())
        {
            var panel = new StatusScreenPanel(bounds, scale, preset, _animates, _passcode is not null);
            Panels.Add(panel);
            panel.Present(key: panel.Contains(cursor.X, cursor.Y), footer);
        }
    }

    /// <summary>显示器插拔、改分辨率（WM_DISPLAYCHANGE）：按现在的屏幕重摆。锁着屏时不摆（解锁就结束了）。</summary>
    public static void OnDisplaysChanged()
    {
        if (!Active || _locked)
        {
            return;
        }

        try
        {
            ArrangePanels();
            UpdateOverlays();
        }
        catch (Exception ex)
        {
            Log.Error("status.rearrange-failed", ex);
            Exit(StatusExitReason.Quit);
            // Quit 是 App 要退出时的收场、不发 Exited；这里 App 还在跑：状态屏期间压着的提醒要当场再看一遍。
            Exited?.Invoke();
        }
    }

    private static string Footer()
        => _preset is { } preset
            ? StatusScreenRules.Footer(_startedAt.ToString("HH:mm"), _elapsed, preset.AutoEndMinutes)
            : string.Empty;

    /// <summary>每秒：小字、窗口再提到最上面；跨了分钟时告示挪个位置（防残影）、换一份新钩子（系统万一摘了旧的）。</summary>
    private static void Tick()
    {
        // 报平安：UI 线程卡住超过 5 秒拦截自己放行（InputBlock.Heartbeat）。
        InputBlock.Heartbeat();
        if (!Active || _locked)
        {
            return;
        }

        var seconds = (int)Math.Round((Environment.TickCount64 - _startedTick) / 1000.0);
        var minuteChanged = seconds / 60 != _elapsed / 60;
        _elapsed = seconds;
        var footer = Footer();
        foreach (var panel in Panels)
        {
            panel.SetFooter(footer);
            panel.RaiseAll();
        }

        if (minuteChanged)
        {
            var drift = StatusScreenRules.Drift(seconds / 60);
            foreach (var panel in Panels)
            {
                panel.SetDrift(drift);
            }

            InputBlock.Refresh();
        }
    }

    // ---- 事件

    /// <summary>拦截交过来的按键和鼠标键。</summary>
    private static void OnInput(StatusInput input)
    {
        var now = Environment.TickCount64;
        if (!Active)
        {
            // 已经退出、拦截还留着：只等按着的键松开。
            _hold.Handle(input, now);
            if (!_hold.IsAnythingDown(now))
            {
                EndLinger();
            }

            return;
        }

        if (_locked)
        {
            return;
        }

        if (_asking)
        {
            TypePasscode(input, now);
            return;
        }

        var hints = _showsHint ? Panels.Select(panel => panel.HintHit).ToList() : null;
        var touched = _hold.Handle(input, now, hints);
        SyncHold();
        if (!touched)
        {
            return;
        }

        _touches++;
        foreach (var panel in Panels)
        {
            panel.Shake();
        }

        RevealHint();
    }

    /// <summary>鼠标挪了：一阵里（中间停不超过 1 秒）累计超过 40 DIP 就浮出退出提示。</summary>
    private static void OnMouseMoved(int x, int y)
    {
        RevealCursor();
        if (!Active || _locked)
        {
            return;
        }

        var now = Environment.TickCount64;
        var scale = Panels.FirstOrDefault(panel => panel.Contains(x, y))?.Scale ?? 1;
        if (_lastMouse is { } last && now - last.At < 1000)
        {
            _travelled += Math.Sqrt(Math.Pow(x - last.X, 2) + Math.Pow(y - last.Y, 2)) / scale;
        }
        else
        {
            _travelled = 0;
        }

        _lastMouse = (x, y, now);
        if (_travelled <= StatusScreenRules.MouseTravelDip)
        {
            return;
        }

        _travelled = 0;
        RevealHint();
    }

    /// <summary>退出判断变了（开始按住 / 取消）：进度环跟上，起 / 撤到点的计时；提示（开着的话）连同进度环一起出来。</summary>
    private static void SyncHold()
    {
        var holding = _hold.Holding is not null;
        if (holding == _holding)
        {
            return;
        }

        _holding = holding;
        _holdTimer?.Stop();
        _holdTimer = null;
        if (holding)
        {
            ScheduleHoldEnd(ExitHold.DurationMs);
        }

        RevealHint();
        UpdateOverlays();
    }

    private static void ScheduleHoldEnd(long milliseconds)
    {
        _holdTimer = Timer((int)Math.Max(1, milliseconds), repeating: false, () =>
        {
            if (!Active || _hold.Remaining(Environment.TickCount64) is not { } rest)
            {
                return;
            }

            if (rest <= 0)
            {
                HoldCompleted();
            }
            else
            {
                ScheduleHoldEnd(rest);
            }
        });
    }

    // ---- 退出密码

    /// <summary>按住满了：没设密码直接退出；设了的浮出密码框，输对了才退出。之后再按 Esc 是「不输了」。</summary>
    private static void HoldCompleted()
    {
        if (_passcode is not { } passcode)
        {
            Exit(StatusExitReason.Held);
            return;
        }

        _asking = true;
        passcode.Begin();
        _hold.Cancel();
        SyncHold();
        _hintTimer?.Stop();
        _showsHint = false;
        _peek = null;
        UpdateOverlays();
        RestartPromptTimer();
        Panels.FirstOrDefault()?.Announce("输入密码退出，按 Esc 取消");
    }

    /// <summary>密码框开着时：数字、Backspace、Esc 归它，别的不理（不算触碰、不晃）。退出判断只跟着记哪些键还按着。</summary>
    private static void TypePasscode(StatusInput input, long now)
    {
        _hold.Handle(input, now);
        _hold.Cancel();
        if (_passcode is not { } passcode)
        {
            return;
        }

        var outcome = passcode.Handle(input, now);
        switch (outcome)
        {
            case PasscodeOutcome.Ignored:
                return;
            case PasscodeOutcome.Matched:
                Exit(StatusExitReason.Held);
                return;
            case PasscodeOutcome.Cancelled or PasscodeOutcome.GaveUp:
                ClosePrompt();
                return;
            case PasscodeOutcome.Wrong:
                Panels.FirstOrDefault()?.Announce("密码不对");
                break;
        }

        RestartPromptTimer();
        UpdateOverlays();
    }

    private static void RestartPromptTimer()
    {
        _promptTimer?.Stop();
        _promptTimer = Timer((int)Passcode.IdleMs, repeating: false, ClosePrompt);
    }

    /// <summary>收起密码框（Esc、连错太多次、一阵没按键、锁屏）：回到告示，要退出得重新按住。</summary>
    private static void ClosePrompt()
    {
        _promptTimer?.Stop();
        _promptTimer = null;
        if (!_asking)
        {
            return;
        }

        _asking = false;
        // 回到告示：指针再藏起来（mac closePrompt 的 hideCursor，挪一下鼠标又会出来）。自检不藏。
        if (!_probe)
        {
            HideCursor();
        }

        UpdateOverlays();
    }

    // ---- 退出提示和眼睛

    /// <summary>退出提示浮出 3 秒（设置里关了就不出，只剩按住 Esc）；告示样式冒眼睛、和它同起同落。密码框开着时都不出。</summary>
    private static void RevealHint()
    {
        if (_asking || _preset is not { } preset)
        {
            return;
        }

        var hint = SettingsService.Current.StatusScreenExitHint;
        var eyes = StatusScreenRules.Peeks(preset.Style, _animates);
        if (!hint && !eyes)
        {
            return;
        }

        _showsHint = hint;
        if (eyes)
        {
            PeekOut(clearOfHint: hint);
        }

        StartDwell();
        UpdateOverlays();
    }

    /// <summary>退出提示和眼睛露 3 秒再收（每次重新计；按住期间到点不收）。</summary>
    private static void StartDwell()
    {
        _hintTimer?.Stop();
        _hintTimer = Timer((int)StatusScreenRules.HintDwellMs, repeating: false, () =>
        {
            if (!Active || _holding)
            {
                return;
            }

            _showsHint = false;
            _peek = null;
            // 提示收了：指针再藏起来（mac startDwell 的 hideCursor）。自检不藏。
            if (!_probe)
            {
                HideCursor();
            }

            UpdateOverlays();
        });
    }

    /// <summary>眼睛探出来：随机挑一处（和上一次不同边）。已经露着就不换地方。</summary>
    private static void PeekOut(bool clearOfHint)
    {
        if (_peek is not null)
        {
            return;
        }

        var next = StatusScreenRules.RandomPeek(_lastPeekEdge, clearOfHint, Random);
        _lastPeekEdge = next.Edge;
        _peek = next;
    }

    /// <summary>没人碰的时候眼睛隔 15–45 秒自己冒出来看一眼；到点时正忙着（提示浮着、眼睛露着、密码框开着、锁着屏）就跳过这一次。</summary>
    private static void ScheduleIdlePeek()
    {
        _peekTimer?.Stop();
        _peekTimer = null;
        if (!Active || _preset is not { } preset || !StatusScreenRules.Peeks(preset.Style, _animates))
        {
            return;
        }

        _peekTimer = Timer(Random.Next(StatusScreenRules.PeekGapMinMs, StatusScreenRules.PeekGapMaxMs), repeating: false, () =>
        {
            ScheduleIdlePeek();
            if (_locked || _asking || _showsHint || _peek is not null)
            {
                return;
            }

            PeekOut(clearOfHint: false);
            StartDwell();
            UpdateOverlays();
        });
    }

    /// <summary>把现在的提示、进度环、密码框、眼睛交给每块屏。</summary>
    private static void UpdateOverlays()
    {
        foreach (var panel in Panels)
        {
            panel.SetHint(_showsHint && !_asking, _holding);
            panel.SetPasscode(_asking ? _passcode : null);
            panel.SetPeek(_asking ? null : _peek);
        }
    }

    // ---- 锁屏

    /// <summary>锁屏、会话切走（WTS_SESSION_LOCK）：不拦输入、窗口收起；「屏幕常亮」降成只防睡眠（不然锁屏界面一直亮着）。</summary>
    public static void Locked()
    {
        if (!Active || _locked)
        {
            return;
        }

        _locked = true;
        InputBlock.Pause();
        _hold.Reset();
        SyncHold();
        _hintTimer?.Stop();
        _peekTimer?.Stop();
        _showsHint = false;
        _peek = null;
        ClosePrompt();
        _lastMouse = null;
        foreach (var panel in Panels)
        {
            panel.Hide();
        }

        if (_preset?.Power == StatusPresets.DisplayOn)
        {
            SetPower(StatusPresets.Awake);
        }

        Log.Info("status.locked");
    }

    /// <summary>解锁回来（WTS_SESSION_UNLOCK）：结束（mac Z9：想真防人就进入之后再锁屏）。</summary>
    public static void Unlocked()
    {
        if (Active && _locked)
        {
            Exit(StatusExitReason.Unlocked);
        }
    }

    // ---- 退出

    public static void Exit(StatusExitReason reason)
    {
        if (!Active || _preset is not { } preset)
        {
            return;
        }

        Active = false;
        var seconds = (int)((Environment.TickCount64 - _startedTick) / 1000);
        foreach (var timer in new[] { _tickTimer, _autoEndTimer, _holdTimer, _hintTimer, _promptTimer, _peekTimer })
        {
            timer?.Stop();
        }

        _tickTimer = _autoEndTimer = _holdTimer = _hintTimer = _promptTimer = _peekTimer = null;
        _asking = false;
        _passcode = null;
        SetPower(StatusPresets.Normal);
        foreach (var panel in Panels)
        {
            panel.Close();
        }

        Panels.Clear();
        RevealCursor();
        // 按着的键（按住退出的 Esc / 左键）还没松：拦截留到松开，最多 2 秒；App 要退出、没有键按着就当场撤。
        if (reason == StatusExitReason.Quit || !_hold.IsAnythingDown(Environment.TickCount64))
        {
            EndLinger();
        }
        else
        {
            _lingerTimer = Timer((int)StatusScreenRules.LingerLimitMs, repeating: false, EndLinger);
        }

        Log.Info($"status.exit reason={reason} seconds={seconds} touches={_touches} swallowed={InputBlock.Swallowed}");
        if (reason == StatusExitReason.Quit)
        {
            return;
        }

        NoticeHost.Show(
            "状态屏已结束", StatusScreenRules.Summary(reason, seconds, _touches, preset.AutoEndMinutes), NoticeTone.Normal);
        Exited?.Invoke();
    }

    /// <summary>撤拦截（退出后等到按键松开、等满了、App 退出、又要进入时）。</summary>
    private static void EndLinger()
    {
        _lingerTimer?.Stop();
        _lingerTimer = null;
        InputBlock.Stop();
    }

    // ---- 电源

    /// <summary>照常不拦；不睡眠只防系统闲置睡眠；屏幕常亮连显示器闲置熄灭一起防（同录屏）。</summary>
    private static void SetPower(string power)
        => SetThreadExecutionState(power switch
        {
            StatusPresets.DisplayOn => EsContinuous | EsSystemRequired | EsDisplayRequired,
            StatusPresets.Awake => EsContinuous | EsSystemRequired,
            _ => EsContinuous,
        });

    private static DispatcherQueueTimer Timer(int milliseconds, bool repeating, Action action)
    {
        var timer = DispatcherQueue.GetForCurrentThread()!.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds);
        timer.IsRepeating = repeating;
        timer.Tick += (_, _) => action();
        timer.Start();
        return timer;
    }

    // ---- 自检

    public const string ProbeArgument = "--status-screen-probe=";

    /// <summary>
    /// 自检（自检档，--status-screen-probe=&lt;目录&gt;）：三种样式各进一次 Probe 模式（只吞带标记的注入事件，真的键盘鼠标照常放行），
    /// 每次：截各屏的窗口 → 发一个带标记的 A（看有没有被吞、标题晃）→ 浮出退出提示再截 → 发带标记的 Esc 按住 2.3 秒（看会不会退出）。
    /// 屏幕会被盖住约 15 秒、前台被拿走，跑之前跟用户说一声；结果写日志 status.probe-*，图存进目录。
    /// </summary>
    public static async Task RunProbeAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        foreach (var preset in StatusPresets.BuiltIn())
        {
            Enter(preset, probe: true);
            if (!Active)
            {
                Log.Warn($"status.probe-enter-failed style={preset.Style}");
                continue;
            }

            await Task.Delay(1200);
            await SnapAsync(directory, preset.Style + "-entered");
            InputBlock.SendProbeKey(0x41);
            await Task.Delay(300);
            Log.Info($"status.probe-key style={preset.Style} swallowed={InputBlock.Swallowed} touches={_touches} active={Active}");
            await SnapAsync(directory, preset.Style + "-touched");
            InputBlock.SendProbeKey(0x1B, down: true, up: false);
            await Task.Delay(2300);
            Log.Info($"status.probe-hold style={preset.Style} active-after-hold={Active}");
            InputBlock.SendProbeKey(0x1B, down: false, up: true);
            await Task.Delay(800);
            Exit(StatusExitReason.Held);
            await Task.Delay(500);
        }

        Log.Info("status.probe-done");
    }

    private static async Task SnapAsync(string directory, string name)
    {
        var index = 0;
        foreach (var panel in Panels)
        {
            foreach (var hwnd in panel.Handles)
            {
                await WindowShot.SaveAsync(hwnd, Path.Combine(directory, $"status-{name}-{index++}.png"));
            }
        }
    }

    [LibraryImport("kernel32.dll")]
    private static partial uint SetThreadExecutionState(uint flags);

    // ---- 鼠标指针

    private static bool _cursorHidden;

    /// <summary>
    /// 藏起鼠标指针。ShowCursor 的计数跟着本线程走：只在指针停在本线程的窗口（每块屏的告示、压暗层）上时藏得住——正好就是状态屏盖着的时候；
    /// 一藏一放成对（_cursorHidden），计数不会越减越多。
    /// </summary>
    private static void HideCursor()
    {
        if (!_cursorHidden)
        {
            ShowCursor(false);
            _cursorHidden = true;
        }
    }

    /// <summary>挪了鼠标、退出时放回来。</summary>
    private static void RevealCursor()
    {
        if (_cursorHidden)
        {
            ShowCursor(true);
            _cursorHidden = false;
        }
    }

    [LibraryImport("user32.dll")]
    private static partial int ShowCursor([MarshalAs(UnmanagedType.Bool)] bool show);
}
