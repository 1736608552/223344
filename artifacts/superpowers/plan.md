# Gemini Superpowers 攻坚实施规划 (Plan)

## 1. 背景与目标
- **目标**：彻底解决电视端播放红果短剧前三集仅播放 9s/20s、画质被锁死为 360p、第 4 集及之后完全无法播放的问题。
- **方案策略**：100% 照搬并对齐原版 [aston314/hongguoTV](https://github.com/aston314/hongguo-tv) 纯 Kotlin 原生解密与 ExoPlayer 管道架构。
- **核心改动**：
  1. 废除外部 `libhongguotv.so` 守护进程与本地代理模式（消除 Android 10+ W^X 权限拦截与进程崩溃风险）。
  2. 拔除旧版中回退到 `video/public/$vid/360p.mp4` 的 9 秒公开试看假兜底。
  3. 完整移植原版纯 Kotlin 原生解密体系：`Bytes.kt`, `VendorConstants.kt`, `AesV3.kt`, `Signer.kt`, `RequestScope.kt`, `MediaCrypto.kt`, `RemoteVideo.kt`, `ContentRepository.kt`, `VideoDataSource.kt`。
  4. ExoPlayer 直接通过 `VideoDataSource` 读取纯内存解密数据，无缝支持 Range 请求与自适应播放，输出 1080P/720P 官方原画。
  5. TV 端与手机端双端对齐原生 Kotlin 架构，升级版本至 `v2.7.54` 并推送 Release 发布。

## 2. 实施步骤拆解与验证契约
- **步骤 1：审查与对齐 TV 端所有移植组件**
  - 检查 `tv/app/.../hongguo/` 下所有 Kotlin 文件（包名、类引用、方法签名、ExoPlayer 数据源适配）。
  - 检查 `PlayerScreen.kt` 与 `PlayerController.kt` 中的播放调用链路。
  - 验证：运行 TV 端编译预检 / ktlint / gradle 检查。
- **步骤 2：对齐 Android 手机端纯 Kotlin 架构**
  - 在 `android/app/src/main/kotlin/com/example/lunatv/hongguo/` 下落地原版移植组件：`Signer.kt`, `RequestScope.kt`, `MediaCrypto.kt`, `ContentRepository.kt`, `RemoteVideo.kt`, `AesV3.kt`。
  - 检查并修改 `android/.../MainActivity.kt`：清理废弃的 `HongguoCoreManager`，将 Flutter MethodChannel `hongguo/resolveStream` 改为调用纯 Kotlin `ContentRepository().stream`。
  - 验证：手机端编译预检与代码无死链检查。
- **步骤 3：本地编译与静态分析验证**
  - 运行 Gradle 编译任务或静态语法检查，确保无任何未解析引用（unresolved reference）或编译报错。
- **步骤 4：版本自增与发布**
  - 更新 `pubspec.yaml` 版本号至 `2.7.54+20854`。
  - 更新 `FIXLOG.md` 与 `.github/changelogs.json`。
  - Git commit 并打 tag `v2.7.54`，推送到 GitHub 远程仓库，触发全平台 CI 构建发布。
