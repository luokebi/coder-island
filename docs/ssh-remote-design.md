# SSH Remote 技术设计文档

> **状态**：Draft v0  
> **作者**：luo + Claude  
> **日期**：2026-04-15  
> **背景**：基于 Vibe Island v26.3.1 逆向调研（详见 `~/Documents/job/vibe_island_feedback_report.md`）。本设计**抄其架构骨架 + 在三个点上做得更深**。

---

## 0. 目标与非目标

### 目标
- 让 coder-island 能监控远端 Linux/macOS/FreeBSD 主机上的 Claude Code / Codex / Gemini / Cursor / Factory / Qoder 等 CLI 会话
- 支持 SSH 主流认证路径（pubkey, ssh-agent, ProxyJump, ControlMaster）
- 企业受限网络（只能 outbound HTTPS，不能 inbound SSH）也能用
- 远端配置变更对用户**完全透明可审计**（有 diff、有备份、有一键回滚）

### 非目标（v1 不做）
- Windows 远端支持
- Kubernetes pod / Docker exec（放 v2）
- 远端会话的 **跳转**（点击 notch 里远端任务直接跳到远端的 tmux pane）—— v1 只做监控与审批
- 多用户/共享（单用户单 Mac）

---

## 1. 架构总览

```
┌────────────── Mac (coder-island) ──────────────┐        ┌────── Remote host ──────┐
│                                                │        │                         │
│  ┌──────────────────────────────────────────┐  │        │  ~/.claude/settings.json│
│  │             Coder Island.app             │  │        │  ~/.codex/hooks.json    │
│  │                                          │  │        │  ~/.gemini/settings.json│
│  │  SocketServer    TCPServer   SSHManager  │  │        │  ~/.cursor/hooks.json   │
│  │       │              │            │      │  │        │  ~/.factory/settings.json│
│  │       │              │            │      │  │        │  ~/.qoder/settings.json │
│  └───────┼──────────────┼────────────┼──────┘  │        │          │              │
│          │              │            │         │        │          │              │
│   UDS    │          TCP │       fork │         │        │          ↓              │
│   local  │       17891  │    /usr/bin│         │  SSH   │  ~/.coder-island/hook   │
│   hook   │       listen │    /ssh,scp│─────────┼────────┼──>  (Go static binary)   │
│          │              │            │  pubkey │        │          │              │
│          │              │            │  agent  │        │          │ $PORT/$SOCK  │
│          │              │            │ ProxyJ  │        │          ↓              │
│          │              │            │         │        │   reverse tunnel →      │
│          │              │            │←────────┼────────┼──  localhost:$PORT      │
│          │              │            │         │        │                         │
│  ┌───────┴──────────────┴────────────┴──────┐  │        │  OR (Manual mode)       │
│  │        HookEventRouter + AgentStore       │  │        │  https:// reach home    │
│  └───────────────────────────────────────────┘  │       │                         │
└────────────────────────────────────────────────┘        └─────────────────────────┘
```

### 1.1 三条数据通道

| 通道 | 传输层 | 使用场景 | 鉴权 |
|---|---|---|---|
| **A. Local UDS** | `~/.coder-island/hook.sock` | 本地 CLI hooks | 文件系统 user-only 权限 |
| **B. Remote TCP via reverse SSH** | Mac `127.0.0.1:17891` ← `ssh -R`| 标准 SSH 远端 | SSH pubkey / agent / ControlMaster |
| **C. Manual HTTPS**（差异化） | Mac 上 ngrok-like `https://…` | 受限网络 / 容器 / 堡垒机外网 | Pre-shared token + TLS |

**A 已实现**。B 是抄 Vibe Island。C 是 coder-island 的差异化杀手锏。

### 1.2 文件布局（Mac 端）

```
~/.coder-island/
  ├── run/
  │   ├── hook.sock               # 已有：本地 CLI hook 入口
  │   └── tunnels/                # 新增：每个 host 一个 ssh 子进程
  │       └── <host-id>.pid
  ├── hosts.json                  # 新增：SSH Remote 配置（加密存储敏感字段）
  ├── hosts/<host-id>/
  │   ├── backups/                # 远端配置修改前的备份（时间戳命名）
  │   ├── last-probe.json         # 上次探针结果（OS/arch/CLI 列表）
  │   └── tunnel.log              # 最近 1MB 隧道日志
  └── certs/                      # Manual mode 用的自签 CA / token
      ├── ca.pem
      └── tokens.json
```

### 1.3 文件布局（远端）

```
~/.coder-island/
  ├── hook                        # Go 静态二进制（平台对应版本）
  └── token                       # Manual mode 的 bearer token（chmod 600）
```

**决策**：二进制固定放在 `~/.coder-island/hook`，不放 `/usr/local/bin` —— 不需要 sudo，也方便卸载干净。

---

## 2. 远端 helper binary

### 2.1 规格

- 语言：Go（静态编译，CGO_ENABLED=0）
- 体积目标：<3MB
- 6 个构建目标：`{linux,darwin,freebsd}-{amd64,arm64}`
- 命名：`coder-island-hook-<os>-<arch>`，bundle 打包在 `Coder Island.app/Contents/Resources/Hooks/`

### 2.2 运行模式

```bash
# Mode 1: hook event 转发（被 CLI 作为 hook 命令调用）
coder-island-hook event <event-name>    # 从 stdin 读 JSON，转到 $CODER_ISLAND_PORT 或 $CODER_ISLAND_SOCKET

# Mode 2: 自检（Set Up 最后一步用）
coder-island-hook diag

# Mode 3: 配置写入辅助（避免 base64 shell 绕行）
coder-island-hook install-config --cli claude --json <file>
coder-island-hook uninstall-config --cli claude
```

### 2.3 环境变量

| 变量 | 含义 | 优先级 |
|---|---|---|
| `CODER_ISLAND_PORT` | TCP 端口（反向隧道场景） | 高 |
| `CODER_ISLAND_SOCKET` | Unix socket（同机调试用） | 高 |
| `CODER_ISLAND_URL` | HTTPS URL（Manual mode） | 高 |
| `CODER_ISLAND_TOKEN` | Bearer token（Manual mode 必需） | - |
| `CODER_ISLAND_SKIP` | 设为 1 临时跳过（不阻塞 CLI） | - |

**三选一**。Set Up 脚本根据通道选择写入对应的 env 到 CLI 配置。

### 2.4 协议（Mac ↔ Remote）

沿用现有 UDS 协议：`<ACTION>\n<JSON payload>`，ACTION 为 `event` / `permission` / `ask`。远端多加一个前缀字段：

```
event\n{"host":"prod-1","event_name":"PreToolUse","session_id":"...", ...}
```

Mac 侧 `TCPServer` 从 socket 的 `accept` 时的 fd 映射到具体的 host（通过隧道 peer 端口），host 字段可用于校验。

---

## 3. Set Up 流程（标准 SSH 模式）

### 3.1 状态机

```
[Added] ──Set Up Now──> [Probing]
                          │
               probe ok   │   probe fail
          ┌───────────────┼─────────────────┐
          ↓                                 ↓
      [Uploading]                       [Failed:probe]
          │                                 │
          ↓                                 │  (用户看到友好解释+建议)
      [Configuring]                         │
          │                                 │
     ok   │   fail (部分 CLI 失败仍推进)     │
          ↓                                 │
      [Ready]                               │
          │                                 │
          └─Connect─> [Tunneling] ─────────→ (运行态)
                          │
                          │ 断线
                          ↓
                      [Reconnecting]（指数退避，上限 30s）
```

### 3.2 各阶段具体命令

**Probe**（一条 ssh 命令完成所有检测）：
```bash
ssh <opts> <host> /bin/sh -c '
  echo "<<<CI:header>>>"
  echo "OS=$(uname -s)"
  echo "ARCH=$(uname -m)"
  echo "SHELL=$SHELL"
  echo "HOME=$HOME"
  echo "<<<CI:clis>>>"
  for d in .claude .codex .gemini .cursor .factory .qoder; do
    name=${d#.}
    # 同时检测配置目录和 CLI 可执行
    if test -d "$HOME/$d"; then echo "$name=dir"; fi
    if command -v "$name" >/dev/null 2>&1; then echo "$name=bin"; fi
  done
  echo "<<<CI:env>>>"
  echo "SELINUX=$(test -f /sys/fs/selinux/enforce && cat /sys/fs/selinux/enforce 2>/dev/null || echo 0)"
  echo "NOEXEC_HOME=$(mount 2>/dev/null | grep " $HOME " | grep -o noexec || echo 0)"
  echo "<<<CI:end>>>"
'
```
关键差异：检测 SELinux + noexec（Vibe Island 里报错 "SELinux/noexec?" 但没主动检测，是事后解释）。

**Upload**：
```bash
scp <opts> <local_binary> <host>:~/.coder-island/hook
ssh <opts> <host> 'chmod +x ~/.coder-island/hook && ~/.coder-island/hook diag'
```

**Configure**（调用远端 helper 避免 shell 转义）：
```bash
# 先备份
ssh <opts> <host> '~/.coder-island/hook backup-configs --dest ~/.coder-island/backups/$(date +%s)'
# 再写入每个 CLI（并行）
cat local-claude-settings.json | ssh <opts> <host> '~/.coder-island/hook install-config --cli claude --stdin'
# ... 对 codex / gemini / cursor / factory / qoder 同样
```

**Tunnel**：
```bash
ssh <opts> -N -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 127.0.0.1:0:127.0.0.1:17891 \  # 动态分配远端端口，避免冲突
  <host>
```
> 用 `-R 127.0.0.1:0:...` 让 sshd 自选空闲端口，从 stderr 解析实际端口号 `Allocated port XXXXX for remote forward`，写入该 host 的 env（`CODER_ISLAND_PORT`）。这是 Vibe Island 看起来没做的（它写死 17891）。

### 3.3 SSH 通用 opts（三次 ssh 调用共用）

```
-o BatchMode=yes
-o StrictHostKeyChecking=accept-new
-o ConnectTimeout=5           # probe 用
-o ConnectTimeout=10          # upload/configure 用
-o UserKnownHostsFile=~/.coder-island/known_hosts  # 隔离应用的 known_hosts，不污染用户的
-o ControlMaster=auto
-o ControlPath=~/.coder-island/ctl-%r@%h:%p
-o ControlPersist=10m         # 三次调用复用同一 SSH 会话，MFA 只过一次
```

**与 Vibe Island 的差异**：
- 隔离的 `known_hosts`：不污染用户 `~/.ssh/known_hosts`
- 默认 ControlMaster：即使用户不配置，也能自动共享会话（MFA 场景无感）
- 动态远端端口：避免与用户既有服务冲突

---

## 4. Manual 模式（HTTPS 方案，差异化核心）

### 4.1 使用场景

- 企业网限制，远端不能建立到 Mac 的反向 TCP
- 远端在 K8s pod / Docker 容器内（没有 sshd）
- 用户用 Tailscale / 堡垒机，SSH 链路太复杂
- 临时调试：只想在某台服务器跑一次性的 Claude Code，不想留久效配置

### 4.2 架构

Mac 端起一个**本地 HTTPS 服务**：
- 监听 `127.0.0.1:<random>`（不对外）
- 通过 `ngrok` / `Cloudflare Tunnel` / 内置 quic-go 隧道暴露为公网 `https://<subdomain>.coder-island.app`
- 或：用户自提供域名 + 自己的反代（Nginx / Caddy）

远端 helper binary 改用 HTTPS 长轮询 / WebSocket 上报事件：
```bash
CODER_ISLAND_URL=https://xxx.coder-island.app \
CODER_ISLAND_TOKEN=<bearer> \
coder-island-hook event PreToolUse < stdin-json
```

### 4.3 用户 Set Up 流程

```
[Add Host → 选 Manual → 生成一段 curl 命令]

    ┌──────────────────────────────────────────────────┐
    │  在远端粘贴以下命令：                              │
    │                                                   │
    │  curl -fsSL https://coder-island.app/install.sh \│
    │    | CI_TOKEN=xyz123 CI_URL=https://... sh        │
    │                                                   │
    │  [复制到剪贴板] [等待远端连接...]                  │
    └──────────────────────────────────────────────────┘
                    ↓ 远端执行 ↓
    [Status: Connected from 203.0.113.42 · 2 CLIs detected]
```

**关键点**：用户不需要告诉我们远端 IP / SSH key / 任何远端凭据，只需要在远端终端粘贴一行命令。

### 4.4 Token 与信任

- Token 一次性（Single-use）+ 短时效（默认 10 分钟）
- 连接建立后，远端用 token 拿**长期 device cert**（mTLS 客户端证书）
- Mac 端为每个 host 生成独立 CA 签的 cert，可随时吊销

---

## 5. 错误处理与人话化

### 5.1 错误映射表

| SSH stderr 原文 | 用户看到的人话 | 建议动作按钮 |
|---|---|---|
| `connect to host X port Y: Connection refused` | 远端 X:Y 没有 SSH 服务监听。可能是端口错了或 sshd 没开。 | [改端口] [复制 `sudo systemctl start ssh`] |
| `Permission denied (publickey)` | 远端不认识你的 SSH 公钥。 | [查看当前公钥] [复制到剪贴板] |
| `Host key verification failed` | 远端的 SSH 指纹变了（可能是换机/攻击）。 | [查看 diff] [信任新 key] [取消] |
| `ssh_exchange_identification: Connection closed by remote host` | 远端拒绝连接。常见原因：IP 被 fail2ban 拉黑，或 sshd 配置禁止此用户。 | [稍后重试] [改用 Manual 模式] |
| `kex_exchange_identification: read: Connection reset by peer` | 网络波动或远端重启中。 | [重试] |
| `Could not resolve hostname X` | 域名解析失败。 | [ping 测试] |
| `ProxyJump failed` | 跳板机那一跳断了。 | [单独测试跳板机] |
| `Too many authentication failures` | 尝试的 key 太多，sshd 踢掉了连接。 | [指定 -i 单个 key] |
| `Agent admitted failure to sign using the key` | ssh-agent 里的 key 对不上远端。 | [列出 agent key] |

错误码以 `coder-island-ssh-errno: <code>` 前缀输出到日志，便于用户反馈时定位。

### 5.2 诊断工具

Settings → SSH Remote → 每个 host 旁 [Diagnose] 按钮，跑：
1. `ping` / DNS 解析
2. `nc -zv host port`
3. `ssh -vvv` 抓前 20 行
4. 本地 `~/.coder-island/hook.sock` 可读性
5. 17891 端口 bind 状态
6. 如果是 ControlMaster，检查 socket 是否存活

输出一份 markdown 格式的报告，**自动剔除敏感字段**（hostname 变 `<host>`、user 变 `<user>`），一键复制给支持。

---

## 6. 安全与隐私

| 维度 | 决策 |
|---|---|
| 远端二进制哈希 | Mac 端先算 SHA256，上传后远端自检，不匹配拒绝运行 |
| SSH 凭据存储 | **不存**。用户每次用自己的 `~/.ssh/*` 或 agent，coder-island 只记 host/user/options |
| Manual token | Keychain 存储（`kSecClassGenericPassword`），UI 不显示原文 |
| known_hosts | 隔离到 `~/.coder-island/known_hosts`，不污染用户 ssh config |
| 远端配置改动 | 所有写入都有备份 + 一键 restore；卸载时自动恢复到 Set Up 前 |
| 审计日志 | `~/Library/Logs/CoderIsland/ssh-audit.log`，记录所有远端命令（不含 stdin payload） |
| Telemetry | **默认关**，与本地模式一致 |

---

## 7. 与 Vibe Island 的差异化总结

| 维度 | Vibe Island | Coder Island（本设计） |
|---|---|---|
| SSH 实现 | `/usr/bin/ssh` shell out | 同 |
| 远端二进制 | Go 静态，6 平台 | 同 |
| 协议 | TCP 17891 反向隧道 | 同 + **Manual HTTPS** 备选 |
| 远端端口 | 固定 17891 | **动态分配，读取 sshd 输出** |
| known_hosts | 用用户的 | **隔离到 app 目录** |
| ControlMaster | 用户手动配 `-o ControlPath=…` | **默认开启，MFA 无感** |
| 错误呈现 | 直接贴 ssh stderr | **人话化 + 修复建议按钮** |
| 诊断 | 无 | **一键 Diagnose 报告** |
| Manual 模式 | 有但未知如何工作 | **HTTPS 一键安装脚本，一等公民** |
| 配置写入 | 远端 base64 pipe | **远端 helper 子命令，避免 shell 转义** |
| 备份 | `.backup` 单副本 | **时间戳多版本 + UI restore** |
| Tunnel 生命周期 | 需手动 Start | **自动连 + 指数退避重连** |
| 配置热更新 | restart to apply | **大部分字段热更新**（端口需重启是唯一例外） |
| 隧道健康状态 UI | 无可见指标 | **显示延迟、事件计数、最近活跃** |

---

## 8. 里程碑拆解

### M1：协议对齐 + 本地 TCP 通道（1 周）
- 主 app 在 `127.0.0.1:<configurable_port>` 起 TCP listener
- 协议扩展：event payload 加 `host_id` 字段
- Settings 加 "SSH Remote" tab，仅显示 TCP port 配置
- **产出**：可通过 `nc localhost 17891` 手工发 JSON 验证路径通

### M2：远端 helper binary（1-2 周）
- Go 项目 `cmd/coder-island-hook`，6 平台构建
- 实现 `event` / `diag` / `install-config` / `uninstall-config` / `backup-configs`
- 单元测试覆盖协议解析
- **产出**：手动 SCP 到远端 + 手动写 hook 配置 + 手动反向隧道能跑通

### M3：标准 SSH Set Up UI（1-2 周）
- Add Host 对话框（Host / User / Alias / Options）
- 二次确认 → 状态机驱动的 Set Up 过程 UI
- 隔离 known_hosts + ControlMaster 默认开
- 错误人话化前 5 个高频错误
- **产出**：Vibe Island 对等功能

### M4：自动隧道 + 健康状态（1 周）
- 隧道子进程监控 + 指数退避重连
- Host 行显示：状态点 / 延迟 / 最近事件时间戳 / 事件总数
- **产出**：超越 Vibe Island 的运行时体验

### M5：Manual HTTPS 模式（2-3 周）
- 内置 HTTPS server + 证书签发
- 隧道出口：先接 Cloudflare Tunnel（最省事），ngrok 作为备选
- `install.sh` 一键安装脚本托管在 coder-island 官网
- Token 管理 + device cert + revoke UI
- **产出**：差异化核心功能上线

### M6：错误人话化 + Diagnose 工具（1 周）
- 错误映射表全覆盖
- Diagnose 按钮 + 脱敏报告输出
- **产出**：客服压力降低，用户自助率高

总计：约 **7-10 周**。M1-M4 是对等 Vibe Island，M5-M6 是超越项。

---

## 9. 待定问题（需要决策）

1. **Manual 模式的 HTTPS 出口**：先选 Cloudflare Tunnel（免费但依赖 Cloudflare 账号）还是 ngrok（更简单但付费版才能自定义域名）？或者用 [bore](https://github.com/ekzhang/bore) 自己搭？
2. **远端二进制分发**：embedding 在 app bundle 里每个 app 版本更新时都要重新下载（增加包体积约 15MB）；还是在 Set Up 时从 `releases.coder-island.app` 按需下载（用户断网就不能 Set Up）？**倾向：embedding**，简单且对首次体验友好。
3. **多设备 license 场景**：同一个 Mac 连多台远端不限；但远端本身算一个"设备"吗？license 是否要覆盖远端？**倾向：不算**，license 只限 Mac 端数量。
4. **远端跳转是否 v1 做**：报告里 Vibe Island 似乎没解这题。v1 直接不做跳转，点击远端任务只展开详情。v2 再考虑 `ssh + tmux attach` 脚本生成。
5. **远端 session 跨重启保持**：如果用户关掉 Mac app，远端 CLI 事件是否缓存等重连？**倾向：不缓存，丢掉**，Mac 端回来只显示新事件，避免复杂度和存储膨胀。

---

## 10. 参考

- Vibe Island v26.3.1 逆向发现（本仓库外部文档）
- 现有本地 hook 架构：`CoderIsland/HookServer/HookServerSocket.swift`
- SSH hooks 协议：`~/.claude/settings.json` 的 `hooks` 字段（Claude Code 文档）
- ControlMaster：[OpenSSH manual § ControlMaster](https://man.openbsd.org/ssh_config.5#ControlMaster)
