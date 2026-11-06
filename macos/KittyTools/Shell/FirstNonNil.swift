// 「第一个转出来不是 nil 的」（2026-11-06 程序坞预览闪退）：别写 `xs.lazy.compactMap(f).first`——惰性集合的 first 先为了
// 找起点调一次 f，再按下标取值时又调一次 f 并强制解包。f 两次结果不一样（读别的进程的辅助功能：程序坞的选中在两次之间变了）
// 第二次是 nil 就 SIGTRAP 闪退（0.7.1、0.7.2 的崩溃报告都停在 DockWatcher.selectionChanged）；f 很贵的（编码图片、递归找视图）
// 也白做两遍。一律用这个：每个元素只转一次。

extension Sequence {
  nonisolated func firstNonNil<T>(_ transform: (Element) throws -> T?) rethrows -> T? {
    for element in self {
      if let value = try transform(element) { return value }
    }
    return nil
  }
}
