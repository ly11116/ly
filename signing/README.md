# TrollStore 强化签名包

给 ly minis (OpenMinis 1.12 iOS16 fork) 增加纯 TrollStore 环境下的能力上限。

## 文件

```text
TrollStore-entitlements.plist  强化权限声明
sign-trollstore.sh             签名流水线
```

## 用法 (macOS)

```sh
sh signing/sign-trollstore.sh build/Minis112-unsigned.ipa
# 输出: build/Minis112-unsigned-trollstore.ipa
```

用 TrollStore 安装输出 IPA。

## 权限分级说明

### 应当生效

| entitlement | 用途 |
|---|---|
| allow-jit / unsigned-executable-memory / disable-library-validation | iSH JIT、动态分析、加载未签名库 |
| get-task-allow / task_for_pid-allow | frida/LLDB 挂 TrollStore 自装的 App |
| files/assets read-write | 更宽的文件访问 |
| dyld 环境变量 | DYLD_* 调试 |

### 不保证（iOS 16 stock 限制）

| entitlement | 现实 |
|---|---|
| no-sandbox / no-container | 部分缓解，非完整越沙箱 |
| networkextension/vpn-api | NE 需要系统 profile 批准，可能拒；不行就退回 SOCKS5 镜像 |
| task_for_pid-allow | 只对 debuggable(自装)进程有效，App Store App 依旧拒绝 |

### 永远不可能（不用试）

```text
进 App Store App 进程内存
root daemon / 系统 hook
修改系统配置
```

## 能力矩阵（纯 TrollStore 设备）

```text
✅ iSH 静态逆向全链(r2/capstone/angr/binwalk/密码分析)
✅ frida 插桩 TrollStore 自装 App
✅ 本机流量镜像(隧道/代理层面)
❌ App Store App 动态插桩 —— 需越狱设备
```

## 审计

签名后验证：

```sh
codesign -d --entitlements :- Payload/Minis.app
```
