# Build Guide

## 环境要求

- macOS 14.0+
- Xcode 15+ (需要 `xcodebuild` 命令行工具)
- Swift 5.9+

## 1. 创建自签名证书

为了避免每次重新编译后 macOS 重置 Accessibility 权限，需要创建一个稳定的自签名证书：

```bash
# 创建自签名证书（只需执行一次）
cat > /tmp/cert.conf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = codesign

[ dn ]
CN = CoderIsland Dev

[ codesign ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

# 生成证书并导入钥匙串
openssl req -x509 -newkey rsa:2048 -keyout /tmp/ci-key.pem -out /tmp/ci-cert.pem \
  -days 3650 -nodes -config /tmp/cert.conf

openssl pkcs12 -export -out /tmp/ci.p12 -inkey /tmp/ci-key.pem -in /tmp/ci-cert.pem \
  -passout pass:""

security import /tmp/ci.p12 -k ~/Library/Keychains/login.keychain-db \
  -T /usr/bin/codesign -P ""

# 清理临时文件
rm /tmp/cert.conf /tmp/ci-key.pem /tmp/ci-cert.pem /tmp/ci.p12
```

导入后在 **钥匙串访问 → 登录 → 证书** 中找到 `CoderIsland Dev`，双击 → 信任 → 始终信任。

## 2. 编译

```bash
xcodebuild -project CoderIsland.xcodeproj -scheme CoderIsland -configuration Debug \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="CoderIsland Dev" DEVELOPMENT_TEAM="" build
```

编译产物路径：
```
~/Library/Developer/Xcode/DerivedData/CoderIsland-*/Build/Products/Debug/CoderIsland.app
```

## 3. 运行

```bash
open ~/Library/Developer/Xcode/DerivedData/CoderIsland-*/Build/Products/Debug/CoderIsland.app
```

## 4. 授权 Accessibility 权限

首次运行需要授权 Accessibility 权限（用于读取终端窗口标题和模拟键盘切换 Tab）：

1. 打开 **系统设置 → 隐私与安全性 → 辅助功能**
2. 点击 `+`，添加编译产物中的 `CoderIsland.app`
3. 使用自签名证书后，重新编译不需要重复此步骤

或使用辅助脚本：
```bash
./grant-accessibility.sh
```

## 5. 功能依赖

| 功能 | 依赖 |
|------|------|
| 监控 Claude Code | `~/.claude/projects/` 目录下的 JSONL 会话文件 |
| 监控 Codex CLI | `~/.codex/` 目录下的 rollout JSONL 文件 |
| Tab 跳转 (Warp/Ghostty) | Accessibility 权限 + 对应终端应用 |

## 快速编译+运行

```bash
xcodebuild -project CoderIsland.xcodeproj -scheme CoderIsland -configuration Debug \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="CoderIsland Dev" DEVELOPMENT_TEAM="" build \
  && pkill -x CoderIsland; sleep 1 \
  && open ~/Library/Developer/Xcode/DerivedData/CoderIsland-*/Build/Products/Debug/CoderIsland.app
```
