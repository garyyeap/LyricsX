# LyricsX 文档索引

**新增或重命名任何文档都必须同步更新这份索引。**

> **项目类型：App（macOS）**。提案的「影响」一节关注用户可见变化、可发现性、
> 数据与配置兼容、平台与最低版本、发布流程，不涉及 ABI。

## 提案

- [提案索引](Evolutions/README.md) —— 所有 evolution 提案及其状态。**新功能与架构级改动动手前必须
  先有一篇被批准的提案。**
  - [0001 切换到下一条歌词候选](Evolutions/0001-next-lyrics-candidate.md) —— 让自动搜索保留候选池，
    并用一个快捷键在候选之间循环切换。
  - [0002 总是忽略歌词库缓存](Evolutions/0002-always-ignore-cached-lyrics.md) —— 一个开关，
    让自动匹配不再读 LyricsX 自己存的歌词库，每次都联网搜。
  - [0003 歌词源排序模式](Evolutions/0003-source-ordering-modes.md) —— 跨来源先比匹配分数，
    分数接近时才由歌词源顺序裁决。

## 实现说明

- [歌词候选池](Internal/LyricsCandidatePool.md) —— 自动搜索为什么改成「擂台赛 + 完整名单」，
  「钉住」为什么不能省，以及用户选定的歌词靠什么活过下一次播放。
- [歌词候选的排序](Internal/LyricsSourceOrdering.md) —— 为什么用分数分桶而不是比分差
  （传递性），偏好迁移为什么必须跑在 `register(defaults:)` 之前。

## 术语

- [项目术语表](Glossary.md) —— 候选池、钉住、补充搜索、覆盖表、优先级窗口、Route B、
  分数桶、同分容差等本项目自造词。

## 工程实践

- [已裁决的 code review 发现](ReviewDecisions.md) —— 判定为误报或不值得修的发现及其理由。
  **每次 code review 先对照这份清单**，已裁决的不再重复走四问。

## 发布与版本

- [Beta 更新通道](BetaUpdateChannel.md) —— 此前只通过 Sparkle 推送正式版；这篇记录 beta 通道的引入。
- [Build 号方案](BuildNumberScheme.md) —— 从手工维护的单调递增整数改为编码方案。
  **改发版流程前必读**，build 号的编码规则影响 Sparkle 的版本比较。
