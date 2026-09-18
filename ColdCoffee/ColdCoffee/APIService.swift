// MARK: - API Service
// 网络请求层，自动注入破甲提示词

import Foundation

class APIService: ObservableObject {
    @Published var isLoading = false
    @Published var response = ""

    func send(seat: Seat, route: Route?, userMessage: String, config: APIConfig, activated: Bool) {
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoading = true
        response = ""

        var messages: [[String: String]] = []

        // 注入破甲 system prompt（冷咖啡核心）
        messages.append(["role": "system", "content": seat.systemPrompt])

        // 激活确认
        if activated {
            messages.append(["role": "assistant", "content": "我理解并确认。我将立即执行，直接交付结果。"])
        }

        // 路由提示
        if let route = route {
            messages.append(["role": "user", "content": "工作路线：\(route.rawValue)\n\(route.prompt)"])
        }

        // 用户消息
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": 4000
        ]

        guard let url = URL(string: config.baseURL),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            isLoading = false
            response = "URL Error"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        URLSession.shared.dataTask(with: request) { data, resp, error in
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.response = "Error: \(error.localizedDescription)"
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    self.response = "Parse error"
                    return
                }
                self.response = content
            }
        }.resume()
    }
}
