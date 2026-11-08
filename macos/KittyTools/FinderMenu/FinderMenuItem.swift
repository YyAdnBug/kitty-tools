// 访达右键里能单独关掉的每一项（2026-11-08 右键扩充拍板 A2；同几家成熟产品每项一个开关）：设置 › 访达右键各一个开关，
// 偏好键「finderMenu<名字>」、注册的默认值是 defaultOn——几家都有、访达自己没有或藏得深的默认开，用的人少或有风险的默认关。
// 扩展读同样的键（注册的默认值它读不到：没存过就用它自己抄的默认值，FinderLinkTests 读扩展源码比对）。
// 「在“X”中打开」不在这里：它跟着「在 App 中打开」那张列表，列表空了就没有。

import Foundation

nonisolated enum FinderMenuItem: String, CaseIterable {
  // rawValue 拼进偏好键，不能改
  case newFile = "NewFile"
  case copyPath = "CopyPath"
  case copyName = "CopyName"
  case transfer = "Transfer"
  case cut = "Cut"
  case deskAlias = "DeskAlias"
  case compress = "Compress"
  case extract = "Extract"
  case fixNames = "FixNames"

  var prefsKey: String { "finderMenu" + rawValue }

  /// 没存过时开不开（拍板 A2：替身到桌面用的人少，默认关）
  var defaultOn: Bool { self != .deskAlias }

  /// 设置里那一行
  var title: String {
    switch self {
    case .newFile: "显示「新建文件」"
    case .copyPath: "显示「拷贝路径」"
    case .copyName: "显示「拷贝名称」"
    case .transfer: "显示「移动到」「复制到」"
    case .cut: "显示「剪切」和「粘贴」"
    case .deskAlias: "显示「发送替身到桌面」"
    case .compress: "显示「压缩」"
    case .extract: "显示「解压到这里」"
    case .fixNames: "显示「修复乱码文件名」"
    }
  }

  /// 设置里那一行的小字：在哪右键
  var detail: String {
    switch self {
    case .newFile: "文件夹窗口的空白处右键"
    case .copyPath: "右键文件、文件夹，或者文件夹窗口的空白处"
    case .copyName: "右键文件、文件夹；几样就一行一个，带扩展名"
    case .transfer: "右键文件、文件夹：送到下面的常用文件夹，或者另选一个"
    case .cut: "剪切之后，到别的文件夹空白处右键「粘贴」，或者在访达里按 ⌥⌘V"
    case .deskAlias: "在桌面上放一个替身，原件挪了也照样打得开"
    case .compress: "右键文件、文件夹：打成 zip 或 7z 放在旁边"
    case .extract: "右键 zip、7z、tar.gz 这类压缩包；带密码的 zip 会先问密码"
    case .fixNames: "只在名字像「ÖÐÎÄ」「╓╨╬─」这种乱码时出现，改回中文"
    }
  }

  /// 开着没有（没存过 = defaultOn）
  @MainActor var isOn: Bool {
    UserDefaults.standard.object(forKey: prefsKey) as? Bool ?? defaultOn
  }
}
