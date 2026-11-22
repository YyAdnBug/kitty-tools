// 识字准备标记被清理时补做一次。只听标记和它所在目录的删除 / 改名（清理器也可能把整个目录移进废纸篓），
// 不列缓存目录、不监听别的文件的读写、不轮询。修复由调用方提供，和启动、前台识字共用同一份准备任务。
// 常驻的代价是两个只收事件的描述符（O_EVTONLY）和两路挂在主队列上的文件事件，平时不醒。
// ponytail: 每清理一次就重编一次（27.0.1 本机冷编 33 s 墙钟、子进程 4.7 s CPU，另有 ANECompilerService 约 28 s，
// PR #42 评审实测）；被定时自动清理的话每次都付一遍，真遇到再加「一段时间内只补一次」

import Darwin
import Foundation

@MainActor
final class OCRPreparationMarkerWatcher {
  private let marker: URL
  /// true = 验过现有标记或写成了新标记；false = 准备失败，不能因为标记还没有就循环重试。
  private let repair: @MainActor () async -> Bool
  private var sources: [DispatchSourceFileSystemObject] = []
  private var generation = 0
  private var pending: Task<Void, Never>?
  private var running = false

  init(marker: URL, repair: @escaping @MainActor () async -> Bool) {
    self.marker = marker
    self.repair = repair
  }

  /// 刚打开识字功能时即使标记还在也要核系统版本，并按偏好预热进程内模型。
  func start(preparing: Bool = false) {
    let wasRunning = running
    running = true
    if preparing {
      scheduleRepair(debounced: false)
    } else if !wasRunning {
      arm(repairIfMissing: true)
    }
  }

  func stop() {
    running = false
    disarm()
    pending?.cancel()
    pending = nil
  }

  /// 后台那次失败后不自己重试；后来用户主动识字准备成了，从新标记接着听。
  func preparationSucceeded() {
    if running, pending == nil, sources.isEmpty { arm(repairIfMissing: true) }
  }

  private func disarm() {
    generation += 1
    for source in sources { source.cancel() }
    sources.removeAll(keepingCapacity: true)
  }

  private func scheduleRepair(debounced: Bool) {
    guard pending == nil else { return }
    disarm()  // 同一轮清理的两路通知只做一次；不对自己写的新标记起反应
    pending = Task { [weak self, repair] in
      if debounced { try? await Task.sleep(for: .milliseconds(500)) }
      guard !Task.isCancelled, self != nil else { return }
      let success = await repair()
      guard !Task.isCancelled, let self else { return }
      pending = nil
      arm(repairIfMissing: success)
    }
  }

  private func arm(repairIfMissing: Bool) {
    let generation = self.generation
    for url in [marker.deletingLastPathComponent(), marker] {
      let path = url.path(percentEncoded: false)
      let fd = open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else {
        let missing = errno == ENOENT
        disarm()
        // 准备成功到重新打开之间被删：这也是一次新的清理。打不开（如权限、描述符耗尽）不重试。
        if missing && repairIfMissing { scheduleRepair(debounced: true) }
        return
      }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .main)
      source.setCancelHandler { _ = close(fd) }
      source.setEventHandler { [weak self] in
        guard let self, self.generation == generation else { return }
        scheduleRepair(debounced: true)
      }
      // open 到内核真正挂好通知之间也可能被换掉。注册完成再核一次：路径必须仍指向手里那个对象。
      source.setRegistrationHandler { [weak self] in
        guard let self, self.generation == generation else { return }
        var opened = stat()
        var named = stat()
        guard fstat(fd, &opened) == 0 else { return }
        let changed =
          lstat(path, &named) == 0
          ? opened.st_dev != named.st_dev || opened.st_ino != named.st_ino : errno == ENOENT
        if changed { scheduleRepair(debounced: true) }
      }
      sources.append(source)
      source.activate()
    }
  }
}
