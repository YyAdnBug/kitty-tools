#!/usr/bin/env swift
// Windows 更新清单的签名（2026-11-25 拍板 W1，PLAN §10「GitCode 国内分发」）：Windows 包没有代码签名，App 内更新原来只信
// GitHub 的地址；GitCode 上那份 windows-update.json 要带这把钥匙的签名（windows-update.json.sig），Windows 版写死公钥、
// 签名对得上才认（windows 分支 KittyTools.Core/UpdateManifest.cs 的 SigningKey / VerifySignature）。
// ECDSA P-256 + SHA-256，签名是 DER 编码（.NET 的 DSASignatureFormat.Rfc3279DerSequence）再 base64，公钥是 SubjectPublicKeyInfo 的
// DER 再 base64（.NET 的 ImportSubjectPublicKeyInfo）；只用 CryptoKit 和钥匙串，零依赖。
// 私钥只在你的登录钥匙串里（服务名 kitty-tools-update-signing），脚本不打印它。**丢了就没法给 Windows 版发 GitCode 那条路的更新**
// （只能发一个手动下载的新版本换公钥），所以 new-key 之后自己备份一份：打开「钥匙串访问」搜 kitty-tools-update-signing →
// 显示密码 → 存进密码管理器。
// 用法：
//   swift macos/sign-manifest.swift new-key          生成一把存进钥匙串（已经有了就不动），打印公钥（填进 Windows 的 SigningKey）
//   swift macos/sign-manifest.swift public-key       打印钥匙串里那把的公钥
//   swift macos/sign-manifest.swift sign <文件>       用钥匙串里那把签，写 <文件>.sig（publish-gitcode.sh 调）
//   swift macos/sign-manifest.swift selftest <目录>   用一把临时钥匙签一个样例，写 pub.der / sample.json / sample.json.sig（不碰钥匙串；
//                                                    openssl 交叉核对、生成 Windows 单测的测试向量用）
import CryptoKit
import Foundation
import Security

let service = "kitty-tools-update-signing"

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// 钥匙串里那把（原始的 32 字节标量，base64 存成一条通用密码）；没有就 nil
func storedKey() -> P256.Signing.PrivateKey? {
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  var item: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &item)
  guard status == errSecSuccess, let data = item as? Data,
    let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self))
  else {
    if status != errSecItemNotFound && status != errSecSuccess { fail("读钥匙串失败（\(status)）") }
    return nil
  }
  return try? P256.Signing.PrivateKey(rawRepresentation: raw)
}

func publicKey(_ key: P256.Signing.PrivateKey) -> String {
  key.publicKey.derRepresentation.base64EncodedString()
}

/// 签 data，签完用公钥核一遍
func signature(of data: Data, with key: P256.Signing.PrivateKey) -> Data {
  guard let signed = try? key.signature(for: data), key.publicKey.isValidSignature(signed, for: data)
  else { fail("签名失败") }
  return signed.derRepresentation
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.dropFirst().first) {
case ("new-key", nil):
  if let key = storedKey() {
    print("钥匙串里已经有一把了，没动它。公钥：\n\(publicKey(key))")
    exit(0)
  }
  let key = P256.Signing.PrivateKey()
  let add: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    kSecAttrAccount as String: NSUserName(), kSecAttrLabel as String: service,
    kSecValueData as String: Data(key.rawRepresentation.base64EncodedString().utf8),
  ]
  let status = SecItemAdd(add as CFDictionary, nil)
  guard status == errSecSuccess else { fail("存进钥匙串失败（\(status)）") }
  print("存好了（钥匙串里的 \(service)）。先备份：「钥匙串访问」里搜它 → 显示密码 → 存进密码管理器。")
  print("公钥（填进 windows 分支 KittyTools.Core/UpdateManifest.cs 的 SigningKey）：\n\(publicKey(key))")
case ("public-key", nil):
  guard let key = storedKey() else { fail("钥匙串里没有 \(service)：先跑 new-key") }
  print(publicKey(key))
case ("sign", let path?):
  guard let key = storedKey() else { fail("钥匙串里没有 \(service)：先跑 new-key") }
  guard let data = FileManager.default.contents(atPath: path) else { fail("读不到 \(path)") }
  let text = signature(of: data, with: key).base64EncodedString() + "\n"
  do { try Data(text.utf8).write(to: URL(filePath: path + ".sig"), options: .atomic) } catch {
    fail("写不了 \(path).sig：\(error.localizedDescription)")
  }
case ("selftest", let folder?):
  let key = P256.Signing.PrivateKey()
  let sample = Data(
    #"{"version":"0.3.0","page":"https://gitcode.com/yyandbug/kitty-tools/releases/windows-v0.3.0"}"#.utf8)
  let directory = URL(filePath: folder)
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try key.publicKey.derRepresentation.write(to: directory.appending(path: "pub.der"))
    try sample.write(to: directory.appending(path: "sample.json"))
    try signature(of: sample, with: key).write(to: directory.appending(path: "sample.json.sig.der"))
    try Data((signature(of: sample, with: key).base64EncodedString() + "\n").utf8)
      .write(to: directory.appending(path: "sample.json.sig"))
  } catch { fail("写不了 \(folder)：\(error.localizedDescription)") }
  print("公钥 \(publicKey(key))")
  print("样例 \(sample.base64EncodedString())")
  print("签名 \(signature(of: sample, with: key).base64EncodedString())")
default:
  fail("用法：swift macos/sign-manifest.swift new-key | public-key | sign <文件> | selftest <目录>")
}
