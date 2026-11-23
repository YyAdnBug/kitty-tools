// 键位映射插件（PR #43）的启停、每把键盘的规则以及系统写入状态。映射交给系统的 UserKeyMapping（HIDKeyMapping），
// 不看按了什么键、不建事件拦截。什么时候核一遍：插件添加时、规则变了、键盘连上 / 断开（IOKit 的服务通知，不轮询）、
// 醒来（AppDelegate）、设置页打开时。别的工具运行中把 UserKeyMapping 整个清掉的，到下一次这几件事之一才补回去。

import AppKit
import IOKit
import IOKit.hidsystem
import OSLog
import Observation

@Observable final class KeyRemapping {
  struct Profile: Codable {
    let keyboard: RemapKeyboard
    var rules: [RemapRule]
  }

  struct Issue: Equatable {
    let message: String
    var needsInputMonitoring = false
  }

  private struct Applied {
    let owned: [UInt64: UInt64]
    let desired: [RemapRule]
  }

  private(set) var profiles: [Profile] = []
  private(set) var connected: [RemapKeyboard] = []
  private(set) var problems: [String: Issue] = [:]
  private(set) var configProblem: String?
  @ObservationIgnored private var running = false
  @ObservationIgnored private var notifyPort: IONotificationPortRef?
  @ObservationIgnored private var iterators: [io_iterator_t] = []
  @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
  @ObservationIgnored private var applied: [UInt64: Applied] = [:]
  @ObservationIgnored private var attempted: [UInt64: [RemapRule]] = [:]
  @ObservationIgnored private var serviceProblems: [UInt64: Issue] = [:]
  @ObservationIgnored private var stored: String?
  @ObservationIgnored private let rulesKey: String
  @ObservationIgnored private let defaults: UserDefaults

  init(rulesKey: String, defaults: UserDefaults = .standard) {
    self.rulesKey = rulesKey
    self.defaults = defaults
  }

  var keyboards: [RemapKeyboard] {
    let offline = profiles.map(\.keyboard).filter { saved in
      !connected.contains { $0.id == saved.id }
    }
    return connected + offline
  }

  func start() {
    guard !running else { return }
    running = true
    watchServices()
    defaultsChanged()
  }

  func stop() {
    guard running else { return }
    running = false
    pendingRefresh?.cancel()
    pendingRefresh = nil
    for iterator in iterators { IOObjectRelease(iterator) }
    iterators = []
    if let notifyPort { IONotificationPortDestroy(notifyPort) }
    notifyPort = nil
    for service in currentServices() ?? [] {
      guard let previous = applied[service.id], !previous.owned.isEmpty else { continue }
      do {
        let current = try service.read()
        let restored = current.filter { previous.owned[$0.key] != $0.value }
        if restored != current { try service.write(restored) }
      } catch {
        Log.keyRemapping.error("撤销键位映射没成：\(service.keyboard.name) \(error)")
      }
    }
    applied = [:]
    attempted = [:]
    serviceProblems = [:]
    connected = []
    problems = [:]
    stored = nil
  }

  func defaultsChanged() {
    guard running else { return }
    let text = defaults.string(forKey: rulesKey) ?? "[]"
    guard text != stored else { return }
    stored = text
    do {
      let loaded = try JSONDecoder().decode([Profile].self, from: Data(text.utf8))
      guard Set(loaded.map(\.keyboard.id)).count == loaded.count,
        loaded.allSatisfy({ profile in
          Set(profile.rules.map(\.source)).count == profile.rules.count
            && profile.rules.allSatisfy {
              HIDKey.isValid($0.source) && HIDKey.isValid($0.target) && $0.source != $0.target
            }
        })
      else { throw HIDKeyMapping.Failure.read }
      profiles = loaded
      configProblem = nil
    } catch {
      profiles = []
      configProblem = String(localized: "无法读取保存的键位映射")
      Log.keyRemapping.error("读不出保存的键位映射：\(error)")
    }
    refresh()
  }

  func save(_ rule: RemapRule, for keyboard: RemapKeyboard) {
    var rules = rules(for: keyboard)
    if let index = rules.firstIndex(where: { $0.source == rule.source }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    store(rules, for: keyboard)
  }

  func remove(_ rule: RemapRule, from keyboard: RemapKeyboard) {
    store(rules(for: keyboard).filter { $0.source != rule.source }, for: keyboard)
  }

  func rules(for keyboard: RemapKeyboard) -> [RemapRule] {
    profiles.first { $0.keyboard.id == keyboard.id }?.rules ?? []
  }

  private func store(_ rules: [RemapRule], for keyboard: RemapKeyboard) {
    var next = profiles.filter { $0.keyboard.id != keyboard.id }
    if !rules.isEmpty { next.append(Profile(keyboard: keyboard, rules: rules)) }
    do {
      let text = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
      defaults.set(text, forKey: rulesKey)
      defaultsChanged()
    } catch {
      configProblem = String(localized: "无法保存键位映射")
      Log.keyRemapping.error("存不下键位映射：\(error)")
    }
  }

  /// 键盘连上 / 断开：IOKit 里 HID 事件服务出现、消失时通知（回调在主线程的 run loop 上）。
  /// 本对象由 AppDelegate 拿到 App 退出为止，stop() 在放手之前先拆掉通知，所以 refcon 不挂空
  private func watchServices() {
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    notifyPort = port
    CFRunLoopAddSource(
      CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
      .commonModes)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
      var iterator: io_iterator_t = 0
      // 匹配字典会被这个调用拿走一份引用，不另外释放
      guard
        IOServiceAddMatchingNotification(
          port, type, IOServiceMatching("IOHIDEventService"),
          { refcon, iterator in KeyRemapping.servicesChanged(refcon, iterator) }, refcon, &iterator)
          == KERN_SUCCESS
      else { continue }
      Self.drain(iterator)  // 先把已有的取空，通知才会开始来
      iterators.append(iterator)
    }
  }

  nonisolated private static func servicesChanged(
    _ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t
  ) {
    drain(iterator)
    guard let refcon else { return }
    let remapping = Unmanaged<KeyRemapping>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { remapping.refreshSoon() }
  }

  nonisolated private static func drain(_ iterator: io_iterator_t) {
    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
  }

  /// IOKit 先报、HID 事件系统里的服务稍后才有：0.5 s 和 2 s 各核一次。
  /// ponytail: 两个固定的点，慢于 2 s 才出来的键盘要等醒来或打开设置页；真遇到再改成看到它为止
  private func refreshSoon() {
    pendingRefresh?.cancel()
    pendingRefresh = Task { [weak self] in
      for delay in [Duration.milliseconds(500), .seconds(2)] {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        self?.refresh(recheck: true)
      }
    }
  }

  private func currentServices() -> [HIDKeyMapping.Service]? {
    // 重连后 macOS 会创建新的 HID 服务，每次现建一个 simple client，不沿用旧的服务列表
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
    else { return nil }
    return services.compactMap { HIDKeyMapping.Service($0, client: client) }
  }

  func refresh(recheck: Bool = false) {
    guard running, let services = currentServices() else { return }
    var keyboards: [String: RemapKeyboard] = [:]
    var problems: [String: Issue] = [:]
    let live = Set(services.map(\.id))
    applied = applied.filter { live.contains($0.key) }
    attempted = attempted.filter { live.contains($0.key) }
    serviceProblems = serviceProblems.filter { live.contains($0.key) }
    for service in services {
      keyboards[service.keyboard.id] = service.keyboard
      let desired = rules(for: service.keyboard)
      if !desired.isEmpty || applied[service.id] != nil,
        recheck || attempted[service.id] != desired || serviceProblems[service.id] == nil
      {
        attempted[service.id] = desired
        reconcile(service, desired: desired)
      }
      if let issue = serviceProblems[service.id] { problems[service.keyboard.id] = issue }
    }
    let connected = keyboards.values.sorted {
      ($0.name, $0.id) < ($1.name, $1.id)
    }
    if self.connected != connected { self.connected = connected }
    if self.problems != problems { self.problems = problems }
  }

  private func reconcile(_ service: HIDKeyMapping.Service, desired: [RemapRule]) {
    do {
      let current = try service.read()
      let plan = try HIDKeyMapping.plan(
        current: current, owned: applied[service.id]?.owned ?? [:], desired: desired)
      if plan.mapping != current { try service.write(plan.mapping) }
      applied[service.id] = desired.isEmpty ? nil : Applied(owned: plan.owned, desired: desired)
      serviceProblems[service.id] = nil
    } catch HIDKeyMapping.Failure.conflict(let source) {
      serviceProblems[service.id] = Issue(
        message: String(localized: "\(HIDKey.title(source)) 已有其他映射"))
    } catch {
      // macOS 14.2 起改字母、数字这类键要「输入监听」授权，没有时系统不收这次写入
      let needsInputMonitoring = !CGPreflightListenEventAccess()
      serviceProblems[service.id] = Issue(
        message: needsInputMonitoring
          ? String(localized: "macOS 未应用映射。请检查输入监听权限。")
          : String(localized: "macOS 未应用键位映射"),
        needsInputMonitoring: needsInputMonitoring)
      Log.keyRemapping.error("应用键位映射没成：\(service.keyboard.name) \(error)")
    }
  }
}
