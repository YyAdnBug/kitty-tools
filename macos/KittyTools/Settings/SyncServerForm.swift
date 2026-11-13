// 设置 › 通用「同步」里「连接服务器…」的表单（issue #18，2026-11-13）：填 WebDAV 服务器的地址、文件夹、用户名和密码。
// 「测试连接」看连不连得上、能不能写；「连接」先看服务器上那个文件夹（NoteSyncServer.inspect），已经有别的电脑在同步就先问
// 合不合在一起（说明同选文件夹时那段，SyncSection.joinNote），再开（NoteSyncer.enable(server:)）。网络都在主线程外。

import SwiftUI

/// 骨架同导出、导入的表单（TransferForm）：页头、四个输入框、「测试连接」和一行说明 / 结果，底栏「取消」「连接」
struct SyncServerForm: View {
  let syncer: NoteSyncer
  /// 开成了（调用方收起表单、start）
  let connected: () -> Void
  @State private var address = ""
  @State private var path = "Kitty Tools 同步"
  @State private var user = ""
  @State private var password = ""
  /// 正在测试 / 连接（输入框和按钮都停用）
  @State private var working = false
  /// 测试、连接的结果（没有时显示说明）
  @State private var outcome: Outcome?
  /// 服务器上已经有别的电脑在同步：确认框开着时有值
  @State private var joining: Joining?

  enum Outcome: Equatable {
    case fine(String)
    case problem(String)
  }

  struct Joining {
    var account: WebDAV.Account
    var devices: Int
    var notes: Int
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
          TextField("文件夹", text: $path, prompt: Text("Kitty Tools 同步"))
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
    .disabled(working)
    .confirmationDialog(
      "和服务器上这个文件夹里已经在同步的电脑合在一起？",
      isPresented: Binding {
        joining != nil
      } set: {
        if !$0 { joining = nil }
      },
      presenting: joining
    ) { joining in
      Button("合在一起") { Task { await enable(joining.account) } }
    } message: { joining in
      Text(
        (joining.notes > 0
          ? "这个文件夹里已经有 \(joining.devices) 台电脑在同步，有 \(joining.notes) 条便签（含「最近删除」里的）。"
          : "这个文件夹里已经有 \(joining.devices) 台电脑在同步。")
          + SyncSection.joinNote)
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
    Task {
      switch await NoteSyncServer.test(account, session: syncer.session) {
      case .success(.ready): outcome = .fine("连上了，能读能写")
      case .success(.missing): outcome = .fine("连上了；服务器上还没有这个文件夹，连接时会新建")
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
    Task {
      switch await NoteSyncServer.inspect(
        account, session: syncer.session, device: syncer.store.deviceID)
      {
      case .failure(let failure):
        outcome = .problem(failure.message)
        working = false
      case .success(let seen):
        if let marker = seen.marker, marker.format <= NoteSyncFolder.format, seen.devices > 0 {
          working = false
          joining = Joining(account: account, devices: seen.devices, notes: seen.notes)
        } else {
          await enable(account)
        }
      }
    }
  }

  private func enable(_ account: WebDAV.Account) async {
    working = true
    let problem = await syncer.enable(server: account)
    working = false
    if let problem {
      outcome = .problem(problem)
    } else {
      connected()
    }
  }
}
