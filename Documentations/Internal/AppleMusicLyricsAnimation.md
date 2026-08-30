# Apple Music 26.6 歌词动画

> 对应提案：[对齐 Apple Music 26.6 歌词动画](../Evolutions/0007-apple-music-lyrics-animation-parity.md)
>
> 面向维护者。这里记录最终数据链、动画状态所有权和降级边界；旧的探索文档保留为历史记录，
> 不再作为 26.6 行为的实现依据。

## 一句话

主歌词现在走两条明确的数据路径：Apple Music TTML 保留真实的 word/syllable range 与结束时间，
按 Apple Music 26.6 的 factor、stagger 和 contextual blur 执行动画；行间切换使用用户确认过观感的旧
SwiftUI cascade。没有结构化数据的其他歌词继续走原来的 phrase 推断，不伪造不存在的层级。

## 最终数据链

```text
Apple Music TTML
  → LyricsKit Lyrics+TTML
  → LyricsLine.Attachments.SynchronizedTextTiming
  → LRCX [synchronized-timing] + 既有 [tt]
  → AppleMusicLyricsPanel LineTextLayout
  → WordEmphasisPlan / LineTransitionPlan / LineBlurPlan / viewport mask
  → CALayer 显式动画
```

### 结构化 timing 为什么必须在 LyricsKit 保存

TTML 的 `<span>` 同时给出了文本范围、`begin`、`end` 和嵌套关系。旧 parser 只把每个 span 的
开始位置写进 `[tt]`，因此进入面板之前就已经丢掉了结束时间以及 word/syllable 层级；面板再复杂也
无法可靠还原。

`LyricsLine.Attachments.SynchronizedTextTiming` 现在保存：

- word 的 Swift `Character` range 与相对行首的 time range；
- word 下每个 syllable 的 character range 与 time range；
- 可选的整行 duration。

只有一层 timed span 时，它成为一个 word，并生成一个同 range、同 time range 的 syllable；外层
word 包含内层 timed span 时，内层 span 原样成为 syllable。解析仍同时生成既有 `[tt]`，旧消费者
因此还能得到逐字开始时间。

### LRCX 的附加格式

新 attachment 的 tag 是 `[synchronized-timing]`，payload 为：

```text
1:<Base64(JSON)>
```

版本号在 Base64 之外，JSON 内的时间全部是整数毫秒，range 使用半开区间的起止 character index。
这是 additive 格式：没有修改 `[tt]` 的任何字节或语义。

载入时会整体校验：

- word range 有序、非空且不越过歌词文本；
- syllable 位于所属 word 内；
- character range 与 time range 都不会反向；
- 时间有限、非负；
- payload version、Base64 或 JSON 损坏时直接拒绝。

任何一项失败都只丢弃 `SynchronizedTextTiming`，继续使用同一行的 `[tt]`；不会保留半份结构，也不会
让整首歌词解析失败。反向 range 在构造 Swift `Range` 之前就会被拒绝，损坏文件不能借此触发崩溃。

## 行内动画

### 精确路径与 fallback

`LineTextLayout` 先把 Swift `Character` index 转成 Core Text 使用的 UTF-16 code-unit index，
再把 glyph 放回对应 word 与 syllable。结构化 range 之间允许空白；空白形成不带 timing 的边界，
不会被算进相邻 word 的 duration 或 glyph count。

存在有效 `SynchronizedTextTiming` 时，emphasis 使用真实 word duration、word length 和 glyph count。
缺少它时，既有 `InlineTimeTag` 仍会把相邻字符归回 phrase；这条 fallback 保留原有的满强度 factor
与首 glyph 零延迟，避免非 Apple Music 来源突然改变观感。

`InlineTimeTag` 也可能把一段快速演唱拆成连续的空格分隔单元，却没有 Apple Music 用来区分 word 与
syllable 的层级。若同一视觉行里连续至少三个 fallback 单元各自现有的 `emphasisDuration` 不超过
`0.25` 秒，`LineTextLayout` 会让这一段共享 phrase 的 `emphasisDuration` 与
`emphasisGlyphCount`，直到遇到普通速度单元、换行或累计时长超过 `3` 秒。各单元自身的
`timeRange` 不变，因此起跳时刻和 karaoke progression 仍服从来源数据；改变的只是 spring period，
避免每个单元都在一两百毫秒内独立起跳和回落。少于三个的孤立快词不会被合并。

这条 `0.25` 秒规则是缺少结构化层级时的项目 fallback，不是从 Apple Music 26.6 恢复出的常量。
结构化 `SynchronizedTextTiming` 即使 word 很短也始终保留原始 envelope。

### factor 与语言能力

结构化路径按歌词的 `lang` id tag 取基础语言代码。`ar`、`he`、`zh`、`ja`（含地区后缀）保留 lift，
但没有额外 scale 和 glow。其他或未知语言只有同时满足下面两项才有 factor：

```text
wordDuration > 1 second
wordLength <= 7 characters
factor = min(wordDuration, 2) - 1
```

factor 为 0 不代表 glyph 静止：lift 仍然执行，只是 scale 保持 1、glow 保持 0。

### 调度公式与 layer 层级

`WordEmphasisPlan` 固定 26.6 恢复出的公式：

```text
scale        = 1 + factor × 0.14
glowOpacity  = factor × 0.4
springPeriod = min(wordDuration, 3)
glyphStagger = min(wordDuration / glyphCount × 0.4, 0.4)
riseDelay    = glyphStagger × (glyphIndex + 1)
returnDelay  = riseDelay + 2 × wordDuration / glyphCount
```

glow 在 rasterized `WordLayer` 上，`shadowRadius = 5`、`shadowOffset = 0`；glyph layer 只负责 position
与 affine transform，不再各自投影。word duration 到达后，glow 由独立的
`mass 1 / stiffness 14 / damping 7` spring 回到 0，和 glyph 的几何回落不是同一批动画。

seek、换行、歌词替换或 view reuse 都会取消尚未执行的 glyph return 与 deglow work item，删除显式
动画，并一次性恢复模型状态。新的动画永远从 presentation layer 的可见状态接续。

## 行间动画

选中主歌词使用 `.topRelative(40)`。Apple Music 对 text-only line frame 的计算是：

```text
topInset = visibleHeight × 0.40 - CTFontGetAscent(font)
targetY  = max(lineFrame.minY - topInset, 0)
```

本项目的 row frame 在文字前还有 28 点内边距，因此 `LineTransitionPlan` 从 40% 中减去完整的
`mainTextFirstBaselineOffset`。这样定位的是第一条文字 baseline，而不是 row 外框顶部；窗口高度变化时
会重新计算，不能退回固定点数。

普通自动换行恢复旧 SwiftUI 版本的 cascade，但执行端改为 Core Animation：

1. 从 clip 与即将参与动画的 row presentation layer 读取当前可见位置。
2. 在关闭 implicit actions 的同一个 transaction 中把 `NSClipView.bounds` 提交到新 anchor；row 的
   AppKit model frame 始终不变。
3. 用完整 clip displacement 反向补偿附近 row 的 presentation 起点，因此提交 scroll model 时画面
   不会瞬移。
4. 选中行上方最多 3 行以 `0.5` 秒 ease-in-out 归位；选中行及下方最多 6 行使用
   `period 0.6 / dampingRatio 0.725` 的 spring，每行错开 `0.08` 秒。
5. 新 cascade 从旧动画的 row presentation position 接续，并以稳定 animation key 替换旧动画；整个
   过程由 render server 插值，不在 DisplayLink callback 里逐帧改 frame 或触发 layout。

两次高亮变化相隔不足 `0.4` 秒时，不继续叠加 delayed row spring：coordinator 会清掉 cascade，并让
clip 从当前 presentation origin 走 `period 0.5 / dampingRatio 1` 的无反弹 settle。初始化、离屏和
非交互大跨度 seek 直接落到模型终点。点击歌词跳转继续使用
`mass 2 / stiffness 260 / damping 50` 的 interactive clip spring，即使跨度较大也执行。

instrumental dots 仍然居中，并复用 coordinator 的 clip spring，不维护第二套逐帧动画状态。

## 多行文本坐标

`LineTextLayout` 已把 Core Text 的 y-up baseline 转换成 y-down frame。`SyncedLyricsLineContentLayer`
也必须固定为 `isGeometryFlipped = true`。此前根据 AppKit backing layer 的状态动态取反，使 content layer
在真实 flipped row view 中变成 unflipped；一条歌词换成两行时，第二个视觉行因此被画到第一个视觉行上方。

回归测试使用用户截图中的版权句“（未经著作权人许可，不得翻唱翻录或使用。）”，同时固定两层契约：
layout 中 visual row 0 的 y 小于 visual row 1，承载这些 frame 的 content layer 保持 y-down。

## Contextual blur

blur 不再等同于“所有非选中行”。scroll view 先根据当前渲染上下文生成 `LineBlurPlan`，只把上下文内
可见的非选中主歌词放进目标集合；离开上下文的 row 回到 0，避免复用时残留 filter 状态。没有选中行
时集合为空。

半径仍使用屏幕实测校准后的值。`filters.gaussianBlur.inputRadius` 的 transition 为：

- duration `0.12` 秒；
- cubic control points `(0.33, 0)` 与 `(0.2, 0.1)`；
- model radius 先写最终值，显式动画从 presentation radius 开始；
- 动画期间关闭 rasterization，且只有最新 animation generation 的 completion 可以恢复原状态。

### 外层 viewport edge fade

行级 blur 本身不是距离渐变。`SyncedLyricsLineLayer` 对进入 `blurredLineViews` 的 row 使用固定半径；
远处歌词逐渐消失来自更外层的 `Music.LyricsXViewController.maskLayer`。26.6 的类型信息确认该字段是
`CAGradientLayer`，`sub_1001284F8` 把它安装到完整歌词 container 的 backing layer，并设置：

```text
colors    = [clear, white, white, clear]
locations = [0, firstFadeDistance / height,
             1 - secondFadeDistance / height, 1]
```

汇编中的分支不能只看“是否自动跟随”：pretty mode 自动跟随时两个 distance 都是 128 point，手动
scroll 时都是 30 point；non-pretty 自动跟随路径的 first distance 是 70 point，second distance 是
视口高度的一半，因此得到 `[0, 70 / height, 0.5, 1]`。

Music 把 mask 安装在 flipped 的 `AMPFlippedDocumentView` 上，上述 locations 因而是在 flipped geometry
中解释的。本项目把 mask 安装在外层、未 flipped 的 `SyncedLyricsContainerView` 上；内部 document view
是否 flipped 不会改变外层 mask 的坐标。locations 必须保留二进制恢复值，同时反转 gradient vector：

```text
colors     = [clear, white, white, clear]
locations  = [0, 70 / height, 0.5, 1]
startPoint = (0.5, 1)
endPoint   = (0.5, 0)
```

映射后的视觉结果是：顶部约 70 point 从透明过渡到完全不透明，中段保持完全不透明，底部从半屏处开始
渐隐到透明。选中歌词 baseline 位于距视觉顶部 40% 的位置，因此不会再被 mask 降到约 78% opacity。

mask 只创建一次，每次 layout 在关闭 implicit animation 的 transaction 中更新 frame 和 locations，
不参与 display-link tick。

`NSScrollView` viewport 与 Apple Music 一样继续使用 container 的完整 bounds，不增加物理 top / bottom
inset；边缘空间完全由 mask 的 alpha transition 形成。曾尝试上下各缩进 32 point，但用户并排截图
确认这种硬留白与 Apple Music 不符，随后撤销。

因此不能把视觉上的渐隐误实现为“离选中行越远，Gaussian blur radius 越大”。那既不符合二进制结构，
也会让更多大半径 filter 参与行间 spring 合成。非选中行仍保持统一的基础 alpha 和固定 blur，连续的
上下衰减只由 viewport mask 负责。用户反馈的边缘观感不是 row 的真实文字间距不足，因此没有扩大
row spacing，也没有保留额外 viewport inset。

## AppKit 与 Core Animation 的所有权

`NSView.frame` 和 `NSClipView.bounds` 是模型真值，backing layer 的 `position`、`frame`、`bounds`
不能成为另一套持久状态。Core Animation 只承载 presentation：

- model target 总是在动画安装前提交；
- 中断时只从 `presentation()` 读取可见起点；
- animation key 稳定，新动画替换同属性旧动画；
- layout pass 可以随时重投影 backing layer，而不会改变最终状态。

后续若直接长期修改 row backing layer 的 geometry，AppKit 下一次 layout 会把它重写，表现通常是
换行中途突然跳回。不要用 completion 再补 model value，那会同时破坏 hit testing 和连续换行。

## 与提案的差异和已知边界

- 范围仍只有 main vocals；Background Vocals、duet alignment 和 agent transform 未实现。
- 没有新增开关，新路径直接替换旧动画；非 Apple Music 来源只保留数据 fallback。
- 提案要求精确路径不受 phrase 字段污染。最终代码把统一执行字段命名为
  `emphasisDuration` / `emphasisGlyphCount`：结构化路径填真实 word 值，只有 fallback 才从 phrase 推断。
- Apple Music 26.6 的精确公式没有最小 spring period；非结构化来源的连续快词因为缺失 word/syllable
  层级，额外使用上述 fallback phrase envelope。它只修正运动曲线，不修改来源 timing，也不进入
  `SynchronizedTextTiming` 路径。
- 提案最初把选中位置写成 `.top(12)`，二进制消费端复核随后把精确定位修正为
  `.topRelative(40)`，并表明 Apple Music 的 normal update 由单 clip bounds spring 承担。项目曾完全
  按这条私有机制实现，但 `mass 1 / stiffness 100 / damping 18` 的超调不足一个像素，用户确认视觉上
  仍是刚性平移；旧 SwiftUI cascade 反而更接近目标观感。因此当前版本保留 40% baseline anchor，另加
  presentation-only row cascade。这是项目的视觉校准，不再宣称是 Apple Music 私有 row update 的逐项还原。
- 第一版只移植了 LyricsX 内部的 contextual blur，漏掉 Music 外层
  `LyricsXViewController.maskLayer`，导致所有非选中行在 viewport 内同样可见。第一次修正又选中了
  pretty mode 的 128 / 128 point 对称分支；第二张并排截图和汇编复核把 locations 改为 non-pretty
  自动跟随路径的 `[0, 70 / height, 0.5, 1]`。之后先后尝试 128 point 底边校准与
  `[0, 0.5, 0.5, 1]` 对称渐隐，但仍直接沿用了 Music 的 gradient direction，忽略了两边 mask target
  的 flipped 状态不同；对称版本还让位于视觉顶部 40% 的选中行进入 fade。最终保留恢复出的
  `[0, 70 / height, 0.5, 1]`，并在未 flipped 的外层 container 上反转 gradient vector。曾加入的
  scroll viewport 上下各 32 point 留白也被并排截图证明与 Apple Music 不符，最终恢复完整 container
  height。仍然没有恢复距离型 blur、距离型 alpha 或扩大 row spacing。
- 本次没有获得交互式 UI 验证授权，因此没有启动应用；位置与流畅度判断使用用户提供的 Apple Music
  对比录屏，自动化 probe 验证 layer 层级、模型终点、presentation continuity、spring 参数、
  relative baseline、换行顺序与 rasterization 生命周期。

## 验证记录

2026-08-29 的本地验证：

- LyricsXPackage：99 项、10 个 suite 全部通过，原始退出码 0；其中集成测试实际执行本地 LyricsKit 的
  flat/nested TTML、LRCX 往返、extended grapheme range 和损坏 payload fallback。
- 新增回归先在旧实现上以原始退出码 1 失败：找不到 clip bounds spring，且 wrapped content layer
  为 unflipped；修复后定向 5 项与完整 99 项均通过。行内两项真实时间轴 Metal probe 保持通过。
- LyricsKit `LyricsService` target：隔离 SwiftPM 目录构建成功，原始退出码 0。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme：使用隔离 DerivedData 构建成功，
  并从 workspace 链接本地 LyricsKit；本次修正后再次构建成功。
- viewport edge fade 回归在缺少 mask 时以原始退出码 1 失败；补上 mask 后定向测试通过，完整
  LyricsXPackage 106 项全部通过、原始退出码 0，随后 workspace Debug scheme 使用隔离 DerivedData
  再次构建成功。
- 非对称 viewport edge fade 回归在 128 / 128 point 实现上以原始退出码 1 失败，并分别报告 top stop
  偏差 0.0725、bottom stop 偏差 0.34；改为 `[0, 70 / height, 0.5, 1]` 后定向测试通过。加入 HUD
  visibility 回归后，LyricsXPackage 107 项在 `--no-parallel` 下全部通过、原始退出码 0，随后
  workspace Debug scheme 使用隔离 DerivedData 构建成功。
- LyricsKit 全量 test target 目前在进入新测试前被既有
  `GroupProviderTests.StaticProvider` / `FailingProvider` 未遵循当前 `LyricsProvider` protocol 阻断；
  这两个文件不在本次改动中。不要把这次编译失败写成“新测试失败”。

2026-08-30 的底部渐隐视觉校准：

- 回归在 70 point 实现上以原始退出码 1 失败，bottom stop 与 128 point 目标相差 0.0725；顶部 0.5
  stop 没有变化。修改后定向测试通过。
- 第一次完整测试聚合运行返回一次没有失败明细的瞬时退出码 1；随后裸输出复跑与再次聚合复跑连续
  两次通过，均为 107 项、13 个 suite，原始退出码 0。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功；本次
  没有启动应用做交互式 UI 验证。

2026-08-30 的对称渐隐与 viewport 留白：

- 两项回归在 128 point 实现上先失败：800 point 测试视口的 bottom stop 与 0.5 对称目标相差 0.34；
  scroll view 仍占满 `(0, 0, 640, 800)`，与上下各 32 point 的目标 frame 相差 32 point。
- 改为 `[0, 0.5, 0.5, 1]` 并应用 32 point vertical inset 后，两项定向回归通过；选中 baseline 与单
  clip bounds spring 的既有回归也继续通过。
- LyricsXPackage 108 项、13 个 suite 全部通过，原始退出码 0；`MxIris-LyricsX-Project.xcworkspace`
  的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动应用做交互式 UI 验证。

2026-08-30 撤销 viewport 硬留白：

- 用户并排截图确认 Apple Music 的 lyrics viewport 仍覆盖完整高度，边缘空间来自渐隐而不是 frame
  inset。完整高度回归在 32 point 实现上先失败，实际 frame 为 `(0, 32, 640, 736)`，目标为
  `(0, 0, 640, 800)`。
- 移除 inset 后，完整高度与对称渐隐两项定向回归通过；LyricsXPackage 108 项、13 个 suite 全部
  通过，原始退出码 0。真实 row spacing、line blur、行内动画与 display-link 路径均未改变。

2026-08-30 修正 flipped coordinate mapping：

- 同一首歌的并排截图显示，对称 mask 把本项目选中行压到约 78% normalized opacity，而 Apple Music
  的选中行保持完全不透明；这证明选中行本身错误地落进了 fade。
- 重新核对 26.6 Swift interface、`sub_1001284F8` 的反编译与汇编后，确认 Music 的 mask target 是
  flipped 的 `AMPFlippedDocumentView`，non-pretty 自动跟随 locations 仍是
  `[0, 70 / height, 0.5, 1]`。本项目外层 container 未 flipped，因此最终反转 `startPoint` 与
  `endPoint`，而不是继续修改 distance。
- 新回归在对称实现上先以原始退出码 1 失败：800 point 视口的第二个 stop 与 `70 / height` 相差
  0.4125，gradient vector 的起点和终点也与目标相反。修复后渐隐与完整高度两项定向回归通过；
  LyricsXPackage 108 项、13 个 suite 全部通过，原始退出码 0；隔离 DerivedData 的 LyricsX workspace
  Debug build 成功。未启动应用做交互式 UI 验证。

2026-08-30 快速 fallback word 的运动 envelope：

- 使用真实歌词 `You say you say what I should do` 的 0.14–0.22 秒 inline timing 增加回归；旧实现下
  每个空格分隔单元仍使用自己的短 spring，测试以原始退出码 1 失败。
- 修复后连续快词、孤立快词和结构化快词共 4 项 layout 回归全部通过；LyricsXPackage 117 项、
  15 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0。
- 默认并行全量运行仍会触发既有 `WidgetDataStoreTests.writeAndRead` 与 `clearData` 共用同一静态 suite
  名称的竞态；单独运行失败项通过。本次没有修改该测试或 widget data store。
- `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动
  应用做交互式 UI 验证。

2026-08-30 恢复旧 SwiftUI 行间 cascade：

- 回归先在单 clip spring 实现上以原始退出码 1 失败：普通换行仍存在 1 个 clip bounds spring，附近
  row 的 `position.y` animation 为 0，无法产生逐行弹跳。
- 修复后 6 项 `LineTransitionProbes` 全部通过：普通换行有 3 行上方 smooth settle 与当前行加下方
  5 行 spring cascade，spring 间隔为 80 ms；快速连续换行会取消 row cascade，并从当前可见 clip
  origin 开始 critically damped settle；点击歌词仍使用原有 interactive clip spring。
- LyricsXPackage 117 项、15 个 suite 在 `--no-parallel` 下全部通过，原始退出码 0；
  `MxIris-LyricsX-Project.xcworkspace` 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。
- 本次没有启动应用做交互式 UI 验证；最终视觉效果仍需在真实歌词播放中与 Apple Music 并排确认。

## 以后重做版本核对时

Apple Music 私有实现会随版本变化。升级验证时应分别核对：word factor 的语言门槛、rise/return delay、
deglow spring、normal/tap line spring、selected baseline fraction、blur membership、viewport mask 分支、
mask target 的 flipped 状态与 cubic curve。
这些值集中在纯 plan 与 `LyricsSpecs`，不要先在 layer 执行代码里散改常数。
