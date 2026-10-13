// 示例便签（2026-10-13 手测反馈「一个便签都没有，右侧边是不是要给个默认的便签示例」）：这台电脑从没放过示例、便签库里
// 又一条都没有时，放一条讲怎么用的便签——屏幕边缘从一开始就有药丸可看、可点（PLAN §10「便签」拍板 B①「有了第一条
// 便签才出现」没变，只是第一条由我们放）。只放一次：放过没有记在偏好里（Prefs.notesSampleAdded，这台电脑自己的状态，
// 不注册默认值、不跟设置的导出走）；删掉之后不再出现，便签库「重新开始」换了新库也不再放。
// 库里已经有便签（哪怕只在归档、最近删除里）就只记「放过了」、不放。屏幕边缘的总开关关着时这次不放也不记：
// 示例讲的就是边缘那一叠，等开关打开、库还空着的那次启动再放。
// 启动时便签库开好之后调一次（AppDelegate.finishLaunchingNotes，在 NoteEdge 开始之前）。

import Foundation

enum NoteSample {
  /// 这次启动该做什么
  nonisolated enum Step: Equatable {
    /// 不放、也不记
    case skip
    /// 不放，记成放过了
    case mark
    /// 放一条，记成放过了
    case add
  }

  /// 该做什么（纯函数）。wasAdded：放过了；isDeckEnabled：屏幕边缘的总开关；count：库里一共几条（连归档、最近删除）
  nonisolated static func step(wasAdded: Bool, isDeckEnabled: Bool, count: Int) -> Step {
    if wasAdded { return .skip }
    if count > 0 { return .mark }
    return isDeckEnabled ? .add : .skip
  }

  /// 示例的正文（纯函数）。标题留空：第一行就是标题。edge：那一叠在屏幕哪条边；hotKey：「快速记一条」现在的快捷键
  /// （「⌥N」），没设键是 nil——那一行换成从菜单栏、启动器走
  static func body(edge: NoteDeckOptions.Edge, hotKey: String?) -> String {
    let capture =
      hotKey.map { "按 \($0) 随手记一条" }
      ?? "在菜单栏或启动器里选「\(HotKeyAction.noteCapture.title)」随手记"
    return """
      欢迎使用便签
      鼠标靠到屏幕\(edge.name)边缘，这一叠就会展开，点一张标签打开它。
      ☐ \(capture)
      ☐ 拖动标签调整顺序
      ☐ 点图钉固定，点别处时它也不收
      用不着这条了，点「⋯」里的「删除」。
      """
  }

  /// 便签库开好之后调：该放就放一条、该记就记。返回放没放
  @discardableResult
  static func addIfFirst(to store: NoteStore, defaults: UserDefaults, hotKey: String?) -> Bool {
    let options = NoteDeckOptions(defaults)
    let step = step(
      wasAdded: defaults.bool(forKey: Prefs.notesSampleAdded), isDeckEnabled: options.isEnabled,
      count: store.notes.count)
    guard step != .skip else { return false }
    if step == .add { store.create(body: body(edge: options.edge, hotKey: hotKey)) }
    defaults.set(true, forKey: Prefs.notesSampleAdded)
    return step == .add
  }
}
