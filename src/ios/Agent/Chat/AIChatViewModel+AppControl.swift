//
//  AIChatViewModel+AppControl.swift
//  MinisApp
//
//  ly patch — `app_control` 工具：枚举 / 启动已安装的 iOS App
//
//  实现方式：不在 Swift 侧直接调私有 API，而是转发给原生 offload CLI
//  `apple-apps`（见 NativeOffloads/OpenOffload.m）。好处：
//   - 私有 API 调用集中在 ObjC（可用 noff_try_objc 兜住 NSException）
//   - 用户也能在终端里手动敲 `apple-apps list`，调试路径与 agent 完全一致
//   - 巨魔/非巨魔环境由原生侧自行降级，Swift 侧无需分支
//

import Foundation

extension AIChatViewModel {

    func executeAppControlTool(from json: String) async -> FileToolResult {
        var action = "list"
        var query: String?
        var bundleID: String?
        var target: String?
        var limit: Int?
        var userOnly = false

        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let a = obj["action"] as? String, !a.isEmpty { action = a }
            query = obj["query"] as? String
            bundleID = obj["bundle_id"] as? String
            target = obj["target"] as? String
            if let n = obj["limit"] as? Int, n > 0 { limit = min(n, 500) }
            userOnly = (obj["user_only"] as? Bool) ?? false
        }

        // ---- 组装 apple-apps 命令行 ----
        var argv: [String] = []

        switch action {
        case "list":
            argv = ["list"]
            if let query, !query.isEmpty { argv += ["--filter", query] }
            if let limit { argv += ["--limit", "\(limit)"] }
            if userOnly { argv.append("--user-only") }

        case "info", "schemes":
            guard let bid = bundleID ?? target else {
                return FileToolResult(output: "Error: 'info'/'schemes' 需要 bundle_id 参数。先用 action=list 查。", success: false)
            }
            argv = [action, bid]

        case "frontmost":
            argv = ["frontmost"]

        case "open":
            guard let t = target ?? bundleID else {
                return FileToolResult(output: "Error: 'open' 需要 target 参数（bundle id / URL scheme / app 名称）。", success: false)
            }
            argv = ["open", t]

        default:
            return FileToolResult(
                output: "Error: 未知 action '\(action)'。可用：list / info / schemes / open / frontmost。",
                success: false)
        }

        let cmd = (["apple-apps"] + argv.map { Self.shellQuote($0) }).joined(separator: " ")

        do {
            let r = try await executeCommand(cmd, timeout: 30, lineCallback: { _ in })
            let body = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = r.exitCode == 0
            if !ok && body.isEmpty {
                return FileToolResult(
                    output: "apple-apps 执行失败 (exit \(r.exitCode))。该命令依赖 LSApplicationWorkspace —— 巨魔(TrollStore)环境下可用；普通签名环境会返回 NOT_AVAILABLE。",
                    success: false)
            }
            return FileToolResult(output: body, success: ok)
        } catch {
            return FileToolResult(output: "app_control 执行出错: \(error.localizedDescription)", success: false)
        }
    }
}
