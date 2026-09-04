# Apple Music 歌词面板 Metal 渐变背景

> 对应提案：[自绘 Metal 歌词渐变背景](../Evolutions/0008-apple-music-metal-gradient.md)
>
> 面向维护者。这里记录最终 artwork texture、Metal Performance Shaders、网格形变与窗口生命周期之间的边界。

## 一句话

`GradientBackgroundView` 在后台把 artwork 缩到最长边 300 pixel，上传为 private mipmapped texture；
`ArtworkGradientMetalView` 使用 `MTKView` 的显示同步循环，在完整 backing resolution 上依次执行 artwork transition、
`MPSImageGaussianBlur` 和细分网格合成。窗口不可见、拖动、live resize 或 Reduce Motion 时暂停连续绘制。

## 数据流

```text
main thread                  artwork queue                    MTKView display cadence
───────────                  ─────────────                    ───────────────────────
NSImage → CGImage ─────────→ longest edge ≤ 300 pixel
track identity + generation average luminosity
       ↑                     private mipmapped MTLTexture
       └── accepted texture ← generation gate ──────────────→ source/destination queue
                                                                  │
                                                                  ▼
                                                       artwork composition pass
                                                                  │
                                                                  ▼
                                                       MPSImageGaussianBlur
                                                                  │
                                                                  ▼
                                                   mesh warp + saturation + scrim
                                                                  │
                                                                  ▼
                                                     full-resolution drawable
```

原 artwork 的像素细节只影响一次性的后台预处理。逐帧路径不再执行 palette clustering，也不再为每个输出像素计算五组
`sin` 色场或程序化 grain。

## Apple Music 26.6 证据边界

本实现复刻的是公开可重建的架构，不复制 Apple 的 shader、metallib 或私有类型：

- `TSLBackdropMetalView` 继承 `MTKView` 并实现 `MTKViewDelegate`；没有覆盖默认每秒 60 帧
  （frames per second，FPS）。
- `setCGImage:` 在后台把 artwork 最长边限制为 300 pixel，计算一次平均 luminosity，再通过 `MTKTextureLoader` 上传。
- `OffscreenBackdropEncoder` 持有 composition、blurred texture 与 `MPSImageGaussianBlur`。
- `PinchEncoder` 使用预生成的 5 × 5 base mesh，subdivision level 为 3，最终 pass 处理 saturation 与 scrim。
- offscreen `imageDownSample` 在该版本初始化为 1，因此输出按完整 drawable pixel size 构建。
- 支持时使用 `BGR10A2Unorm`，否则回退 `BGRA8Unorm`；Gaussian blur options raw value 为 6，即
  `.allowReducedPrecision + .disableInternalTiling`，edge mode 为 `.zero`。
- `draw(in:)` 先编码 offscreen backdrop，再获取 `currentRenderPassDescriptor` 并编码最终 pass；present 发生在 populate
  完成之后。

这些结论分别由 runtime dump 的类型/地址、Interactive Disassembler（IDA）decompile 与 disassembly 交叉确认。具体视觉常量属于本项目重新调校值，
不宣称逐项等同于 Apple Music。

## Artwork 预处理

`ArtworkBackdropImageProcessor` 只做两件事：

1. 当 artwork 最长边超过 300 pixel 时，按原 aspect ratio 用 sRGB Core Graphics context 下采样；小图保持原尺寸。
2. 另绘制一张 32 × 32 sample，在 linear-light 空间按 Rec. 709 权重计算平均 luminosity。

`MTKTextureLoader` 在同一 serial queue 上创建 texture，固定使用：

- sRGB sampling；
- generated mipmaps；
- `.private` storage；
- `.shaderRead` usage；
- top-left origin。

completion 回到 main thread 后必须先通过 `ArtworkGradientRequestState` 的 generation gate。上一首歌晚到的 texture 不能
进入 transition queue。`NSImage` 转 `CGImage` 仍在 main thread 完成，后台线程不访问 AppKit object。

## Metal pipeline

### Artwork composition

source 与 destination texture 先绘制到与 drawable 相同格式的 offscreen texture。renderer 依次尝试
`.bgr10a2Unorm` 与 `.bgra8Unorm`，只有 device 能创建 render-target/shader-write texture 且两条 render pipeline 都能建立时
才采用该格式。vertex shader 计算 aspect-fill、轻微 rotation 和固定 zoom；fragment shader 只做两次 texture sample 与
crossfade。切歌 transition duration 为 0.5 second，播放中再次到达的新 texture 放进单项 pending queue，当前 transition
完成后再接续，避免中途跳色。

### Gaussian blur

composition texture 直接交给 `MPSImageGaussianBlur`。sigma 按 drawable diagonal 的 `0.045394707` 计算，只在 drawable
size 改变时重建 kernel。kernel 使用 `.allowReducedPrecision + .disableInternalTiling` 与 `.zero` edge mode；composition 与
blurred texture 都使用 `.private` storage，并与 drawable 使用同一非 sRGB format。

### Mesh 与最终合成

`ArtworkBackdropMeshTopology` 从 5 × 5 control points 出发，执行三级均匀细分：

- 每个维度 33 个 vertex；
- 总计 1,089 个 vertex；
- 6,144 个 `UInt32` index。

vertex buffer 与 index buffer 只创建一次。运动的 `sin`/`cos` 只在这些 vertex 上执行，fragment shader 只 sample blurred
texture、提高 saturation，并根据 source/destination 平均 luminosity 插值 black/white scrim。没有逐像素程序化 noise。

最终 render target 优先为 `.bgr10a2Unorm`，不支持时为 `.bgra8Unorm`；drawable pixel size 等于
`convertToBacking(bounds)`，不再使用 0.35 scale。

## Frame pacing 与生命周期

连续绘制完全交给 `MTKView`：

- `preferredFramesPerSecond` 最高为 60，即使当前屏幕支持 120 Hz；这与分析版本的 Apple Music 默认值一致。
- 不创建 `DispatchSourceTimer`，不直接调用 `CAMetalLayer.nextDrawable()`。
- `MTKViewDelegate.draw(in:)` 先创建 command buffer 并编码 composition/blur，再获取 `currentRenderPassDescriptor` 与
  `currentDrawable`，最后编码 mesh pass、present 与 commit。
- 连续绘制从暂停恢复时只修改 `isPaused`，不额外同步调用一次 `draw()`。
- `autoResizeDrawable` 关闭，由 view layout 显式同步完整 backing size；拖动和 live resize 时冻结 size，结束后一次更新。

`ArtworkGradientRenderingPolicy` 只有在以下条件全部满足时才允许连续渲染：

- view controller 已显示；
- view 已附着到可见 window；
- window occlusion state 包含 `.visible`；
- view 没有被隐藏；
- window 不在自定义 drag；
- view 不在 live resize；
- Reduce Motion 未开启。

暂停时 `ArtworkGradientAnimationClock` 同时停止，恢复后不会跳到 wall-clock 的新位置。Reduce Motion 只在 artwork、尺寸或
状态改变时请求单帧。

## 日志与性能埋点

实现继续使用 FrameworkToolbox：

- `ArtworkBackdropPreparation` 覆盖 downsample、luminosity 与 texture upload。
- 每个 reporting interval 输出 requested/measured FPS、missed frame、最大 frame gap、drawable size 与各阶段平均/最大值。
- 超出当前 60 FPS 帧预算时发出 `GradientSlowFrame`，command buffer error 单独记录。
- `GradientFrameEncode`、drawable acquisition、offscreen/final encoding、submission，以及歌词 display link 的内部 interval
  默认不生成；只有进程环境变量 `LYRICSX_DETAILED_FRAME_SIGNPOSTS=1` 时才开启。

不要把逐帧 signpost 改成逐帧可读字符串日志。常规复测只使用状态转换、资源重建、周期汇总、慢帧和异常日志；需要
阶段级 signpost 时启动单个隔离构建进程并临时设置环境变量。

## 失败降级

以下任一条件失败时只显示 `LayerBackedView` 的静态 fallback color，不影响歌词与控制：

- 没有 Metal device；
- Metal Performance Shaders 不支持当前 device；
- command queue、pipeline、mesh buffer 或 fallback texture 创建失败；
- package resource bundle 缺少预期 Metal function。

暂时缺少 artwork 时保留上一张背景 1.2 second；仍未收到时 transition 到内置 2 × 2 fallback texture。fallback texture
只用于无 artwork，不恢复已删除的 palette extractor。

## 与原提案的差异

原提案先后采用过 Core Image 静态 backdrop、低分辨率 palette `MTKView`，以及为了隔离 main thread 而改写的自定义
`CAMetalLayer + DispatchSourceTimer`。真实日志证明最后一种路径仍会因 drawable backpressure 稳定落到 30 FPS；
Apple Music 二进制证据也推翻了“不应每帧使用 artwork texture”的前提。

最终实现因此有意撤销三项旧约束：

- 从 palette uniform 回到 artwork texture；
- 从 0.35 drawable scale 回到完整 backing resolution；
- 从自定义 timer 回到 `MTKView` display pacing。

保留下来的部分是 generation gate、窗口生命周期暂停、Reduce Motion、隔离构建以及性能日志。

## 验证边界

自动化测试覆盖：默认 300 pixel/60 FPS/完整 drawable 配置、5 × 5 三级细分拓扑、aspect-ratio-preserving downsample、
luminosity 范围、generation gate、窗口生命周期和 `MTKView` 架构断言。

Swift Package Manager 命令行测试不会把 `.metal` 编译进 `default.metallib`，因此最终必须再使用隔离 DerivedData 构建
umbrella workspace，并确认四个 function 存在：

- `artworkBackdropCompositionVertex`
- `artworkBackdropCompositionFragment`
- `artworkBackdropMeshVertex`
- `artworkBackdropFinalFragment`

自动化测试不评价真实观感与 WindowServer cadence。最终 brightness、形变幅度和全屏 60 FPS 仍需用户在实际播放中与
Apple Music 并排复检；不得用 `xctrace`，需要进程采样时只使用 `sample` 或现有 signpost/log。

### 2026-08-31 当前验证结果

- 歌词面板相关 50 项测试串行执行，`swift test` 原始退出码为 0。
- 同一个实时行内弹跳探针在与 workspace build 并行时曾因 wall-clock 抖动失败；单独重跑和随后串行执行完整 50 项均通过。
- umbrella workspace 的 LyricsX Debug scheme 使用隔离 DerivedData 构建，`xcodebuild` 原始退出码为 0。
- app resource bundle 的 `default.metallib` 已确认包含上述四个 function。

### 2026-08-31 cadence 复检与修订

- 单实例稳定阶段背景周期汇总为 56.5–60 FPS；间歇出现 48–128 ms 的 callback gap，但对应 frame 内 command encoding
  约 0.17–0.59 ms，说明主要空档发生在 `MTKViewDelegate` callback 之间，而不是 shader encoding 内。
- 同一时间曾运行隔离 DerivedData 与 Xcode DerivedData 中的两个 `LyricsX-Debug`，并各自产生逐帧 lyrics/gradient
  signpost；这既干扰 WindowServer cadence，也让统一日志过快淘汰旧消息。
- 回归测试先在缺少诊断 policy 与 rendering profile 时编译失败，新增的三项测试在实现后通过。随后定向运行 52 项
  歌词面板测试：51 项通过，一个真实时间行内弹跳探针在并发测试负载下失败；该探针单独重跑原始退出码为 0。
- umbrella workspace 的 LyricsX Debug scheme 使用隔离 DerivedData 构建，`xcodebuild` 原始退出码为 0；app bundle 的
  `default.metallib` 仍包含四个预期 function。
- 隔离构建已作为唯一 LyricsX app 启动，等待打开真实全屏歌词后检查 selected pixel format 与周期 cadence；因此本轮
  尚不把运行时观感和稳定 60 FPS 标记为已验证。
- 后续真实复测只运行隔离 DerivedData 中的一个 app；不得使用 `xctrace`，如仍有间歇卡顿，只允许使用 `sample`、
  Lightweight Logging 汇总或显式开启一次详细 signpost。
- 完整 package test 仍有既存 `LyricsXWidgetSharedTests.WidgetDataStore` round-trip 失败；本次不把它记录为通过。
- 隔离构建已启动；截至记录时窗口处于 `occluded=true`，尚未取得真实全屏 cadence，提案因此仍为 `In Progress`。
