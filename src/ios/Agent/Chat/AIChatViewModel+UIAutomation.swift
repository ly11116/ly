//
//  AIChatViewModel+UIAutomation.swift
//  MinisApp
//
//  ly patch — `ui_automation` 工具：驱动别的 App（截图 → 视觉决策 → 触控注入）
//
//  这是「让它打开美团点外卖」的实现体。闭环：
//     apple-hid screenshot  →  视觉模型看屏 + 输出一个动作 JSON
//        ↑                                        ↓
//        └──────  apple-hid tap/swipe/type  ←──────┘
//    直到模型输出 done / fail，或步数用尽。
//
//  三条硬约束（安全设计，不是可选装饰）：
//   1) 绝不自动确认支付 —— 目标页出现支付类按钮时立即停止并把控制权交回用户。
//   2) 每个动作必须带 label（目标控件上的文字），label 命中支付黑名单直接拒绝执行。
//   3) 步数与单步等待都有硬上限。
//
//  ⚠️ 依赖 apple-hid（TrollStore 私有权限）。启动前会先 probe，不可用则直接报错，
//     不做无意义的循环。
//

import Foundation

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {

    // MARK: - 参数

    struct UIAutomationParams {
        var goal: String = ""
        var app: String?
        var maxSteps: Int = 15
        var secondsPerStep: Double = 2.2
        var model: String?
        var stopBefore: String?      // 额外的"到此为止"关键词
    }

    func parseUIAutomationParams(from json: String) -> UIAutomationParams {
        var p = UIAutomationParams()
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return p }
        p.goal = (o["goal"] as? String) ?? (o["task"] as? String) ?? ""
        p.app = o["app"] as? String
        if let n = (o["max_steps"] as? NSNumber)?.intValue, n > 0 { p.maxSteps = min(n, 40) }
        if let s = (o["seconds_per_step"] as? NSNumber)?.doubleValue, s > 0 {
            p.secondsPerStep = min(s, 8)
        }
        p.model = o["model"] as? String
        p.stopBefore = o["stop_before"] as? String
        return p
    }

    // MARK: - 支付 / 不可逆操作黑名单

    /// 命中即拒绝执行该次点击，并把控制权交回用户。
    /// 覆盖常见支付/下单确认入口，宁可多拦不可漏拦。
    static let uiPaywallKeywords: [String] = [
        "支付", "付款", "去支付", "立即支付", "确认支付", "提交订单", "立即购买", "确认下单",
        "开通", "续费", "购买", "打赏", "转账", "提现", "免密支付", "指纹支付", "面容支付",
        "pay", "payment", "purchase", "buy now", "checkout", "confirm order", "subscribe",
        "transfer", "withdraw", "top up", "recharge",
    ]

    static func uiHitsPaywall(_ label: String) -> Bool {
        let l = label.lowercased()
        guard !l.isEmpty else { return false }
        return uiPaywallKeywords.contains { l.contains($0.lowercased()) }
    }

    // MARK: - 主入口

    func executeUIAutomationTool(from json: String) async -> FileToolResult {
        let p = parseUIAutomationParams(from: json)
        guard !p.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FileToolResult(output: "Error: missing required 'goal'.", success: false)
        }

        // ---- 0) 先探针：没有注入能力就别开始 ----
        let probe = await runNative("apple-hid probe")
        guard probe.exit == 0, Self.probeSaysTouchReady(probe.output) else {
            return FileToolResult(output: """
            apple-hid 不可用，无法驱动其他 App。
            探针输出：\(probe.output.prefix(500))

            需要：TrollStore(巨魔) 安装 + Minis.entitlements 里的
              com.apple.private.hid.client.event-dispatch
            普通签名环境下内核会拒绝该系统调用。
            """, success: false)
        }

        // ---- 1) 需要的话先启动目标 App ----
        var trace: [String] = []
        if let app = p.app, !app.isEmpty {
            let r = await runNative("apple-apps open \(Self.shellQuote(app))")
            trace.append("launch \(app) → exit \(r.exit)")
            if r.exit != 0 {
                return FileToolResult(output: "无法启动 \(app)：\n\(r.output)", success: false)
            }
            try? await Task.sleep(nanoseconds: UInt64(2.0 * 1e9))
        }

        // ---- 2) 视觉模型 ----
        let entry = resolveVisionEntry(preferred: p.model)
        guard let visionEntry = entry else {
            return FileToolResult(output: "没有可用的视觉模型（需要支持图片输入）。请在设置里给会话配一个能看图的模型。", success: false)
        }
        let provider = await AIChatViewModel.makeAgentProvider(for: visionEntry)
        let screen = await screenSize()

        trace.append("model \(visionEntry.model.id)  screen \(Int(screen.w))x\(Int(screen.h))")

        let systemPrompt = Self.uiAutomationSystemPrompt(screen: screen, goal: p.goal, stopBefore: p.stopBefore)

        // ---- 3) 闭环 ----
        var history: [AgentMessage] = []
        var step = 0
        var lastAction = ""

        while step < p.maxSteps {
            step += 1
            if Task.isCancelled {
                return FileToolResult(output: trace.joined(separator: "\n") + "\n[已取消]", success: false)
            }

            // ── 截图：走「系统截图 + 相册导出」链路 ──
            // 为什么不用 apple-hid screenshot：
            //   实测本机 IOSurfaceCreate 全部变体返回 NULL（8/8），
            //   _UICreateScreenUIImage 返回 nil，CARenderServerSnapshot 返回 NULL。
            //   而 HID 触控注入是可用的 —— 于是改走：
            //     注入「音量上 + 电源」→ iOS 自己截图 → 存相册 → apple-photos export
            //   这条链路每一环都已实测可用，且不依赖 IOSurface / AX。
            let shotPath = "/var/minis/attachments/ui_step\(step).png"
            let shot = await Self.captureViaSystemScreenshot(
                toGuestPath: shotPath, run: { await self.runNative($0) })
            switch shot {
            case .ok:
                break
            case .failed(let why):
                trace.append("step \(step): 截图失败 → \(why)")
                return FileToolResult(output: trace.joined(separator: "\n"), success: false)
            }
            guard let imgData = loadGuestFileAsData(shotPath) else {
                trace.append("step \(step): 截图文件读不到 \(shotPath)")
                return FileToolResult(output: trace.joined(separator: "\n"), success: false)
            }

            // 问模型
            let parts: [AgentContentPart] = [
                .text("Step \(step). Screen size \(Int(screen.w))x\(Int(screen.h)) points. "
                      + (lastAction.isEmpty ? "This is the current screen." : "Previous action: \(lastAction).")),
                .imageData(data: imgData, mimeType: "image/png", linuxPath: shotPath),
            ]
            history.append(AgentMessage(role: .user, parts: parts))

            var reply = ""
            do {
                let stream = try await provider.streamAgentMessage(
                    messages: history, systemPrompt: systemPrompt, tools: [],
                    maxTokens: 1024, thinkingLevel: .off)
                for try await ev in stream {
                    if case .textDelta(let d) = ev { reply += d }
                }
            } catch {
                trace.append("step \(step): 模型请求失败 \(error.localizedDescription)")
                return FileToolResult(output: trace.joined(separator: "\n"), success: false)
            }

            history.append(AgentMessage(role: .assistant, parts: [.text(reply)]))
            // 历史里只留最近 3 步的图，避免上下文爆掉
            if history.count > 6 { history.removeFirst(history.count - 6) }

            // 解析动作
            guard let action = Self.parseUIAction(reply) else {
                trace.append("step \(step): 模型输出无法解析 → \(reply.prefix(200))")
                return FileToolResult(output: trace.joined(separator: "\n"), success: false)
            }

            let kind = action.action.lowercased()
            let label = action.label ?? action.target ?? ""

            // ---- 安全闸门 ----
            if kind == "tap" && Self.uiHitsPaywall(label) {
                let msg = """
                ⛔️ 已停止：下一步会点到「\(label)」——属于支付/下单确认类操作，需要你本人决定。

                已完成步骤：
                \(trace.joined(separator: "\n"))

                当前屏幕截图：\(shotPath)
                你确认的话，我可以继续；或者你直接自己点最后一步。
                """
                return FileToolResult(output: msg, success: false)
            }

            // ---- 执行 ----
            switch kind {
            case "done":
                trace.append("step \(step): DONE — \(action.note ?? "")")
                return FileToolResult(output: """
                ✅ 目标达成（\(step) 步）
                \(trace.joined(separator: "\n"))

                结果说明：\(action.note ?? "(无)")
                最终截图：\(shotPath)
                """, success: true)

            case "fail":
                trace.append("step \(step): FAIL — \(action.note ?? "")")
                return FileToolResult(output: "❌ 未能完成：\(action.note ?? "")\n" + trace.joined(separator: "\n"), success: false)

            case "tap", "long":
                guard let x = action.x, let y = action.y else {
                    trace.append("step \(step): tap 缺坐标")
                    continue
                }
                let cmd = kind == "tap"
                    ? "apple-hid tap \(Int(x)) \(Int(y))"
                    : "apple-hid long \(Int(x)) \(Int(y)) 0.7"
                let r = await runNative(cmd)
                lastAction = "\(kind) (\(Int(x)),\(Int(y))) label=\"\(label)\""
                trace.append("step \(step): \(lastAction) → exit \(r.exit)")

            case "swipe":
                guard let x = action.x, let y = action.y,
                      let x2 = action.x2, let y2 = action.y2 else {
                    trace.append("step \(step): swipe 缺坐标")
                    continue
                }
                let r = await runNative("apple-hid swipe \(Int(x)) \(Int(y)) \(Int(x2)) \(Int(y2)) 0.35")
                lastAction = "swipe (\(Int(x)),\(Int(y)))→(\(Int(x2)),\(Int(y2)))"
                trace.append("step \(step): \(lastAction) → exit \(r.exit)")

            case "type":
                let text = action.text ?? ""
                let r = action.asciiOnly == true
                    ? await runNative("apple-hid type \(Self.shellQuote(text))")
                    : await runNative("apple-hid paste \(Self.shellQuote(text))")
                lastAction = "input \"\(text.prefix(40))\""
                trace.append("step \(step): \(lastAction) → exit \(r.exit)")

            case "key":
                let r = await runNative("apple-hid key \(Self.shellQuote(action.text ?? "enter"))")
                lastAction = "key \(action.text ?? "enter")"
                trace.append("step \(step): \(lastAction) → exit \(r.exit)")

            case "wait":
                let secs = min(action.seconds ?? p.secondsPerStep, 8.0)
                lastAction = "wait \(secs)s"
                trace.append("step \(step): \(lastAction)")
                try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
                continue

            default:
                trace.append("step \(step): 未知动作 '\(kind)'")
            }

            try? await Task.sleep(nanoseconds: UInt64(p.secondsPerStep * 1e9))
        }

        return FileToolResult(output: """
        ⏹ 达到步数上限（\(p.maxSteps)）仍未完成。
        \(trace.joined(separator: "\n"))

        最后截图：/var/minis/attachments/ui_step\(step).png
        """, success: false)
    }

    // MARK: - 提示词

    static func uiAutomationSystemPrompt(screen: (w: Double, h: Double), goal: String, stopBefore: String?) -> String {
        """
        You are a UI automation controller. You see ONE screenshot of an iOS screen and must decide the SINGLE next action.

        GOAL: \(goal)
        SCREEN SIZE: \(Int(screen.w)) x \(Int(screen.h)) POINTS. All coordinates you output MUST be in this coordinate space (origin top-left, x→right, y→down). Do NOT output pixel coordinates.

        Reply with ONE JSON object and nothing else:
        {"action":"tap","x":120,"y":640,"label":"the exact text on the control you are tapping","note":"why"}
        {"action":"swipe","x":200,"y":700,"x2":200,"y":300,"note":"scroll down"}
        {"action":"type","text":"黄焖鸡米饭","asciiOnly":false,"note":"fill the search box"}
        {"action":"key","text":"enter","note":"submit search"}
        {"action":"wait","seconds":2,"note":"app is still loading"}
        {"action":"done","note":"what was accomplished and where it is visible"}
        {"action":"fail","note":"what blocked you and what you already tried"}

        HARD RULES:
        - Output exactly one action per reply. Always set `label` for tap/long: the literal text shown on the control.
        - NEVER tap anything whose text means pay / confirm order / purchase / submit order / subscribe / transfer. If reaching the goal REQUIRES such a tap, reply {"action":"done","note":"reached the final confirmation screen; user must tap <label> themselves"}.
        - If a screen is still loading (spinner, skeleton, blank), use {"action":"wait"}.
        - If the same screen repeats with no progress for several steps, reply {"action":"fail", ...} rather than tapping randomly.
        - Prefer tapping things you can actually read in the screenshot. Do not invent controls that are not visible.
        - Search: tap the search field first, then use "type", then "key"/enter.
        \(stopBefore.map { "- Also stop immediately when you see: \($0)\n" } ?? "")
        """
    }

    // MARK: - 动作解析

    struct UIAction: Decodable {
        var action: String
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var text: String?
        var label: String?
        var target: String?
        var note: String?
        var seconds: Double?
        var asciiOnly: Bool?
    }

    /// 从模型回复里抠出第一个平衡的 JSON 对象并解码。
    static func parseUIAction(_ raw: String) -> UIAction? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.components(separatedBy: "\n").drop(while: { $0.hasPrefix("```") }).joined(separator: "\n")
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}") else { return nil }
        let json = String(s[start...end])
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UIAction.self, from: d)
    }

    // MARK: - 辅助

    // MARK: - 截图（系统截图 + 相册导出）

    enum CaptureOutcome {
        case ok
        case failed(String)
    }

    /// 让 iOS 自己截图，再从相册导出到 guest 路径。
    /// 走这条路是因为 IOSurface / AX 在本机被用户态服务拒绝，而 HID 可用。
    static func captureViaSystemScreenshot(
        toGuestPath guestPath: String,
        run: (String) async -> (output: String, exit: Int)
    ) async -> CaptureOutcome {

        // 记录触发前的最新一张，避免误取到旧截图
        let before = await Self.latestPhotoId(run: run)

        // 1) 注入 音量上 + 电源
        let trig = await run("apple-hid systshot")
        if trig.exit != 0 {
            return .failed("systshot exit=\(trig.exit) \(trig.output.prefix(160))")
        }

        // 2) 轮询相册，等新截图出现（最多 ~6s）
        var newId: String? = nil
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let cur = await Self.latestPhotoId(run: run)
            if let c = cur, c != before { newId = c; break }
        }
        guard let assetId = newId else {
            return .failed("系统截图未出现在相册（可能被「屏幕使用时间」或权限拦截）")
        }

        // 3) 导出到 guest 路径
        let exp = await run("apple-photos export --id \(Self.shellQuote(assetId)) --size original --path \(Self.shellQuote(guestPath))")
        if exp.exit != 0 {
            // 有的版本 export 用 --dest / 位置参数，退一步再试
            let exp2 = await run("apple-photos export --id \(Self.shellQuote(assetId)) \(Self.shellQuote(guestPath))")
            if exp2.exit != 0 {
                return .failed("export exit=\(exp.exit) \(exp.output.prefix(160))")
            }
        }
        return .ok
    }

    /// 取相册最新一张的 localIdentifier
    private static func latestPhotoId(
        run: (String) async -> (output: String, exit: Int)
    ) async -> String? {
        let r = await run("apple-photos list --limit 1 --type photo")
        guard r.exit == 0,
              let start = r.output.firstIndex(of: "{"),
              let end = r.output.lastIndex(of: "}"),
              let data = String(r.output[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (obj["data"] as? [String: Any]) ?? obj
        if let assets = payload["assets"] as? [[String: Any]], let first = assets.first {
            return (first["id"] as? String) ?? (first["localIdentifier"] as? String)
        }
        return nil
    }

    private func runNative(_ cmd: String) async -> (output: String, exit: Int) {
        do {
            let r = try await executeCommand(cmd, timeout: 45, lineCallback: { _ in })
            return (r.output, r.exitCode)
        } catch {
            return ("error: \(error.localizedDescription)", -1)
        }
    }

    /// 解析 apple-hid probe 的 JSON，判断触控注入是否真的可用。
    /// 不靠字符串匹配 —— 输出可能是 pretty 也可能是 compact。
    static func probeSaysTouchReady(_ raw: String) -> Bool {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let payload = (obj["data"] as? [String: Any]) ?? obj
        return (payload["touch_injection"] as? Bool) ?? false
    }

    private func screenSize() async -> (w: Double, h: Double) {
        let r = await runNative("apple-hid size")
        var w = 390.0, h = 844.0
        if let d = extractJSON(from: r.output),
           let data = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let payload = (data["data"] as? [String: Any]) ?? data as [String: Any]? {
            if let n = payload["width"] as? Double { w = n }
            if let n = payload["height"] as? Double { h = n }
        }
        return (w, h)
    }

    /// apple-* CLI 输出的是 {ok,tool,action,data,...}，把最外层 JSON 抠出来
    private func extractJSON(from s: String) -> Data? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end]).data(using: .utf8)
    }

    /// 把 guest 路径（/var/minis/...）读成 Data —— 走既有宿主路径解析
    private func loadGuestFileAsData(_ guestPath: String) -> Data? {
        guard let host = resolveHostPath(guestPath) else { return nil }
        return try? Data(contentsOf: host)
    }

    /// 选一个支持图片输入的模型
    func resolveVisionEntry(preferred: String?) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        if let want = preferred, !want.isEmpty {
            if let e = store.modelEntries.first(where: {
                ($0.model.id == want || $0.model.id.lowercased().contains(want.lowercased())) &&
                $0.model.capabilities.supportedModalities.contains(.imageInput)
            }) { return e }
        }
        if let e = resolveSubEntry(), e.model.capabilities.supportedModalities.contains(.imageInput) { return e }
        if let e = resolveCurrentEntry(), e.model.capabilities.supportedModalities.contains(.imageInput) { return e }
        return store.modelEntries.first { $0.model.capabilities.supportedModalities.contains(.imageInput) }
    }
}
