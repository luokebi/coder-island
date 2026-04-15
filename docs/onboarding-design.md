# Onboarding 设计文档

> **状态**：Draft v0  
> **作者**：luo + Claude  
> **日期**：2026-04-15  
> **背景**：Vibe Island v26.3.1 onboarding 实机走查 + 代码反向（UserDefaults key `hasCompletedOnboarding`, `onboardingVersion=3`）

---

## 0. 为什么要重做

当前 coder-island 没有 onboarding —— 启动即弹 macOS Accessibility 系统弹窗，用户经常：
- 不知道应用能做什么 → 随手关掉
- 不理解要什么权限 → Deny
- 不知道 hooks 要手动开 → 以为坏了

Vibe Island 的 onboarding 是报告里**被用户单独点名最多的东西**（"world class"、"top notch"、"most fun"）。核心不是告诉用户"要做什么"，而是让用户**爱上这个产品**。

---

## 1. Vibe Island 的 onboarding 完整流程（9 屏）

### 屏 1: Welcome Card（全屏仪式）

**视觉**：
- 桌面背景被**暗化 + 模糊**（"ceremony" 模态处理，非弹窗）
- 居中显示一个**像素风格的 notch 形状**，中央写 app 名
- app 名用**像素字体 + glitch/matrix 动画**逐字定格（截到 "Vibe Fslan5" → "Vibe Island" 过渡）
- notch 边缘有**粉紫渐变光晕**旋转动画（代码 symbol：`_onboardingGlowRotation`, `_onboardingGlowIntensity`）
- notch 下方一行 tagline："A Dynamic Island for your AI coding tools"
- 底部一个 **Get Started** 按钮 + 6 个分页圆点

**实现信号**：`OnboardingFullscreenWindow` + `_onboardingCornerBounce` + `onboarding-ceremony`

**为什么 work**：用户第一眼看到的不是表单、不是"欢迎"，而是产品的"灵魂"—— 像素美学 + notch 这个核心意象。0.3 秒的 glitch 动画给产品立刻"有手工感"。

### 屏 2-5: 4 个 Demo（自动轮播，每屏约 3 秒）

**Demo 1/4**: "All your AI agents, one Dynamic Island"
- Notch 里模拟出现**多个 AI agent 的 icon 列**（Claude/Codex/Gemini/...）
- 字幕：价值主张

**Demo 2/4**（推测，没抓到）: Permission 审批
- Notch 弹出 Allow/Deny 按钮演示
- 字幕：**"Approve without switching."** / **"One of them has been waiting for you."**（情感化）

**Demo 3/4**（推测，没抓到）: Context switching 痛点
- 字幕：**"That's 15 hours a week."** / **"Context switches"**
- 把用户的时间浪费量化出来 —— 制造付费动机

**Demo 4/4**: Jump-back（**交互式**）
- Notch 显示已完成的 Claude Code 任务（"webapp - add dark mode"，带真实的进度条、file tree、token count）
- 字幕："Click to jump back."
- **诱导用户点击 notch**
- 点击后：展开一个**模拟的 Claude Code 终端窗口**（完全 UI 仿真，显示 cwd、版本、model、Read/Edit 动作序列）
- 字幕："Land in the exact window, tab, or split — across 13+ terminals and IDEs."
- 底部小字预告："Vibe Island needs Accessibility to jump to the right window. Choose 'Allow' once macOS requests permission."
- Next 按钮

**为什么 work**：
1. 前 3 个 demo 是**视觉+口号组合拳**（3 秒单位 × 情感化文案 + 时长数据）
2. 第 4 个 demo 是**交互式**（诱导点击），用户"做了一次"就记住了
3. **权限请求预告**在演示时就出现 —— 用户理解 "为什么要这个权限"

### 屏 6: All Set（检测反馈）

**标题**：**"All Set"** + 副标题 **"Vibe Island automatically detected and configured your tools."**

**内容**：
- **AI AGENTS 区**：列出所有检测到的 CLI（Claude Code / Codex / Gemini CLI / Droid / Qoder / Copilot / Cursor Agent / OpenCode），每个有绿色 ✓ 和 **toggle**
- **TERMINALS 区**：列出检测到的终端（iTerm2 / Ghostty / Terminal.app / VS Code），用 **tag pill 形式**（不可 toggle，只是确认"看到了"）
- Next 按钮

**为什么 work**：
- 把"我装了什么你懂不懂"这个焦虑一把消除
- AI 用 toggle（**用户能控制**），Terminal 用 pill（**识别即可**）—— UX 区分体现了思考深度
- "Automatically detected and configured" 是**主动承诺 + 过去完成时** —— 心理学上把"配置"这个待办任务关闭了

### 屏 7: Paywall

**标题**：**"Ready to land?"**（延续岛 → 降落的 wordplay，从头到尾保持 tone）

**内容**：
- 副标题：**"One-time purchase · no subscriptions"** —— 反订阅立场
- 3 个价值点（复述前面 demo 的 claim）：
  - ✓ Never miss a permission request again
  - ✓ Jump to any terminal in one click
  - ✓ All your agents, one Notch
- **主 CTA**：**"Start 2-Day Free Trial"** ⭐（白色大按钮）
- **次 CTA**：**"Get Early Bird Price — $14.99"**（暗色按钮）
- **tertiary**：**"Already have a license key?"** 文字链接 → 点击**内联展开** `Paste license key` 输入框 + Activate 按钮

**关键设计**：
- **Trial 置顶**：降低承诺成本（不是 "buy now"，而是 "试一下"）
- **Early Bird** 制造稀缺感（即使不是真的稀缺）
- License 输入**原地展开**（不是模态切换）—— 避免"找不到入口"的老用户焦虑
- **强调 no subscriptions** —— 对独立开发者友好，也是报告里用户反复认可的点

### 屏 8: Post-checkout（付费后或 trial 后）

推测内容（从 strings 推）：
- `onboarding.checkEmail`: "Check your email for the license key"
- `onboarding.reopenCheckout`: "Re-open checkout"
- `onboarding.startTrialInstead`: "Start trial instead"（付费失败回退）

### 屏 9: Ready（最后一步）

从 strings `onboarding.readyRestartHint`: **"Restart any running sessions, or start a new one."**  
以及 `onboarding.startVibing`: **"Start Vibing"**

**为什么需要这一屏**：hooks 只对**新启动的 session** 生效。不告诉用户这点，他们会以为坏了。这是个**必须说的技术真相**，但放到最后一屏不破坏前面的节奏。

---

## 2. 架构拆解（三种窗口类型）

从 binary strings 找到 3 个 SwiftUI WindowController 类：

| 类 | 用途 | 对应屏 |
|---|---|---|
| `OnboardingFullscreenWindow` | 全屏 ceremony，背景暗化 | 屏 1, 2-5 |
| `OnboardingCardWindow` | 居中 card 模态 | 屏 6, 7, 8 |
| `OnboardingReadyWindow` | 最后的 restart 提示 | 屏 9 |

还有一个辅助类 `OnboardingDemoRunner` —— 负责驱动 demo-onboarding-001/002/003/004 这 4 个脚本化 session。

**设计分离**：ceremony（全屏）和配置（card）使用不同的窗口类，避免一个窗口承载所有状态。

---

## 3. 提炼出的 5 条 UX 原则

### 原则 1：Ceremony 不是 onboarding，是产品宣言
前两屏不解释任何功能，只传达**产品有灵魂**。像素美学 + glitch 动画 + 发光 notch，0 信息密度但 100% 记忆点。

### 原则 2：Demo > Tutorial
**不告诉用户怎么用，演示给他们看**。4 个 demo 自动播放 + 1 个诱导交互，比 10 页 tooltip 有效 10 倍。

### 原则 3：权限请求要预告
在 demo 播放时就告诉用户"**一会儿** macOS 会弹 Accessibility，点 Allow"。用户**被动接受** → **主动预期** → **确认按钮**。权限授予率会高很多。

### 原则 4：检测反馈要强调"我看见你了"
"All Set" 屏本质是**技术性动作**（遍历 `~/.claude` 之类的目录），但包装成**"我已经帮你搞定了"**。用户感到**被看见 + 被照顾**。

### 原则 5：Paywall 前置所有价值证明
Paywall 不在第一屏，也不在最后屏，**在用户已经看到所有好处之后**。此时"值不值"不是抽象判断，是具体回忆。

---

## 4. 对 coder-island 的具体建议

### 4.1 保留什么（抄架构，不抄美术）

| 抄 | 为什么抄 |
|---|---|
| 3 个窗口类的分离（Fullscreen/Card/Ready） | 避免单窗口状态机膨胀 |
| 自动 demo 轮播 + 最后一个交互式 | demo > tutorial 原则 |
| All Set 检测反馈屏（AI agents toggle + Terminal pills） | 消除"装了什么"焦虑 |
| Paywall 的三层按钮（Trial/Purchase/License）+ License 内联展开 | 给用户最大回旋空间 |
| Ready 屏提示 restart session | 技术真相必须说 |

### 4.2 差异化什么（不要 1:1 模仿）

| coder-island 差异化 | 原因 |
|---|---|
| **美术风格要自己的** | 像素风是 Vibe Island 的识别符号，照抄会被归为 "又一座岛" 的仿品。coder-island 需要一个**同等有记忆点但不同**的美学方向（待定） |
| **加一个"你可以跳过"出口** | Vibe Island 第一屏没有 Skip（我们看到第 4 demo 才有 Skip 小字）。技术用户喜欢跳过，可以前置 |
| **检测到用户运行中的 session** 并在 demo 里用**真实数据** | Vibe Island 的 demo 是硬编码的"webapp/add dark mode"。coder-island 可以检测 `~/.claude/sessions/` 最近的一条真实 session，用它做 demo 素材 —— 用户会感觉"这是我的东西" |
| **权限请求要有 fallback UI** | 如果用户第一次点 Deny，Vibe Island 似乎没有补救。coder-island 应该做一个"为什么需要这个权限 + 再次授权"的页面 |
| **Onboarding 后有"玩一下"环节** | Ready 屏可以不是终点，而是引导用户**立刻开一个测试 session**，播放那个 8-bit 音效 —— 形成"我已经在用了"的完成感 |

### 4.3 时间线估算

- M1：架构 + 骨架（1 周）—— 3 个 window class、状态机、跳过/返回逻辑
- M2：美术（1-2 周，并行）—— 与设计师合作确定视觉方向
- M3：Ceremony + Demo 屏（2 周）—— glitch 文字动画、发光效果、demo 脚本
- M4：检测反馈 + 权限预告 + Ready（1 周）
- M5：Paywall 集成（1 周，如需集成 Stripe/Paddle）
- M6："玩一下"环节 + 8-bit 音效联动（0.5 周）
- M7：打磨 + 文案迭代（1 周）

**总计**：约 6-8 周。

---

## 5. 开发决策待定

1. **美术方向**：像素 / 手绘 / 极简文字 / 3D 立体？这是最重要的决策，需要设计师入场
2. **Demo 数量**：4 个（Vibe Island 数）还是 3 个？再少会不会削弱冲击？
3. **权限预告时机**：在 demo 播放时（Vibe Island）还是单独一屏专门讲？
4. **Paywall 出现时机**：第一次 onboarding 就出（Vibe Island）还是推迟到用了 N 天后？
5. **是否做 B/A 测试框架**：onboarding 文案和视觉影响转化率巨大，要不要一开始就插桩
6. **多语言覆盖**：Vibe Island 有 en/zh-Hans/ja/ko 四种。coder-island v1 覆盖哪些？

---

## 6. 文案参考（Vibe Island 原文，用作 tone 对标）

| 维度 | 示例 |
|---|---|
| 价值主张 | "A Dynamic Island for your AI coding tools" / "All your AI agents, one Dynamic Island." |
| 痛点数据化 | "That's 15 hours a week." / "Context switches" |
| 情感化 | "One of them has been waiting for you." / "Everything. One glance." |
| 功能点 | "Approve without switching." / "Jump to the exact tab." / "Click to jump to the right window" |
| 检测反馈 | "Everything's configured. No action needed." / "You have 4 agents running." |
| Paywall | "Ready to land?" / "One-time purchase · no subscriptions" |
| 权限说明 | "Vibe Island needs Accessibility to jump to the right window. Choose 'Allow' once macOS requests permission." |
| Ready | "Restart any running sessions, or start a new one." / "Start Vibing" |

**tone 总结**：短句 / 小标题格式 / 有 wordplay（island → land, vibing）/ 数据化痛点 / 情感化动词。

coder-island 的 tone 要自己定 —— 可能更**工程师化**（克制、技术准确）、或者更**polish** —— 但必须**保持一致**。

---

## 7. 参考
- Vibe Island `OnboardingWindowController` 类相关 strings
- 本仓库 SSH 设计文档：`docs/ssh-remote-design.md`
- 现有主 app 入口：`CoderIsland/AppDelegate.swift` —— 当前 onboarding 空缺位置
