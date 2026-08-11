# 歌词候选池

> 对应提案：[0001 切换到下一条歌词候选](../Evolutions/0001-next-lyrics-candidate.md)
>
> 面向维护者。讲的是「为什么这么实现」，不是「实现了什么」——后者读代码更快。

## 一句话

自动搜索原本是擂台赛（新结果赢了就替换、输了就丢），现在改成擂台赛**加**一份完整名单：
落败的候选全部留在 `AppController.lyricsCandidatePool` 里，`advanceToNextLyricsCandidate()`
在名单里循环前进。上屏规则一个字没改。

## 三个「看起来更简单的路走不通」

### 一、为什么候选必须先入池再判上屏，而不是「上屏成功后顺手记一笔」

改造前 `lyricsReceived` 的结构是：比优先级 → 输了 `return` → 赢了才做 `filtrate()` /
`recognizeLanguage()` / 设 `currentLyrics`。

如果保持这个结构、只在赢的分支里往池子里塞一份，池子里就只有历任冠军，而不是全部候选 ——
恰恰漏掉了用户最想要的那些（被质量分压住的第二、第三名）。

所以顺序被倒过来了：**先把每条结果处理完整并入池，再决定它上不上屏**。代价是原本只对冠军做的
`filtrate()` / `recognizeLanguage()` 现在对每条候选都要做（最多 5–8 条，可忽略），
以及封面相似度打分（`scheduleArtworkScoring`）也扩展到了全部候选 —— 后者是**必须**的，
因为封面加分会改变排序，只给冠军打分会让池子的顺序和用户在搜索面板里看到的不一致。

### 二、为什么「钉住」不能省

用户按下快捷键切到第 2 条时，搜索**通常还在跑**。没有钉住的话，两秒后一条高分结果到达，
`lyricsReceived` 会照常判定它优先级更高并替换 `currentLyrics` —— 屏幕自己跳回去了，
而用户完全无法理解发生了什么。

`candidateSelectionIsPinned` 因此有三个作用点，缺一不可：

- `lyricsReceived`：钉住后新结果**继续入池**（用户还可以继续往下切），但不再上屏；
- `applyArtworkBonus`：封面加分同样不得移动用户的选择，但**仍然要重排池子**；
- `currentTrackChanged`：切歌时清除，否则下一首歌会带着上一首的钉住状态开场。

### 三、为什么需要 `LyricsSelectionOverrideTable`，而不是直接写文件

自动加载有固定顺序：音频文件内嵌歌词 → 音轨旁边的 `.lrc` → 保存目录。
用户切换后的那条会 `persist()` 到保存目录，也就是**顺序最末**。下次播放时前两者仍然优先，
用户的选择只活一次播放。

三条路都试过，前两条被否：

- **直接覆盖音轨旁边的文件** —— 违反 `3f1c1ab` 建立的「beside-track 歌词默认只读」策略，
  会破坏用户自己放的文件。
- **把「用户已选定」写进 lrcx 的自定义标签** —— 不需要新的偏好数据，且随文件走。
  但要求 LyricsKit 对未知 id tag 做无损往返，这一点没有验证过，风险高于收益。
- **（采用）按 track id 记一张覆盖表** —— 不碰用户任何文件，加载时把表里那条插到查找顺序最前。

表只在**自动顺序确实会压过这次选择时**才写（`automaticLookupPrecedes`），否则反而要把旧条目删掉；
所以大多数用户这张表始终是空的。上限 300 条，超了按时间戳裁到 200 —— 时间戳正是条目编码成
`"<unix 时间戳>\t<路径>"` 的唯一理由，纯路径无法决定该淘汰谁。

## 池子为什么是泛型的、又为什么放在 LyricsXFoundation

`PriorityOrderedCandidatePool<Candidate: AnyObject>` 不认识 `Lyrics`，比较函数从外面传进来
（app 侧传的是 `lyricsHasHigherPriority`，它依赖 `defaults`，进不了 package）。

这样做的直接好处是它能在 `LyricsXFoundationTests` 里用一个三行的 `ScoredCandidate` 测完
——包括那条最容易写错、也最难在真机上复现的规则：**插入点落在选中项之前时，`selectedIndex`
要跟着 +1**。不修正的话，一条迟到的高分结果会把选择悄悄挪到隔壁，用户按下一次「下一条」
拿到的是自己刚看过的那条歌词。

`resort()` 用「重放插入顺序」而不是 `sort`，是为了让同分候选保持到达顺序 ——
`SearchLyricsViewController.resortAfterArtworkScoring` 早就是这么做的，两边必须一致。

## 与提案的差异

- 提案写的是「候选池为空时触发补充搜索，完成后再切」。实现改成**收到第一条与当前内容不同的
  候选就立刻切**，不等搜索跑完。一次完整搜索可能几十秒，按键后几十秒没反应等同于快捷键坏了。
- 提案没提去重。实现按**时间轴正文指纹**（`lyricsContentFingerprint`，只算行时间与文本、
  不算 metadata）去重：不同源返回一模一样的歌词很常见，切过去看不出变化同样等同于坏了。
- 提案没提 `importLyrics`。实现顺带把它也接进了池子并钉住 —— 拖入一个 lrc 文件后，
  在途的搜索结果原本同样能把它顶掉，这是同一个竞态。
- 提案里 `advanceToNextCandidate()` 有返回值。实现改成返回 `Void`，结果走
  `lyricsCandidateSwitchOutcomes`（`PassthroughSubject`）：补充搜索那条路径的结果是**异步**产生的，
  按键返回时还不知道切没切成，返回值天然表达不了它。两条路径因此汇到同一个显示入口。
- 提案计划把「钉住后不被自动替换」做成自动化测试。首版**没做成**（判定散在
  `AppController` 里，而 app target 没有测试宿主）；补窗口缺口时把整段判定抽成了
  `LyricsDisplayEligibilityPolicy`，这条随之补上。

## 四、迟到的结果要进池子，但不许上屏

优先级窗口（默认 5 秒）原本的实现是在 `searchTask` 的循环里**直接丢弃**窗口外的直接结果 ——
连 `lyricsReceived` 都不调用。候选池加进来之后这就成了缺口：迟到的结果同样是合法候选，
用户按「下一条」时理应能切到它们，只是不该在用户已经开始读歌词之后自己把屏幕换掉。

修法是把窗口从「要不要处理这条结果」下移到「这条结果能不能上屏」：窗口外的结果照常走
`lyricsReceived` 入池，只是被打上 `Lyrics.arrivedAfterPriorityWindow` 标记。

**标记为什么挂在 `Lyrics` 上而不是做成函数参数** —— 因为封面相似度的加分是**异步**落地的
（`applyArtworkBonus`）。加分会抬高分数，若它不知道这条候选已经错过窗口，就会从封面这条路
把它送上屏，绕开正门的拦截。标记跟着歌词对象走，两个判断点才能看到同一个事实。

「能不能上屏」的完整判定（钉住、迟到、Route B 分层、质量比较）抽成了
`LyricsDisplayEligibilityPolicy`，因此可以在 `LyricsXFoundationTests` 里测 ——
包括那条最要紧、也最难在真机上复现的：**钉住之后，任何输入组合都不得替换屏幕**。

## 已知空白

候选池的状态机本身（`candidatePoolTrackId` 的串池防护、补充搜索的取消与重入）仍然没有
自动化测试：它们是 `AppController` 的状态，而 app target 没有测试宿主，项目的自动化测试
只覆盖 `LyricsXPackage`。可测的部分已经尽量外移成纯策略（排序、索引修正、回绕、覆盖表、
上屏资格），剩下的只能手工验证：播一首有多个候选的歌 → 立刻按快捷键 →
观察后续到达的结果不再改变屏幕、但按「下一条」仍能切到它们。

## 并发

候选池跟 `currentLyrics` 用同一套访问约定 —— 也就是**没有约定**：`currentTrackChanged`
跑在 `DispatchQueue.lyricsDisplay` 上，搜索结果与用户动作跑在主线程。这是既有设计，
本次没有改变它，因此候选池的方法也一律不标 `@MainActor`。

真正的防线不是隔离而是**身份校验**：`candidatePoolTrackId` 保证跨曲目的结果不会串池，
`searchRequest.id` 保证跨搜索的结果不会串。改并发模型是另一件事，不要顺手在这里做半套。
