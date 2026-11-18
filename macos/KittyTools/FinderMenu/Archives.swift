// 访达右键「压缩为 ▸ ZIP、7Z、TAR.GZ」「解压到这里」（2026-11-08 右键扩充第 2 批，拍板 D1 D2；TAR.GZ 2026-11-17）。都交给系统自带的
// tar（bsdtar；另起进程，不卡主线程、停得住），不带第三方：
// - 压缩：一样东西叫「名字.zip」，几样叫「归档.zip」（同访达；跟当时的界面语言，英文界面「Archive.zip」），放在第一样所在的
//   文件夹、重名加「 2」。zip 里的名字标上 UTF-8（zip:hdrcharset=UTF-8；访达和 ditto 打的不标，别的系统解开中文名会乱码，
//   2026-11-08 实测），不带 __MACOSX、._*、.DS_Store（--no-mac-metadata 加排除）；7z 用 LZMA2。只选了一个包（App 这类）时 zip 改用 ditto（同访达的压缩：带着扩展属性，
//   签名不坏）。不同文件夹里的同名东西包里只放得下一个，不打。不做带密码的压缩（拍板）。
//   tar.gz（2026-11-17）：gzip 是 tar 自带的 zlib，不靠外面的程序；名字按 pax 存成 UTF-8。另加 --no-xattrs --no-acls --no-fflags：
//   --no-mac-metadata 只管 ._ 那份，扩展属性（每个文件都有的 com.apple.provenance、下载来的隔离标记）、上锁 / 隐藏标志照样写进
//   pax 头（LIBARCHIVE.xattr.*、SCHILY.fflags，实测），Linux 的 GNU tar 解的时候每个文件报一句「Ignoring unknown extended header
//   keyword」。别的几种不加：.tar.xz 慢（38 MB 22 s，gz 1.7 s，只小两成）、.tar.zst 系统 tar 没带 zstd、要外面的程序（实测报错），
//   .tar.bz2 / 不压缩的 .tar 用的人少，菜单不加长。
// - 解压：zip、7z、rar、tar 一族（.tar、.tar.gz / .tgz、.tar.xz / .txz、.tar.bz2 / .tbz），和只压了一个文件的 .gz / .bz2
//   （系统的 gunzip / bunzip2，解出来的叫包名去掉 .gz，带上包的隔离标记）。RAR（2026-11-12）：系统 tar 是 libarchive 3.7.4，
//   RAR4、RAR5 都解得开（本机样本实测，字节数和清单一致）；带密码的解不开（libarchive 不解 RAR 的密码：头加了密的 tar 说
//   「encryption」，只是数据加了密的它不认、当成坏数据报错，所以 RAR 解不开时的原因写「坏了，或者有密码」）；分卷的不解
//   （RAR5 读到第一卷末尾当成包结束了，没被切开的那几样解出来、tar 照样退出 0，像是解完了）：先读主头的「分卷」标志，标着就不交给 tar。
//   zip 先读一遍中央目录（ZipNames）：
//   没标 UTF-8、名字又不是合法 UTF-8 的按 GB18030 解（不说的话 tar 直接报错，ditto 解出来是乱码，实测）；有加密的条目先问密码
//   （tar 认 ZipCrypto 和 AES；不对再问）：本 App 不在前台时先在刘海岛说「有密码」带「输入密码…」，点了再弹框——直接弹的框
//   拿不到键盘，打的字会进访达。先解进包旁边一个隐藏的临时文件夹，里面只有一样东西就把它放到包旁边，几样就把
//   临时文件夹改成包的名字（同归档实用工具），重名加「 2」；出错、停了只删临时文件夹。包带着「从网上下载」的隔离标记时，
//   系统 tar 自己会给解出来的每样东西也带上（实测），不另外做；它默认也不解绝对路径、带 .. 的路径，不顺着包里的符号链接往外写。
// - 压缩时另外跳过的名字（2026-11-13 拍板 Z1–Z5，Prefs.finderCompressSkip，默认空）：只认名字（任意一层叫这个名字的都不压，
//   只有 * ? 是通配），带「/」的不收；选中的那几样自己不跳过；不进 .app 这类包里面跳（跳掉包里的东西签名就坏了，只压一个包走
//   ditto 时整个不用名单）；解压不受影响。**不能直接交给 tar 的 --exclude**（评审实测 bsdtar 3.5.3：它的匹配能从路径里任意一层
//   开头、任意一层结尾，* 和 ? 还跨「/」——「Screenshot*.png」会扔掉 Screenshots/2024/a.png；[ ] \ 也被当成通配）：先用 find
//   按名字找出要跳的确切路径（skipFindArguments：-name 只看名字，最外层 -depth +0 不算，包 -prune 不进去），转义后写进一个
//   临时文件交给 tar -X（escapedForTar）；进度的总大小 = 全部 − 跳过的那几样（skipped）。
// - 只差大小写的文件（2026-11-17 拍板 A2）：Mac 的盘默认不分大小写，包里有 src/Readme.md 和 src/README.md 时 tar 解出来只剩
//   后一个、照样退出 0（实测）；文件 BUILD 后面跟着文件夹 build/ 时，文件被文件夹顶掉、也退出 0（评审实测）。解压加 -v 让 tar
//   报出解了哪些，caseClashes 按包里的先后找出被顶掉的文件（文件夹只参与比：同名的文件夹合在一起，留第一个的写法），再一次把它们
//   都解到旁边的临时文件夹（同一组里丢了不止一个时分几轮，免得在临时文件夹里又撞上），改名加「 2」放回原来那一层（同访达拷贝
//   重名），刘海岛说一声；平时不多读一遍包，只有撞名时才多读，进度条照走。分大小写的盘（volumeSupportsCaseSensitiveNames）上
//   两个本来都在，不做。另存不了的（名字里有「\」——-v 会把它打成「\\」，对不上；包里是绝对路径；落不下）照实说几个。
//   -v 要 UTF-8 的 locale（不然中文名打成转义），出错原因里先去掉 -v 报的名字（extractErrors）。
// - 包旁边放不下（只读的盘、没有写权限的文件夹；2026-11-17 拍板 B1）：动手之前先看（unwritable；不然 tar 只说「Failed to open」），
//   刘海岛上带「放到下载」「选择位置…」两个按钮，换个地方再做（同几家解压软件碰到只读位置时问放哪）。
// - 解压后把压缩包移到废纸篓（2026-11-17 拍板 B2，设置一项、默认关；同系统归档实用工具「展开后：将归档移到废纸篓」）：
//   解成功才移，刘海岛上带「放回压缩包」（从废纸篓挪回原处，不覆盖）。按住 ⌥ 的「解压到…」（B3）先选放在哪，走同一个 into。
// - 压缩时有文件读不到（2026-11-17 拍板 A3）：说出是哪个（unreadable：tar 的「Can't open `x'」「x: Couldn't visit directory」
//   「x: Cannot stat」），整个照旧不打（同访达自带的压缩）；原来一律说成「没有权限读写这个位置」。
// - 进度条（ByteMeter）：压缩按读过的字节（tar -v / ditto -V 报做完的文件，加上正读着的那个读到哪了），解压按压缩包读到第几个
//   字节，刘海岛上「42% · 1.2 GB / 2.9 GB」。
// - 落到正式名字都用「目标已存在就报错」的改名（FileMoves.land），算完名字到落下之间别人占了也盖不掉；和移动、复制排在同一条队
//   （FileMoves.enqueue）：超过 1 秒在刘海岛上挂「正在…」带「停止」，做完说一声、带「在访达中显示」。
// 名字、tar 的参数、出错原因是纯函数（ArchivesTests，另在临时文件夹里真压、真解一遍）。
// ponytail: 读 zip 的中央目录在主线程上（几万条的包要几十毫秒，在卡住的网络盘上会跟着卡）；真遇到再挪到主线程外。
//   iCloud 云盘这类还没下载下来的包不读（一读就要整个下载、主线程卡到下完）：不认 GBK、不预先问密码，tar 说要密码时再问。
// ponytail: tar 打的 zip / 7z 里不带访达的标签、替身、上锁、自定义图标（bsdtar 的 zip 写入不存这些，评审实测；设置页写明了，
//   在 Mac 之间原样传用访达自带的「压缩」）。叫「._*」「__MACOSX」的普通文件也会被当成杂文件跳过。
// ponytail: 解压后在主线程上拆一遍 tar -v 的输出找撞名（caseClashes）：几千条无感，二十万条的包估计要停顿一秒左右（没量过）；
//   碰到再挪出主线程（mac-native §3 的 @concurrent 白名单里没有这一类，要先拍板）。
// ponytail: 7z 是先把整份压缩数据暂存在启动盘的临时目录里再写到目标（bsdtar 的做法），空间不够说的是启动盘。
// ponytail: zip 的密码放在 tar 的命令行上（--passphrase，本机同一个用户的进程用 ps 看得到）：tar 只认它和终端输入。

import AppKit

@MainActor enum Archives {
  nonisolated enum Format: String {
    case zip
    case sevenZip = "7z"
    case tarGz = "tar.gz"
  }

  /// 压缩还是解压（刘海岛上说哪一个）
  nonisolated enum Verb {
    case compress, extract
  }

  /// 一次的结果
  nonisolated enum Outcome: Equatable {
    /// renamed：解压时只差大小写、另存的那几个的新名字；unsaved：只差大小写、没能另存的几个
    case done(URL, renamed: [String] = [], unsaved: Int = 0)
    case stopped
    /// 没给密码，tar 说要（中央目录没读出来加密的条目时）
    case needsPassword
    case wrongPassword
    case failed(String)
  }

  // MARK: 名字和参数（纯函数）

  /// 「解压到这里」认的（扩展里抄了一份，FinderLinkTests 比对）
  nonisolated static let suffixes = [
    ".zip", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tbz2", ".gz",
    ".bz2", ".rar",
  ]

  /// RAR 的主头标着「分卷」吗（head：包开头的几十个字节）。RAR4：7 字节的签名后是主头（类型 0x73），标志第 0 位；
  /// RAR5：8 字节的签名后是 CRC32、头大小、头类型（1 = 主头）、头标志（第 0 位：后面跟附加区大小），再是归档标志，第 0 位。
  /// 都是变长整数。头加了密的 RAR5（主头前是类型 4）读不出来，算不是（tar 会说加了密）
  nonisolated static func isRARVolume(_ head: Data) -> Bool {
    let bytes = [UInt8](head.prefix(64))
    if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) {
      return bytes.count > 10 && bytes[9] == 0x73 && bytes[10] & 0x01 != 0
    }
    guard bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) else { return false }
    var index = 12
    func number() -> UInt64? {
      var value: UInt64 = 0
      var shift: UInt64 = 0
      while index < bytes.count, shift < 64 {
        let byte = bytes[index]
        index += 1
        value |= UInt64(byte & 0x7F) << shift
        if byte & 0x80 == 0 { return value }
        shift += 7
      }
      return nil
    }
    guard number() != nil, number() == 1, let flags = number() else { return false }
    if flags & 0x01 != 0, number() == nil { return false }
    return (number() ?? 0) & 0x01 != 0
  }

  /// 只压了一个文件的 .gz / .bz2（不是 tar 包）交给系统的 gunzip / bunzip2（tar 不认这种，实测）；别的是 nil。
  /// 单文件的 .xz 不认（系统的 gunzip 据说也解得了，但本机造不出样本来验）
  nonisolated static func decompressor(for archive: URL) -> String? {
    switch suffix(of: archive) {
    case ".gz": "/usr/bin/gunzip"
    case ".bz2": "/usr/bin/bunzip2"
    default: nil
    }
  }

  /// 认得的扩展名里最长的那个（.tar.gz 不当成 .gz）；光有扩展名、前面没名字的不算
  nonisolated static func suffix(of url: URL) -> String? {
    let name = url.lastPathComponent.lowercased()
    return suffixes.filter { name.hasSuffix($0) && name.count > $0.count }
      .max { $0.count < $1.count }
  }

  nonisolated static func isArchive(_ url: URL) -> Bool { suffix(of: url) != nil }

  /// 解出来的文件夹叫什么：去掉扩展名（.tar.gz 整个去掉）
  nonisolated static func stem(of archive: URL) -> String {
    let name = archive.lastPathComponent
    guard let suffix = suffix(of: archive) else { return name }
    return String(name.dropLast(suffix.count))
  }

  /// 打出来的包叫什么：一样东西用它的名字，几样叫「归档」（同访达；跟界面语言）。名字太长的截短：加上扩展名、重名时的「 99」
  /// 还在 255 个字符以内（同 NewFile.freeName；不然白打完一整包、落不下来）
  nonisolated static func archiveName(for items: [URL], format: Format) -> String {
    var base =
      items.count == 1
      ? items[0].lastPathComponent
      : String(
        localized: "finder.archiveName", defaultValue: "归档",
        comment: "访达右键压缩几样东西时包的文件名（不含扩展名），同访达自己的「归档.zip」")
    while (base + " 99." + format.rawValue).utf16.count > 255 { base.removeLast() }
    return base + "." + format.rawValue
  }

  /// 包落在 folder 里叫什么：重名加「 2」。tar.gz 的「 2」加在整个扩展名前面（「资料 2.tar.gz」）：FileMoves.freeName 只认最后一段
  /// 扩展名（同访达拷贝时），会让成「资料.tar 2.gz」，再「解压到这里」就被当成只压了一个文件的 .gz
  nonisolated static func freeName(_ name: String, format: Format, in folder: URL) -> String {
    guard format == .tarGz, name.hasSuffix(".tar.gz") else {
      return FileMoves.freeName(name, in: folder, used: [])
    }
    return NewFile.freeName(String(name.dropLast(3))) {
      FileMoves.occupied(folder.appending(path: $0 + ".gz"))
    } + ".gz"
  }

  /// 同名的（不分大小写、统一合成形式：解到 Mac 上会撞）第一个：包里只放得下一个
  nonisolated static func clash(in items: [URL]) -> String? {
    var seen = Set<String>()
    return items.first {
      !seen.insert($0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted
    }?.lastPathComponent
  }

  /// 打包、解包都不要的 Mac 杂文件
  nonisolated static let junk = ["__MACOSX", "._*", ".DS_Store"]

  /// 用户另加的跳过名单（设置里那一页拼成的一行字）：skipEntries 里不带毛病（skipProblem）的，最多 50 条
  /// （偏好是导入、同步来的，不信它）
  nonisolated static func skipNames(_ text: String) -> [String] {
    Array(skipEntries(text).filter { skipProblem($0) == nil }.prefix(50))
  }

  /// 那一行字拆成的每一条：全角半角逗号隔开、去掉两头空白、去掉空的和重复的；写错的也留着（设置页列出来、标橙，让人看到再删）
  nonisolated static func skipEntries(_ text: String) -> [String] {
    var entries: [String] = []
    for part in text.split(whereSeparator: { $0 == "," || $0 == "，" }) {
      let name = part.trimmingCharacters(in: .whitespaces)
      if !name.isEmpty, !entries.contains(name) { entries.append(name) }
    }
    return entries
  }

  /// 一条为什么不算（设置页上的橙字）：带「/」的不认（只认名字，Z2）、超过 100 个字的不收；nil = 照跳
  nonisolated static func skipProblem(_ name: String) -> String? {
    if name.contains("/") { return String(localized: "只认名字、不认路径") }
    if name.count > 100 { return String(localized: "超过 100 个字") }
    return nil
  }

  /// 不进去跳的包（扩展名）：App、框架、插件这类带签名的包，跳掉里面的东西就坏了。
  /// ponytail: 按扩展名认，没列的包（.rtfd、.photoslibrary 之类）里面照样跳；要按访达认的包算得自己走一遍目录，有人碰到再改
  nonisolated static let packages = [
    "app", "framework", "bundle", "plugin", "appex", "xpc", "kext", "systemextension",
  ]

  /// 找要跳的路径的 find 参数（在 roots 所在的文件夹里跑，roots 是「./名字」）：名字对上的打印出来、不进去；最外层（选中的那几样）
  /// 不算（-depth +0）；包不进去（先看名字：包自己叫名单里的名字照样跳）。名单里的 [ ] \ 转义掉，只有 * ? 是通配
  nonisolated static func skipFindArguments(_ names: [String], roots: [String]) -> [String] {
    let either = { (patterns: [String]) in
      patterns.enumerated().flatMap { ($0 == 0 ? [] : ["-o"]) + ["-name", $1] }
    }
    let escaped = names.map {
      $0.replacing("\\", with: "\\\\").replacing("[", with: "\\[").replacing("]", with: "\\]")
    }
    return roots + ["(", "-depth", "+0", "("] + either(escaped) + [
      ")", ")", "-prune", "-print0", "-o", "(",
    ]
      + either(packages.map { "*." + $0 }) + [")", "-type", "d", "-prune"]
  }

  /// 交给 tar 的一个确切路径（-X 的一行、解压时跟在 -- 后面的写法）：* ? [ ] \ 前面加反斜杠，不让它当通配；^ $ 也加
  /// （开头的 ^、结尾的 $ 会被当成锚点：「^Readme」解出了「Readme」，评审实测）
  nonisolated static func escapedForTar(_ path: String) -> String {
    var line = ""
    for character in path {
      if "\\*?[]^$".contains(character) { line.append("\\") }
      line.append(character)
    }
    return line
  }

  /// 这一次要跳的确切路径：每个文件夹里跑一次 find（另起进程），给回「./名字/…」和它的完整路径（量大小用）。名单空时不跑。
  /// ponytail: 名字里带换行的找到了也写不进 tar -X 的一行，照压不跳
  static func skipped(_ items: [URL], names: [String]) async -> [(relative: String, url: URL)] {
    guard !names.isEmpty else { return [] }
    var groups: [(folder: String, roots: [String])] = []
    for item in items {
      let folder = (FileMoves.plainPath(item) as NSString).deletingLastPathComponent
      let root = "./" + item.lastPathComponent
      if let index = groups.firstIndex(where: { $0.folder == folder }) {
        groups[index].roots.append(root)
      } else {
        groups.append((folder, [root]))
      }
    }
    var found: [(relative: String, url: URL)] = []
    for group in groups {
      guard
        let result = try? await Subprocess.run(
          "/usr/bin/find", skipFindArguments(names, roots: group.roots), captures: true,
          environment: ByteMeter.utf8Environment, quality: .userInitiated,
          directory: URL(filePath: group.folder, directoryHint: .isDirectory), stopsOnCancel: true)
      else { continue }
      for path in result.output.split(separator: "\0").map(String.init)
      where path.hasPrefix("./") && !path.contains("\n") {
        found.append((path, URL(filePath: group.folder + "/" + path.dropFirst(2))))
      }
    }
    return found
  }

  /// 压缩用 tar 的参数：按所在的文件夹分组，每组先「-C 文件夹」，再跟「./名字」（./ 开头的名字不会被当成选项，-s 再把它去掉；
  /// S：符号链接指向哪里不改）
  /// excludes：要跳的确切路径写成的文件（tar -X，见 skipped）
  nonisolated static func compressArguments(
    _ items: [URL], format: Format, to archive: URL, excludes: URL? = nil
  ) -> [String] {
    var arguments = ["-c", "-v", "-f", archive.path(percentEncoded: false)]
    switch format {
    case .zip: arguments += ["--format", "zip", "--options", "zip:hdrcharset=UTF-8"]
    case .sevenZip: arguments += ["--format", "7zip", "--options", "7zip:compression=lzma2"]
    // 格式用 tar 默认的（用得着才写 pax 头的 ustar）；扩展属性、ACL、文件标志不带（见文件头）
    case .tarGz: arguments += ["-z", "--no-xattrs", "--no-acls", "--no-fflags"]
    }
    arguments += ["--no-mac-metadata", "-s", "|^\\./||S"]
    arguments += junk.flatMap { ["--exclude", $0] }
    if let excludes { arguments += ["-X", excludes.path(percentEncoded: false)] }
    var folder: String?
    for item in items {
      let parent = (FileMoves.plainPath(item) as NSString).deletingLastPathComponent
      if parent != folder {
        arguments += ["-C", parent]
        folder = parent
      }
      arguments.append("./" + item.lastPathComponent)
    }
    return arguments
  }

  /// 解压用 tar 的参数。没有密码也给一个：不给的话碰到加了密的条目，tar 从标准输入问、读到空的也一遍遍问
  nonisolated static func extractArguments(
    _ archive: URL, into folder: URL, gbk: Bool, password: String?
  ) -> [String] {
    var arguments = [
      "-x", "-v", "-f", archive.path(percentEncoded: false), "-C",
      folder.path(percentEncoded: false),
      "--passphrase", password ?? "kitty-no-password",
    ]
    if gbk { arguments += ["--options", "hdrcharset=GB18030"] }
    return arguments + junk.flatMap { ["--exclude", $0] }
  }

  /// 解压时 tar -v 报的条目（「x 路径」，文件夹带结尾的「/」）。按「\n」拆：名字里的 U+2028 这类 tar 原样打出来，
  /// 不能按 isNewline 拆。报错的那一行是「x 路径: 原因」，只在失败时有
  nonisolated static func extractedEntries(_ stderr: String) -> [String] {
    stderr.split(separator: "\n").compactMap { line in
      line.hasPrefix("x ") ? String(line.dropFirst(2)) : nil
    }
  }

  /// 不分大小写的盘上被顶掉的文件：按包里的先后，路径（不分大小写、不分合成形式，同 Mac 的盘）对得上、写法不一样的——
  /// 后来的文件盖掉前面的文件；后来的文件夹顶掉前面的文件（tar 先删文件再建文件夹）；文件夹之间合在一起、不算丢。
  /// 写法一模一样的不算（tar 包本来就是后一个为准）。给回被顶掉的文件，按包里的先后
  nonisolated static func caseClashes(_ entries: [String]) -> [String] {
    var occupant: [String: (name: String, folder: Bool)] = [:]
    var lost: [String] = []
    for entry in entries {
      let folder = entry.hasSuffix("/")
      let name = folder ? String(entry.dropLast()) : entry
      let key = name.precomposedStringWithCanonicalMapping.lowercased()
      if let current = occupant[key], current.name != name, !current.folder,
        !lost.contains(current.name)
      {
        lost.append(current.name)
      }
      // 文件夹已经在了就还是它（它的写法留着）；别的情况换成这一个。同一个写法的文件后面又来一次：盘上是它最后那一份，
      // 按这个写法再解也只拿得到这一份，不算丢
      if !(folder && occupant[key]?.folder == true) {
        occupant[key] = (name, folder)
        if !folder { lost.removeAll { $0 == name } }
      }
    }
    return lost
  }

  /// 被顶掉的几个分成几轮：同一轮里没有两个对得上，也没有一个在另一个「里面」（丢的文件 a 和丢的 A/b 一起解，
  /// A/b 会因为 a 是文件建不了文件夹，评审实测）。一般只有一轮
  nonisolated static func rounds(_ lost: [String]) -> [[String]] {
    var rounds: [[String]] = []
    let key = { (entry: String) in entry.precomposedStringWithCanonicalMapping.lowercased() }
    let clash = { (a: String, b: String) in a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    for entry in lost {
      let mine = key(entry)
      if let index = rounds.firstIndex(where: { round in
        !round.contains { clash(key($0), mine) }
      }) {
        rounds[index].append(entry)
      } else {
        rounds.append([entry])
      }
    }
    return rounds
  }

  /// 出错原因只看原因：-v 报的「x 路径」去掉，「x 路径: 原因」只留原因（文件名里的字别被当成原因认，比如叫 encrypted.txt 的文件）
  nonisolated static func extractErrors(_ stderr: String) -> String {
    stderr.split(separator: "\n").compactMap { line -> Substring? in
      guard line.hasPrefix("x ") else { return line }
      return line.range(of: ": ").map { line[$0.upperBound...] }
    }.joined(separator: "\n")
  }

  /// 压缩时读不到的那一样（tar 的标准错误里的「Can't open `x'」「x: Couldn't visit directory」「x: Cannot stat」），给名字和原因
  nonisolated static func unreadable(_ errors: String) -> (
    name: String, missing: Bool, denied: Bool
  )? {
    for line in errors.split(whereSeparator: \.isNewline) {
      var path: Substring?
      if let open = line.range(of: "Can't open `"),
        let close = line.range(of: "'", options: .backwards),
        open.upperBound <= close.lowerBound
      {
        path = line[open.upperBound..<close.lowerBound]
      } else if line.hasPrefix("tar: "),
        let end = line.range(of: ": Couldn't visit directory") ?? line.range(of: ": Cannot stat")
      {
        path = line[line.index(line.startIndex, offsetBy: 5)..<end.lowerBound]
      }
      guard let path, !path.isEmpty else { continue }
      return (
        (path as NSString).lastPathComponent, line.contains("No such file"),
        line.contains("Permission denied") || line.contains("Operation not permitted")
      )
    }
    return nil
  }

  /// 压缩失败，给人看的原因
  nonisolated static func packFailure(_ errors: String, format: Format) -> String {
    let problem = placeProblem(errors)
    if problem == .noSpace {
      return format == .sevenZip
        ? String(localized: "磁盘空间不够了（7z 还要先在启动盘上暂存一份）") : PlaceProblem.noSpace.text
    }
    if let item = unreadable(errors) {
      if item.missing { return String(localized: "「\(item.name)」不见了（压缩时被移走或改了名）") }
      return item.denied
        ? String(localized: "「\(item.name)」读不到（没有权限）") : String(localized: "「\(item.name)」读不到")
    }
    // 写不了包本身：tar 只说「Failed to open '包'」（实测），动手前已经看过一遍（unwritable），这里是做到一半才变的
    if errors.contains("Failed to open") { return PlaceProblem.noPermission.text }
    return problem?.text ?? String(localized: "有文件读不到（被移走、改名了，或者没有权限）")
  }

  /// 往 folder 里写不了时的原因（只读的盘、没有写权限）；写得了是 nil。动手之前看：不然白打完一整包才知道
  static func unwritable(_ folder: URL) -> String? {
    guard !FileManager.default.isWritableFile(atPath: folder.path(percentEncoded: false)) else {
      return nil
    }
    let readOnly =
      (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    return readOnly ? PlaceProblem.readOnly.text : String(localized: "没有权限写这个位置")
  }

  /// 空间、权限这类和包本身无关的原因（压缩、解压都用）
  nonisolated enum PlaceProblem {
    case noSpace, readOnly, noPermission

    /// 给人看的
    var text: String {
      switch self {
      case .noSpace: String(localized: "磁盘空间不够了")
      case .readOnly: String(localized: "这个位置是只读的")
      case .noPermission: String(localized: "没有权限读写这个位置")
      }
    }
  }

  /// tar 的标准错误里认得出的空间、权限问题
  nonisolated static func placeProblem(_ error: String) -> PlaceProblem? {
    let known: [(String, PlaceProblem)] = [
      ("No space left", .noSpace),
      ("Read-only file system", .readOnly),
      ("Operation not permitted", .noPermission),
      ("Permission denied", .noPermission),
    ]
    return known.first { error.localizedCaseInsensitiveContains($0.0) }?.1
  }

  /// 解压失败，给人看的原因（tar 的标准错误里认得的说成中文）。password：给过密码——这时报「密码不对」，或者数据校验不对、
  /// 解不开（ZipCrypto 只校验一个字节，错的密码有 1/256 混过校验、解到一半才报这些，Kitty Box 实测）都算密码不对；
  /// 包不完整、不是压缩包这类照实说，不然输对了密码也一遍遍问。rar：只是数据加了密的 RAR，tar 不认密码、当成坏数据报
  /// （见文件头），认不出来的原因说「坏了，或者有密码」
  nonisolated static func outcome(ofFailure error: String, password: Bool, rar: Bool = false)
    -> Outcome
  {
    if let problem = placeProblem(error) { return .failed(problem.text) }
    if error.contains("Incorrect passphrase") { return password ? .wrongPassword : .needsPassword }
    if password,
      ["bad CRC", "decompression failed"].contains(where: error.localizedCaseInsensitiveContains)
    {
      return .wrongPassword
    }
    let incomplete = String(localized: "压缩包不完整，可能没下载完")
    let unknown = String(localized: "不是压缩包，或者是不支持的格式")
    let damaged = [
      ("ncrypt", String(localized: "这个包加了密码，这里只解得开 zip 的密码")),
      ("runcated", incomplete),
      ("nexpected end", incomplete),
      ("ends unexpectedly", incomplete),
      ("Unrecognized archive format", unknown),
      ("not in gzip format", unknown),
      ("is not a bzip2 file", unknown),
    ]
    return .failed(
      damaged.first { error.localizedCaseInsensitiveContains($0.0) }?.1
        ?? (rar
          ? String(localized: "压缩包可能坏了，或者加了密码（RAR 的密码这里解不开）")
          : String(localized: "压缩包可能坏了")))
  }

  // MARK: 压缩

  /// 打一个包：先写到 archive 旁边的隐藏临时名，打完落到 archive（重名换「 2」）
  /// skip：另外跳过的名字（skipNames 收拾过的）；只压一个包走 ditto 时不用
  static func pack(
    _ items: [URL], format: Format, to archive: URL, skip: [String] = [],
    report: @escaping FileMoves.Report = { _, _ in }
  ) async -> Outcome {
    let temporary = FileMoves.temporary(in: archive.deletingLastPathComponent())
    let package =
      format == .zip && items.count == 1
      && (try? items[0].resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    // 进度（ByteMeter）：一共多大先数好；tar -v 每开始一个文件报「a 名字」，名字按它所在的文件夹拼回去看多大；
    // ditto -V 每打完一个报「N bytes for 名字」
    let excluded = package ? [] : await skipped(items, names: skip)
    let excludes =
      excluded.isEmpty
      ? nil
      : FileManager.default.temporaryDirectory.appending(path: "kitty-skip-\(UUID().uuidString)")
    if let excludes {
      try? Data(excluded.map { escapedForTar($0.relative) + "\n" }.joined().utf8).write(
        to: excludes)
    }
    defer { if let excludes { try? FileManager.default.removeItem(at: excludes) } }
    let total = await ByteMeter.sizes(of: items).reduce(0, +)
    let meter = ByteMeter(
      total: max(total - (await ByteMeter.sizes(of: excluded.map(\.url)).reduce(0, +)), 0))
    var parents: [String: String] = [:]
    for item in items {
      parents[item.lastPathComponent] =
        (FileMoves.plainPath(item) as NSString).deletingLastPathComponent
    }
    let size = { (name: String) -> Int64? in
      parents[String(name.prefix { $0 != "/" })].flatMap { ByteMeter.fileSize($0 + "/" + name) }
    }
    let watch = { (pid: pid_t, lines: String) in
      meter.feed(lines, size: size)
      let value = meter.value(current: ByteMeter.reading(pid: pid))
      report(meter.fraction(value), meter.detail(value))
    }
    let result =
      package
      ? try? await Subprocess.run(
        "/usr/bin/ditto",
        [
          "-c", "-k", "-V", "--sequesterRsrc", "--keepParent", items[0].path(percentEncoded: false),
          temporary.path(percentEncoded: false),
        ], captures: true, quality: .userInitiated, stopsOnCancel: true, watch: watch)
      : try? await Subprocess.run(
        "/usr/bin/tar", compressArguments(items, format: format, to: temporary, excludes: excludes),
        captures: true,
        environment: ByteMeter.utf8Environment, quality: .userInitiated, stopsOnCancel: true,
        watch: watch)
    let failure: Outcome
    if Task.isCancelled {
      failure = .stopped
    } else if let result, result.status != 0 {
      failure = .failed(packFailure(ByteMeter.errors(result.error), format: format))
    } else if result == nil {
      failure = .failed(String(localized: "系统的工具没能运行"))
    } else if let placed = FileMoves.land(temporary, at: archive) {
      FileMoves.release(temporary)
      return .done(placed)
    } else {
      failure = .failed(String(localized: "没能放到旁边"))
    }
    await FileMoves.discard(temporary)
    return failure
  }

  /// into：放到哪个文件夹（nil = 第一样所在的文件夹；放不下时刘海岛上换的地方）
  static func compress(_ files: [URL], format: Format, island: Island?, into: URL? = nil) {
    var items: [URL] = []
    for file in files where FileMoves.occupied(file) {
      let path = FileMoves.plainPath(file)
      if !items.contains(where: { FileMoves.plainPath($0) == path }) { items.append(file) }
    }
    guard let first = items.first else {
      island?.show("没有压缩", detail: "选中的东西不在了", tone: .warning)
      return
    }
    if let name = clash(in: items) {
      island?.show(
        "没有压缩", detail: "「\(name)」有不止一个（在不同的文件夹里），包里只放得下一个", tone: .warning)
      return
    }
    let folder =
      into
      ?? URL(
        filePath: (FileMoves.plainPath(first) as NSString).deletingLastPathComponent,
        directoryHint: .isDirectory)
    if let reason = unwritable(folder) {
      let chosen = items
      island?.show(
        "没有压缩", detail: "\(reason)", tone: .warning,
        actions: elsewhere(than: folder, verb: .compress) { place in
          compress(chosen, format: format, island: island, into: place)
        })
      return
    }
    let name = archiveName(for: items, format: format)
    let skip = skipNames(UserDefaults.standard.string(forKey: Prefs.finderCompressSkip) ?? "")
    FileMoves.enqueue("正在压缩成「\(name)」…", detail: ByteMeter.preparing, island: island) {
      report in
      await pack(
        items, format: format,
        to: folder.appending(path: freeName(name, format: format, in: folder)), skip: skip,
        report: report)
    } finish: { outcome in
      report(outcome, verb: .compress, island: island)
    }
  }

  // MARK: 解压

  /// 解一个包到它旁边（into：另放到哪个文件夹）
  static func unpack(
    _ archive: URL, password: String?, gbk: Bool, into: URL? = nil,
    report: @escaping FileMoves.Report = { _, _ in }
  ) async -> Outcome {
    let manager = FileManager.default
    // 进度：压缩包读到第几个字节 ÷ 包有多大（ByteMeter，看子进程开着的那个包）
    let meter = ByteMeter(
      total: Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    let name = archive.lastPathComponent
    let watch = { (pid: pid_t, _: String) in
      let value = meter.archiveValue(ByteMeter.reading(pid: pid, named: name))
      report(meter.fraction(value), meter.detail(value))
    }
    let parent = into ?? archive.deletingLastPathComponent()
    let work = FileMoves.temporary(in: parent)
    guard (try? manager.createDirectory(at: work, withIntermediateDirectories: false)) != nil else {
      FileMoves.release(work)
      return .failed(String(localized: "没有权限写这个位置"))
    }
    var result: Subprocess.Result?
    let output = work.appending(path: stem(of: archive))
    if let tool = decompressor(for: archive) {
      // 解到临时文件夹里一个和包同名（去掉 .gz）的文件；参数按位置传给 sh，名字里有什么都不会被当成命令
      result = try? await Subprocess.run(
        "/bin/sh",
        [
          "-c", "exec \"$0\" -c -- \"$1\" > \"$2\"", tool, archive.path(percentEncoded: false),
          output.path(percentEncoded: false),
        ], captures: true, quality: .userInitiated, stopsOnCancel: true, watch: watch)
      // 包末尾有补零 / 垃圾时 gunzip 解完整了、只说一句「trailing garbage ignored」、退出码 2（评审实测）：算成了
      if var finished = result, finished.status == 2,
        case let lines = finished.error.split(whereSeparator: \.isNewline), !lines.isEmpty,
        lines.allSatisfy({ $0.hasSuffix("trailing garbage ignored") })
      {
        finished.status = 0
        result = finished
      }
      // gunzip 不管「从网上下载」的隔离标记（tar 会）：照包上的给解出来的那个也带上
      if result?.status == 0,
        let quarantine = try? archive.resourceValues(forKeys: [.quarantinePropertiesKey])
          .quarantineProperties
      {
        var file = output
        var values = URLResourceValues()
        values.quarantineProperties = quarantine
        try? file.setResourceValues(values)
      }
    } else {
      result = try? await Subprocess.run(
        "/usr/bin/tar", extractArguments(archive, into: work, gbk: gbk, password: password),
        captures: true, environment: ByteMeter.utf8Environment, quality: .userInitiated,
        stopsOnCancel: true, watch: watch)
    }
    var renamed: [String] = []
    var unsaved = 0
    let caseSensitive =
      (try? work.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
      .volumeSupportsCaseSensitiveNames == true
    if let result, result.status == 0, !Task.isCancelled, decompressor(for: archive) == nil,
      !caseSensitive
    {
      let lost = caseClashes(extractedEntries(result.error))
      if !lost.isEmpty {
        (renamed, unsaved) = await recover(
          lost, from: archive, into: work, gbk: gbk, password: password, watch: watch)
      }
    }
    let failure: Outcome
    if Task.isCancelled {
      failure = .stopped
    } else if let result, result.status != 0 {
      failure = outcome(
        ofFailure: extractErrors(result.error), password: password != nil,
        rar: suffix(of: archive) == ".rar")
    } else if result == nil {
      failure = .failed(String(localized: "系统的工具没能运行"))
    } else if let placed = settle(work, stem: stem(of: archive), in: parent) {
      FileMoves.release(work)
      return .done(placed, renamed: renamed, unsaved: unsaved)
    } else {
      failure = .failed(String(localized: "没能放到压缩包旁边"))
    }
    await FileMoves.discard(work)
    return failure
  }

  /// 被顶掉的那几个（caseClashes）：每一轮（rounds）一次把它们都解到旁边的临时文件夹（tar 按写法认、分大小写，只解这几个；
  /// 再读一遍包，进度条照走），名字加「 2」放回 work 里它原来那一层（那一层是包里只读的文件夹时先临时放开写权限）。给回另存的
  /// 新名字和没能另存的个数：名字里有「\」的（-v 把它打成「\\」，对不上）、解不出来的（包里是绝对路径这类）、解出来不是文件的
  /// （包里同一个写法既是文件又是文件夹）、落不下的算没能另存。写法后面加「$」只认这一条（tar 的写法按前缀认，「a」会把 a/ 下面的
  /// 都解出来；zip、7z、tar 的文件夹 -v 都带结尾的「/」，实测）
  static func recover(
    _ lost: [String], from archive: URL, into work: URL, gbk: Bool, password: String?,
    watch: ((pid_t, String) -> Void)? = nil
  ) async -> (renamed: [String], unsaved: Int) {
    var names: [String] = []
    var unsaved = lost.count { $0.contains("\\") }
    let manager = FileManager.default
    for round in rounds(lost.filter { !$0.contains("\\") }) where !Task.isCancelled {
      let scratch = FileMoves.temporary(in: work.deletingLastPathComponent())
      guard (try? manager.createDirectory(at: scratch, withIntermediateDirectories: false)) != nil
      else {
        FileMoves.release(scratch)
        unsaved += round.count
        continue
      }
      _ = try? await Subprocess.run(
        "/usr/bin/tar",
        extractArguments(archive, into: scratch, gbk: gbk, password: password) + ["--"]
          + round.map { escapedForTar($0) + "$" }, captures: true,
        environment: ByteMeter.utf8Environment,
        quality: .userInitiated, stopsOnCancel: true, watch: watch)
      for entry in round where !Task.isCancelled {
        let source = scratch.appending(path: entry)
        // 看它自己是什么（attributesOfItem 不顺着符号链接走）：没解出来、解出来是文件夹都算没能另存
        let type =
          (try? manager.attributesOfItem(atPath: source.path(percentEncoded: false)))?[
            .type] as? FileAttributeType
        guard let type, type != .typeDirectory else {
          unsaved += 1
          continue
        }
        let folder = work.appending(path: (entry as NSString).deletingLastPathComponent)
        let name = FileMoves.freeName(source.lastPathComponent, in: folder, used: [])
        if let placed = landOpening(source, at: folder.appending(path: name)) {
          names.append(placed.lastPathComponent)
        } else {
          unsaved += 1
        }
      }
      await FileMoves.discard(scratch)
    }
    return (names, unsaved)
  }

  /// 落到 target（不覆盖）；它所在的那一层没有写权限（包里带的只读文件夹）时先给自己加上写权限、落完改回去
  private static func landOpening(_ item: URL, at target: URL) -> URL? {
    let folder = target.deletingLastPathComponent().path(percentEncoded: false)
    let manager = FileManager.default
    guard !manager.isWritableFile(atPath: folder),
      let mode = (try? manager.attributesOfItem(atPath: folder))?[.posixPermissions] as? Int
    else { return FileMoves.land(item, at: target) }
    try? manager.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: folder)
    defer { try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: folder) }
    return FileMoves.land(item, at: target)
  }

  /// 解好之后：里面只有一样东西（不是隐藏的、不是符号链接：放出来访达里看不见，还会悄悄落在包旁边起作用）就把它放到包旁边，
  /// 不然把临时文件夹改成包的名字；重名加「 2」
  static func settle(_ work: URL, stem: String, in parent: URL) -> URL? {
    let manager = FileManager.default
    guard let children = try? manager.contentsOfDirectory(atPath: work.path(percentEncoded: false))
    else { return nil }
    if children.count == 1, !children[0].hasPrefix("."),
      (try? manager.destinationOfSymbolicLink(
        atPath: work.appending(path: children[0]).path(percentEncoded: false))) == nil,
      let placed = FileMoves.land(
        work.appending(path: children[0]),
        at: parent.appending(path: FileMoves.freeName(children[0], in: parent, used: [])))
    {
      try? manager.removeItem(at: work)
      return placed
    }
    return FileMoves.land(
      work, at: parent.appending(path: FileMoves.freeName(stem, in: parent, used: [])))
  }

  /// into：解到哪个文件夹（nil = 包旁边；放不下时刘海岛上换的地方）
  static func extract(_ files: [URL], island: Island?, into: URL? = nil) {
    let archives = files.filter { isArchive($0) && FileMoves.occupied($0) }
    guard !archives.isEmpty else {
      island?.show("没有解压", detail: "压缩包不在了，或者不是能解的格式", tone: .warning)
      return
    }
    // 放不下的那一批一起说一声（选中的一般在同一个文件夹里），别的照常解
    let blocked = archives.filter { unwritable(into ?? $0.deletingLastPathComponent()) != nil }
    if let first = blocked.first, let reason = unwritable(into ?? first.deletingLastPathComponent())
    {
      let title: LocalizedStringResource =
        blocked.count == 1
        ? "没有解压「\(first.lastPathComponent)」" : "没有解压这 \(blocked.count) 个压缩包"
      island?.show(
        title, detail: "\(reason)", tone: .warning,
        actions: elsewhere(than: into ?? first.deletingLastPathComponent(), verb: .extract) {
          place in extract(blocked, island: island, into: place)
        })
    }
    for archive in archives where !blocked.contains(archive) {
      extract(archive, retry: nil, island: island, into: into)
    }
  }

  /// 放不下时刘海岛上的两个按钮：「放到下载」（下载文件夹就是写不了的那个时不给）、「选择位置…」
  private static func elsewhere(
    than folder: URL, verb: Verb, redo: @escaping (URL) -> Void
  ) -> [Island.Action] {
    var actions: [Island.Action] = []
    if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first,
      FileMoves.plainPath(downloads) != FileMoves.plainPath(folder)
    {
      actions.append(Island.Action("放到下载") { redo(downloads) })
    }
    actions.append(
      Island.Action("选择位置…") {
        Task {
          if let place = await chooseFolder(verb: verb) { redo(place) }
        }
      })
    return actions
  }

  /// 选放在哪个文件夹（照 FilePanel：本 App 不在前台时也开在最上面）；取消是 nil
  static func chooseFolder(verb: Verb) async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = verb == .compress ? String(localized: "放在这里") : String(localized: "解压到这里")
    panel.message =
      verb == .compress
      ? String(localized: "把压缩包放在哪个文件夹") : String(localized: "解压到哪个文件夹")
    guard await FilePanel.begin(panel) == .OK else { return nil }
    return panel.url
  }

  /// 排一个包进队。有加密条目的 zip 先问密码（排队之前问：框开着的时候别挂「正在解压」）。retry：上一回 tar 说要密码
  /// （needsPassword：中央目录没读出来，包前面多了一截这种）或者密码不对——这时不管认没认出来都问，每一回都要用户点，
  /// 取消就停（评审：不问就重排会一直转下去、把队堵死）
  private static func extract(
    _ archive: URL, retry: Outcome?, island: Island?, askNow: Bool = false, into: URL? = nil
  ) {
    var password: String?
    var gbk = false
    var encrypted = retry != nil
    let cloud = try? archive.resourceValues(forKeys: [
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ])
    let offline =
      cloud?.isUbiquitousItem == true && cloud?.ubiquitousItemDownloadingStatus == .notDownloaded
    // 分卷的 RAR 不交给 tar（见文件头）。同读 zip 的中央目录：在主线程上读几十个字节，还没下载下来的不读
    if !offline, suffix(of: archive) == ".rar",
      let handle = try? FileHandle(forReadingFrom: archive),
      let head = try? handle.read(upToCount: 64), isRARVolume(head)
    {
      island?.show(
        "没有解压「\(archive.lastPathComponent)」", detail: "分卷的 RAR（.part1.rar 这种）这里解不开",
        tone: .warning)
      return
    }
    if !offline, ZipNames.isZip(archive), let entries = ZipNames.entries(of: archive) {
      gbk = ZipNames.charset(for: entries) == .gb18030
      encrypted = encrypted || entries.contains(where: \.encrypted)
    }
    // 本 App 不在前台时直接弹的框拿不到键盘（打的字进了访达，评审）：先在刘海岛说一声，点了按钮（点的是本 App）再弹
    if encrypted, !askNow, let island, !NSApp.isActive {
      island.show(
        retry == .wrongPassword
          ? LocalizedStringResource("finder.wrongPassword", defaultValue: "密码不对")
          : "「\(archive.lastPathComponent)」有密码",
        detail: "点「输入密码」再解压", tone: .info,
        actions: [
          Island.Action("输入密码…") {
            extract(archive, retry: retry, island: island, askNow: true, into: into)
          }
        ])
      return
    }
    if encrypted {
      guard let given = askPassword(for: archive, wrong: retry == .wrongPassword) else {
        // 重问时取消了：「正在解压」那一条可能还挂着，换成一句
        if retry != nil {
          island?.show("没有解压", detail: "\(archive.lastPathComponent)", tone: .info)
        }
        return
      }
      password = given
    }
    FileMoves.enqueue(
      "正在解压「\(archive.lastPathComponent)」…", detail: ByteMeter.preparing, island: island
    ) { report in
      await unpack(archive, password: password, gbk: gbk, into: into, report: report)
    } finish: { outcome in
      if outcome == .wrongPassword || outcome == .needsPassword {
        // 这一批先收尾，再另起一个去问：框开着的时候别堵住后面排着的
        Task { extract(archive, retry: outcome, island: island, into: into) }
      } else {
        // 解成功了、设置里开着：压缩包移到废纸篓，记下到了哪儿（「放回压缩包」用）。有只差大小写、没能另存的不扔：
        // 那几个文件只剩压缩包里这一份（评审）
        var trashed: URL?
        var trashFailed = false
        if case .done(_, _, 0) = outcome,
          UserDefaults.standard.bool(forKey: Prefs.finderTrashAfterExtract)
        {
          var landed: NSURL?
          if (try? FileManager.default.trashItem(at: archive, resultingItemURL: &landed)) != nil {
            trashed = landed as URL?
          } else {
            trashFailed = true
          }
        }
        report(
          outcome, verb: .extract, island: island, trashed: trashed.map { ($0, archive) },
          trashFailed: trashFailed)
      }
    }
  }

  /// 按住 ⌥ 的「解压到…」：先选放在哪（面板开在最前面），再照「解压到这里」解进去
  static func chooseAndExtract(_ files: [URL], island: Island?) {
    Task {
      guard let place = await chooseFolder(verb: .extract) else { return }
      extract(files, island: island, into: place)
    }
  }

  /// 问 zip 的密码；取消、空着、已经开着一个框是 nil
  private static func askPassword(for archive: URL, wrong: Bool) -> String? {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
    let alert = NSAlert()
    alert.messageText =
      wrong
      ? String(localized: "密码不对，再输一次")
      : String(localized: "「\(archive.lastPathComponent)」有密码")
    alert.informativeText = String(localized: "输入解压的密码。")
    alert.addButton(withTitle: String(localized: "解压"))
    // Esc = 取消
    alert.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
    alert.accessoryView = field
    guard FinderLink.ask(alert, focus: field) == .alertFirstButtonReturn,
      !field.stringValue.isEmpty
    else { return nil }
    return field.stringValue
  }

  // MARK: 说一声

  /// trashed：解压后压缩包移进了废纸篓（废纸篓里的位置，原来的位置）；trashFailed：设置里开着、却没能移进去
  /// （只读的盘、没有废纸篓的盘）
  private static func report(
    _ outcome: Outcome, verb: Verb, island: Island?, trashed: (URL, URL)? = nil,
    trashFailed: Bool = false
  ) {
    let compress = verb == .compress
    switch outcome {
    case .done(let url, let renamed, let unsaved):
      let reveal = Island.Action("在访达中显示", opens: true) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
      // 从废纸篓挪回原处（不覆盖：原处又有了同名的就加「 2」）
      let putBack = trashed.map { trash, original in
        Island.Action("放回压缩包") {
          let inTrash = FileMoves.occupied(trash)
          let placed = inTrash ? FileMoves.land(trash, at: original) : nil
          // 可选参数里的三目只有第一个分支抽得进目录：先放进不是可选的 let
          let detail: LocalizedStringResource =
            if let placed {
              "\(placed.lastPathComponent)"
            } else if inTrash {
              "原来的文件夹不在了，或者那里写不了"
            } else {
              "废纸篓里已经没有它了"
            }
          island?.show(
            placed == nil ? "没能放回压缩包" : "已放回压缩包", detail: detail,
            tone: placed == nil ? .warning : .info)
        }
      }
      if unsaved > 0 {
        // 只差大小写、没能另存的：照实说（盘上只留下了一个）
        island?.show(
          "已解压「\(url.lastPathComponent)」", detail: "有 \(unsaved) 个文件和别的只差大小写，这块盘上只留下了一个",
          tone: .warning, actions: [reveal] + (putBack.map { [$0] } ?? []))
      } else if renamed.isEmpty, let putBack {
        island?.show(
          "已解压", detail: "\(url.lastPathComponent) · 压缩包移到了废纸篓", actions: [reveal, putBack])
      } else if renamed.isEmpty, trashFailed {
        island?.show(
          "已解压", detail: "\(url.lastPathComponent) · 压缩包没能移到废纸篓", tone: .warning,
          actions: [reveal])
      } else if renamed.isEmpty {
        island?.show(
          compress ? "已压缩" : "已解压", detail: "\(url.lastPathComponent)", actions: [reveal])
      } else {
        // 可选参数里的三目只有第一个分支抽得进目录：先放进不是可选的 let
        let detail: LocalizedStringResource =
          renamed.count == 1
          ? "有个文件和别的只差大小写，另存成了「\(renamed[0])」"
          : "\(renamed.count) 个文件和别的只差大小写，另存时名字加了「 2」"
        island?.show(
          "已解压「\(url.lastPathComponent)」", detail: detail, tone: .info,
          actions: [reveal] + (putBack.map { [$0] } ?? []))
      }
    case .stopped:
      island?.show(compress ? "已停止压缩" : "已停止解压", tone: .info)
    case .needsPassword, .wrongPassword:
      island?.show(
        compress ? "没能压缩" : "没能解压",
        detail: LocalizedStringResource("finder.wrongPassword", defaultValue: "密码不对"),
        tone: .error)
    case .failed(let reason):
      island?.show(compress ? "没能压缩" : "没能解压", detail: "\(reason)", tone: .error)
    }
  }
}
