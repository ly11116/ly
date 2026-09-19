# LyPerformance

`LyPerformance` 是给 rootless jailbreak 设备使用的实验性性能插件。

## 边界

- 只注入 `com.ly.minis`
- 只监控 ly minis 自身进程的 memory / thermal 状态
- 只清理 ly minis 自己的缓存目录
- 不读取、修改或终止其他 App
- 不改 kernel、jetsam、swap 或系统内存策略

## 构建

在 macOS + Theos 环境：

```sh
make package FINALPACKAGE=1
```

生成的 `.deb` 安装到 rootless jailbreak 设备后执行：

```sh
dpkg -i packages/com.ly.minis.lyperformance_*.deb
sbreload
```

插件不会凭空增加系统 RAM；它负责在压力和温度升高时降低自身缓存与任务负载。
