# 脚本命令实跑自检（PLAN-v18 L1）

- ok ps1：跑完、退出码 3（该 3）
- ok ps1：中文、带空格和 & 的参数原样到「你好 张 三 & 李」
- ok ps1：工作目录和 KITTY_SCRIPT_DIR 是脚本所在的文件夹
  PowerShell 冷启动 204 ms，第二次 195 ms
- ok cmd（UTF-8）：中文不乱码、参数原样「中文 "a & b"」
- ok cmd（GBK）：中文不乱码「中文」
- ok 超时：TimedOut，1026 ms 停下
- ok 停止：Stopped，子进程 ping 1 个、停后还剩 0 个
- ok 下载标记：认得出 :Zone.Identifier
- ok 下载标记：扫描后才带上标记的不跑
- ok 下载标记：看过、去掉标记后能跑
  这台没有 py.exe：.py 没跑（设置页列「要装 Python」）

**全过**
