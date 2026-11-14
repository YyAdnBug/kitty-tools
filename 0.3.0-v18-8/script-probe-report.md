# 脚本命令实跑自检（PLAN-v18 L1）

- ok ps1：跑完、退出码 3（该 3）
- ok ps1：中文、带空格和 & 的参数原样到「你好 张 三 & 李」
- ok ps1：工作目录和 KITTY_SCRIPT_DIR 是脚本所在的文件夹
  PowerShell 冷启动 213 ms，第二次 214 ms
- ok cmd（UTF-8）：中文不乱码、参数原样「中文 "a & b"」
- ok cmd（GBK）：中文不乱码「中文」
- ok 超时：TimedOut，1024 ms 停下
- ok 停止：Stopped，子进程 ping 1 个、停后还剩 0 个
- ok 下载标记：认得出 :Zone.Identifier
- ok 下载标记：扫描后才带上标记的不跑
- ok 下载标记：看过、去掉标记后能跑
  这台没有 py.exe：.py 没跑（设置页列「要装 Python」）
- ok PowerShell 模板：「你好，YY」
- ok Batch 模板：「你好，YY」
- ok 第一次建文件夹放两个带 BOM 的样板：tq、zs
- ok 自带 time：4 行，0 ms（不起进程）
- ok 自带 bcvt 写错：退出码 1，「写一个整数：十进制，或者 0x / 0b / 0o 开头」

**全过**
