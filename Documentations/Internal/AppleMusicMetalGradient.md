# Apple Music 歌词面板 Metal 渐变背景

> 对应提案：[自绘 Metal 歌词渐变背景](../Evolutions/0008-apple-music-metal-gradient.md)
>
> 面向维护者。这里记录 palette、Metal resource、低分辨率 drawable 与窗口生命周期之间的边界。

## 一句话

`GradientBackgroundView` 每首歌在后台从 44 × 44 artwork sample 提取五个颜色，然后让 `MTKView` 以原生
backing size 的 35%、当前屏幕的最高刷新率绘制一个 full-screen triangle。窗口拖动、不可见、完全被遮挡、
live resize 或 Reduce Motion 时连续渲染暂停，背景只保留最后一帧。

## 数据流

```text
main thread                           palette queue
───────────                           ─────────────
NSImage → CGImage ──────────────────→ 44 × 44 RGBA8
track identity + generation           nearest-centroid clustering
       ↑                              mood + accent selection
       └──────── accepted palette ←── bounded five-color palette
                         │
                         ▼
                source / target colors
                         │ 80 bytes per frame
                         ▼
                   fragment shader
                         │
                         ▼
            0.35-scale opaque drawable
```

原 artwork 不会成为 Metal texture。封面复杂度只影响一次性的 44 × 44 Core Graphics downsample，不影响每帧
fragment 工作量，也不会在窗口拖动时重新采样。

## Palette 提取

`ArtworkGradientPaletteExtractor` 执行轻量 nearest-centroid clustering：

1. 把 `CGImage` 绘制到 44 × 44 sRGB RGBA8 bitmap；
2. 用均匀分布的初始 centroid 做固定轮数的 assignment / recompute；
3. 先取覆盖率最大的三个 mood color；
4. 再取覆盖面积不低于阈值的高 saturation accent；
5. 调整 saturation，并把 brightness 压进适合白色歌词的范围；
6. 不足五色时循环已有颜色补齐，完全失败时使用内置 fallback palette。

提取只在 `ArtworkGradientPaletteExtraction` serial queue 上执行。`NSImage` 转 `CGImage` 仍在 main thread 完成，
避免从后台访问 AppKit object。

`ArtworkGradientRequestState` 保证同一 track identity 最多提交一次，并给每次请求分配 generation。completion 回到
main thread 后必须核对 generation；晚到的上一首歌 palette 直接丢弃。

## Metal resource 与 pipeline

shader source 位于 `AppleMusicLyricsPanel` target 内，并在 `Package.swift` 中显式登记为 processed resource。
Xcode 的 Swift Package Manager 集成会把它编译成 target resource bundle 里的默认 Metal library。renderer 必须使用：

```swift
try metalDevice.makeDefaultLibrary(bundle: .module)
```

不能使用无 bundle 参数的 default library；调用者 app 的 main bundle 不拥有 package shader。

命令行 `swift test` 当前会把 processed `.metal` 保留为 source resource，而不是生成 `default.metallib`；因此 package
测试只能验证 Swift 端逻辑，最终 app build 必须通过 Xcode workspace 验证 Metal 编译与 bundle 装配。

每个 `ArtworkGradientMetalView` 只创建一次 command queue 和 render pipeline。每帧只有：

- 一个 current drawable；
- 一个 render pass；
- 一个由 `vertex_id` 生成的 full-screen triangle；
- 五个 `float4` palette color；
- 一个 `float4` rendering parameter；
- 一次 present。

没有 vertex buffer、artwork texture、offscreen texture、depth attachment 或 multisampling。`framebufferOnly` 保持
开启，render target 使用 opaque BGRA sRGB 格式。

## 低分辨率 drawable

`autoResizeDrawable` 必须关闭。view 在 `layout()` 与 `viewDidChangeBackingProperties()` 中计算：

```text
drawable width  = native backing width  × 0.35
drawable height = native backing height × 0.35
```

宽高至少为一个 pixel。0.35 的宽高比例意味着 fragment 总数约为原生 drawable 的 12.25%。渐变只有低频色面，
交给 compositor 放大不会像文字或图标一样暴露像素边缘。

不要改回 `preferredDrawableSize` 或 window backing size，也不要根据 artwork resolution 决定 drawable size；这两种
写法都会让成本重新随显示器或封面变化。

`preferredFramesPerSecond` 必须取当前 `window.screen.maximumFramesPerSecond`。view 尚未附着到屏幕时使用 60；
`NSWindow.didChangeScreenNotification` 到达后重新读取，以支持窗口在 60 Hz 与 120 Hz 屏幕之间移动。不要再次固定成
30 FPS：这个 `MTKView` 覆盖整个窗口并持续 present，固定 30 会让窗口的可见提交 cadence 和 Xcode 帧率读数都落到
约 30 Hz，即使 AppKit event handling 本身没有被限速，操作仍会呈现明显的低帧率观感。

## Shader 与颜色过渡

vertex function 只生成覆盖 viewport 的 triangle。fragment function 根据 elapsed time 得到五个缓慢移动的颜色中心，
以距离权重混合 palette，再加入很弱的静态 grain 和 black scrim。

Swift 端在 source / target palette 之间做 linear-light interpolation。palette 数组单独作为连续 `float4` 上传，时间、
scrim、grain 和 aspect ratio 放在另一个 `float4`；不要合并成跨 Swift / Metal 的自定义嵌套 struct，以免 alignment
或 padding 改动静默破坏颜色。

切歌不会重建 pipeline 或 drawable。只更新 target palette 与 transition start time。Reduce Motion 开启时立即采用
target palette，并在 paused renderer 上手动请求一张 frame。

## 生命周期

`ArtworkGradientRenderingPolicy` 只有在以下条件全部满足时才允许连续渲染：

- view controller 已显示；
- view 已附着到 window；
- window `isVisible == true`；
- window `occlusionState` 包含 `.visible`；
- view 没有被隐藏；
- window 不在自定义 drag；
- view 不在 live resize；
- Reduce Motion 未开启。

`DraggablePanelView` 在第一次 `mouseDragged` 时通知背景暂停，在 `mouseUp` 时恢复。这里只冻结背景，不恢复
`isMovableByWindowBackground` 的 nested event tracking loop；歌词与播放状态仍可在 default run-loop mode 更新。

renderer 的动画时钟与 `isPaused` 同时停下。恢复时用累计动画时间继续，因此拖动后不会瞬间跳到 wall-clock 对应的
新位置。window occlusion 变化由 `NSWindow.didChangeOcclusionStateNotification` 触发重新判断。

## 性能边界

正常显示期间背景按当前屏幕上限执行低分辨率 fragment pass，常见为每秒 60 或 120 次。提高提交 cadence 是为了
避免全窗口 30 Hz 的交互观感；每帧 fragment 数量仍只有原生 drawable 的 12.25%，并继续受窗口生命周期策略约束。
以下操作只允许在 artwork 或 layout 变化时发生：

- `NSImage` 转 `CGImage`；
- 44 × 44 downsample 与 palette clustering；
- drawable size 更新；
- source / target palette 切换。

不要把 palette 提取放进 `draw(in:)`，不要在 shader 中采样原 artwork，也不要从歌词的 display link 主动调用背景
draw。歌词动画和背景各有自己的节奏与暂停条件。

## 失败与降级

- Metal device、command queue、shader library 或 pipeline 创建失败：显示内置静态 fallback color，不影响歌词。
- artwork 无法转换为 `CGImage`：切到 fallback palette。
- 新曲目暂时没有 artwork：保留上一 palette 1.2 秒，再切到 fallback palette。
- 异步旧结果晚到：generation gate 静默丢弃。
- Reduce Motion：停止连续渲染，palette 更新时只绘制一帧。

这里没有可重试的 runtime dependency，因此不建立 renderer retry loop。下一次 view 创建或曲目变化会自然重新走
相应初始化与 palette 路径。

## 依赖边界

ColorfulX、ColorVector 与 SpringInterpolation 保持从 Swift Package manifest、Xcode project 和 tracked
`Package.resolved` 移除。实现只使用 AppKit、Core Graphics、Metal 与 MetalKit。

`MSDisplayLink` 必须保留：`AppleMusicLyricsScrollView` 仍直接用它驱动 karaoke update；它与背景无关。

## 验证边界

自动化测试覆盖配置、drawable size、generation、palette normalization、真实合成图片取色与 lifecycle policy。
package / workspace build 负责验证 `.metal` resource 能编译和链接。

自动化测试不启动窗口，无法评价渐变观感或真实拖动流畅度。最终视觉、窗口拖动和不同显示器 backing scale 仍由
用户在应用中观察；agent 未获得交互式 UI 授权时不得自行启动应用。

## 2026-08-30 自动化验证

- `ArtworkGradient` 专项 12 项通过，`swift test` 原始退出码为 0；包含无屏幕回退 60、60 Hz 与 120 Hz 策略检查。
- 使用本地 sibling dependencies 运行完整 package tests，114 项通过，原始退出码为 0。
- umbrella workspace 的 LyricsX Debug scheme 使用 `/tmp/codex/DerivedData/LyricsX` 构建成功。
- 产物 `LyricsXPackage_AppleMusicLyricsPanel.bundle` 内存在 `default.metallib`；二进制包含
  `artworkGradientFullScreenVertex` 与 `artworkGradientFragment`。
- 未启动应用、未执行交互式 UI 验证；渐变观感与真实窗口拖动仍由用户确认。
