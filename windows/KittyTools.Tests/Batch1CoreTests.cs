// 补发修饰键抬起、窗口像素矩形、撤销栈拿回条目：第二版第 1 批新加的纯函数单测。
// 全部照 PLAN §2 的修法写的期望值，和 mac 版没有可直接搬的用例。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class ModifierReleaseTests
{
    [TestMethod]
    public void NothingDownMeansNothingToRelease()
    {
        Assert.AreEqual(0, ModifierRelease.Plan(false, false, false, false, false).Count);
    }

    [TestMethod]
    public void AltIsAlwaysLast()
    {
        var plan = ModifierRelease.Plan(control: true, alt: true, shift: true, leftWindows: false, rightWindows: false);
        CollectionAssert.AreEqual(
            new[] { ModifierKey.Shift, ModifierKey.Control, ModifierKey.Alt },
            plan.ToArray());
        Assert.IsTrue(ModifierRelease.NeedsAltGuard(plan[^1]));
        Assert.IsFalse(ModifierRelease.NeedsAltGuard(plan[0]));
    }

    [TestMethod]
    public void WindowsKeysGoBeforeControlAndAlt()
    {
        var plan = ModifierRelease.Plan(control: true, alt: true, shift: false, leftWindows: true, rightWindows: true);
        CollectionAssert.AreEqual(
            new[] { ModifierKey.LeftWindows, ModifierKey.RightWindows, ModifierKey.Control, ModifierKey.Alt },
            plan.ToArray());
    }

    [TestMethod]
    public void OnlyAltHeldIsJustTheGuardedTap()
    {
        // 划词时 Alt+E 还按着、其它都松了：只补一个带 vkE8 的 Alt 抬起。
        var plan = ModifierRelease.Plan(control: false, alt: true, shift: false, leftWindows: false, rightWindows: false);
        Assert.AreEqual(1, plan.Count);
        Assert.AreEqual(ModifierKey.Alt, plan[0]);
        Assert.IsTrue(ModifierRelease.NeedsAltGuard(plan[0]));
    }

    [TestMethod]
    public void VirtualKeyCodes()
    {
        Assert.AreEqual(0x11, ModifierRelease.VirtualKey(ModifierKey.Control));
        Assert.AreEqual(0x12, ModifierRelease.VirtualKey(ModifierKey.Alt));
        Assert.AreEqual(0x10, ModifierRelease.VirtualKey(ModifierKey.Shift));
        Assert.AreEqual(0x5B, ModifierRelease.VirtualKey(ModifierKey.LeftWindows));
        Assert.AreEqual(0x5C, ModifierRelease.VirtualKey(ModifierKey.RightWindows));
    }
}

[TestClass]
public sealed class MonitorLayoutTests
{
    private static readonly WorkArea Primary = new(0, 0, 1920, 1040);

    [TestMethod]
    public void PixelsFollowTargetMonitorScale()
    {
        // 720 DIP 在 100% 屏上是 720 px，在 150% 屏上是 1080 px（内容始终 720 DIP 宽）。
        Assert.AreEqual(720, MonitorLayout.Pixels(720, 1.0));
        Assert.AreEqual(1080, MonitorLayout.Pixels(720, 1.5));
        Assert.AreEqual(1.5, MonitorLayout.ScaleOf(144));
        Assert.AreEqual(1.0, MonitorLayout.ScaleOf(96));
        // 拿不到 DPI 时按 100% 算，不要算出 0。
        Assert.AreEqual(1.0, MonitorLayout.ScaleOf(0));
    }

    [TestMethod]
    public void OverlayIsCenteredAndSitsOneFifthDown()
    {
        var rect = MonitorLayout.Overlay(Primary, 1.0, 720, 520, 0.2);
        Assert.AreEqual(600, rect.X);
        Assert.AreEqual(208, rect.Y);
        Assert.AreEqual(720, rect.Width);
        Assert.AreEqual(520, rect.Height);

        // 150% 屏：像素翻倍，居中位置也跟着变；矩形不能超出工作区。
        var scaled = MonitorLayout.Overlay(Primary, 1.5, 720, 520, 0.2);
        Assert.AreEqual(1080, scaled.Width);
        Assert.AreEqual(780, scaled.Height);
        Assert.AreEqual(420, scaled.X);
        Assert.IsTrue(scaled.Right <= Primary.Right);
        Assert.IsTrue(scaled.Bottom <= Primary.Bottom);
    }

    [TestMethod]
    public void NoticeIsCenteredAtTheTop()
    {
        var rect = MonitorLayout.Notice(Primary, 1.0, 460, 64, 12);
        Assert.AreEqual((1920 - 460) / 2, rect.X);
        Assert.AreEqual(12, rect.Y);
        Assert.AreEqual(64, rect.Height);

        var scaled = MonitorLayout.Notice(Primary, 1.5, 460, 64, 12);
        Assert.AreEqual(690, scaled.Width);
        Assert.AreEqual(96, scaled.Height);
        Assert.AreEqual(18, scaled.Y);
    }

    [TestMethod]
    public void NegativeAndPortraitMonitorsKeepContentInside()
    {
        // 副屏在左边：坐标是负的，居中不能按 0 夹。
        var left = new WorkArea(-1920, 0, 0, 1040);
        var rect = MonitorLayout.Overlay(left, 1.5, 720, 520, 0.2);
        Assert.AreEqual(-1500, rect.X);
        Assert.IsTrue(rect.X >= left.Left);
        Assert.IsTrue(rect.Right <= left.Right);

        // 副屏竖放：工作区高大于宽，轻提示仍然居中、贴顶。
        var portrait = new WorkArea(1920, 0, 3000, 1920);
        var notice = MonitorLayout.Notice(portrait, 1.25, 460, 64, 12);
        Assert.AreEqual(1920 + (1080 - 575) / 2, notice.X);
        Assert.AreEqual(15, notice.Y);
        Assert.IsTrue(notice.Right <= portrait.Right);
    }

    [TestMethod]
    public void NearPointerFlipsWhenItDoesNotFit()
    {
        var right = MonitorLayout.NearPointer(100, 100, Primary, 1.0, 460, 320);
        Assert.AreEqual(112, right.X);
        Assert.AreEqual(112, right.Y);

        // 右下都放不下：翻到鼠标左边和上边。
        var flipped = MonitorLayout.NearPointer(1900, 1030, Primary, 1.0, 460, 320);
        Assert.AreEqual(1900 - 460 - 12, flipped.X);
        Assert.AreEqual(1030 - 320 - 12, flipped.Y);
        Assert.IsTrue(flipped.Right <= Primary.Right);
        Assert.IsTrue(flipped.Bottom <= Primary.Bottom);
    }

    [TestMethod]
    public void ClampKeepsWindowInsideNegativeMonitor()
    {
        // 副屏在主屏左边：工作区是负坐标，浮层也不能跑到主屏上。
        var left = new WorkArea(-2560, -200, 0, 1240);
        var rect = MonitorLayout.Overlay(left, 1.5, 720, 520, 0.2);
        Assert.IsTrue(rect.X >= left.Left);
        Assert.IsTrue(rect.Right <= left.Right);
        Assert.IsTrue(rect.Y >= left.Top);
    }
}

[TestClass]
public sealed class SchemaMigrationTests
{
    private sealed class FakeExecutor : ISchemaExecutor
    {
        public List<string> Log { get; } = new();

        public int Version { get; private set; }

        public int FailOnVersion { get; set; } = -1;

        public void Execute(string sql)
        {
            Log.Add(sql);
            if (FailOnVersion == 2 && sql.Contains("launcher_usage", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("故意失败");
            }
        }

        public void SetVersion(int version)
        {
            Version = version;
            Log.Add($"user_version={version}");
        }
    }

    [TestMethod]
    public void FreshDatabaseRunsEveryStepInOrder()
    {
        var executor = new FakeExecutor();
        Assert.AreEqual(Schema.Steps.Count, Schema.Migrate(executor));
        Assert.AreEqual(Schema.CurrentVersion, executor.Version);

        var versions = executor.Log.Where(entry => entry.StartsWith("user_version=", StringComparison.Ordinal)).ToList();
        Assert.AreEqual($"user_version={Schema.CurrentVersion}", versions[^1]);
        CollectionAssert.AreEqual(
            Schema.Steps.Select(step => $"user_version={step.Version}").ToArray(),
            versions.ToArray());
    }

    [TestMethod]
    public void UpToDateDatabaseRunsNothing()
    {
        var executor = new FakeExecutor();
        executor.SetVersion(Schema.CurrentVersion);
        executor.Log.Clear();
        Assert.AreEqual(0, Schema.Migrate(executor));
        Assert.AreEqual(0, executor.Log.Count);
    }

    [TestMethod]
    public void OlderDatabaseOnlyRunsTheNewerSteps()
    {
        // 第一版停在 1 的库：补跑 2 之后的所有步骤（第二版的启动器、第三版的翻译历史 / 片段列）。
        CollectionAssert.AreEqual(
            Schema.Steps.Where(step => step.Version > 1 && step.Version <= Schema.CurrentVersion)
                .Select(step => step.Version).ToArray(),
            Schema.Pending(1).Select(step => step.Version).ToArray());
        Assert.AreEqual(0, Schema.Pending(0).Count(step => step.Version < 1));
    }

    [TestMethod]
    public void NewerDatabaseIsLeftAlone()
    {
        // 用户装过更新的版本（库比代码新）：一步都不跑，也不报错。
        Assert.AreEqual(0, Schema.Pending(Schema.CurrentVersion + 5).Count);
    }

    [TestMethod]
    public void FailedStepRollsBackAndKeepsOldVersion()
    {
        var executor = new FakeExecutor { FailOnVersion = 2 };
        Assert.ThrowsExactly<InvalidOperationException>(() => Schema.Migrate(executor));
        Assert.AreEqual(1, executor.Version);
        Assert.IsTrue(executor.Log.Contains("ROLLBACK;"));
        // 1 的那一步已经提交过了，重跑时不会再跑。
        CollectionAssert.AreEqual(
            Schema.Steps.Where(step => step.Version > 1 && step.Version <= Schema.CurrentVersion)
                .Select(step => step.Version).ToArray(),
            Schema.Pending(executor.Version).Select(step => step.Version).ToArray());
    }

    [TestMethod]
    public void EveryStepIsIdempotent()
    {
        foreach (var step in Schema.Steps)
        {
            var sql = step.Sql;
            var creates = sql.Split("CREATE ", StringSplitOptions.RemoveEmptyEntries)
                .Where(part => part.StartsWith("TABLE", StringComparison.OrdinalIgnoreCase) ||
                               part.StartsWith("INDEX", StringComparison.OrdinalIgnoreCase))
                .ToList();
            Assert.IsTrue(creates.Count > 0 || sql.Contains("ADD COLUMN", StringComparison.OrdinalIgnoreCase),
                step.Description);
            Assert.IsTrue(
                creates.All(part => part.Contains("IF NOT EXISTS", StringComparison.OrdinalIgnoreCase)),
                $"{step.Description} 的每一步都要幂等");
            // 加列的步骤只加一次：同一列不能在这个步骤里出现两次（迁移只会跑一次，重跑会报 duplicate column）。
            var added = sql.Split("ADD COLUMN", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Skip(1)
                .Select(part => part.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault())
                .Where(name => name is not null)
                .ToList();
            Assert.AreEqual(added.Count, added.Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                $"{step.Description} 有重复的列");
        }
    }
}

[TestClass]
public sealed class AccentRampTests
{
    [TestMethod]
    public void LightStepsDoNotWashOutToWhite()
    {
        // 品牌粉 #FF4D7E 的 Light3：以前每个通道 +92 直接变成接近白色。
        var light3 = AccentRamp.Scale(new AccentRamp.Rgb(0xFF, 0x4D, 0x7E), 0.45);
        Assert.AreNotEqual(255, light3.G);
        Assert.AreNotEqual(255, light3.B);
        Assert.IsTrue(light3.G < 240 && light3.B < 245);

        // 还是粉色：红最高、绿最低，色相没跑。
        Assert.IsTrue(light3.R >= light3.B && light3.B > light3.G);
    }

    [TestMethod]
    public void DarkStepsKeepHue()
    {
        var dark3 = AccentRamp.Scale(new AccentRamp.Rgb(0xFF, 0x4D, 0x7E), -0.45);
        Assert.IsTrue(dark3.R > dark3.G && dark3.R > dark3.B);
        Assert.IsTrue(dark3.R < 0xFF);
    }

    [TestMethod]
    public void GrayscaleAndExtremesStayPut()
    {
        Assert.AreEqual(new AccentRamp.Rgb(255, 255, 255), AccentRamp.Scale(new AccentRamp.Rgb(255, 255, 255), 0.45));
        Assert.AreEqual(new AccentRamp.Rgb(0, 0, 0), AccentRamp.Scale(new AccentRamp.Rgb(0, 0, 0), -0.45));
        var gray = new AccentRamp.Rgb(128, 128, 128);
        var scaled = AccentRamp.Scale(gray, 0.2);
        Assert.AreEqual(scaled.R, scaled.G);
        Assert.AreEqual(scaled.G, scaled.B);
    }
}

[TestClass]
public sealed class StartMenuFilterTests
{
    [TestMethod]
    public void UninstallEntriesAreNotApps()
    {
        Assert.IsTrue(StartMenuFilter.ShouldSkip("卸载 Foo"));
        Assert.IsTrue(StartMenuFilter.ShouldSkip("Uninstall Bar"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\unins000.exe"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\Uninstall.exe"));
    }

    [TestMethod]
    public void DocsAndWebShortcutsAreNotApps()
    {
        Assert.IsTrue(StartMenuFilter.ShouldSkip("Foo 帮助文档"));
        Assert.IsTrue(StartMenuFilter.ShouldSkip("Release Notes"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\readme.txt"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget("https://example.com"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\manual.pdf"));
        Assert.IsTrue(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\website.url"));
    }

    [TestMethod]
    public void RealAppsStay()
    {
        Assert.IsFalse(StartMenuFilter.ShouldSkip("Visual Studio Code"));
        Assert.IsFalse(StartMenuFilter.ShouldSkip("计算器"));
        Assert.IsFalse(StartMenuFilter.ShouldSkip("微信"));
        Assert.IsFalse(StartMenuFilter.ShouldSkipTarget(@"C:\Users\yy\AppData\Local\Programs\Code\Code.exe"));
        Assert.IsFalse(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo\Foo.exe"));
        // 解析不到目标（空）时不拦，按名字那边已经过滤过一遍了。
        Assert.IsFalse(StartMenuFilter.ShouldSkipTarget(string.Empty));
        // 目录 / 无扩展名的启动项不按扩展名拦。
        Assert.IsFalse(StartMenuFilter.ShouldSkipTarget(@"C:\Program Files\Foo"));
    }
}

[TestClass]
public sealed class MotionCurveTests
{
    [TestMethod]
    public void ParametersMatchTheMacTable()
    {
        Assert.IsNull(MotionCurves.Of(MotionCurve.Instant));
        Assert.AreEqual(new SpringSpec(0.16, 0.15), MotionCurves.Of(MotionCurve.Snap));
        Assert.AreEqual(new SpringSpec(0.26, 0.10), MotionCurves.Of(MotionCurve.Glide));
        Assert.AreEqual(new SpringSpec(0.24, 0), MotionCurves.Of(MotionCurve.Settle));
        Assert.AreEqual(new SpringSpec(0.32, 0.25), MotionCurves.Of(MotionCurve.Pop));
        Assert.AreEqual(new SpringSpec(0.42, 0.22), MotionCurves.Of(MotionCurve.Island));
        Assert.AreEqual(new SpringSpec(0.34, 0), MotionCurves.Of(MotionCurve.Retract));
    }

    [TestMethod]
    public void DampingRatioAndPeriodFollowComposition()
    {
        var pop = MotionCurves.Of(MotionCurve.Pop)!.Value;
        Assert.AreEqual(1 - 0.25, pop.DampingRatio, 1e-9);
        Assert.AreEqual(TimeSpan.FromSeconds(0.32), pop.Period);
        var settle = MotionCurves.Of(MotionCurve.Settle)!.Value;
        Assert.AreEqual(1.0, settle.DampingRatio, 1e-9);
    }

    [TestMethod]
    public void ReducedMotionKeepsOnlyFades()
    {
        // snap / glide 减弱动画时不做；其余退成 0.2 s 淡入淡出（调用方只动透明度）。
        Assert.IsNull(MotionCurves.Effective(MotionCurve.Snap, reduced: true));
        Assert.IsNull(MotionCurves.Effective(MotionCurve.Glide, reduced: true));
        Assert.IsNull(MotionCurves.Effective(MotionCurve.Instant, reduced: false));
        Assert.IsNull(MotionCurves.Effective(MotionCurve.Settle, reduced: true));
        Assert.IsNull(MotionCurves.Effective(MotionCurve.Pop, reduced: true));
        Assert.IsNotNull(MotionCurves.Effective(MotionCurve.Settle, reduced: false));
        Assert.IsNotNull(MotionCurves.Effective(MotionCurve.Snap, reduced: false));
        Assert.IsFalse(MotionCurves.RunsWhenReduced(MotionCurve.Glide));
        Assert.IsTrue(MotionCurves.RunsWhenReduced(MotionCurve.Island));
    }
}

[TestClass]
public sealed class UndoStackTests
{
    private sealed class Item
    {
        public Item(long id)
        {
            Id = id;
        }

        public long Id { get; }

        public long CopiedAt { get; set; }
    }

    [TestMethod]
    public void TakesTheEntryOutOfItsBatch()
    {
        var batches = new List<List<Item>>
        {
            new() { new Item(1), new Item(2) },
            new() { new Item(3) },
        };

        var taken = UndoStack.Take(batches, item => item.Id == 2);
        Assert.IsNotNull(taken);
        Assert.AreEqual(2L, taken.Id);
        Assert.AreEqual(2, batches.Count);
        Assert.AreEqual(1, batches[0].Count);
        Assert.AreEqual(1, batches[0][0].Id);
    }

    [TestMethod]
    public void EmptiedBatchIsDropped()
    {
        var batches = new List<List<Item>> { new() { new Item(7) } };
        Assert.AreEqual(7L, UndoStack.Take(batches, item => item.Id == 7)?.Id);
        Assert.AreEqual(0, batches.Count);
        // 撤销栈空了就等于没有可撤销的，再拿一次是 null。
        Assert.IsNull(UndoStack.Take(batches, _ => true));
    }

    [TestMethod]
    public void MissingEntryReturnsNullAndLeavesTheStackAlone()
    {
        var batches = new List<List<Item>> { new() { new Item(1) } };
        Assert.IsNull(UndoStack.Take(batches, item => item.Id == 99));
        Assert.AreEqual(1, batches.Count);
        Assert.AreEqual(1, batches[0].Count);
    }

    [TestMethod]
    public void ReclaimedEntryGoesBackToTheFront()
    {
        // 面板列表：删掉的 5 还在撤销栈里，列表里剩 9、8。
        var items = new List<Item> { new(9), new(8) };
        var batches = new List<List<Item>> { new() { new Item(5) } };
        var entry = UndoStack.Take(batches, item => item.Id == 5);
        Assert.IsNotNull(entry);
        entry.CopiedAt = 1000;
        items.Insert(0, entry);
        CollectionAssert.AreEqual(new long[] { 5, 9, 8 }, items.Select(item => item.Id).ToArray());
        Assert.AreEqual(0, batches.Count);
    }
}
