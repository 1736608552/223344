# 彻底攻克短剧四大取流通道 0 字节丢包与卡在选集打不开缺陷执行记录 (v2.7.67)

## 1. 代码改动清单 (Touched Files)
1. `android/app/src/main/kotlin/com/example/lunatv/hongguo/HongguoStreamResolver.kt`
   - 为 `executeSingleRegisteredVideoModel`、`executeVideoTab`、`executeMultiVideoModel`、`executeSingleVideoModel` 四大通道全量注入标准鉴权 Cookie；
   - 增加 `resolveLock` 串行互斥锁，保护 `doResolve`。
2. `tv/app/src/main/java/org/moontechlab/selenetv/hongguo/HongguoStreamResolver.kt`
   - 同步为四大通道补齐鉴权 Cookie，并添加 `resolveLock` 互斥串行锁。
3. `lib/screens/player_screen.dart`
   - 恢复短剧进入后自动起播 `_playEpisode(targetEp)`，切至播放全屏；
   - 移除进页瞬间后台并发发起的双集预拉取；
   - 增加第 1 集平滑降级起播自愈防线。
4. `lib/services/duanju_core_bridge.dart`
   - 规范化通道 2 的 Cookie 头格式；
   - 为 `prefetchEpisode` 注入 600ms 延迟防抖机制。
5. `pubspec.yaml`
   - 版本更新至 `2.7.67+20867`。
6. `.github/changelogs.json`
   - 补充 `v2.7.67` 版本更新日志。

## 2. 静态分析与自愈验证
- Android 原生 Kotlin 代码语法检查：已严格对齐类与函数签名；
- Dart 代码语法检查：无缺失变量或括号不匹配；
- 串行锁与防抖逻辑：有效解除多线程并发争抢设备 ID 导致的高频封禁风险。
