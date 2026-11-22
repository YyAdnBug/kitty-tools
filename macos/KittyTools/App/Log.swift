// 统一日志（os.Logger）。查看：log stream --predicate 'subsystem BEGINSWITH "com.yy.kitty-tools.native"'
// 红线：日志里不得出现密钥、请求 URL、请求头、剪贴板正文。

import OSLog

nonisolated enum Log {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"
  static let storage = Logger(subsystem: subsystem, category: "storage")
  static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
  static let record = Logger(subsystem: subsystem, category: "record")
  /// 访达右键（FinderLink）：交给别的 App 打开没成
  static let finder = Logger(subsystem: subsystem, category: "finder")
  /// 刘海岛（Island）：每块屏认成刘海 / 胶囊 / 系统灵动岛和它的几何（屏幕变了时写一次）
  static let island = Logger(subsystem: subsystem, category: "island")
  /// 刘海岛的正在播放（NowPlaying）：连不上服务、服务说 MediaRemote 不能用
  static let nowPlaying = Logger(subsystem: subsystem, category: "nowplaying")
  /// 全局快捷键（HotKeyCenter）：每次重新注册（几个、哪些没注册上）、停用（issue #27：失效时能看出是没注册上还是停着）
  static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
  /// 键位映射插件（KeyRemapping）：读不出 / 存不下规则、系统没收映射（键盘的名字按默认的不公开记）
  static let keyRemapping = Logger(subsystem: subsystem, category: "keyremapping")
}
