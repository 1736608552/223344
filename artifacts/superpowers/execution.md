# 彻底根治手机端与TV端短剧播放缺陷执行记录

## 执行步骤与验证清单

### 步骤 1：重构 Signer.kt 与播放接口签名头
- [x] **移动端 Signer.kt**：新增 `signPlayback`，彻底剔除 `x-medusa`，补齐 `Sdk-Version: 2`、`X-Xs-From-Web: 0`、`X-Tt-Dt: ""`、`X-Tt-Store-Region: cn`、`X-Tt-Store-Region-Src: did`；
- [x] **TV 端 Signer.kt**：新增 `signPlayback`，剔除 `x-medusa` 并补齐标准头；
- [x] **移动端 & TV 端 HongguoStreamResolver.kt**：`executeMultiVideoModel` 和 `executeSingleVideoModel` 切换至 `signPlayback`，过滤所有 Medusa 头，彻底消除 551 envelope 协议冲突返回 0 字节的故障；
- [x] **移动端 & TV 端 ContentRepository.kt**：接入三步尝试策略（Signed Primary -> Signed Alternate -> Unsigned Fallback），并在失败时自动联动 `HongguoStreamResolver` 双向容灾。

### 步骤 2：构建原生微型本地回环解密流服务（HongguoLocalServer）
- [x] **移动端 HongguoLocalServer.kt**：在 `android/app/src/main/kotlin/com/example/lunatv/hongguo/` 下创建高性能微型 HTTP Range 代理服务，监听 `127.0.0.1:0`，支持多线程分块读取与流式解密输出纯明文标准 MP4；
- [x] **TV 端 HongguoLocalServer.kt**：在 `tv/app/src/main/java/org/moontechlab/selenetv/hongguo/` 下创建相同能力的服务；
- [x] **LRU 缓存与自动释放**：具备活跃流 LRU 淘汰机制与 socket 断开优雅处理。

### 步骤 3：打通移动端与 TV 端的本地流直连
- [x] **MainActivity.kt**：在 `resolveStream` 时通过 `HongguoLocalServer.instance.getPlayUrl` 为每个视频流分配本地播放直链 `http://127.0.0.1:<PORT>/hongguo/media/<token>.mp4`，并将本地直链返回给 Flutter；
- [x] **Flutter duanju_media_kit_backend.dart**：对本地已解密明文流避免重复配置 demuxer key，直接标准 H.264+AAC 硬件解码播放；
- [x] **TV 端 PlayerScreen.kt**：形成「策略 1: 内存硬解直喂 -> 策略 2: 本地回环解密代理流 -> 策略 3: ExoPlayer 原生解密」三阶立体容灾保障，彻底杜绝黑屏与解码器不支持异常。

### 步骤 4：工程与版本同步
- [x] `pubspec.yaml` 版本升级为 `2.7.58+20858`；
- [x] `FIXLOG.md` 记录详细技术复盘与修复说明。
