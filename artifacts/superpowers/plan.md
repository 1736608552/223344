# 彻底根治手机端与TV端短剧播放缺陷，实现毫秒级秒开对齐标杆仓库实施方案

## 一、问题根因深度复盘与分析

### 1. 官方播放接口返回 0 字节空响应的死穴
- **铁证事实**：标杆仓库 `aston314/hongguo-tv` 在 `minireel_sign.go` 第 43~46 行明确记录：
  ```go
  // The account Medusa profile conflicts with the playback 551 envelope:
  // same-request live comparisons return an empty body when it is included.
  // Keep account signing intact, but do not send that header to playback APIs.
  headers.Del("X-Medusa")
  headers.Set("Sdk-Version", "2")
  headers.Set("X-Xs-From-Web", "0")
  headers.Set("X-Tt-Dt", "")
  headers.Set("X-Tt-Store-Region", "cn")
  headers.Set("X-Tt-Store-Region-Src", "did")
  ```
- **LunaTV 当前缺陷**：移动端和 TV 端的 `Signer.kt` 在 `sign()` 中无差别添加了 `x-medusa`，导致 `multi_video_model` 和 `video_model` 触发服务端 551 envelope 协议冲突，下发 0 字节空响应体；而在 fallback 未签名时又被服务端风控直接拦截。

### 2. 手机端与 TV 端播放器解码失败/黑屏的根本原因
- **火山 CDN 加密机制**：火山引擎的短剧 MP4 采用 ISO-BMFF CENC 规范，MP4 box 类型为 `encv`（加密视频）与 `enca`（加密音频），媒体数据经 AES-128-CTR 样本级加密。
- **播放器缺陷**：客户端播放器（Flutter media_kit/libmpv、ExoPlayer）无法直接解码 `encv`。直接传入火山 CDN 直链必然导致解码器报不支持的编码格式或黑屏无限转圈。
- **标杆仓库核心解决方案**：标杆仓库在本地启动微型 HTTP Range 代理服务（`serveMiniReelRangeMedia`），向播放器提供本地标准 MP4 直链（`http://127.0.0.1:<PORT>/minireel-proxy/...`）。在本地服务中，透明将 `encv` 改写为 `avc1`，将 `enca` 改写为 `mp4a`，并对请求的 Range 数据段实时执行 AES-128-CTR 异或解密。播放器接收到的是纯明文标准 MP4，毫秒级秒开且硬件加速 100% 兼容。

---

## 二、架构重构与改造规划

### 步骤 1：重构 Signer.kt 与播放接口签名头
- 在 `android/app/src/main/kotlin/com/example/lunatv/hongguo/Signer.kt` 与 `tv/app/src/main/java/org/moontechlab/selenetv/hongguo/Signer.kt` 中：
  - 新增 `signPlayback` 方法：自动剔除 `x-medusa` / `X-Medusa`；
  - 严格补齐 `Sdk-Version: 2`、`X-Xs-From-Web: 0`、`X-Tt-Dt: ""`、`X-Tt-Store-Region: cn`、`X-Tt-Store-Region-Src: did`；
- 在 `HongguoStreamResolver.kt` 和 `ContentRepository.kt` 中：
  - 对齐标杆仓库三步尝试策略（Signed Primary -> Signed Alternate -> Unsigned Fallback）；
  - 确保向 `multi_video_model` 和 `video_model` 发起的请求绝不携带 `x-medusa`。

### 步骤 2：构建 Android 原生轻量级本地回环流服务（HongguoLocalServer）
- 在 `android/app/src/main/kotlin/com/example/lunatv/hongguo/HongguoLocalServer.kt`：
  - 启动轻量级内置 HTTP 服务（监听 `127.0.0.1:0` 动态端口）；
  - 暴露路由 `/stream?token=<UUID>`；
  - 完整支持 HTTP `Range: bytes=start-end` 头与 HTTP 206 Partial Content / HTTP 200；
  - 集成 `RemoteVideo`，按请求区间流式调用 `RemoteVideo.read(start, length)`，输出纯明文 MP4 数据；
  - 具备连接超时、客户端断开处理、流资源 LRU 缓存与自动回收机制；
- 同步在 `tv/app/src/main/java/org/moontechlab/selenetv/hongguo/HongguoLocalServer.kt` 中提供相同能力。

### 步骤 3：打通移动端（Flutter）与 TV 端（ExoPlayer）的本地流直连
- **移动端 MainActivity.kt**：
  - `resolveStream` 时，通过 `HongguoLocalServer` 为每个解析成功的视频流分配本地播放直链 `http://127.0.0.1:<PORT>/stream?token=...`；
  - 将此本地直链返回给 Flutter。
- **Flutter 端 player_screen.dart / duanju_core_bridge.dart**：
  - 播放器直接播放此本地直链，无论是 `ExoPlayerBackend` 还是 `DuanjuMediaKitBackend`，无需额外解密配置，秒开起播。
- **TV 端 PlayerScreen.kt / PlayerController.kt**：
  - 优先直连 `RemoteVideo` 内存通道；若需 HTTP 流，直接连接 `HongguoLocalServer` 本地直链，彻底消灭任何黑屏与解码异常。

### 步骤 4：自检与版本发布
- 静态编译与语法检查；
- 更新版本至 `2.7.58+20858`，更新 `FIXLOG.md`；
- Git commit，打 tag `v2.7.58` 并推送到 GitHub，触发全平台 CI 构建并发布至 Release 仓库。
