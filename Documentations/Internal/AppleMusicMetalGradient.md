# Apple Music 歌词面板 Metal 渐变背景

> 对应提案：[自绘 Metal 歌词渐变背景](../Evolutions/0008-apple-music-metal-gradient.md)
>
> 面向维护者。这里记录最终 artwork texture、Metal Performance Shaders、网格形变与窗口生命周期之间的边界。

## 一句话

`GradientBackgroundView` 在后台把 artwork 缩到最长边 300 pixel，上传为 private mipmapped texture；
`ArtworkGradientMetalView` 使用 `MTKView` 的显示同步循环，在完整 backing resolution 上依次执行 artwork transition、
三组封面旋转合成、`MPSImageGaussianBlur` 和双曲面网格插值。最终颜色按 Apple Music 的高亮限制、深色遮罩和通道
下限处理，避免红色封面变成大面积高亮纯红。窗口不可见、拖动、live resize 或 Reduce Motion 时暂停连续绘制。

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

本实现通过公开 Metal API 重建已恢复的参数和着色公式，不分发 Apple 的 `metallib`，运行时不调用私有 mesh API：

- `TSLBackdropMetalView` 继承 `MTKView` 并实现 `MTKViewDelegate`；没有覆盖默认每秒 60 帧
  （frames per second，FPS）。
- `setCGImage:` 在后台把 artwork 最长边限制为 300 pixel，计算一次平均 luminosity，再通过 `MTKTextureLoader` 上传。
- `OffscreenBackdropEncoder` 持有 composition、blurred texture 与 `MPSImageGaussianBlur`。
- `PinchEncoder` 使用 5 × 5 个四边形单元，即 6 × 6 个控制点；subdivision level 为 3，最终 pass 处理 saturation 与 scrim。
- offscreen `imageDownSample` 在该版本初始化为 1，因此输出按完整 drawable pixel size 构建。
- 支持时使用 `BGR10A2Unorm`，否则回退 `BGRA8Unorm`；Gaussian blur options raw value 为 6，即
  `.allowReducedPrecision + .disableInternalTiling`，edge mode 为 `.zero`。
- `draw(in:)` 先编码 offscreen backdrop，再获取 `currentRenderPassDescriptor` 并编码最终 pass；present 发生在 populate
  完成之后。

CPU 侧结论由 runtime dump 的类型/地址、Interactive Disassembler（IDA）的反编译和 ARM64 汇编交叉确认。
2026-09-05 进一步读取本机 Music 的 Metal 着色器中间表示，补齐此前自行调校的颜色与运动逻辑：

| 证据入口 | 确认内容 |
|---|---|
| `OffscreenBackdropEncoder encode:uniforms:dark:`，`0x101400524` | composition saturation 为 1.3；一次绘制三个 instance |
| `TSLBackdropMetalView prepareImageScaleAndTime`，`0x1018291C8`；`populateCommandBuffer:`，`0x1018294B4` | 三组平移和旋转周期；默认 speed 为 0.5 |
| `PinchEncoder encode:...`，`0x10144CCF4`；`buildModels`，`0x10182927C` | 最终 saturation 为 2；默认黑色遮罩 0.25，深色偏移 0.02，通道范围 0.07–0.97 |
| `PinchVertexMap`，`0x101866FFC`、`0x1018670A0`；数据 `0x101AFC6F8` | 五组双曲面控制点，36 个初始顶点、25 个面和三级细分 |
| `rotation_vertex`、`rotation_fragment`、`pinch_vertex`、`pinch_fragment` | 两次旋转的矩阵顺序、两阶段饱和度、双曲面插值和高亮限制 |

CPU 数据来自 `/Volumes/RE/AppleMusic/26.6/Music.i64`。着色器来自本机
`/System/Applications/Music.app/Contents/Resources/default.metallib`，其目标为 macOS 26.6，SDK 为 26.6.1；该安装版本与
提供的 CPU binary 不是同一个 build，因此记录为两份相互核对的证据，不宣称整个程序逐字节一致。着色器文件的 SHA-256 为
`a2371de3540883dc38baf9d3419eecb98e970a9c77c701f51ac9ab05699fe762`。

## Artwork 预处理

`ArtworkBackdropImageProcessor` 只做两件事：

1. 当 artwork 最长边超过 300 pixel 时，按原 aspect ratio 用 sRGB Core Graphics context 下采样；小图保持原尺寸。
2. 另绘制一张 32 × 32 sample，在 linear-light 空间按 Rec. 709 权重计算平均 luminosity。

平均 luminosity 保留为纹理元数据；当前白字歌词面板采用深色合成规则，不再根据平均亮度叠加白色遮罩。

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
才采用该格式。每帧使用同一个六顶点 quad 绘制三个 instance，平移分别为 `(0, 0)`、`(-0.5, 0.7)`、`(-0.95, -0.7)`，
旋转参数的周期分别为 60、45、35 second。变换顺序为 `view × rotation × translation × rotation`；view 的纵向比例为
drawable width / height。三张封面按绘制顺序覆盖，随后由 blur 混合边界，不使用额外的逐像素色场或 alpha 叠加。

fragment shader 对 source/destination 使用相同纹理坐标，crossfade 后按 `(0.3, 0.59, 0.11)` 的灰度权重把 saturation
设为 1.3。切歌 transition duration 为 0.5 second，播放中再次到达的新 texture 放进单项 pending queue，当前 transition
完成后再接续。原版直接映射整张纹理到 quad；这里也不再把非正方形输入先裁成 aspect-fill。

### Gaussian blur

composition texture 直接交给 `MPSImageGaussianBlur`。sigma 按 drawable diagonal 的 `0.045394707` 计算，只在 drawable
size 改变时重建 kernel。kernel 使用 `.allowReducedPrecision + .disableInternalTiling` 与 `.zero` edge mode；composition 与
blurred texture 都使用 `.private` storage，并与 drawable 使用同一非 sRGB format。

### Mesh 与最终合成

`ArtworkBackdropMeshPresets` 保存五组 source/destination 控制点，创建 renderer 时只随机选择一次。第三、第四组在
分析版本中相同，保留两个入口以保持原版的选择概率。测试通过 `meshVariant` 固定选择，避免随机性影响参考坐标。

`ArtworkBackdropMeshTopology` 从 6 × 6 control points 出发，使用自行实现的规则网格 Catmull-Clark 曲面细分，执行三级：

- 每个维度 41 个 vertex；
- 总计 1,681 个 vertex；
- 9,600 个 `UInt32` index。

水平和垂直方向分别进行三点曲线细分，固定四个角点；边界曲线和内部曲率都参与细分，不能用均匀插值代替。
独立调用系统 `CAMeshTransform` 得到的参考坐标验证了曲面和弯曲边界；应用本身不依赖该私有类型。

两个曲面的顶点写入同一个 buffer。vertex shader 使用以下时间曲线插值屏幕位置，同时把纹理坐标向中心缩到 0.8：

```text
position = acos(sin(time × π / 1.75)) / π
progress = position² × (3 − 2 × position)
screenPosition = mix(sourcePosition, destinationPosition, progress)
textureCoordinate = (originalCoordinate − 0.5) × 0.8 + 0.5
```

这一插值每 3.5 second 往返一次，不是对固定网格的纹理坐标加小幅 `sin` 偏移。vertex/index buffer 和细分曲面只在
初始化时生成；逐帧三角函数位于 vertex shader，fragment shader 不产生程序化 noise。

最终深色合成按以下顺序执行，灰度权重仍为 `(0.3, 0.59, 0.11)`：

```text
saturated = gray + (blurredColor − gray) × 2
highlightLimited = min(saturated, 0.995)
darkened = highlightLimited × (1 − 0.25) − 0.02
output = clamp(darkened, 0.07, 0.97)
```

**高亮限制必须在黑色遮罩之前。** 如果只在最后截到 0–1，放大的颜色可以抵消遮罩，把红色重新顶到 1；绿、蓝又被
截成 0，形成此前的刺眼纯红。通道下限 0.07 保留暗部颜色，深色路径的实际最高通道约为 0.726。这里采用浮点实现，
与原版半精度运算及不同输出格式之间允许量化误差。当前面板不实现浅色背景分支，也不套用 mini player 的尺寸相关遮罩。

最终 render target 优先为 `.bgr10a2Unorm`，不支持时为 `.bgra8Unorm`；drawable pixel size 等于
`convertToBacking(bounds)`，不再使用 0.35 scale。

输出视图保留原版 `MTKView.colorspace = nil` 的默认行为，不再显式指定 sRGB。
[Apple 文档](https://developer.apple.com/documentation/metalkit/mtkview/colorspace) 将 nil 定义为不进行颜色匹配；
不能据此把它等同于 linear sRGB。离屏 PNG 为了便于复现而显式标记 sRGB，只用于检查像素与形变，不代表显示器上的最终颜色。

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

当前工作树中，用户已通过 `isEnabled: false` 关闭歌词与背景类的日志和性能宏；本轮保留这些设置。以下为埋点开启时的设计，
仅设置环境变量不会重新开启编译时关闭的宏。

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

自动化测试覆盖：默认 300 pixel/60 FPS/完整 drawable 配置、6 × 6 控制点的三级细分拓扑、aspect-ratio-preserving
downsample、luminosity 范围、generation gate、窗口生命周期，以及从原版取得的双曲面和边界参考坐标。

`ArtworkBackdropRenderingTests` 在现有 pipeline 的编码入口执行真实离屏 Metal 绘制，读取输出像素，检查饱和红色、
黑白灰、两阶段合成的采样位置、三组独立旋转，以及包含 MPS blur 的完整移动画面。命令行 Swift Package Manager 不生成
`default.metallib`，因此测试只在初始化时从实际 `.metal` 源文件编译并注入 library；应用仍加载 package 编译资源，不在
运行时编译着色器。最终还必须使用隔离 DerivedData 构建 umbrella workspace，并确认四个 function 存在：

- `artworkBackdropCompositionVertex`
- `artworkBackdropCompositionFragment`
- `artworkBackdropMeshVertex`
- `artworkBackdropFinalFragment`

自动化测试不评价真实观感与 WindowServer cadence。最终 brightness、形变幅度和全屏 60 FPS 仍需用户在实际播放中与
Apple Music 并排复检；不得用 `xctrace`，需要进程采样时只使用 `sample` 或现有 signpost/log。

设置 `LYRICSX_BACKDROP_PREVIEW_DIRECTORY` 可以在离屏测试中保存两帧 PNG。输入是自建的玫红封面测试图，导出结果用来
检查渲染后的颜色和空间变化；它不是运行中应用的截图，也不代表与同一首歌的 Apple Music 已完成逐帧对照。

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

### 2026-09-05 背景视觉修复验证

- 颜色、三组封面合成、原版曲面坐标与输出色彩空间回归测试均先在旧实现上失败，再在修复后通过。颜色测试读取真实
  Metal 输出，而不是重复调用实现公式；曲面参考值来自独立的原版控制点和系统细分结果。
- 包含 MPS blur 的离屏完整渲染通过，使用自建玫红封面验证通道范围与两帧间的空间变化。
- 首次完整串行执行 144 项测试时，既有 `emphasisTimelineKeepsGlyphsIntactAndInPlace` 在首次快照未读到文字而失败，
  原始退出码为 1。该测试单独复测通过；随后再次完整串行运行，144 项测试、18 个 suite 全部通过，原始退出码为 0。
  未修改该测试或歌词行内动画实现来绕过这次失败。
- umbrella workspace 的 LyricsX Debug 构建通过，原始退出码为 0。三条 warning 均来自此次未修改的 AppDelegate 和
  SearchLyricsViewController 中的过时 API；背景 Swift 和 Metal 编译没有新增 warning。
- 构建使用 `/tmp/codex/DerivedData/LyricsX`，已确认产物 resource bundle 的 `default.metallib` 包含全部四个预期 function。
  测试使用 `/tmp/codex/SwiftPM/LyricsX`；本轮八个背景相关 Swift 文件通过 SwiftFormat lint，`git diff --check` 通过。
- 未启动应用、未做交互截图或实际播放中的帧率测量；当前结论限于原版参数对齐、离屏像素验证与应用构建。

验证日志：`/tmp/codex/SwiftPM/LyricsX/backdrop-full-suite.log`、`backdrop-emphasis-recheck.log`、
`backdrop-full-suite-recheck.log`，以及 `/tmp/codex/BuildLogs/LyricsX/backdrop-build.log`。
