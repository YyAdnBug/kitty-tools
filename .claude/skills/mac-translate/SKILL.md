---
name: mac-translate
description: 原生分支翻译规范（语言规则、服务分发与钥匙串密钥、智谱 max_tokens 1024 与关思考、大模型地址补全与分档、SSE 流式与取消、划词取词、复制即译）。在修改 macos/KittyTools/Translate/**、Settings/TranslateTab.swift、Storage/Keychain.swift 前必须先读；或涉及 翻译服务 / 智谱 / OpenAI / Anthropic / Azure / 厂商预设 / 流式译文 / 译文为空 / 思考参数 / 思考中 / 截断 / 错误卡 / 划词取不到词 / 复制即译 / 自动复制 / 浮窗位置 / 输入翻译 / 翻译历史 / 历史 ⌘K / 导出 / 朗读 / 段落接行 等问题时。
---

# mac-translate

动手前先读同目录 `rule.mdc` 全文（正文唯一数据源：`.cursor/rules/mac-translate.mdc`）。

红线速查：
- 语言只在 `Lang.resolve` 解析；发给服务的目标语言必须是具体语言。
- 分发只有 `TranslateService.translate` 一个 switch；密钥只进钥匙串，账户名 `<服务 id>.<字段>`。
- 智谱 max_tokens ≤ 1024、必须关思考；关思考参数只在 400/422 时降档。
- 流被取消是正常结束：`for try await` 之后先判断 `Task.isCancelled`；流里的空串 = 在思考；finish_reason = length / stop_reason = max_tokens 是截断（`.truncated`，不写历史、不自动复制）。
- 错误分 `TranslateError.kind`：配置类橙卡只给「打开设置」（直达服务详情页），网络 / 服务类红卡给「重试」。
- 划词：取词完成前绝不显示浮窗；复制即译先过 `worthTranslating`、用 `present(makingKey: false)`，复制即译带来的原文不自动复制；自家浮层里的 ⌘C 不触发。
- 浮窗：↩ 就是翻译（原文改过没重译才出粉色「翻译 ↩」胶囊）；顶栏只有语言胶囊 + 图钉 + ⋯；收藏 ⌘D（⌘S 不响应）；输入翻译热键是开关、保留上次内容；历史是和剪贴板同一套的键盘列表，⌘K 用 ActionMenu。
- 服务列表只放加进来的：内置可删（密钥留着）、「+」加回或新建 AI 服务（厂商预设）。
