// 让分配器把用完的空页还给系统（第二轮体检 M4）。malloc 放掉的内存平时留在进程里等着再用，活动监视器里的数不降；
// 刚丢掉一大块东西之后调一次，空下来的页当场还回去。实测（内存探针）：⌘Y 大卡看过一张整屏截图、丢掉它的缩略图后，
// 解码用的那 14 MB 不调就一直留着，调了当场还；调用本身 0.3–4 ms。
// 只在「刚丢掉一大块、界面已经收走」的时候调（现在只有剪贴板 ⌘Y 大卡放掉之后，AppDelegate.quickLookPanel）；
// 截图、转 GIF 之后不调（实测它们自己还得干净，调了也还不出东西）。

import Foundation

enum Memory {
  /// 所有 zone、能还多少还多少
  static func relieve() {
    _ = malloc_zone_pressure_relief(nil, 0)
  }
}
