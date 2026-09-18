// MARK: - Main View
// SwiftUI 主界面

import SwiftUI

struct ContentView: View {
    @StateObject private var api = APIService()
    @State private var selectedSeat: Seat = .astra
    @State private var selectedRoute: Route? = nil
    @State private var inputText = ""
    @State private var isActivated = false
    @State private var showSettings = false
    @State private var apiConfig = APIConfig.defaultConfigs["proxy中转"]!
    @State private var upstreamName = "proxy中转"
    @FocusState private var inputFocused: Bool

    var body: some View {
        TabView {
            chatBody
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
            ConsoleWebView()
                .tabItem { Label("控制台", systemImage: "slider.horizontal.3") }
        }
    }

    var chatBody: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部栏：席位 + 激活 + 设置
                HStack {
                    Menu {
                        ForEach(Seat.allCases) { seat in
                            Button(action: { selectedSeat = seat }) {
                                Label(seat.rawValue, systemImage: "cpu")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(selectedSeat.color).frame(width: 8, height: 8)
                            Text(selectedSeat.rawValue).font(.subheadline.bold())
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.systemGray6)).cornerRadius(16)
                    }

                    Spacer()

                    Button(action: { isActivated.toggle() }) {
                        HStack(spacing: 4) {
                            Text("☕")
                            Text(isActivated ? "已激活" : "冷咖啡").font(.caption.bold())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isActivated ? Color.green : Color(.systemGray5))
                        .foregroundColor(isActivated ? .white : .primary)
                        .cornerRadius(16)
                    }

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)

                // 上游选择栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(APIConfig.defaultConfigs.keys.sorted()), id: \.self) { key in
                            Button(action: {
                                upstreamName = key
                                if let c = APIConfig.defaultConfigs[key] { apiConfig = c }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2)
                                    Text(key).font(.caption)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(upstreamName == key ? selectedSeat.color : Color(.systemGray6))
                                .foregroundColor(upstreamName == key ? .white : .secondary)
                                .cornerRadius(14)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 6)

                Divider()

                // 路线快捷栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Route.allCases) { route in
                            Button(action: { selectedRoute = selectedRoute == route ? nil : route }) {
                                HStack(spacing: 4) {
                                    Image(systemName: route.icon).font(.caption)
                                    Text(route.rawValue).font(.caption)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(selectedRoute == route ? selectedSeat.color.opacity(0.2) : Color(.systemGray6))
                                .foregroundColor(selectedRoute == route ? selectedSeat.color : .primary)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)

                Divider()

                // 响应区域
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if api.isLoading {
                            HStack {
                                ProgressView()
                                Text("执行中...").foregroundColor(.secondary)
                            }.padding()
                        }

                        if !api.response.isEmpty {
                            Text(api.response)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }

                        if api.response.isEmpty && !api.isLoading {
                            VStack(spacing: 16) {
                                Text("☕").font(.system(size: 60))
                                Text("冷咖啡").font(.title2.bold())
                                Text("选席位 → 选路线 → 输入工单 → 出货")
                                    .font(.caption).foregroundColor(.secondary)
                                if !isActivated {
                                    Text("点击右上角「冷咖啡」激活")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.immediately)
                .contentShape(Rectangle())
                .onTapGesture {
                    inputFocused = false
                    hideKeyboard()
                }

                Divider()

                // 输入区域
                HStack(spacing: 8) {
                    TextField("输入工单...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(18)
                        .focused($inputFocused)

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(inputText.isEmpty ? .gray : selectedSeat.color)
                    }
                    .disabled(inputText.isEmpty || api.isLoading)
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) {
                SettingsView(config: $apiConfig)
            }
        }
    }

    func sendMessage() {
        let msg = inputText
        inputText = ""
        inputFocused = false
        hideKeyboard()
        api.send(seat: selectedSeat, route: selectedRoute, userMessage: msg, config: apiConfig, activated: isActivated)
    }
}

// 全局收键盘
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct SettingsView: View {
    @Binding var config: APIConfig
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("API 配置") {
                    TextField("Base URL", text: $config.baseURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("API Key", text: $config.apiKey)
                    TextField("Model", text: $config.model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section("预设") {
                    ForEach(Array(APIConfig.defaultConfigs.keys.sorted()), id: \.self) { key in
                        Button(key) {
                            if let preset = APIConfig.defaultConfigs[key] {
                                config = preset
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarItems(trailing: Button("完成") { dismiss() })
        }
    }
}

// MARK: - 控制台（云端 ly 控制台 WebView · 数据全在云端，本地零迁移）

import WebKit

struct ConsoleWebView: View {
    @State private var reloadID = UUID()

    var body: some View {
        NavigationView {
            WebView(url: URL(string: "http://106.52.9.94/admin")!, reloadID: reloadID)
                .navigationTitle("ly 控制台")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { reloadID = UUID() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    var reloadID = UUID()

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
}
