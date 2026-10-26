// 晾衣绳（第十族，2026-10-26 拍板）的纯函数单测：排法（从两边往中间、中间给刘海岛留着、屏幕窄时挂得少、
// 最多 8 张）、绳子的下垂、卡片宽、菜单栏那一条、该不该滑下来 / 收起、面板的位置和坐标换算。
// 都是 ClotheslineLayout 里的纯函数，不建窗口、不碰偏好。

import AppKit
import Testing

@testable import KittyTools

struct ClotheslineTests {
  /// 一张 4:3 的图
  private let photo = CGSize(width: 1600, height: 1200)

  /// 排法（拍板 C2）：第 1 张最左、第 2 张最右、第 3 张挨着第 1 张……中间那一段谁都不占
  @Test func cardsHangFromBothEndsAndLeaveTheMiddleAlone() {
    let width: CGFloat = 1512
    let gap = ClotheslineLayout.gap(notch: nil)
    let plan = ClotheslineLayout.plan(Array(repeating: photo, count: 4), width: width, gap: gap)
    #expect(plan.cards.count == 4)
    // 一、三在左边（从左往右），二、四在右边（从右往左）
    #expect(plan.cards[0].minX == ClotheslineLayout.sideInset)
    #expect(plan.cards[2].minX > plan.cards[0].minX)
    #expect(plan.cards[1].maxX == width - ClotheslineLayout.sideInset)
    #expect(plan.cards[3].maxX < plan.cards[1].maxX)
    // 中间那一段（刘海岛的位置）空着
    let hole = CGRect(
      x: (width - gap) / 2, y: 0, width: gap, height: ClotheslineLayout.panelHeight)
    #expect(plan.cards.allSatisfy { !$0.intersects(hole) })
    // 绳子两段也在中间断开，两端顶着屏幕两边
    #expect(plan.ropes.count == 2)
    #expect(plan.ropes[0].from.x == 0 && plan.ropes[1].to.x == width)
    #expect(plan.ropes[1].from.x - plan.ropes[0].to.x == gap)
  }

  /// 刘海屏：中间让出来的那一段至少比刘海宽（两边各 12）
  @Test func gapClearsTheNotch() {
    #expect(ClotheslineLayout.gap(notch: nil) == ClotheslineLayout.minimumGap)
    let notch = CGRect(x: 600, y: 900, width: 260, height: 38)
    #expect(ClotheslineLayout.gap(notch: notch) == 284)
  }

  /// 最多 8 张；屏幕窄时按宽度减（拍板 B3），挂不下的不出现在排好的样子里
  @Test func capacityFollowsTheScreenWidth() {
    let gap = ClotheslineLayout.gap(notch: nil)
    let twelve = Array(repeating: photo, count: 12)
    #expect(
      ClotheslineLayout.fits(twelve, width: 3008, gap: gap) == ClotheslineLayout.maxCards)
    let narrow = ClotheslineLayout.fits(twelve, width: 1280, gap: gap)
    #expect(narrow > 0 && narrow < ClotheslineLayout.maxCards)
    // 太窄了（整块屏比中间那一段还小）：一张都挂不上，也不崩
    #expect(ClotheslineLayout.plan(twelve, width: 200, gap: gap).cards.isEmpty)
  }

  /// 长截图这种细长的也只占一张卡片的宽（夹在 cardWidths 里），不会把绳子占满
  @Test func cardWidthFollowsTheImageButIsClamped() {
    #expect(ClotheslineLayout.width(of: photo) == (ClotheslineLayout.cardHeight * 4 / 3).rounded())
    #expect(
      ClotheslineLayout.width(of: CGSize(width: 1200, height: 9000))
        == ClotheslineLayout.cardWidths.lowerBound)
    #expect(
      ClotheslineLayout.width(of: CGSize(width: 5000, height: 300))
        == ClotheslineLayout.cardWidths.upperBound)
    #expect(ClotheslineLayout.width(of: .zero) == ClotheslineLayout.cardHeight)
  }

  /// 绳子两端固定、中间垂 sag
  @Test func ropeSagsInTheMiddle() {
    #expect(ClotheslineLayout.drop(x: 0, from: 0, to: 600) == 0)
    #expect(ClotheslineLayout.drop(x: 600, from: 0, to: 600) == 0)
    #expect(ClotheslineLayout.drop(x: 300, from: 0, to: 600) == ClotheslineLayout.sag)
    // 卡片跟着绳子垂下来：靠中间那张比靠边那张低
    let plan = ClotheslineLayout.plan(
      Array(repeating: photo, count: 4), width: 1512, gap: ClotheslineLayout.gap(notch: nil))
    #expect(plan.cards[2].minY > plan.cards[0].minY)
  }

  /// 菜单栏那一条：量得到菜单栏就是它；菜单栏自动隐藏时 visible 顶到屏幕顶边，这时按菜单栏的高往下让
  /// （面板比菜单栏高一层，贴着顶边摆会把露出来的菜单栏盖住）
  @Test func triggerStripIsTheMenuBar() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 32, width: 1512, height: 912)
    let strip = ClotheslineLayout.strip(screen: screen, visible: visible, menuBar: 24)
    #expect(strip == CGRect(x: 0, y: 944, width: 1512, height: 38))
    #expect(ClotheslineLayout.top(screen: screen, visible: visible, menuBar: 24) == 944)
    // 自动隐藏：按菜单栏的高让出 24 点
    let hidden = ClotheslineLayout.strip(screen: screen, visible: screen, menuBar: 24)
    #expect(hidden == CGRect(x: 0, y: 958, width: 1512, height: 24))
  }

  /// 停在菜单栏那一条上才滑下来；刘海那一块不算（那是刘海岛的）
  @Test func showsOnTheMenuBarButNotOnTheNotch() {
    let strip = CGRect(x: 0, y: 944, width: 1512, height: 38)
    let notch = CGRect(x: 656, y: 944, width: 200, height: 38)
    #expect(
      ClotheslineLayout.wantsShow(mouse: CGPoint(x: 100, y: 960), strip: strip, notch: notch))
    #expect(
      !ClotheslineLayout.wantsShow(mouse: CGPoint(x: 756, y: 960), strip: strip, notch: notch))
    #expect(
      !ClotheslineLayout.wantsShow(mouse: CGPoint(x: 100, y: 900), strip: strip, notch: notch))
    // 没有刘海的屏：整条都算
    #expect(ClotheslineLayout.wantsShow(mouse: CGPoint(x: 756, y: 960), strip: strip, notch: nil))
  }

  /// 收不收：在面板上、还在菜单栏那一条上都算在这儿；离开满 0.4 秒才收
  @Test func keepsOpenNearTheRopeThenLingers() {
    let panel = CGRect(x: 0, y: 800, width: 1512, height: 140)
    let strip = CGRect(x: 0, y: 944, width: 1512, height: 38)
    #expect(ClotheslineLayout.keepsOpen(mouse: CGPoint(x: 10, y: 900), panel: panel, strip: strip))
    #expect(ClotheslineLayout.keepsOpen(mouse: CGPoint(x: 10, y: 960), panel: panel, strip: strip))
    // 面板和那一条之间没有缝（面板紧贴菜单栏下沿），底下远一点就算离开了
    #expect(!ClotheslineLayout.keepsOpen(mouse: CGPoint(x: 10, y: 700), panel: panel, strip: strip))
    // #expect 里不能调 mutating 的方法（宏展开后那份是不可变的），先算出来再看
    var linger = ClotheslineLayout.Linger()
    var hides = [
      linger.update(inside: true, now: 100), linger.update(inside: false, now: 100),
      linger.update(inside: false, now: 100.3), linger.update(inside: false, now: 100.4),
    ]
    #expect(hides == [false, false, false, true])
    // 回来了就重新算
    linger = ClotheslineLayout.Linger()
    hides = [
      linger.update(inside: false, now: 200), linger.update(inside: true, now: 200.5),
      linger.update(inside: false, now: 200.5), linger.update(inside: false, now: 200.8),
    ]
    #expect(hides == [false, false, false, false])
  }

  /// 右键菜单（拍板 C3 D2）：截图是常驻缩略图那一整套 + 改标注，末尾「取下」「从历史里删掉」各一节；
  /// 存过的才有「在访达中显示」；录制的那几条没有图，只有拷贝 / 打开 / 在访达中显示
  @Test func cardMenu() {
    let shot = ShotHistory.Item(
      id: UUID(), kind: .shot, createdAt: .now, pixelSize: CGSize(width: 800, height: 600),
      scale: 2)
    #expect(
      ClotheslineModel.menu(for: shot, screenshotOn: true) == [
        [.edit, .copy, .save, .pin, .history], [.unpeg], [.forget],
      ])
    var saved = shot
    saved.savedPath = "/tmp/截图.png"
    #expect(
      ClotheslineModel.menu(for: saved, screenshotOn: true) == [
        [.edit, .copy, .save, .pin, .reveal, .history], [.unpeg], [.forget],
      ])
    var video = shot
    video.kind = .video
    video.filePath = "/tmp/录屏.mp4"
    #expect(
      ClotheslineModel.menu(for: video, screenshotOn: true) == [
        [.copy, .open, .reveal, .history], [.unpeg], [.forget],
      ])
    // 名字：同一个动作全 App 一个叫法
    #expect(
      ClotheslineModel.menu(for: shot, screenshotOn: true).flatMap { $0 }.map(\.title) == [
        "改标注", "拷贝", "存储", "钉图", "在历史里看", "取下", "从历史里删掉",
      ])
  }

  /// 旧的「留不留常驻缩略图」升成「截完图放哪」三选一（拍板 B1）：关过它的人是「都不要」，
  /// 没存过（= 开着）照常是角落的缩略图；新键已经有值就不动它
  @Test func placementUpgradesFromTheOldToggle() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    Prefs.migrate(defaults, domainName: suite)
    #expect(Prefs.ShotPlacement.current(defaults) == .corner)

    defaults.set(false, forKey: Prefs.screenshotShelfLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(Prefs.ShotPlacement.current(defaults) == Prefs.ShotPlacement.none)

    defaults.set(Prefs.ShotPlacement.clothesline.rawValue, forKey: Prefs.screenshotPlacement)
    Prefs.migrate(defaults, domainName: suite)
    #expect(Prefs.ShotPlacement.current(defaults) == .clothesline)
    // 认不出来的值按默认的角落
    defaults.set("什么", forKey: Prefs.screenshotPlacement)
    #expect(Prefs.ShotPlacement.current(defaults) == .corner)
  }

  /// 绳子只是历史的一个视图（拍板 B2）：历史里删掉的跟着没，取下只去掉「挂着」这一笔、历史不动
  @MainActor @Test func pegsFollowTheHistory() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-clothesline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try ShotHistory(
      db: Database(path: ":memory:"), directory: root.appending(path: "shots"))
    let items = (0..<3).map {
      ShotHistory.Item(
        id: UUID(), kind: .shot, createdAt: Date.now.addingTimeInterval(Double($0)),
        pixelSize: CGSize(width: 800, height: 600), scale: 2)
    }
    history.seed(items)
    let model = ClotheslineModel(history: history)
    model.setPegged(items.map(\.id))
    #expect(model.items.map(\.id) == items.map(\.id))
    history.remove([items[1].id])
    #expect(model.items.map(\.id) == [items[0].id, items[2].id])
    model.setPegged([items[0].id])
    #expect(!model.isEmpty && model.items.count == 1)
    // 历史里那条还在
    #expect(history.items.contains { $0.id == items[2].id })
  }

  /// 面板贴在菜单栏下沿、铺满这块屏；卡片的面板内坐标换成屏幕坐标
  @Test func panelSitsUnderTheMenuBar() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 32, width: 1512, height: 912)
    let top = ClotheslineLayout.top(screen: screen, visible: visible, menuBar: 24)
    let panel = CGRect(
      x: screen.minX, y: top - ClotheslineLayout.panelHeight, width: screen.width,
      height: ClotheslineLayout.panelHeight)
    #expect(panel.maxY == visible.maxY)  // 不盖菜单栏
    let card = CGRect(x: 16, y: 30, width: 123, height: 92)
    let onScreen = Clothesline.screenRect(card, in: panel)
    #expect(onScreen.minX == 16)
    #expect(onScreen.maxY == panel.maxY - 30)
    #expect(onScreen.size == card.size)
  }
}
