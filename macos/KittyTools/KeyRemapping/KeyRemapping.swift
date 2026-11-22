// 键位映射插件的启停、每把键盘的规则以及系统写入状态。

import AppKit
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

  private static let log = Logger(subsystem: "com.yy.kitty-tools.native", category: "KeyRemapping")
  private(set) var profiles: [Profile] = []
  private(set) var connected: [RemapKeyboard] = []
  private(set) var problems: [String: Issue] = [:]
  private(set) var configProblem: String?
  private(set) var needsFnAccess = false
  @ObservationIgnored private var client: IOHIDEventSystemClient?
  @ObservationIgnored private var monitor: Timer?
  @ObservationIgnored private var applied: [UInt64: Applied] = [:]
  @ObservationIgnored private var attempted: [UInt64: [RemapRule]] = [:]
  @ObservationIgnored private var serviceProblems: [UInt64: Issue] = [:]
  @ObservationIgnored private var stored: String?
  @ObservationIgnored private let rulesKey: String
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let fnEditingKeys = FnEditingKeys()

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
    // 只读取键盘服务和映射属性，无需打开键盘或读取按键。
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    monitor = timer
    RunLoop.main.add(timer, forMode: .common)
    defaultsChanged()
  }

  func stop() {
    monitor?.invalidate()
    monitor = nil
    for service in currentServices() ?? [] {
      guard let previous = applied[service.id], !previous.owned.isEmpty else { continue }
      do {
        let current = try service.read()
        let restored = current.filter { previous.owned[$0.key] != $0.value }
        if restored != current { try service.write(restored) }
      } catch {
        Self.log.error("Could not remove key mappings for \(service.keyboard.name): \(error)")
      }
    }
    fnEditingKeys.stop()
    needsFnAccess = false
    applied = [:]
    attempted = [:]
    serviceProblems = [:]
    connected = []
    problems = [:]
    stored = nil
    client = nil
  }

  func defaultsChanged() {
    guard monitor != nil else { return }
    let text = defaults.string(forKey: rulesKey) ?? "[]"
    guard text != stored else { return }
    stored = text
    do {
      let loaded = try JSONDecoder().decode([Profile].self, from: Data(text.utf8))
      guard Set(loaded.map(\.keyboard.id)).count == loaded.count,
        loaded.allSatisfy({ profile in
          Set(profile.rules.map(\.source)).count == profile.rules.count && profile.rules.allSatisfy {
            HIDKey.isValid($0.source) && HIDKey.isValid($0.target) && $0.source != $0.target
          }
        })
      else { throw HIDKeyMapping.Failure.read }
      profiles = loaded
      configProblem = nil
    } catch {
      profiles = []
      configProblem = String(localized: "无法读取保存的键位映射")
      Self.log.error("Could not read key mappings: \(error)")
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
      Self.log.error("Could not save key mappings: \(error)")
    }
  }

  private func currentServices() -> [HIDKeyMapping.Service]? {
    // 重连后 macOS 会创建新的 HID 服务。重新建立 simple client，避免沿用旧服务列表。
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
    else { return nil }
    self.client = client
    return services.compactMap(HIDKeyMapping.Service.init)
  }

  func refresh(recheck: Bool = false) {
    guard monitor != nil, let services = currentServices() else { return }
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
    let wantsFn = applied.values.contains { $0.desired.contains { $0.target == HIDKey.globe.id } }
    if wantsFn {
      if recheck || !needsFnAccess { needsFnAccess = !fnEditingKeys.start() }
    } else {
      fnEditingKeys.stop()
      needsFnAccess = false
    }
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
      serviceProblems[service.id] = Issue(message: String(localized: "\(HIDKey.title(source)) 已有其他映射"))
    } catch {
      let needsInputMonitoring = !CGPreflightListenEventAccess()
      serviceProblems[service.id] = Issue(
        message: needsInputMonitoring
          ? String(localized: "macOS 未应用映射。请检查输入监听权限。")
          : String(localized: "macOS 未应用键位映射"),
        needsInputMonitoring: needsInputMonitoring)
      Self.log.error("Could not apply key mappings to \(service.keyboard.name): \(error)")
    }
  }
}
