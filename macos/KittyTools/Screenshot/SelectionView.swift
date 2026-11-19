// 框选遮罩里一块屏幕的画面与交互（会话见 RegionSelector）。从下到上：冻结帧（本视图图层的内容）→ 标注层
// （AnnotationCanvas，只重画变了的那块）→ 暗色蒙层、选区边框、吸附参考线、手柄、放大镜（CALayer，拖动时只改路径和位置，
// 不重画整屏）→ 尺寸胶囊（SizeField）→ 文字输入框 → 工具栏、样式托盘、HUD 菜单（EditorToolbar.swift）。外观是 Whisker §6
// 截图的品牌粉。框选、拖边：⇧ 锁比例（新框正方形，或按锁着的比例）、⌥ 从中心、空格平移、⌃ 暂停吸附（6 pt 内吸到冻结时的
// 窗口边和屏幕边，吸上时画粉色虚线参考线），拖动中按下 / 松开修饰键立刻重算。
// 截图翻译 / 识字：拖动框选、松手即确认（同样的放大镜、修饰键和吸附）。截图：悬停窗口（洞和粉框磁吸变形、显示窗口尺寸；
// 认元素时是窗口里指针下最小的那一层，滚轮往上大一层、往下小一层，Tab 只认窗口，见 hoverStack）、单击选中悬停的那块，
// 拖出或单击后进入调整：整条边和四角都能拖（悬停的边加粗、手柄放大）、拖动平移、方向键微调（⇧ 10 点）、
// ⌘ / ⌥ + 方向键推 / 收那条边；尺寸胶囊点数字输入像素宽高、比例菜单锁比例；右键没有标注时回到待选，有标注时只提示；
// 放大镜显示中心像素的色值（C 复制），按住 ⌘ 出整屏十字准线；S 长截图、T 钉图、O 识字；
// 标注 1–0（矩形、椭圆、箭头、直线、画笔、荧光笔、文字、序号、打码（模糊 / 像素）、聚光灯，⇧ 画正方形 / 45° 线，再按一次收起；
// 序号单击放、画笔一路累点），画完自动选中（工具保持）：粉色虚线框 + 手柄，拖手柄改大小（矩形类四角 + 边中点；⇧ 约束、⌥ 从中心）、拖箭头中间的手柄弯曲
// （⇧ 对称、拖回弦上拉直、双击拉直）、拖本体移动（⇧ 锁轴）、⌥ 拖动复制、⌘D 复制、改颜色粗细、⌫ 删除、双击文字重新编辑，
// ⌘Z 撤销、⇧⌘Z 重做（拖着标注时这几个键不响应）。
// 录屏（录屏第 1 批）：悬停、单击窗口 / 整屏、拖框、调整、尺寸胶囊、D、放大镜都同截图，没有标注和出图键；调整时选区下方是
// 录制条 [系统声音][麦克风][显示点按][显示按键] ｜ [取消][● 开始录制]（开关第 4 批，显示按键是手测反馈第 2 批），
// ↩ / 双击选区 / 点 ● 交回选区（短边不到 64 pt 只提示）。截图调整时按 R / 点工具栏「录屏」切过来（录屏第 2 批）：工具栏原地换成录制条、选区不变；有标注时不切，只提示。
// 旁白（Whisker §7）：遮罩整块是一个分组，标签读状态（待选 / 选区像素尺寸、当前工具、锁着的比例），顶部提示是帮助；
// 进入调整、换工具、锁比例时主动播报（取色后的「已复制色值」由刘海岛播报）。
// 这个文件留状态、存储属性和几个小类型；旁白、画面、工具栏、标注、文字、出图、鼠标、键盘拆在同目录的 SelectionView+*.swift（第五轮体检 H1）。

import AppKit
import Carbon.HIToolbox

final class SelectionView: NSView, NSTextViewDelegate {
  enum Mode {
    /// 截图翻译、识字：松手即确认
    case quick
    case capture
    /// 录屏：框选同截图，没有标注和出图
    case record
  }

  /// 冻结帧（原地翻译之后换成贴了译文的那张，所以不是 let）
  var image: CGImage
  /// 冻结那一刻的窗口（本屏视图坐标，从前到后）
  let windows: [CGRect]
  /// 和 windows 一一对应：悬停时问哪几个进程要窗口里的元素（按顺序，第一个问出东西的算：菜单栏那条先问前台 App、
  /// 再问控制中心）；空的 = 不认元素（单测、截图自检的默认）
  let owners: [[pid_t]]
  /// 和 windows 一一对应：窗口号（单击选中整扇窗口、出图时单独截它带透明圆角和阴影，WindowShot）；没有的 nil。
  /// 空的 = 都没有（单测、截图自检的默认）
  let windowIDs: [CGWindowID?]
  /// 单击选中的那扇窗口（第五轮体检 N1）：窗口号和当时的选区。选区之后再动过（拖边、挪、方向键）就和它对不上，
  /// 出图照旧按矩形裁
  var clickedWindow: (id: CGWindowID, frame: CGRect, index: Int)?
  let session: SelectionSession
  /// 截图工具栏「翻译」就地翻：给选区的图和它每点几个像素，返回覆盖了译文的图、放不下的段（失败带一句原因）。
  /// 由 AppDelegate 经 SelectionSession 注入；nil = 现在不能就地翻（退回原来的「退出截图页再翻」）
  var translateHandler: ((CGImage, CGFloat) async -> ScreenshotOverlay.Outcome)?
  /// 框完松手、单击选中就直接翻（⌥S：截图翻译 = 截图 + 自动点「翻译」，人还留在截图页）
  var autoTranslates: Bool { session.autoTranslates }
  /// 正在就地翻译：选区上出脉冲、框选和工具栏暂时不动
  var translating = false
  /// 一键打码正在识字（再点「自动」不重复跑）
  var redacting = false
  /// 托盘上点了吸管：下一下单击取放大镜中心的颜色（拍板 O10）；Esc 取消。设置里不显示色值时，取色期间色值卡照样出来
  var pickingColor = false {
    didSet { if pickingColor != oldValue { layOutMagnifier() } }
  }
  /// 正在跑的就地翻译（Esc / 换屏框选时取消：不然剩下的段会继续打翻译服务）
  var translateTask: Task<Void, Never>?
  /// 就地翻译之前的冻结帧，和译文贴在哪个选区上（2026-11-06 用户：翻完再框别处，上次的译文还留在「屏幕」上，像是
  /// 上一张截图贴在了屏幕里）。译文只属于翻的那个选区：选区一变（重新框、挪、拉边、D、右键回到待选）就换回原图
  var untranslated: (image: CGImage, selection: CGRect)?
  /// 就地翻译到字号下限也放不下的段：挂在选区外的译文卡片（2026-11-08 拍板 B1–B4）；选区一变、✕、Esc 收起
  var translationCard: TranslationCard?
  /// 贴了译文的那张冻结帧、现在图上是不是换回了原文在看（卡片上的「看原文」，第二轮 E1；不重新请求）
  var translated: CGImage?
  var showingOriginal = false
  /// 选区上的扫光（翻译中）：容器裁掉多余的部分，里面一条浅白渐变从左扫到右。
  /// 之前是整块白呼吸，白底窗口上几乎看不出来，改成扫光
  let translatingPulse = CALayer()
  let translatingBand = CAGradientLayer()
  /// 这一轮扫光要走的距离（选区宽 + 光带宽）：拖边改了宽度要按新距离重启动画
  var translatingSweep: CGFloat = 0
  var mode: SelectionView.Mode { session.mode }
  /// 截图、录屏：悬停窗口、单击选中、调整阶段（手柄、拖边、方向键、尺寸胶囊、比例）
  var adjusts: Bool { mode != .quick }
  /// 只有截图：标注、出图键（⌘C ⌘S ⇧⌘S T S O）、工具栏（录屏的 ↩ / 双击是开始录，见 confirm）
  var annotates: Bool { mode == .capture }

  /// 当前选区（点，视图坐标）；截图自检直接设它摆出各种状态
  var selection: CGRect? {
    didSet {
      annotationCanvas?.selection = selection
      // 选区一动（方向键、拖边）开着的 HUD 菜单就收起：它锚着的栏 / 胶囊跟着挪了
      if selection != oldValue { hudMenu?.dismiss() }
      // 有了选区，悬停停在哪一层就作废：回到待选时从最小那层重新来
      if selection != nil { stack = nil }
      // 译文贴在原来那个选区上：选区变了就换回原图，放不下的那张卡片也收起
      if let untranslated, selection != untranslated.selection { restoreUntranslated() }
      if let translationCard, selection != translationCard.selection { closeTranslationCard() }
      refresh()
    }
  }
  /// 截图：选区已确定，可以调整、标注、选输出方式
  var isAdjusting = false {
    didSet {
      if isAdjusting, !oldValue, let selection {
        announce(String(localized: "已选中 \(sizeText(selection))"))
      }
      refresh()
    }
  }
  /// 鼠标位置（悬停窗口、放大镜）；nil = 鼠标不在这块屏上。
  /// 只更新跟着鼠标走的那几样（悬停的洞和尺寸、手柄的悬停态、放大镜、十字）——整屏蒙层的底、选区描边、
  /// 工具栏、参考线和鼠标位置无关，没必要每帧都碰一遍图层（2026-10-26 用户手测「快速移动很卡」）
  var mouse: CGPoint? { didSet { refreshPointer() } }
  var drag: Drag? { didSet { refresh() } }
  /// 拖动框选途中按下空格：整块平移（系统截屏的习惯）。按下鼠标前就按着的不算（自动重复的按键也不算），
  /// 不然按着空格从选区外拖，会去平移旧选区而不是框新的
  var isSpaceDown = false
  /// 当前的修饰键（取自事件：flagsChanged、鼠标事件都带着，鼠标从别的屏移过来时也是准的）：⌘ 十字准线，
  /// ⇧ 锁比例、⌥ 从中心、⌃ 暂停吸附
  var modifiers: NSEvent.ModifierFlags = [] {
    didSet { if modifiers.contains(.command) != oldValue.contains(.command) { refresh() } }
  }
  /// 拖动中上一次的鼠标位置：按下 / 松开修饰键时按它重算
  var dragPoint: CGPoint?
  /// 吸上的边（x 竖线、y 横线），拖动时整屏画粉色虚线参考线；交互测试读它
  var guides: (x: CGFloat?, y: CGFloat?) = (nil, nil)

  // 标注（截图模式）。截图自检直接设它们摆出各种状态
  var annotations: [Annotation] = [] { didSet { syncAnnotations() } }
  var tool: Annotation.Tool? { didSet { refresh() } }
  var selectedAnnotation: UUID? { didSet { refresh() } }
  /// 新标注用的颜色和粗细
  var style = Annotation.Style()
  /// 正在拖出来的标注
  var draft: Annotation? { didSet { syncAnnotations() } }
  var undoStack: [[Annotation]] = []
  var redoStack: [[Annotation]] = []
  /// 正在输入的文字：输入框、改的是哪条标注（nil = 新建）、左上角、样式
  var editor: Editor?

  struct Editor {
    let field: EditorField
    /// 每个输入框自己的撤销记录（共用窗口的会串到已经收掉的输入框上）
    let undo = UndoManager()
    let id: UUID?
    let origin: CGPoint
    var style: Annotation.Style
  }

  enum Drag {
    /// 截图：按下还没拖开，松手算单击（截窗口 / 整屏）
    case pending(CGPoint)
    /// restore：调整时在选区外拖出新框之前的选区（新框太小算误触，恢复它）
    case draw(anchor: CGPoint, last: CGPoint, restore: CGRect? = nil)
    case move(start: CGPoint, original: CGRect)
    case resize(RegionSelector.Handle, original: CGRect)
    /// 用当前工具拖出新标注（画笔一路累点）
    case annotate(start: CGPoint)
    /// 拖动标注：original 是按下时的样子（⌥ 拖动时是刚复制出的那份、单击放的序号是刚放的那个）；before 是按下前的全部标注
    /// （松手时记一步撤销）；copyOf 是 ⌥ 复制的原件
    case moveAnnotation(Annotation, start: CGPoint, before: [Annotation], copyOf: UUID?)
    /// 拖选中标注的手柄改大小；offset 是按下时手柄离按下的点多远（线类两端、弯曲手柄：按在手柄边上一拖，手柄不先跳到光标上）
    case resizeAnnotation(Annotation, Annotation.Handle, before: [Annotation], offset: CGVector)
  }

  var annotationCanvas: AnnotationCanvas?
  /// 标注层下面的聚光灯压暗（偶奇填充：选区 + 洞，见 AnnotationCanvas）
  private let dimCanvas = Canvas()
  let spotlightDim = CAShapeLayer()
  private let canvas = Canvas()
  let shade = CAShapeLayer()
  let outline = CAShapeLayer()
  let highlight = CAShapeLayer()
  /// 8 个手柄各一层（依次弹出、悬停的那个放大）；按住的边 / 角加粗的粉线
  let handleLayers = Dictionary(
    uniqueKeysWithValues: RegionSelector.Handle.allCases.map { ($0, CAShapeLayer()) })
  let edgeHighlight = CAShapeLayer()
  /// 选中标注的 1 pt 粉色虚线框和手柄（白 9 pt 圆 + 1.5 pt 粉环）
  let annotationOutline = CAShapeLayer()
  let annotationHandles = CAShapeLayer()
  /// 选区双描边的外圈（内圈 1.5 pt 粉是 outline）
  let outlineOuter = CAShapeLayer()
  /// 按住 ⌘ 时穿过光标的十字准线：1 pt white 0.6 贴 1 pt black 0.25，亮底暗底都看得见
  let crossLight = CAShapeLayer()
  let crossDark = CAShapeLayer()
  /// 吸附参考线：1 pt 粉色虚线 [4, 3] 横穿整屏
  let guideLayer = CAShapeLayer()
  /// 选区（或悬停窗口）的像素尺寸；调整时可输入、可锁比例
  let sizeField = SizeField()
  let hint = HintPill(font: .systemFont(ofSize: 13), padding: CGSize(width: 14, height: 7))
  let magnifier = CALayer()
  let loupe = CALayer()
  private let loupeShadow = CALayer()
  let loupeGrid = CAShapeLayer()
  let loupeBands = CAShapeLayer()
  let loupeCenter = CAShapeLayer()
  private let infoCard = CALayer()
  let infoSwatch = CALayer()
  let infoText = CATextLayer()
  let infoKey = CATextLayer()
  var toolbar: EditorToolbar?
  var styleBar: StyleBar?
  /// 录屏的录制条（截图工具栏的位置）
  var recordBar: RecordBar?
  /// 开着的 HUD 菜单（同时最多一个）：Esc、点外面先收它
  var hudMenu: HUDMenu?
  /// 放大镜上次取样的像素和色值（像素没变就不重取）
  var sampled: (x: Int, y: Int, hex: String)?
  /// 上次画的悬停窗口：换到别的窗口 / 桌面时，洞和高亮框磁吸变形过去（S5）
  var shownHover: CGRect?
  /// 指针下这一点上的几层（认元素时，见 hoverStack）
  var stack: HoverStack?
  /// 触控板换层攒着的量（ElementFinder.step）
  var scrollPending: CGFloat = 0
  /// 已经排了「到点再问一次」的 App（刚叫醒的，见 recheck）
  var rechecking: Set<pid_t> = []
  /// 待选时按下那一刻悬停的那块：单击松手就选它（按下后手抖出了换大的那层，重问会落回最小那层，评审）
  var pressedHover: CGRect?
  /// 没悬停窗口时洞缩成光标处的零尺寸占位（路径元素数恒定，桌面 ↔ 窗口也能变形）
  var placeholder = CGPoint.zero
  /// 上次的洞是不是选区（单击窗口选中时洞圆角 10 → 0 用 pop）
  var holeIsSelection = false
  /// 上次有没有洞：有无变化时蒙层深浅过渡
  var hadHole = false
  /// 悬停（或正在拖）的选区边 / 角：那条边加粗、对应手柄放大 1.3。截图自检、交互测试读它
  var hotHandle: RegionSelector.Handle?
  /// 手柄上次是否显示（进入调整时依次弹出）
  var handlesShown = false
  /// 放大镜上次在光标哪一侧（翻边时滑过去）
  var magnifierSide: (left: Bool, above: Bool)?
  /// 顶部提示的几段（旁白的帮助也读它）；截图切成录屏时换
  var hintParts: [String]
  /// 顶部提示临时换了一句（右键不清空）：有选区时也显示
  var hintFlashing = false
  /// 正在给这个快捷键录新的键（工具栏按钮上右键「改快捷键…」之后）：下一下按键就是它，Esc / 点一下取消
  var rebinding: ShotKey?
  /// 右键的是哪颗钮：改快捷键的提示挂在它旁边、等着时它带一圈呼吸的粉圈
  var rebindItem: EditorToolbar.Item?
  /// 改快捷键的提示（2026-11-06 用户：放在屏幕顶上不够明显）：挂在那颗钮旁边，工具栏离选区远的那一侧，放不下换另一侧
  let rebindTip = HintPill(
    font: .systemFont(ofSize: 13, weight: .medium), padding: CGSize(width: 12, height: 7))
  var rebindTipGeneration = 0
  /// 框选时保持屏幕原色（设置 › 截图，Prefs.screenshotKeepsColors）：每次框选新建遮罩时读一次（单测、截图自检直接给）
  let keepsColors: Bool
  /// 刚开始框选时顶部那条 3 秒的提示（设置 › 截图「框选时显示操作提示」，Prefs.screenshotShowsHint）；关着时
  /// flashHint 那种临时说一句照出。读法同 keepsColors
  let showsHint: Bool
  /// 框选时的放大镜（设置 › 截图，Prefs.Loupe）：放大镜和色值 / 只显示放大镜 / 不显示。读法同 keepsColors
  let loupeStyle: Prefs.Loupe

  /// 遮罩压多暗（纯函数，配单测）：待选整屏 0.18，有洞（选区、悬停的窗口）时洞外 0.45；保持原色时不压
  static func shadeAlpha(hasHole: Bool, keepsColors: Bool) -> CGFloat {
    keepsColors ? 0 : hasHole ? 0.45 : 0.18
  }
  /// 上一次主动播报的话（交互测试读它）
  var announcement: String?
  /// 待选时单击选中了窗口 / 整屏、栏又正好长在按下的地方（整屏、贴着屏幕底的窗口）：双击间隔内的第二下归自己（hitTest），
  /// 算双击拷贝，不落到刚长出来的栏上
  var clickSelected: (time: TimeInterval, point: CGPoint)?
  /// 上一下按在了哪条箭头 / 直线的弯曲手柄上：双击要两下都按在弯曲手柄上才拉直（第一下点弧线选中它、第二下正好落在刚出现的
  /// 弯曲手柄上不算）。每次按下都先取出清掉
  var bendPressed: UUID?
  /// 每次显示提示加一：旧的淡出计时作废
  var hintGeneration = 0
  /// 每个工具记住的样式（Prefs.screenshotToolStyles）、录制条的四个开关（录屏第 4 批、手测反馈第 2 批）和「窗口截图带阴影」
  /// （第五轮体检 N1，只读）存在哪：交互测试换成临时偏好域，
  /// 不写用户的真实偏好（录制条在 init 里就建了，换了域要跟着换）
  var styleDefaults = UserDefaults.standard {
    didSet { recordBar?.defaults = styleDefaults }
  }

  /// 放大镜取样边长（像素，奇数才有中心）、每个像素放大后的边长（点）、下方信息卡高度
  static let loupePixels = 15
  private static let loupeCell: CGFloat = 9
  private static let infoHeight: CGFloat = 40

  init(
    image: CGImage, windows: [CGRect] = [], owners: [[pid_t]] = [],
    windowIDs: [CGWindowID?] = [], session: SelectionSession,
    keepsColors keeps: Bool? = nil, showsHint shows: Bool? = nil, loupe: Prefs.Loupe? = nil
  ) {
    self.image = image
    self.windows = windows
    self.owners = owners
    self.windowIDs = windowIDs
    self.session = session
    keepsColors = keeps ?? UserDefaults.standard.bool(forKey: Prefs.screenshotKeepsColors)
    showsHint = shows ?? UserDefaults.standard.bool(forKey: Prefs.screenshotShowsHint)
    loupeStyle = loupe ?? Prefs.Loupe.current()
    hintParts = Self.hintParts(for: session)
    super.init(frame: .zero)
    wantsLayer = true
    if annotates {
      spotlightDim.fillRule = .evenOdd
      dimCanvas.layer?.addSublayer(spotlightDim)
      dimCanvas.autoresizingMask = [.width, .height]
      addSubview(dimCanvas)
      let view = AnnotationCanvas(image: image, dim: spotlightDim)
      view.autoresizingMask = [.width, .height]
      addSubview(view)
      annotationCanvas = view
    }
    canvas.autoresizingMask = [.width, .height]
    addSubview(canvas)
    let root = canvas.layer!
    translatingPulse.masksToBounds = true
    // 底层压暗一点而不是提亮：纯白背景上白色叠白色是零变化，先压暗才有「扫过去变亮」的对比
    translatingPulse.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
    translatingPulse.isHidden = true
    translatingBand.colors = [
      NSColor.white.withAlphaComponent(0).cgColor,
      NSColor.white.withAlphaComponent(0.55).cgColor,
      NSColor.white.withAlphaComponent(0).cgColor,
    ]
    translatingBand.locations = [0, 0.5, 1]
    translatingBand.startPoint = CGPoint(x: 0, y: 0.5)
    translatingBand.endPoint = CGPoint(x: 1, y: 0.5)
    translatingPulse.addSublayer(translatingBand)
    root.addSublayer(translatingPulse)
    shade.fillRule = .evenOdd
    shade.fillColor =
      NSColor.black.withAlphaComponent(Self.shadeAlpha(hasHole: false, keepsColors: keepsColors))
      .cgColor
    let pink = Style.Shot.accent
    outline.fillColor = nil
    outline.strokeColor = pink.cgColor
    outline.lineWidth = 1.5
    outlineOuter.fillColor = nil
    outlineOuter.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
    outlineOuter.lineWidth = 1
    edgeHighlight.fillColor = nil
    edgeHighlight.strokeColor = pink.cgColor
    edgeHighlight.lineWidth = 2.5
    edgeHighlight.lineCap = .round
    highlight.fillColor = keepsColors ? nil : pink.withAlphaComponent(0.12).cgColor
    highlight.strokeColor = pink.cgColor
    highlight.lineWidth = 2
    for (handle, layer) in handleLayers {
      layer.path = Self.handleShape(handle)
      layer.fillColor = NSColor.white.cgColor
      layer.strokeColor = pink.cgColor
      layer.lineWidth = 1.5
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.3
      layer.shadowRadius = 1.5
      layer.shadowOffset = CGSize(width: 0, height: -0.5)
      layer.shadowPath = layer.path
      layer.isHidden = true
    }
    annotationOutline.fillColor = nil
    annotationOutline.strokeColor = pink.cgColor
    annotationOutline.lineWidth = 1
    annotationOutline.lineDashPattern = [4, 3]
    annotationHandles.fillColor = NSColor.white.cgColor
    annotationHandles.strokeColor = pink.cgColor
    annotationHandles.lineWidth = 1.5
    guideLayer.fillColor = nil
    guideLayer.strokeColor = pink.cgColor
    guideLayer.lineWidth = 1
    guideLayer.lineDashPattern = [4, 3]
    for (layer, color) in [
      (crossLight, NSColor.white.withAlphaComponent(0.6)),
      (crossDark, .black.withAlphaComponent(0.25)),
    ] {
      layer.fillColor = nil
      layer.strokeColor = color.cgColor
      layer.lineWidth = 1
    }
    setUpMagnifier()
    infoKey.isHidden = mode == .quick  // 截图翻译 / 识字不能按 C 复制色值
    for layer in [
      shade, highlight, outlineOuter, outline, guideLayer, edgeHighlight, crossDark, crossLight,
    ]
      + Self.handleOrder.compactMap({ handleLayers[$0] })
      + [annotationOutline, annotationHandles, hint.layer, rebindTip.layer, magnifier]
    {
      root.addSublayer(layer)
    }
    rebindTip.layer.isHidden = true
    sizeField.isHidden = true
    sizeField.onEdit = { [unowned self] which in beginSizeEditing(which) }
    sizeField.onCommit = { [unowned self] in finishSizeEditing(commit: true) }
    sizeField.onCancel = { [unowned self] in escape() }
    sizeField.onRatio = { [unowned self] in toggleRatioMenu() }
    addSubview(sizeField)
    hint.setParts(hintParts)
    // 不显示操作提示：一开始就是透明的（不设 isHidden，同 dismissHint）；flashHint 照样浮上来再淡出
    if !showsHint { hint.layer.opacity = 0 }
    if annotates { makeBars() } else if adjusts { makeRecordBar() }
    updateScale()
  }

  /// 待选时顶部提示的几段（按会话的模式）
  static func hintParts(for session: SelectionSession) -> [String] {
    let lastRegion = session.lastRegion == nil ? [] : [String(localized: "D 上次区域")]
    // 认元素时单击选中的是指针下那一块，滚轮换大小、Tab 切只认窗口；切成只认窗口后提示怎么切回来
    let elements = session.findsElements && !session.windowOnly
    let layers =
      !session.findsElements
      ? []
      : session.windowOnly
        ? [String(localized: "Tab 认元素")]
        : [String(localized: "滚轮 换大小"), String(localized: "Tab 只认窗口")]
    return switch session.mode {
    case .quick: session.hint.components(separatedBy: " · ")
    case .capture where session.autoTranslates:
      [
        String(localized: "拖动框选要翻译的文字"),
        elements ? String(localized: "单击翻译") : String(localized: "单击翻译窗口"),
      ] + layers + [String(localized: "Esc 取消")]
    case .capture:
      [
        String(localized: "拖动框选"),
        elements ? String(localized: "单击选中") : String(localized: "单击选中窗口"),
      ] + layers + [String(localized: "双击直接拷贝")] + lastRegion
        + [String(localized: "Esc 取消")]
    case .record:
      [
        String(localized: "拖动框选要录的区域"),
        elements ? String(localized: "单击选中") : String(localized: "单击选中窗口区域"),
      ] + layers + [String(localized: "单击桌面录整屏"), String(localized: "双击直接开始")]
        + lastRegion + [String(localized: "Esc 取消")]
    }
  }

  /// 顶部提示排成几行（第五轮体检 U3：英文整行 800–1200 pt，窄屏上两头被裁掉、「Esc to cancel」看不见）：一段不拆开，
  /// 放不下 limit 就在段与段之间折行（一段本身就超的自己占一行）；行数定了再把各行排得差不多宽，不剩一段孤零零挂在最后。
  /// widths 是各段的宽、separator 是「 · 」的宽；返回每行几段。纯函数，配单测
  nonisolated static func hintRows(_ widths: [CGFloat], separator: CGFloat, limit: CGFloat) -> [Int]
  {
    let count = packRows(widths, separator: separator, limit: limit).count
    // 行数不变，把上限往下压到刚好还是这么多行
    var (low, high) = (widths.max() ?? 0, limit)
    while high - low > 0.5 {
      let middle = (low + high) / 2
      if packRows(widths, separator: separator, limit: middle).count <= count {
        high = middle
      } else {
        low = middle
      }
    }
    return packRows(widths, separator: separator, limit: max(high, low))
  }

  /// 一段一段往后接，接上超过 limit 就另起一行
  nonisolated private static func packRows(
    _ widths: [CGFloat], separator: CGFloat, limit: CGFloat
  ) -> [Int] {
    var rows: [Int] = []
    var width: CGFloat = 0
    for part in widths {
      if !rows.isEmpty, width + separator + part <= limit {
        rows[rows.count - 1] += 1
        width += separator + part
      } else {
        rows.append(1)
        width = part
      }
    }
    return rows
  }

  /// 顶部提示最宽多宽：所在屏的可见宽度（程序坞在侧边时比屏窄）减两边各 32，不窄于 240。纯函数，配单测
  nonisolated static func hintWidthLimit(screen: CGFloat, visible: CGFloat?) -> CGFloat {
    max(min(screen, visible ?? screen) - 64, 240)
  }

  /// 放大镜：15 × 15 像素、每格 9 pt（135 pt，圆角 10，2 pt 白环 + 阴影），0.5 pt 像素网格，中心行列粉色十字条带，
  /// 放大镜那块格子有多大（交互测试按它判断有没有带色值卡）
  static var loupeSide: CGFloat { CGFloat(loupePixels) * loupeCell }
  /// 整块放大镜多高：截图时是格子 + 6 + 信息卡，翻译 / 识字只有格子（设置里不显示色值时截图也只有格子）
  var magnifierHeight: CGFloat { magnifier.bounds.height }
  /// 顶部提示现在看不看得见（交互测试读它）
  var hintShowing: Bool { !hint.layer.isHidden && hint.layer.opacity > 0 }
  /// 顶部提示摆在哪、写的什么（几行之间是换行；交互测试读它）
  var hintLayout: (frame: CGRect, text: String) { (hint.frame, hint.text) }
  /// 按住 ⌘ 的十字准线画着没有（交互测试读它）
  var showsCrosshair: Bool { crossLight.path != nil }
  /// 放大镜下面贴不贴色值卡：截图时按设置（放大镜和色值）；吸管取色时一定贴。录屏、截图翻译 / 识字没有
  var showsColorCard: Bool { annotates && (loupeStyle == .full || pickingColor) }

  /// 中心格按亮度描黑或白；截图时下贴一张 40 pt 的 HUD 信息卡（色块 + HEX + 坐标 +「C」键帽）。
  /// 截图翻译 / 识字只有放大镜本身、没有那张卡（2026-10-26 用户问「翻译识字时有必要出现吗」）：
  /// 这两种模式下用户要的是把文字框准，色值是噪音；而且那张卡上的「C」在这两种模式里本来就按不动
  /// （取色那一句在 keyDown 里被 `guard adjusts` 挡着）
  private func setUpMagnifier() {
    let side = CGFloat(Self.loupePixels) * Self.loupeCell
    let cell = Self.loupeCell
    let middle = CGFloat(Self.loupePixels / 2) * cell
    let loupeFrame = CGRect(x: 0, y: 0, width: side, height: side)
    loupe.frame = loupeFrame
    loupe.magnificationFilter = .nearest
    loupe.cornerRadius = Style.Radius.card
    loupe.cornerCurve = .continuous
    loupe.masksToBounds = true
    loupe.backgroundColor = NSColor.black.cgColor
    loupe.borderColor = NSColor.white.cgColor
    loupe.borderWidth = 2
    loupeShadow.frame = loupeFrame
    loupeShadow.shadowPath = CGPath(
      roundedRect: loupeShadow.bounds, cornerWidth: Style.Radius.card,
      cornerHeight: Style.Radius.card, transform: nil)
    loupeShadow.shadowColor = NSColor.black.cgColor
    loupeShadow.shadowOpacity = 0.45
    loupeShadow.shadowRadius = 6
    loupeShadow.shadowOffset = CGSize(width: 0, height: -2)
    let grid = CGMutablePath()
    for index in 1..<Self.loupePixels {
      let offset = CGFloat(index) * cell
      grid.move(to: CGPoint(x: offset, y: 0))
      grid.addLine(to: CGPoint(x: offset, y: side))
      grid.move(to: CGPoint(x: 0, y: offset))
      grid.addLine(to: CGPoint(x: side, y: offset))
    }
    loupeGrid.frame = loupe.bounds
    loupeGrid.path = grid
    loupeGrid.strokeColor = NSColor.black.withAlphaComponent(0.14).cgColor
    loupeGrid.lineWidth = 0.5
    let bands = CGMutablePath()
    bands.addRect(CGRect(x: 0, y: middle, width: side, height: cell))
    bands.addRect(CGRect(x: middle, y: 0, width: cell, height: side))
    loupeBands.frame = loupe.bounds
    loupeBands.path = bands
    // 保持原色时十字带只描边：填上粉色，正中那个要取的像素也被染了
    if keepsColors {
      loupeBands.fillColor = nil
      loupeBands.strokeColor = Style.Shot.accent.cgColor
      loupeBands.lineWidth = 1
    } else {
      loupeBands.fillColor = Style.Shot.accent.withAlphaComponent(0.18).cgColor
    }
    loupeCenter.frame = loupe.bounds
    loupeCenter.path = CGPath(
      rect: CGRect(x: middle, y: middle, width: cell, height: cell), transform: nil)
    loupeCenter.fillColor = nil
    loupeCenter.strokeColor = NSColor.white.cgColor
    loupeCenter.lineWidth = 1
    for layer in [loupeBands, loupeGrid, loupeCenter] { loupe.addSublayer(layer) }
    infoCard.frame = CGRect(x: 0, y: 0, width: side, height: Self.infoHeight)
    Style.HUD.applySkin(to: infoCard, radius: Style.Radius.card)
    Style.HUD.applyShadow(
      to: infoCard,
      path: CGPath(
        roundedRect: infoCard.bounds, cornerWidth: Style.Radius.card,
        cornerHeight: Style.Radius.card, transform: nil))
    infoSwatch.frame = CGRect(x: 10, y: 12, width: 16, height: 16)
    infoSwatch.cornerRadius = 4
    infoSwatch.borderWidth = 0.5
    infoSwatch.borderColor = Style.HUD.swatchStroke.cgColor
    infoText.frame = CGRect(x: 34, y: 5, width: side - 34 - 34, height: 30)
    infoText.isWrapped = false
    infoKey.frame = CGRect(x: side - 30, y: 11, width: 20, height: 18)
    infoKey.backgroundColor = Style.HUD.chipFill.cgColor
    infoKey.cornerRadius = 4
    infoKey.alignmentMode = .center
    infoKey.string = NSAttributedString(
      string: "C",
      attributes: [
        .font: Style.HUD.keyFont, .foregroundColor: Style.HUD.text, .baselineOffset: -2,
      ])
    for layer in [infoSwatch, infoText, infoKey] { infoCard.addSublayer(layer) }
    magnifier.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    for layer in annotates ? [loupeShadow, loupe, infoCard] : [loupeShadow, loupe] {
      magnifier.addSublayer(layer)
    }
    layOutMagnifier()
  }

  /// 按贴不贴色值卡摆格子和整块的高（showsColorCard：吸管取色开始 / 结束时会变）
  func layOutMagnifier() {
    let side = Self.loupeSide
    let card = showsColorCard
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    loupe.frame.origin.y = card ? Self.infoHeight + 6 : 0
    loupeShadow.frame = loupe.frame
    infoCard.isHidden = !card
    magnifier.bounds = CGRect(x: 0, y: 0, width: side, height: loupe.frame.maxY)
    if card, let sampled { writeInfo(sampled) }  // 卡藏着时没写字
    CATransaction.commit()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if let armed = clickSelected,
      ProcessInfo.processInfo.systemUptime - armed.time < NSEvent.doubleClickInterval
    {
      let local = convert(point, from: superview)
      if hypot(local.x - armed.point.x, local.y - armed.point.y) <= 4 { return self }
    }
    return super.hitTest(point)
  }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() { layer?.contents = image }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    canvas.layer?.frame = CGRect(origin: .zero, size: newSize)
    dimCanvas.layer?.frame = CGRect(origin: .zero, size: newSize)
    refresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }

  /// 外部选中一块区域并进入调整（D 键上次区域）
  func select(_ rect: CGRect) {
    drag = nil
    draft = nil
    selection = rect
    isAdjusting = true
    refreshCursor()
  }

  /// 画了标注，或正在输入还没收下的文字：会把它们一下清掉的操作（右键、到别的屏框选、D 跳到别的屏）都不做
  var hasAnnotations: Bool {
    !annotations.isEmpty
      || editor.map { !$0.field.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        == true
  }

  /// 挡下会清掉标注的操作：提示音 + 顶部提示怎么退出
  func refuseWipe(_ what: String) {
    NSSound.beep()
    flashHint([what, String(localized: "Esc 退出")])
  }

  /// 回到待选（别的屏开始操作、右键重新框时）：标注一起清掉
  func reset() {
    pickingColor = false
    cancelTranslation()
    hudMenu?.dismiss()
    finishSizeEditing(commit: false)
    endEditing()
    guides = (nil, nil)
    dragPoint = nil
    drag = nil
    draft = nil
    selection = nil
    clickedWindow = nil
    isAdjusting = false
    mouse = nil
    stack = nil
    isSpaceDown = false
    tool = nil
    selectedAnnotation = nil
    undoStack = []
    redoStack = []
    annotations = []
  }

  // MARK: 跟手要的存储属性（跟手的方法在 SelectionView+Mouse.swift）

  /// 放大镜跟手（2026-10-26 用户手测「颜色识别快速移动时很卡」）：鼠标移动事件默认是合并的
  /// （`NSEvent.isMouseCoalescingEnabled`），本 App 又从不激活前台，快速划过时收到的移动事件比屏幕刷新稀，
  /// 放大镜就一直落在光标后面。挂一条显示链每帧补读一次光标位置——位置没变就直接回（几乎不花时间），
  /// 变了才走和 mouseMoved 同一条路。只在遮罩挂在可见窗口上时跑，窗口 orderOut 或视图离开窗口就停，
  /// 不是常驻动画（Whisker 核心 §8）
  var follow: CADisplayLink?
}

/// 文字标注的输入框。「描边」样式时先画带阴影的外描边、再让 NSTextView 画字（和收下后画出来的一样）。
/// 焦点环（Whisker §3 输入框焦点）：1 pt 粉 0.55 + 粉 0.18 r4 外发光，单独一层（输入框图层自己的阴影给底色色块用）。
/// 右键不出文本菜单（菜单层级比遮罩低，会被压在下面看不见），交给遮罩（回到待选）
final class EditorField: NSTextView {
  /// 外描边（Annotation.outlineAttributes）；nil = 不描边
  var outline: [NSAttributedString.Key: Any]? { didSet { needsDisplay = true } }
  /// 焦点环的圆角：同底色色块（有底色 6，否则 3）
  var ringRadius: CGFloat = 3 { didSet { layoutRing() } }
  private let ring = CALayer()

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutRing()
  }

  /// 环贴着输入框的边、跟着输入变大；发光按描边的轮廓给 shadowPath
  private func layoutRing() {
    guard let layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if ring.superlayer == nil {
      let pink = Style.Shot.accent
      ring.borderWidth = 1
      ring.borderColor = pink.withAlphaComponent(0.55).cgColor
      ring.shadowColor = pink.cgColor
      ring.shadowOpacity = 0.18
      ring.shadowRadius = 4
      ring.shadowOffset = .zero
      ring.zPosition = 1  // 压在文字片段的图层上面
      layer.addSublayer(ring)
    }
    ring.frame = bounds
    ring.cornerRadius = ringRadius  // 圆弧角：同底色色块（CGPath 的圆角矩形）
    ring.shadowPath = CGPath(
      roundedRect: bounds, cornerWidth: ringRadius, cornerHeight: ringRadius, transform: nil
    ).copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .round, miterLimit: 1)
  }

  override func draw(_ dirtyRect: NSRect) {
    if let outline {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current?.cgContext.setLineJoin(.round)
      var attributes = outline
      attributes[.shadow] = Annotation.textShadow
      // 同 Annotation.draw 的 draw(in:)，字从文字容器的左上角排起（视图是翻转的）
      NSAttributedString(string: string, attributes: attributes).draw(
        in: CGRect(origin: textContainerOrigin, size: bounds.size))
      NSGraphicsContext.restoreGraphicsState()
    }
    super.draw(dirtyRect)
  }

  override func menu(for event: NSEvent) -> NSMenu? { nil }
  override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
}

/// 标注层：只重画变了的标注所在的那块（整屏重画在 5K 屏上太慢）。聚光灯的压暗不画在这一层：由它下面的 dim 图层画
/// （偶奇填充的 CAShapeLayer，拖选区、挪洞时只换路径），这一层只给垫底的（马赛克、荧光笔垫的底）补同样的压暗
/// （Annotation.drawAll 的 dimsUnderlaysOnly）。AppKit 会把几条 setNeedsDisplay 并成一块外框重画，压暗画在这里时
/// 拖一下选区就要按整个选区压暗一遍（2300 × 1250 一次 20 多毫秒）。不接事件
/// 标注层：画全部标注，只重画变了的那块。遮罩和长图标注窗口共用——遮罩给 dim（聚光灯压暗画在下面那层，
/// 它还要配合选区），长图不给（压暗在这一层自己画，范围就是整张图），选中框和手柄也只有长图这边画在这里（chrome）
final class AnnotationCanvas: NSView {
  /// 冻结帧（马赛克从它取像素）；截图页里就地翻译之后换成贴了译文的那张
  var image: CGImage { didSet { needsDisplay = true } }
  private let dim: CAShapeLayer?
  var annotations: [Annotation] = [] {
    didSet {
      invalidate(from: oldValue)
      updateDim()
    }
  }
  /// 选区：聚光灯只压暗选区里面。选区一变下面的压暗换路径；这一层只重画碰到新旧选区不重合处的垫底标注
  var selection: CGRect? {
    didSet {
      guard selection != oldValue else { return }
      updateDim()
      guard Annotation.dimLevel(of: annotations) != nil else { return }
      let strips = oldValue.flatMap { old in
        selection.map { Annotation.dimChange(from: old, to: $0) }
      }
      for annotation in annotations where Self.isUnderlay(annotation) {
        let box = annotation.drawBounds
        guard strips?.contains(where: { $0.intersects(box) }) ?? true else { continue }
        setNeedsDisplay(box.insetBy(dx: -2, dy: -2))
      }
    }
  }

  /// 选中的那条：1 pt 粉虚线框（线类不画框）+ 白底粉边的手柄；zoom 是画布缩放，线宽和半径按它补偿
  /// （缩小看长图时手柄还是一样大）。遮罩那边用 CALayer 画，不设这个
  var chrome: (selected: Annotation, zoom: CGFloat)? {
    didSet {
      for side in [oldValue, chrome] {
        guard let side else { continue }
        setNeedsDisplay(Self.chromeBounds(side.selected, zoom: side.zoom))
      }
    }
  }

  init(image: CGImage, dim: CAShapeLayer? = nil) {
    self.image = image
    self.dim = dim
    super.init(frame: .zero)
  }

  /// 画在这一层、本该压在暗色下面的：马赛克、荧光笔（垫的底）
  private static func isUnderlay(_ annotation: Annotation) -> Bool {
    annotation.tool == .mosaic || annotation.tool == .highlighter
  }

  /// 下面的压暗图层：选区 + 聚光灯的洞（没有聚光灯、没有选区时空）
  private func updateDim() {
    guard let dim else { return }  // 长图标注窗口：压暗在这一层自己画（draw 里 dimsUnderlaysOnly 为假）
    let spotlights = annotations.filter { $0.tool == .spotlight }
    let shape = selection.flatMap { Annotation.spotlightDim(spotlights, bounds: $0) }
    let fill = CGColor(gray: 0, alpha: shape?.alpha ?? 0)
    guard dim.path != shape?.path || dim.fillColor != fill else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dim.path = shape?.path
    dim.fillColor = fill
    CATransaction.commit()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    Annotation.drawAll(
      annotations, in: context, image: image, viewSize: bounds.size, shadowScale: 1,
      dirty: dirtyRect, spotlightBounds: dim == nil ? bounds : (selection ?? .zero),
      dimsUnderlaysOnly: dim != nil)
    if let chrome, chromeBounds(chrome).intersects(dirtyRect) {
      Self.drawChrome(chrome.selected, zoom: chrome.zoom, in: context)
    }
  }

  private func chromeBounds(_ chrome: (selected: Annotation, zoom: CGFloat)) -> CGRect {
    Self.chromeBounds(chrome.selected, zoom: chrome.zoom)
  }

  /// 这次改动要不要整层重画：压暗由这一层自己画（长图标注窗口）、且前后有聚光灯时才要——它的压暗盖住整张图，
  /// 按标注各自的框去重画只会挖出洞、周围不变暗。纯函数，配单测
  static func redrawsEverything(from old: [Annotation], to new: [Annotation], dimsItself: Bool)
    -> Bool
  {
    guard dimsItself else { return false }
    return old.contains { $0.tool == .spotlight } || new.contains { $0.tool == .spotlight }
  }

  /// 选中框和手柄盖住多大（外扩手柄半径和虚线框）。纯函数，配单测
  static func chromeBounds(_ selected: Annotation, zoom: CGFloat) -> CGRect {
    let reach = (3 + 6) / max(zoom, 0.01)
    return selected.bounds.insetBy(dx: -reach, dy: -reach)
  }

  /// 画选中框和手柄（样式同遮罩里的那两个图层：1 pt 粉虚线 [4, 3]、手柄白底 1.5 pt 粉边，半径 4.5 / 弯曲手柄 3.5）
  static func drawChrome(_ selected: Annotation, zoom: CGFloat, in context: CGContext) {
    let pink = Style.Shot.accent.cgColor
    let thin = 1 / max(zoom, 0.01)
    context.saveGState()
    defer { context.restoreGState() }
    if ![.arrow, .line, .highlighter].contains(selected.tool) {
      context.setStrokeColor(pink)
      context.setLineWidth(thin)
      context.setLineDash(phase: 0, lengths: [4 * thin, 3 * thin])
      context.stroke(selected.bounds.insetBy(dx: -3 * thin, dy: -3 * thin))
      context.setLineDash(phase: 0, lengths: [])
    }
    context.setFillColor(NSColor.white.cgColor)
    context.setStrokeColor(pink)
    context.setLineWidth(1.5 * thin)
    for (handle, point) in selected.handles(zoom: zoom) {
      let radius = (handle == .bend ? 3.5 : 4.5) * thin
      let dot = CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
      context.fillEllipse(in: dot)
      context.strokeEllipse(in: dot)
    }
  }

  private func invalidate(from old: [Annotation]) {
    // 长图那边压暗画在这一层（dim 为 nil），范围是整张图：聚光灯一动得整层重来，只重画它自己那块的话
    // 洞挖好了、周围还是亮的（2026-10-26 用户手测「绘制时不生效，保存后又生效」）
    if Self.redrawsEverything(from: old, to: annotations, dimsItself: dim == nil) {
      return setNeedsDisplay(bounds)
    }
    // 压暗的档变了（加上第一个聚光灯、改深浅）：垫底的补的那层压暗跟着变
    if Annotation.dimLevel(of: annotations) != Annotation.dimLevel(of: old) {
      for annotation in annotations where Self.isUnderlay(annotation) {
        setNeedsDisplay(annotation.drawBounds.insetBy(dx: -2, dy: -2))
      }
    }
    let before = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
    let now = Set(annotations.map(\.id))
    for annotation in annotations where before[annotation.id] != annotation {
      // 画笔边画边累点：只重画新接上的那一截
      if let previous = before[annotation.id], let tail = annotation.penGrowth(from: previous) {
        setNeedsDisplay(tail.insetBy(dx: -2, dy: -2))
        continue
      }
      setNeedsDisplay(annotation.drawBounds.insetBy(dx: -2, dy: -2))
      if let previous = before[annotation.id] {
        setNeedsDisplay(previous.drawBounds.insetBy(dx: -2, dy: -2))
      }
    }
    for annotation in old where !now.contains(annotation.id) {
      setNeedsDisplay(annotation.drawBounds.insetBy(dx: -2, dy: -2))
    }
  }
}

/// 只放图层、不接事件（事件都给 SelectionView）。先设 layer 再 wantsLayer：layer-hosting，可以随意加子图层
private final class Canvas: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    layer = CALayer()
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// HUD 胶囊里一行白字（Style.HUD 皮肤 + 阴影）：顶部提示。放不下 maxWidth 时在段与段之间折行（第五轮体检 U3）
final class HintPill {
  let layer = CALayer()
  private let textLayer = CATextLayer()
  private let font: NSFont
  private let padding: CGSize
  private var parts: [String] = []
  /// 最宽多宽（含左右内边距；顶部提示按所在屏的可见宽度减边距给）：一行放不下就在「 · 」处折行，一段不拆开、哪段都不裁
  var maxWidth: CGFloat = .greatestFiniteMagnitude {
    didSet { if maxWidth != oldValue { layOut() } }
  }

  init(font: NSFont, padding: CGSize) {
    self.font = font
    self.padding = padding
    Style.HUD.applySkin(to: layer, radius: 0)
    layer.anchorPoint = .zero
    textLayer.foregroundColor = Style.HUD.text.cgColor
    layer.addSublayer(textLayer)
  }

  /// 几段之间用「 · 」隔开，点是次要文字色
  func setParts(_ parts: [String]) {
    self.parts = parts
    layOut()
  }

  /// 按 maxWidth 排成几行（SelectionView.hintRows），行内用「 · 」接、行间换行
  private func layOut() {
    let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Style.HUD.text]
    let dot = NSAttributedString(
      string: " · ", attributes: [.font: font, .foregroundColor: Style.HUD.tertiaryText])
    let pieces = parts.map { NSAttributedString(string: $0, attributes: text) }
    let rows = SelectionView.hintRows(
      pieces.map { ceil($0.size().width) }, separator: dot.size().width,
      limit: maxWidth - padding.width * 2)
    let string = NSMutableAttributedString()
    var next = 0
    for (row, count) in rows.enumerated() {
      if row > 0 { string.append(NSAttributedString(string: "\n", attributes: text)) }
      for index in next..<next + count {
        if index > next { string.append(dot) }
        string.append(pieces[index])
      }
      next += count
    }
    // 几行时各行居中（一行时照旧，和原来逐像素一样）
    textLayer.alignmentMode = rows.count > 1 ? .center : .natural
    set(string, rows: rows.count)
  }

  /// 文字没变就不动
  private func set(_ string: NSAttributedString, rows: Int) {
    guard (textLayer.string as? NSAttributedString) != string else { return }
    let textSize = string.size()
    textLayer.string = string
    textLayer.frame = CGRect(
      x: padding.width, y: padding.height, width: ceil(textSize.width),
      height: ceil(textSize.height))
    layer.bounds.size = CGSize(
      width: ceil(textSize.width) + padding.width * 2,
      height: ceil(textSize.height) + padding.height * 2)
    // 一行时两端是半圆：continuous 的圆角到了高的一半会被夹住，描边在两端多出一道竖线（截图自检看到的）。
    // 折成几行时圆角照一行时的半径（不鼓成一团）
    let radius = (ceil(textSize.height / CGFloat(max(rows, 1))) + padding.height * 2) / 2
    Style.HUD.applySkin(to: layer, radius: radius, curve: .circular)
    Style.HUD.applyShadow(
      to: layer,
      path: CGPath(
        roundedRect: layer.bounds, cornerWidth: layer.cornerRadius,
        cornerHeight: layer.cornerRadius, transform: nil))
  }

  var size: CGSize { layer.bounds.size }
  var frame: CGRect { CGRect(origin: layer.position, size: size) }
  var text: String { (textLayer.string as? NSAttributedString)?.string ?? "" }

  var scale: CGFloat {
    get { textLayer.contentsScale }
    set { textLayer.contentsScale = newValue }
  }

  /// 左下角放在 origin（取整到整点：选区给的是小数点，文字落在半像素上会糊）
  func place(at origin: CGPoint) {
    layer.position = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }
}
