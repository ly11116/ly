# ly executor

在 rootless jailbreak 设备上运行：

```sh
cd jailbreak/ly-executor
sh install-rootless.sh
curl http://127.0.0.1:8765/health
```

执行任务：

```sh
curl -s http://127.0.0.1:8765/v1/task \\
  -H 'Content-Type: application/json' \\
  -d '{"stop_on_error":true,"steps":[{"command":"uname -a"},{"command":"df -h"}]}'
```

当前默认 allowlist：`pwd id uname df du ps uptime whoami ls find cat grep launchctl`。

这是第一版安全骨架：只监听 localhost、限制命令、单步最长 120 秒、最多 32 步、记录 JSONL 审计。执行器不会读取 secrets、不会执行任意 shell 字符串、不会操作其他 App 数据。后续接入 Minis 时，Agent 发送的是结构化 task，不是拼接后的 shell。
