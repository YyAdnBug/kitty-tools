// PLAN-v22：折叠的翻译服务不自动翻译、点开才翻；设置里标出免费的服务。期望值照 mac 的 collapsedServicesTranslateOnExpand、
// orderedServicesPutCollapsedLast、FreeServicesTests。会话级那条用一个最小的假会话：卡的状态只按 TranslateSession 的规则走
// （TranslateCoordinator 里同样只问这几个函数），「请求」记进一张表，看哪些服务被请求了几次。
using KittyTools.Core;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KittyTools.Tests;

[TestClass]
public sealed class PlanV22Tests
{
    [TestMethod]
    public void PrimarySkipsIdleAndOpenedCards()
    {
        static int Pick(params (CardState, string, bool)[] cards) => TranslateSession.Primary(cards);

        // 没翻的折叠卡排第一：不挡着等，主结果是后面翻出来的
        Assert.AreEqual(1, Pick((CardState.Idle, "", false), (CardState.Done, "乙", false)));
        // 后面的还在跑：照旧等
        Assert.AreEqual(-1, Pick((CardState.Idle, "", false), (CardState.Running, "半", false)));
        // 点开后才翻的：翻完了也不认
        Assert.AreEqual(1, Pick((CardState.Done, "甲", true), (CardState.Done, "乙", false)));
        Assert.AreEqual(-1, Pick((CardState.Done, "甲", true), (CardState.Idle, "", false)));
        // 全部折叠：没有主结果
        Assert.AreEqual(-1, Pick((CardState.Idle, "", false), (CardState.Idle, "", false)));
    }

    [TestMethod]
    public void OrderedPutsCollapsedLast()
    {
        var services = new[] { "a", "b", "c", "d" };
        CollectionAssert.AreEqual(new[] { "b", "d", "a", "c" },
            TranslateSession.Ordered(services, id => id, new HashSet<string> { "a", "c" }));
        CollectionAssert.AreEqual(services, TranslateSession.Ordered(services, id => id, new HashSet<string>()));
        CollectionAssert.AreEqual(services, TranslateSession.Ordered(services, id => id, new HashSet<string>(services)));
        // 偏好里有已经删掉的服务：不影响
        CollectionAssert.AreEqual(new[] { "b", "a" }, TranslateSession.Ordered(new[] { "a", "b" }, id => id, new HashSet<string> { "a", "gone" }));
    }

    [TestMethod]
    public void CollapsedServicesTranslateOnExpand()
    {
        var session = new FakeSession(new[] { "deep", "zhipu", "ms" });
        var collapsed = new HashSet<string> { "deep" };

        // 开会话：只请求没折叠的
        session.Start("hello", collapsed);
        CollectionAssert.AreEqual(new[] { "zhipu", "ms" }, session.Requests);
        Assert.AreEqual(CardState.Idle, session.State("deep"));
        session.FinishAll();
        Assert.AreEqual("zhipu", session.Primary(), "折叠卡排第一也不挡主结果");

        // 点开：现在才翻，翻完也不当主结果
        collapsed.Remove("deep");
        session.Expand("deep");
        CollectionAssert.AreEqual(new[] { "zhipu", "ms", "deep" }, session.Requests);
        session.FinishAll();
        Assert.AreEqual("zhipu", session.Primary());

        // 再折叠、再点开：不重复请求
        collapsed.Add("deep");
        collapsed.Remove("deep");
        session.Expand("deep");
        Assert.AreEqual(3, session.Requests.Count);

        // 换原文：折叠的回到没翻
        collapsed.Add("deep");
        session.Start("world", collapsed);
        Assert.AreEqual(CardState.Idle, session.State("deep"));
        Assert.AreEqual(5, session.Requests.Count);

        // 生成中被取消（Esc 收起），再打开输入翻译：没折叠的重跑，折叠的回到没翻、不跑
        session.Cancel();
        session.Resume(collapsed);
        Assert.AreEqual(CardState.Idle, session.State("deep"));
        CollectionAssert.AreEqual(new[] { "zhipu", "ms" }, session.Requests.Skip(5).ToList());

        // 全部折叠：一个请求都不发、没有主结果
        session.Start("again", new HashSet<string> { "deep", "zhipu", "ms" });
        Assert.AreEqual(7, session.Requests.Count);
        Assert.IsNull(session.Primary());
    }

    [TestMethod]
    public void FreeKinds()
    {
        Assert.IsTrue(TranslateSession.IsFreeKind("zhipu"));
        Assert.IsTrue(TranslateSession.IsFreeKind("microsoft"));
        Assert.IsTrue(TranslateSession.IsFreeKind("youdaoDict"));
        Assert.IsFalse(TranslateSession.IsFreeKind("deepl"));
        Assert.IsFalse(TranslateSession.IsFreeKind("ai"));
        Assert.IsTrue(TranslateSession.ShowsFree("microsoft", hasOwnKey: false));
        Assert.IsFalse(TranslateSession.ShowsFree("microsoft", hasOwnKey: true));
        Assert.IsTrue(TranslateSession.ShowsFree("zhipu", hasOwnKey: true));
        Assert.IsFalse(TranslateSession.ShowsFree("google", hasOwnKey: false));
    }

    /// <summary>照 TranslateCoordinator 的 Start / Expand / Cancel / ResumeInput，只留卡的状态和「请求了谁」。</summary>
    private sealed class FakeSession(string[] services)
    {
        private readonly List<(string Id, CardState State, bool Opened)> _cards = new();

        public List<string> Requests { get; } = new();

        public CardState State(string id) => _cards.First(card => card.Id == id).State;

        public void Start(string text, ISet<string> collapsed)
        {
            _cards.Clear();
            _cards.AddRange(services.Select(id => (id, TranslateSession.StartState(collapsed.Contains(id)), false)));
            foreach (var card in _cards.Where(card => card.State != CardState.Idle))
            {
                Requests.Add(card.Id);
            }
        }

        public void Expand(string id)
        {
            var index = _cards.FindIndex(card => card.Id == id);
            if (!TranslateSession.ExpandRuns(_cards[index].State))
            {
                return;
            }

            _cards[index] = (id, CardState.Waiting, true);
            Requests.Add(id);
        }

        public void FinishAll()
        {
            for (var index = 0; index < _cards.Count; index++)
            {
                if (_cards[index].State is CardState.Waiting or CardState.Running)
                {
                    _cards[index] = _cards[index] with { State = CardState.Done };
                }
            }
        }

        public void Cancel()
        {
            for (var index = 0; index < _cards.Count; index++)
            {
                if (_cards[index].State is CardState.Waiting or CardState.Running)
                {
                    _cards[index] = _cards[index] with { State = CardState.Failed };
                }
            }
        }

        public void Resume(ISet<string> collapsed)
        {
            for (var index = 0; index < _cards.Count; index++)
            {
                var card = _cards[index];
                if (TranslateSession.ResumeState(card.State, interrupted: true, collapsed.Contains(card.Id)) is not { } next)
                {
                    continue;
                }

                _cards[index] = card with { State = next };
                if (next != CardState.Idle)
                {
                    Requests.Add(card.Id);
                }
            }
        }

        public string? Primary()
        {
            var index = TranslateSession.Primary(_cards.Select(card => (card.State, card.State == CardState.Done ? "译文" : "", card.Opened)).ToList());
            return index >= 0 ? _cards[index].Id : null;
        }
    }
}
