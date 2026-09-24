# ly 补丁说明（app 驱动 + 逆向工具链）

在原有 `ly minis` 之上追加的能力。全部为新增，未删除任何上游功能。

## 新增工具（3 个，agent 可直接调用）

| 工具 | 作用 |
|---|---|
| `app_control` | 枚举 / 查询 / **启动**已安装的 iOS App（bundle id、URL scheme、显示名三种方式） |
| `ui_automation` | **闭环驱动别的 App**：全屏截图 → 视觉模型决策 → 注入真实触控，循环到目标达成 |
| `subagent` | 子 Agent 委派：独立上下文 + 工具白名单，只回最终报告，中间输出不污染主对话 |

## 新增原生 CLI（rootfs 内，shell 可直接调用）

```
apple-apps    list / info / schemes / open / frontmost
apple-hid     probe / size / tap / swipe / long / type / paste / key / screenshot
ly-recon      macho / elf / apk / entropy / xor / carve / strings / hex / info / install / status
```

- `apple-hid` 走 IOHIDEventSystemClient 合成触摸 —— 系统当**真实手指**，可以操作别的 App。
  私有符号全部 `dlsym` 动态解析，不在链接期依赖私有 framework。
- `apple-hid screenshot` 走 CARenderServerRenderDisplay，能拍到**整个屏幕**（含别的 App）。
- `ly-recon` 通过 `default_mount/` 每次启动叠加进 Alpine rootfs，一次 `install` 后工具持久保留。

## 安全设计（不可绕过）

`ui_automation` 内置**支付黑名单硬闸门**：模型要点击的控件文案命中
`支付 / 付款 / 提交订单 / 立即购买 / 确认下单 / 开通 / 续费 / 转账 / pay / checkout / subscribe …`
时，**立即停止**，把截图和控制权交回用户。走到最终确认页也会主动停下。

## 必须的配套改动

### 1. 强化 entitlements（`signing/TrollStore-entitlements.plist`）

新增 **`platform-application`** —— 这是下面那些 `com.apple.private.*` 真正被 AMFI 放行的前提，
原先的清单里**没有它**，所以私有权限即使写了也可能被静默忽略。

新增：
- `com.apple.private.hid.client.event-dispatch` / `.event-filter` → 触控与键盘注入
- `com.apple.private.iosurface` / `com.apple.private.coregraphics` → 全屏截图
- `com.apple.private.mobileinstall.allowedSPI` → 枚举已装 App

### 2. CI 增加签名步骤（`codemagic.yaml`）

原先流水线用 `CODE_SIGNING_ALLOWED=NO` 归档，**产物里一个 entitlement 都没有**。
新增 `Sign with TrollStore entitlements` + `Verify embedded entitlements` 两步，
并用 `codesign -d --entitlements` 逐条断言权限确实嵌进去了。

顺带把依赖构建从 `|| echo WARN` 改成**硬失败 + 校验产物** ——
iSH 挂了却继续构建，最后只会在链接阶段抛出一堆看不懂的报错。

### 3. 构建配置可切换（`project.pbxproj`）

`NO_ISH=1` 的 bisect 状态被改成三个可覆盖变量：
`LY_ISH_LDFLAGS` / `LY_C_DEFINES` / `LY_SWIFT_EXTRA`，默认值 = **iSH 启用**。

> ⚠️ `NO_ISH=1` 这条路是**走不通的**：`native_offload.h` 来自 iSH 静态库，
> 所有 `*Offload.m` 都 include 它并调用 `native_offload_add_handler`。
> 不链接 iSH → 头文件不存在 + 全部未定义符号。要真的关掉 iSH，
> 得把二十多个 offload 文件一起桩掉，那就等于放弃 shell —— 本项目的全部能力都建立在 shell 之上。

## 装机后自检（30 秒）

```bash
apple-hid probe          # 期望 touch_injection: true
apple-apps list --user-only --limit 20
apple-hid screenshot /var/minis/attachments/probe.png
ly-recon status
```

`apple-hid probe` 返回的 `reason` 字段会直接指出是哪一层被拒。

## 已知未验证

- 本补丁**未经编译**（编写环境无 Xcode）。请以 CI 结果为准。
- 触控注入的坐标语义与事件掩码位需要真机 `probe` 才能最终确认。
