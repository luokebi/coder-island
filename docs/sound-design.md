# 8-bit 音效与 SoundPack 系统设计文档

> **状态**：Draft v0  
> **作者**：luo + Claude  
> **日期**：2026-04-15  
> **背景**：coder-island 当前音效系统现状 + Vibe Island v26.3.1 `SoundPack*` 架构逆向

---

## 0. 当前状态

### 0.1 coder-island

**代码**：[CoderIsland/Audio/SoundManager.swift](CoderIsland/Audio/SoundManager.swift)（321 行）  
**实现**：`NSSound` 直接播放  
**事件（4 个）**：
- `permission` - 权限请求
- `ask` - AskUserQuestion
- `taskComplete` - 任务完成
- `appStarted` - 应用启动

**预设（2 套）**：
- `mario` - 4 个 .mp3（mario_permission/question/complete/start）
- `system` - macOS 系统音（Submarine / Glass / Hero / Ping 等）

**自定义**：每个 event 可单独导入音频文件，存在 `~/Library/Application Support/CoderIsland/SoundPacks/Custom/`

**防抖**：`minInterval = 0.35s`，同一个事件名 350ms 内不重复播放

**全局/单事件开关**：`soundEnabled` + 4 个 `soundXxxEnabled`

### 0.2 缺点盘点

| 问题 | 影响 |
|---|---|
| **Mario 音效疑似侵权** | 任天堂原声采样商用有法律风险 |
| 只有 2 套预设，增加第 3 套要改代码 | 无法快速扩展 |
| 预设是硬编码进 bundle 的 .mp3 | 和用户自定义（文件系统导入）走两套不同逻辑 |
| 只有 4 个事件 | 细节事件（如 context compacting、spam、error）都响同一个声音或不响 |
| NSSound 不支持交叉淡入、音量渐变、同时多音叠加 | 多 agent 并发时要么打架要么被防抖吞掉 |
| 没有 **pack 分发/分享** 机制 | 社区传播路径断裂 |
| 没有声音-视觉联动 | 错失"像素伙伴"人格化机会（电子鸡效应） |

---

## 1. Vibe Island 的音效架构（逆向结果）

### 1.1 类结构

从 binary symbols 抽出：

```
SoundPackStore        // 管理所有 pack 的注册与加载
SoundPackManifest     // Pack 的元信息（JSON schema）
SoundPackAuthor       // Author 子结构
SoundPackCategoryEntry // 每个 pack 里分类的条目
SoundPackSoundEntry   // 分类下具体音效文件的条目
SoundPackPlayer       // AVAudioEngine-based 播放器
SoundCategory         // 事件类别枚举
```

底层用 **AVAudioEngine + AVAudioPlayerNode + AVAudioMixerNode + AVAudioPCMBuffer**（不是 NSSound）。这意味着支持：
- 多音同时播放（mixer node）
- 音量淡入/淡出
- 采样率无关
- 空间音频（如果以后想做）

### 1.2 Pack 格式：CESP

"**CESP**" 应该是 **Coder Island** 还是 **Custom Extension Sound Pack**？从上下文看应该是 Vibe Island 自定义格式名字（实际全称未知）。

**关键字符串**：
- `"Import Sound Pack..."` 菜单项
- `"Select a CESP sound pack folder or .zip file"` —— 接受**文件夹**或 **.zip**
- `"Invalid sound pack "` —— 校验机制
- `"Failed to load sound pack registry"` —— 有中心 registry

**推测的 CESP 目录结构**（基于 class 分层）：

```
my-pack.cesp/        # 或 my-pack.zip
├── manifest.json    # SoundPackManifest
│   {
│     "name": "Retro Chiptune",
│     "version": "1.0.0",
│     "author": {
│       "name": "Jane Doe",
│       "url": "https://..."
│     },
│     "categories": {                    # SoundPackCategoryEntry[]
│       "taskComplete": ["complete.wav", "complete_alt.wav"],   # SoundPackSoundEntry[]
│       "inputRequired": ["permission.wav"],
│       ...
│     }
│   }
├── sounds/
│   ├── complete.wav
│   ├── complete_alt.wav
│   ├── permission.wav
│   └── ...
└── README.md (optional)
```

### 1.3 事件分类体系（7 个 category，分 4 个 section）

**Section: session**
- `sessionStart` — "new session started"
- `taskComplete` — "AI finished turn"
- `taskError` — "tool or API error"

**Section: interactions**
- `inputRequired` — "permission or question pending"
- `taskAcknowledge` — "user submitted prompt"

**Section: filters**
- `userSpam` — "rapid prompt submissions"
- `resourceLimit` — "context window compacting"

**Section: system**
- （推测）app 启动、probe、hook 相关

每个 category 都有 `sound.cat.xxx`（名字）和 `sound.desc.xxx`（描述）两条 localizable string，说明 UI 里会同时展示 **类别名 + 说明**。

### 1.4 Vibe Island 捆绑的 sound assets

只有一个文件：`onboarding-ceremony.wav`（1.1MB）—— 开屏仪式音。  
**其他声音全部通过 sound pack 加载**。即使是默认"开箱体验"的声音也是一个内置 pack。

**启示**：代码里没有硬编码的音效文件路径，完全通过 pack 抽象出去。

---

## 2. coder-island 的下一代音效系统设计

### 2.1 设计原则

1. **Pack 化一切**：Mario、System、Custom 都是 SoundPack，统一走同一套加载逻辑
2. **Category > Event**：从 "4 个 event" 升级到 "N 个 category，分 section 组织"，每个 category 可映射多个 hook event
3. **AVAudioEngine 替代 NSSound**：支持并发、淡入淡出、音量控制
4. **Pack 格式开放**：社区可以制作/分享（比 Mario 侵权风险更低的路子）
5. **人格化联动**：声音和 notch 视觉绑定（见 §4）
6. **版权合规**：默认 pack 必须全部 CC0 或自制

### 2.2 目录与文件布局

```
~/Library/Application Support/CoderIsland/
├── SoundPacks/
│   ├── Built-in/              # app bundle 解压的默认 pack（只读）
│   │   ├── default.cipack/    # 新格式后缀 .cipack (CoderIslandPack)
│   │   ├── chiptune.cipack/
│   │   └── system.cipack/
│   ├── Installed/             # 用户安装的 pack
│   │   ├── retro-arcade.cipack/
│   │   └── minimal-click.cipack/
│   └── registry.json          # 活跃 pack 状态、版本、安装来源
└── ...
```

### 2.3 Pack 格式：`.cipack`

**Manifest schema**（`manifest.json`）：

```json
{
  "schemaVersion": 1,
  "id": "com.coderisland.default",
  "name": "Coder Island Default",
  "version": "1.0.0",
  "author": {
    "name": "Coder Island",
    "url": "https://coder-island.app",
    "avatar": "author.png"
  },
  "license": "CC0-1.0",
  "description": "Default pack bundled with the app",
  "preview": "preview.mp3",
  "sounds": {
    "sessionStart": [
      { "file": "session-start.wav", "weight": 1.0 }
    ],
    "taskComplete": [
      { "file": "task-complete-1.wav", "weight": 1.0 },
      { "file": "task-complete-2.wav", "weight": 0.3 }  // 变体
    ],
    "inputRequired": [
      { "file": "permission.wav" }
    ]
    // ...
  },
  "defaults": {
    "volume": 0.7,
    "randomizeVariants": true
  }
}
```

**关键设计点**：
- **多文件变体**（`taskComplete` 下多个）+ **权重**：避免同一个声音反复响，用户听疲
- **Schema version**：未来 breaking change 有路径
- **License 字段**：让用户清楚知道版权状态
- **Preview**：Settings UI 播放预览用

### 2.4 事件 → Category 映射（对齐 Vibe Island + 补充）

| Section | Category | 触发 hook 事件 |
|---|---|---|
| Session | `sessionStart` | Claude: `SessionStart` · Codex: `session_started` |
| Session | `taskComplete` | `Stop` / `SubagentStop` |
| Session | `taskError` | `PostToolUseFailure` / 任何 error event |
| Interactions | `inputRequired` | `Notification` with `permission_pending`/`asking_question` |
| Interactions | `taskAcknowledge` | `UserPromptSubmit` |
| Filters | `userSpam` | 本地检测：5 秒内 >3 次 UserPromptSubmit |
| Filters | `resourceLimit` | `PreCompact` / context 接近满 |
| System | `appStarted` | 本地：app 启动 |
| System | `remoteConnected` | 本地：远端 host 隧道建立 |

**比 Vibe Island 多的**：`remoteConnected` —— 呼应 SSH Remote 的用户体验。

### 2.5 新 `SoundManager` API 草图

```swift
final class SoundManager {
    static let shared = SoundManager()

    // 事件分类
    enum Category: String, CaseIterable {
        case sessionStart, taskComplete, taskError
        case inputRequired, taskAcknowledge
        case userSpam, resourceLimit
        case appStarted, remoteConnected
    }
    
    // 播放请求
    struct PlayRequest {
        let category: Category
        let context: Context?          // 携带 agent name/session id，用于视觉联动
    }
    
    // 公共 API
    func play(_ category: Category, context: Context? = nil)
    
    // Pack 管理
    var activePack: SoundPack { get }
    func activatePack(_ id: String) throws
    func installPack(from url: URL) throws -> SoundPack  // .cipack 或 .zip
    func uninstallPack(_ id: String) throws
    func allPacks() -> [SoundPack]
    
    // 每个 category 的开关（沿用当前 @AppStorage 模式）
    func isEnabled(_ category: Category) -> Bool
    func setEnabled(_ category: Category, enabled: Bool)
    
    // 音量
    var masterVolume: Float { get set }   // 0.0 ~ 1.0
}
```

### 2.6 播放策略：防抖 + 优先级 + 叠音

现状 `minInterval = 0.35s` 单一阈值过于粗。新策略：

| 策略 | 规则 |
|---|---|
| **Per-category cooldown** | 每个 category 自己的冷却窗口（例如 `taskComplete = 200ms`, `inputRequired = 无限制`） |
| **Priority table** | `inputRequired` > `taskError` > `taskComplete` > `taskAcknowledge`。低优在高优播放期间被丢弃 |
| **并发叠音** | 不同 category 可以同时响（AVAudioMixerNode 混合），同一 category 不行 |
| **静默时段** | 用户可设"深夜模式" 23:00-8:00 自动切换到柔和 variant 或静音 |
| **焦点感知** | 前台应用是 Xcode / 终端 / Figma 时音量 × 0.5（避免打断专注） |

### 2.7 版权合规

**默认 pack 的声音来源**（必须都是 CC0 / public domain 或自制）：
- [freesound.org](https://freesound.org) CC0 过滤
- [OpenGameArt.org](https://opengameart.org) chiptune 类
- [Kenney.nl](https://kenney.nl/assets) Digital Audio Pack（CC0）
- [Pixabay Audio](https://pixabay.com/sound-effects/) 部分 CC0
- 自制（推荐：请音效师做 8 秒一组共 8 个 category，预算 ~ 2000-5000 元）

**绝对禁止**：
- Mario / Zelda / Pokemon 等任何任天堂/世嘉/ATARI 原声采样
- 任何商业游戏的音效（即使被标注为 "game sound effect"）

**过渡方案**：
- v1 上线前把现有的 4 个 `mario_*.mp3` 替换为 CC0 等价物
- 保留"Mario"风格的 UI 描述（如"Retro Platformer"），但音效本体原创

---

## 3. Settings UI 设计

### 3.1 结构（参考 Vibe Island 的 section 分组）

```
┌─ Settings > Sound ───────────────────────────────────┐
│                                                       │
│  Master volume    [==========|----]   70%            │
│  [✓] Enable sounds globally                           │
│                                                       │
│  ── Active Pack ────                                  │
│  ┌──────────────────────────────────────────────┐    │
│  │  🎹 Retro Chiptune                            │    │
│  │  by Jane Doe · v1.2.0 · CC-BY                 │    │
│  │  [Preview ▶]    [Change Pack]                 │    │
│  └──────────────────────────────────────────────┘    │
│                                                       │
│  ── Session events ────                               │
│  [✓] Session start          ▶     (alt: ding.wav)    │
│  [✓] Task complete          ▶                         │
│  [✓] Task error             ▶                         │
│                                                       │
│  ── Interactions ────                                 │
│  [✓] Permission / Question  ▶                         │
│  [ ] Prompt acknowledged    ▶                         │
│                                                       │
│  ── Filters ────                                      │
│  [ ] Rapid prompts (spam)   ▶                         │
│  [✓] Context limit          ▶                         │
│                                                       │
│  ── System ────                                       │
│  [✓] App started            ▶                         │
│  [✓] Remote connected       ▶                         │
│                                                       │
│  ── Packs ────                                        │
│  [+ Import Sound Pack...]                             │
│  Installed:                                           │
│    ○ Built-in Default                     [Activate]  │
│    ● Retro Chiptune                       [Active]    │
│    ○ Minimal Click                        [Activate] [🗑]│
│                                                       │
│  [Open Sound Pack Folder in Finder]                   │
│                                                       │
└───────────────────────────────────────────────────────┘
```

### 3.2 关键交互

- **每个 event 行有 ▶** → 点击立即试听当前 pack 里这个 category 的声音
- **▶ 旁边小字** → 显示会播放哪个文件（便于 debug 变体）
- **Import 支持拖拽** → 直接拖 .cipack 或 .zip 进窗口任何位置
- **[Open Sound Pack Folder]** → 方便制作者调试自己的 pack

---

## 4. 视觉联动（"像素伙伴" / 电子鸡效应）

这是 coder-island 真正超越 Vibe Island 的机会。Vibe Island 有音效但视觉联动弱。

### 4.1 联动矩阵

| Category | 声音 | Notch 视觉效果 | 时长 |
|---|---|---|---|
| sessionStart | 轻快上扬 3 音 | 🌱 小苗从 notch 长出一次 | 800ms |
| taskComplete | "Ding!" 单音 | ✨ 星星从 notch 飘出 3 颗 | 1200ms |
| taskError | 低沉嗡鸣 | 💥 notch 短促晃动 + 红色闪 | 400ms |
| inputRequired | 询问感小音 | 👀 像素眼睛从 notch 探出，眨眼 | 持续直到用户响应 |
| taskAcknowledge | 微弱 "tick" | 默默脉冲一下 | 200ms |
| userSpam | 被吓到的尖叫 | 😵 notch 表情变乱 | 1500ms |
| resourceLimit | 警告音 | 🔥 notch 边缘红色流光 | 一直闪直到 compact 完 |
| appStarted | 开机音 | 像素角色睡醒动画 | 2000ms |
| remoteConnected | 远距离信号接通音 | 🌐 notch 上出现小地球转一圈 | 1500ms |

### 4.2 核心理念

- **声音 + 视觉绑定在同一个事件上**，单独听或单独看都不够，合起来产生"有生命感"
- **表情变化**：notch 不只是状态指示，是**有情绪的像素生物**。完成时开心、错误时难过、等待时好奇
- **可被用户训练**：和 Tamagotchi 一样，长期使用可"养熟"（比如连续 100 次任务完成解锁新动画）
- **一周新鲜感**：每次 taskComplete 从 3-5 个细微不同的动画里随机挑，避免审美疲劳

### 4.3 实现层

- `SoundManager.play()` 同时发出 `NotificationCenter` 事件（`CoderIslandSoundPlayed`）
- `NotchView` 监听并映射到视觉动画
- 视觉资源也 pack 化（可以 v2 再做）：`.cipack` 里加 `visuals/` 子目录

---

## 5. 里程碑拆解

### M1：SoundManager 重构为 AVAudioEngine（1 周）
- 保持现有 4 个 event 与 2 个 preset 的行为不变
- 底层换成 AVAudioPlayerNode + mixer
- 加 master volume slider
- **产出**：功能不变但底座换好

### M2：Pack 格式定义 + 加载器（1 周）
- 定义 `manifest.json` schema
- 实现 `.cipack` 目录/zip 加载
- 把现有 mario/system 声音**重新打包为 built-in cipack**
- Settings UI 加 "Import Sound Pack"
- **产出**：用户可以装卸 pack

### M3：Category 扩展（1 周）
- Event 枚举扩展为 9 个 category（对齐 Vibe Island + `remoteConnected`）
- 映射到现有 hook events
- Settings UI 按 4 个 section 分组
- **产出**：覆盖面超越 Vibe Island

### M4：版权合规的默认 pack（2 周，并行）
- 委托/自制 8 类音效，每类 3-5 个变体
- 至少两套风格：Retro（8-bit 像素风）+ Minimal（极简点击）
- **产出**：可公开发布、无侵权风险

### M5：播放策略（0.5 周）
- Per-category cooldown + priority table
- 深夜模式 + 焦点感知
- **产出**：多 agent 并发时不吵、不漏

### M6：视觉联动（2-3 周）
- Notch 表情系统（像素角色基础动画集）
- 声音 ↔ 视觉动画绑定
- 随机 variant 机制避免审美疲劳
- **产出**：差异化杀手锏

### M7：Pack 分发生态（视情况）
- 官网 `/packs` 目录展示社区 pack
- 一键安装（`coder-island://install?url=...`）
- Pack 制作指南 + 模板
- **产出**：形成社区传播闭环

**总计**：M1-M5 约 **5.5 周**（必做），M6-M7 约 **4-5 周**（差异化）。

---

## 6. 决策待定

1. **pack 后缀名**：`.cipack`、`.coderislandpack`、`.csp`（Coder Sound Pack）？影响到文件图标设计、系统注册 UTI
2. **默认 pack 风格数量**：1 套（极致打磨）还是 2 套（选择权）？1 套风险是 "太少不够玩"，2 套成本翻倍
3. **视觉联动是 v1 做还是 v2 做**：v1 做的话 onboarding 就有更强的"哇"时刻；v2 做的话 v1 可以早 3 周上线
4. **音效师预算**：自制 vs 外包 vs 全用 CC0 素材库拼。**推荐外包**，独家感强，但要 2000-5000 元
5. **Pack 是否分付费/免费**：v1 全免费建立口碑，v2 可考虑 premium pack（比如 Studio Ghibli 风格、中国风像素等，与特定艺术家合作分成）
6. **是否引入用户录制**：让用户自己录一段 3 秒声音做个人化音效。有趣但复杂

---

## 7. 与 Vibe Island 的差异化总结

| 维度 | Vibe Island | Coder Island（本设计） |
|---|---|---|
| 底层 | AVAudioEngine | 同 |
| Pack 格式 | `.cesp`（闭源） | `.cipack`（开源 schema + 文档） |
| Category 数 | 7 | 9（加 `appStarted` 和 `remoteConnected`） |
| Section 分组 | 4 个 | 同 |
| 多变体播放 | 未知 | **明确支持 + 权重** |
| 深夜 / 焦点模式 | 未知 | **明确支持** |
| 视觉联动 | 弱 | **核心差异化** |
| Pack 分发生态 | 未知 | **官网 packs 目录 + 一键装** |
| 版权 | 不清楚 | **明确声明每个 pack 的 license** |
| 用户录音 | 未知 | 备选方案 |

---

## 8. 参考

- Vibe Island `SoundPack*` 类与 `sound.cat.*` / `sound.desc.*` 字符串
- 现有实现：[CoderIsland/Audio/SoundManager.swift](CoderIsland/Audio/SoundManager.swift)
- 相关文档：`docs/onboarding-design.md`（onboarding 的声音部分）、`docs/ssh-remote-design.md`（remote connected 事件）
- Claude Code hooks 事件清单：[`docs/hook-events-todo.md`](docs/hook-events-todo.md)
