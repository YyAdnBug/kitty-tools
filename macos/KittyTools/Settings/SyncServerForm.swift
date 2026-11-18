// 设置 › 通用「同步」里「连接服务器…」的表单（issue #18，2026-11-13）：填 WebDAV 服务器的地址、文件夹、用户名和密码。
// 「测试连接」看连不连得上、能不能写；「连接」先看服务器上那个文件夹（NoteSyncServer.inspect），已经有别的电脑在同步就先问
// 合不合在一起（说明同选文件夹时那段，SyncSection.joinNote），再开（NoteSyncer.enable(server:)，看过的那一眼一起交过去，
// 不再列一遍）。网络都在主线程外。测试、连接时只停用输入框和按钮，「取消」和 Esc 照常能用：表单收起就取消在跑的请求
// （第五轮体检 U2①）。同一个文件里还有「更新密码…」的小表单（SyncPasswordForm，E1）。

import SwiftUI

/// 骨架同导出、导入的表单（TransferForm）：页头、四个输入框、「测试连接」和一行说明 / 结果，底栏「取消」「连接」
struct SyncServerForm: View {
  let syncer: NoteSyncer
  /// 开成了（调用方收起表单、start）
  let connected: () -> Void
  @State private var address = ""
  @State private var path = Self.defaultFolder
  @State private var user = ""
  @State private var password = ""
  /// 正在测试 / 连接（输入框、「测试连接」「连接」停用；「取消」不停用）
  @State private var working = false
  /// 在跑的测试 / 连接：表单收起（「取消」、Esc）时取消，请求跟着停
  @State private var task: Task<Void, Never>?
  /// 测试、连接的结果（没有时显示说明）
  @State private var outcome: Outcome?
  /// 服务器上已经有别的电脑在同步：确认框开着时有值
  @State private var joining: Joining?

  /// 服务器上默认的文件夹名：**永远不翻**（多语言，TRANSLATION.md 二）——中英两台都用默认值时要连到同一个文件夹
  static let defaultFolder = "Kitty Tools 同步"

  enum Outcome: Equatable {
    case fine(String)
    case problem(String)
  }

  struct Joining {
    var account: WebDAV.Account
    var seen: NoteSyncDisk.Inspection
  }

  var body: some View {
    TransferForm(
      symbol: "server.rack", title: "连接 WebDAV 服务器",
      detail: "几台电脑连同一个服务器上的同一个文件夹，不在一个网络里也能同步。",
      action: "连接", canAct: account != nil && !working, act: connect
    ) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          Text("服务器地址").gridColumnAlignment(.trailing)
          TextField("服务器地址", text: $address, prompt: Text(verbatim: "https://dav.example.com/dav/"))
        }
        GridRow {
          Text("文件夹")
          TextField("文件夹", text: $path, prompt: Text(verbatim: Self.defaultFolder))
        }
        GridRow {
          Text("用户名")
          TextField("用户名", text: $user)
        }
        GridRow {
          Text("密码")
          SecureField("密码", text: $password)
        }
      }
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .disabled(working)
      .onChange(of: [address, path, user, password]) { outcome = nil }
      HStack(spacing: 8) {
        Button("测试连接", action: test)
          .disabled(account == nil || working)
        if working { ProgressView().controlSize(.small) }
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 4) {
        switch outcome {
        case .fine(let text):
          Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        case .problem(let text):
          Text(text).foregroundStyle(Color(nsColor: .systemOrange))
        case nil:
          Text(
            "文件夹没有的话连接时新建，每台电脑填同一个。密码存在这台 Mac 的钥匙串里；有的服务要在网页上另外生成给第三方应用用的密码。"
          )
          .foregroundStyle(.secondary)
        }
        if insecure {
          Text("这个地址没加密（http），密码和同步的内容在网上都是明文的")
            .foregroundStyle(Color(nsColor: .systemOrange))
        }
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
    }
    .onDisappear { task?.cancel() }
    .confirmationDialog(
      "和服务器上这个文件夹里已经在同步的电脑合在一起？",
      isPresented: Binding {
        joining != nil
      } set: {
        if !$0 { joining = nil }
      },
      presenting: joining
    ) { joining in
      Button("合在一起") { task = Task { await enable(joining.account, seen: joining.seen) } }
    } message: { joining in
      Text(SyncSection.joinMessage(devices: joining.seen.devices, notes: joining.seen.notes))
    }
  }

  /// 填的样子拼成的账号：地址不像（不是 http(s)、没有主机）、没填用户名或密码时是 nil
  private var account: WebDAV.Account? {
    let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !user.isEmpty, !password.isEmpty,
      let folder = WebDAV.folder(address: address, path: path)
    else { return nil }
    return WebDAV.Account(folder: folder, user: user, password: password)
  }

  private var insecure: Bool {
    address.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
  }

  private func test() {
    guard let account else { return }
    working = true
    outcome = nil
    task = Task {
      switch await NoteSyncServer.test(account, session: syncer.session) {
      case .success(.ready): outcome = .fine(String(localized: "连上了，能读能写"))
      case .success(.missing): outcome = .fine(String(localized: "连上了；服务器上还没有这个文件夹，连接时会新建"))
      case .failure(let failure): outcome = .problem(failure.message)
      }
      working = false
    }
  }

  /// 先看服务器上那个文件夹：有别的电脑在同步（格式不比这一版新）就先问，不然直接开
  private func connect() {
    guard let account else { return }
    working = true
    outcome = nil
    task = Task {
      switch await NoteSyncServer.inspect(
        account, session: syncer.session, device: syncer.store.deviceID)
      {
      case .failure(let failure):
        outcome = .problem(failure.message)
        working = false
      case .success(let seen):
        if let marker = seen.marker, marker.format <= NoteSyncFolder.format, seen.devices > 0 {
          working = false
          joining = Joining(account: account, seen: seen)
        } else {
          await enable(account, seen: seen)
        }
      }
    }
  }

  /// 表单收起了（「取消」、Esc）就什么都不开、不说；enable 自己落盘前也看一眼（U2⑥）。enable 返回 nil 就是已经开成了
  /// （它落盘之后没有 await）：这时照样 connected()，不然同步开着却要到下次打开 App 才走
  private func enable(_ account: WebDAV.Account, seen: NoteSyncDisk.Inspection) async {
    guard !Task.isCancelled else { return }
    working = true
    let problem = await syncer.enable(server: account, seen: seen)
    working = false
    if let problem {
      if !Task.isCancelled { outcome = .problem(problem) }
    } else {
      connected()
    }
  }
}

/// 「更新密码…」（第五轮体检 E1：服务器不认密码之后，同步那一行上）：只换这台 Mac 钥匙串里的密码，镜像和它的账留着，
/// 换好马上接着同步（NoteSyncer.updatePassword）。骨架同上面那张（TransferForm）
struct SyncPasswordForm: View {
  let syncer: NoteSyncer
  @State private var password = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    TransferForm(
      symbol: "key.fill", title: "更新密码",
      detail: "只换这台 Mac 钥匙串里存的密码；同步的数据都留着，换好马上接着同步。",
      action: "更新", canAct: !password.isEmpty, act: update
    ) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          Text("服务器").gridColumnAlignment(.trailing)
          Text(verbatim: shownServer)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
        }
        GridRow {
          Text("用户名")
          Text(verbatim: syncer.serverUser ?? "")
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
        }
        GridRow {
          Text("密码")
          SecureField("密码", text: $password)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
        }
      }
    }
  }

  /// 网址给人看的样子（中文的文件夹名不显示成 %E5…）
  private var shownServer: String {
    let address = syncer.server?.absoluteString ?? ""
    return address.removingPercentEncoding ?? address
  }

  private func update() {
    syncer.updatePassword(password)
    dismiss()
  }
}
