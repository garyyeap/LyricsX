# 0008 - 自绘 Metal 歌词渐变背景

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-29
- **最后更新**: 2026-08-30
- **所属愿景**: 无
- **关联提案**: [0007 对齐 Apple Music 26.6 歌词动画](0007-apple-music-lyrics-animation-parity.md)
- **实现分支 / Pull Request**: `develop`（当前工作树，未单独开分支）
- **配套文档**: [Metal 歌词渐变背景实现说明](../Internal/AppleMusicMetalGradient.md)

## 摘要

歌词面板改用项目自有的 `MTKView` 渐变背景。每首歌只在后台把封面压到 44 × 44 pixel 并提取五个主色；
fragment shader 用这些颜色绘制缓慢移动的柔和色块。drawable 固定为窗口 backing resolution 的 35%，每秒帧数
（frames per second，FPS）跟随当前屏幕的 `maximumFramesPerSecond`；尚未附着屏幕时回退到 60 FPS。窗口拖动、
不可见、完全被遮挡或开启 Reduce Motion 时停止连续绘制。

不恢复 SwiftUI 宿主，不把原封面作为全窗口 texture，也不重新引入 ColorfulX、ColorVector 或
SpringInterpolation。切歌只替换一组很小的颜色 uniform，并在 shader 中交叉渐变。

## 动机

一次性 Core Image 封面模糊背景在静止时成本很低，但用户实测复杂封面下拖动歌词窗口仍会掉帧。它还要求
WindowServer 在窗口移动时持续合成一张铺满窗口的 artwork layer，性能会随封面内容和显示尺寸变化。

ColorfulX 的视觉方向更合适，但 5.6.4 的 AppKit 实现仍按 drawable 全分辨率、显示刷新率持续提交 compute
command，而且没有窗口遮挡和拖动期间的暂停策略。直接接回它会重新引入三项依赖，也无法约束本项目最关心的
窗口拖动路径。

自有 `MTKView` 可以保留多色渐变的观感，同时明确控制每帧像素量、刷新率与生命周期。封面只参与一次性取色，
因此背景成本不再取决于封面纹理细节。

## 目标

1. 保留封面主色驱动的柔和动态渐变，观感接近此前得到认可的渐变背景。
2. 背景按当前屏幕的最高刷新率持续渲染，drawable 面积约为原生 backing drawable 的 12.25%。
3. 窗口拖动、不可见、完全被遮挡、live resize 和 Reduce Motion 下不持续提交 Metal command。
4. 每首歌最多执行一次后台取色；旧曲目的异步结果不能覆盖当前 palette。
5. 切歌 palette 平滑过渡；Reduce Motion 下立即显示新 palette。
6. 保持歌词面板纯 AppKit，不增加第三方依赖。

## 非目标

- 不复制 Apple Music 或 ColorfulX 的 shader、metallib、内部类型或具体实现。
- 不逐像素复现 Apple Music 私有动态背景。
- 不把原 artwork 上传成 full-window texture，也不做实时 blur。
- 不恢复整套 SwiftUI 歌词面板。
- 不新增背景模式、质量档位或用户设置。
- 不改歌词行内、行间和 viewport blur 动画。

## 提议方案

### 一、异步 palette 提取

`ArtworkGradientPaletteExtractor` 接收在 main thread 取得的 `CGImage`，在专用 serial queue 上执行：

```text
CGImage → 44 × 44 RGBA8 sample → nearest-centroid clustering
        → dominant mood colors + sufficiently large accent colors
        → saturation boost + bounded brightness → five-color palette
```

同一曲目只提交一次。`ArtworkGradientRequestState` 用 track identity 与单调递增 generation 拒绝乱序 completion。
新曲目短暂缺少封面时先保留当前 palette，超过 1.2 秒仍未收到 artwork 才回到内置 fallback palette。

### 二、低分辨率 `MTKView`

`GradientBackgroundView` 承载一个自有 `MTKView`：

- `preferredFramesPerSecond` 跟随 `window.screen.maximumFramesPerSecond`，尚未附着屏幕时回退到 60；
- `framebufferOnly = true`；
- `autoResizeDrawable = false`；
- drawable 宽高分别取 native backing size 的 35%；
- 单个 full-screen triangle，不创建 vertex buffer、artwork texture、depth texture 或 multisample texture；
- `.metal` source 由 Swift Package Manager 预编译，运行时从 `Bundle.module` 创建一次 render pipeline。

低分辨率渐变由 compositor 线性放大。渐变本身是低频内容，不需要原生像素密度；这把 fragment 数量固定到
原生 drawable 的 12.25%，同时避免中央处理器（Central Processing Unit，CPU）生成或上传逐帧图像。

### 三、shader 与 palette transition

fragment shader 每帧只接收五个 `float4` 颜色和一组时间参数。五个缓慢移动的中心按距离计算权重，再混合成
连续色面；最后加入很弱的静态 grain 与黑色遮罩（scrim）。运动完全由 elapsed time 推导，CPU 不维护逐点 spring。

切歌时 Swift 端保留 source / target palette 和 transition start time，每帧在线性颜色空间插值后上传 80 byte
颜色数据。Reduce Motion 开启时 transition duration 为零，并只请求一张静态 frame。

### 四、生命周期与窗口拖动

`GradientBackgroundView` 同时检查：

- view controller 是否正在显示；
- view 是否仍在 window；
- window 是否可见且 `occlusionState` 包含 `.visible`；
- `DraggablePanelView` 是否正在移动窗口；
- view 是否处于 live resize；
- Reduce Motion 是否开启。

任一条件要求暂停时，`MTKView.isPaused` 立即置为 `true`。动画时钟同时暂停，恢复后不会因为 wall-clock 已前进而
跳到另一个渐变位置。窗口拖动只复用最后一张 drawable；拖动结束后按当前屏幕刷新率继续绘制。窗口移到另一块
屏幕时，通过 `NSWindow.didChangeScreenNotification` 立即更新 `MTKView` 的刷新率。

## 替代方案考量

- **恢复 ColorfulX 5.6.4** —— 否决。它是纯 AppKit + `CAMetalLayer`，但默认按完整 drawable 和 display link
  持续 compute，没有本项目需要的 occlusion / drag gating，并重新引入两项传递依赖。
- **保留一次性 Core Image artwork backdrop** —— 否决。静止成本低，但复杂封面下窗口拖动仍出现用户可见掉帧，
  且视觉是封面空间模糊，不是用户最终选择的多色渐变方向。
- **用 `NSHostingView` 恢复最初 SwiftUI gradient** —— 否决。会重新扩大 SwiftUI invalidation boundary；现有
  AppKit 歌词逐帧更新不应经过 hosting tree。
- **全分辨率并按屏幕上限自绘 Metal** —— 否决。原生显示 cadence 能避免全窗口 30 Hz 的交互观感，但背景是低频
  内容，不需要原生像素密度；最终保留 0.35 drawable scale，只让提交 cadence 跟随屏幕。
- **完全静态 palette** —— 保留为 Reduce Motion 降级，不作为默认；正常模式仍需要轻微环境运动。

## 影响

### 用户可见变化

- 背景由封面模糊图改为封面主色驱动的缓慢动态渐变。
- 窗口拖动时背景暂时冻结，松手后从同一位置继续；歌词与控制仍正常更新。
- 切歌时颜色平滑变化，不出现黑帧或旧曲目异步结果回跳。

### 可发现性

这是现有歌词面板的直接视觉替换，没有新入口或设置。

### 数据与配置兼容

不新增或迁移 `UserDefaults`，不改变歌词、封面缓存和播放器数据格式。

### 平台与最低版本

不改变 package 的 macOS 12 最低版本。`MTKView`、Metal 资源 library 与窗口 occlusion API 均满足现有目标。

### 发布

发布说明只需描述歌词面板背景视觉与窗口拖动性能改善，不暴露 shader 或依赖清理细节。

## 测试与验证

### 自动化测试

1. 默认配置固定为五色、44 pixel sample、0.35 drawable scale 与既定 transition 参数；刷新率策略在没有有效屏幕值时
   回退到 60，并原样采用 60 / 120 等有效屏幕上限。
2. drawable size 按 backing size 缩放并处理零尺寸。
3. 同一曲目只取色一次，新曲目使旧 generation 失效。
4. palette normalization 始终生成五个颜色，空结果回退到内置 palette。
5. 合成分区图片能够提取到有界、非空的 palette。
6. lifecycle policy 在隐藏、遮挡、窗口拖动和 Reduce Motion 下停止连续渲染。
7. package build 验证 `.metal` source 能被编译并从 target resource bundle 链接。

### 构建与人工观察

- 运行 `ArtworkGradient` 专项测试并以 `swift test` 原始退出码为准。
- 使用隔离 DerivedData 构建 umbrella workspace 的 LyricsX Debug scheme。
- 不默认启动应用。最终视觉与窗口拖动由用户在真实面板中观察；需要 agent 交互式 UI 验证时另行授权。

## 风险

- `Bundle.module` 取错会导致 runtime 找不到 shader；pipeline 必须明确从 package resource bundle 创建。
- Swift / Metal uniform layout 不一致会产生错误颜色；palette 使用单独的 `float4` array，参数使用一个 `float4`，
  避免自定义结构 padding。
- `autoResizeDrawable` 若保持默认值会恢复原生分辨率；必须关闭并在 layout / backing scale 变化时显式更新。
- 只设置 `isPaused` 而不暂停动画时钟会在松手时跳帧；两者必须作为同一个状态转换。
- palette completion 必须回到 main thread 并通过 generation gate，不能从后台 queue 修改 view 或 renderer 状态。

## 文档策略

- 更新本提案与 `Documentations/Internal/AppleMusicMetalGradient.md`。
- 不修改用户明确不再维护的旧 `docs/`。
- 无调用者 API 和隐藏使用契约，因此不新增 guide。
- 没有引入项目自造术语，因此不修改 glossary。
- 不改变安装、使用和构建流程，因此不修改公开 README。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-29 | Created as Draft | 用户指出 ColorfulX 背景与 Apple Music 的明暗、空间感仍有差距。 |
| 2026-08-29 | Draft → Accepted | 用户接受以自有 Metal artwork renderer 替换 ColorfulX 的初版方案。 |
| 2026-08-29 | 初版持续 Metal 方案撤回 | 真实亮色封面被 brightness lift 推得过亮，用户要求恢复最初 SwiftUI 视觉。 |
| 2026-08-29 | 批准 Core Image 修订 | 用户确认把旧 SwiftUI artwork blur 移植到一次性预渲染与纯 AppKit layer。 |
| 2026-08-29 | Core Image 实现完成 | 专项测试、package tests 与 workspace Debug build 通过，等待真实视觉与性能复检。 |
| 2026-08-30 | 复杂封面拖动复检失败 | 用户确认复杂封面下拖动窗口仍掉帧，要求评估恢复 ColorfulX 或自绘 `MTKView`。 |
| 2026-08-30 | ColorfulX 5.6.4 只读核对 | 确认其为 AppKit + Metal，但按完整 drawable 持续 compute，且没有 occlusion / drag gating。 |
| 2026-08-30 | 批准自绘 `MTKView` 修订 | 用户接受低分辨率 30 FPS、异步 palette、拖动与不可见时暂停的自有 renderer；提案保持 `In Progress` 直到实现和验证完成。 |
| 2026-08-30 | In Progress → Implemented | 自有 `MTKView`、异步五色提取、generation gate、拖动 / 遮挡 / live resize / Reduce Motion 暂停与 package shader resource 已完成。专项 11 项与完整 package 113 项测试均以原始退出码 0 通过；隔离 DerivedData 的 umbrella workspace Debug build 成功，app resource bundle 内存在 `default.metallib` 且包含两个预期 shader function。 |
| 2026-08-30 | 文档与术语裁决 | 更新本提案、实现说明与两份索引；没有调用者隐藏契约和项目自造术语，因此不新增 guide、不更新 glossary，也不修改公开 README。 |
| 2026-08-30 | 固定 30 FPS 复检失败 | 用户观察到 Xcode 将窗口报告为约 30 FPS，面板操作也呈现 30 Hz 的卡顿感；源码核对确认限制来自全窗口 `MTKView`，不是歌词 `MSDisplayLink`。 |
| 2026-08-30 | 刷新率策略修订 | 用户批准让低分辨率 renderer 跟随当前屏幕 `maximumFramesPerSecond`，并在窗口换屏时更新；继续保留 drawable scale 与全部暂停策略。 |
| 2026-08-30 | 刷新率修订验证完成 | `ArtworkGradient` 专项 12 项与完整 package 114 项测试均以原始退出码 0 通过；umbrella workspace 的 LyricsX Debug scheme 使用隔离 DerivedData 构建成功。未启动应用，真实屏幕帧率仍由用户复检。 |
