# 执行记录 (Execution Log)

## 实施步骤记录

### 1. 双端「播放诊断与日志收集引擎 (HongguoDiagnostic)」开发与落地
- **TV 端**：创建 `tv/app/src/main/java/org/moontechlab/selenetv/hongguo/HongguoDiagnostic.kt`
  - 维护最大容量 200 条的内存环形日志缓冲队列（`ConcurrentLinkedQueue<DiagnosticEvent>`）；
  - 定义结构化诊断报告模型 `DiagnosticReport`（涵盖 stage, code, httpStatus, responseBytes, networkReason, elapsedMs, summary, lastError）；
  - 提供 `setContext`、`log`、`updateReport`、`getLogs`、`getFormattedLogs`、`getDiagnosticReportSummary` 与 `clear` 方法。
- **手机端 Android 原生**：创建 `android/app/src/main/kotlin/com/example/lunatv/hongguo/HongguoDiagnostic.kt`
  - 100% 对齐 TV 端日志与诊断结构，并额外实现 `toMap()` 供 Flutter MethodChannel 调用。

### 2. 全链路关键埋点与 100 字节风控判定
- **`DeviceRegister.kt` (双端)**：
  - 发起设备注册时记录开始日志；收到响应记录 HTTP 状态码与字节数；
  - 精准识别服务端返回的 `{"device_id":0,...}`（100 字节），标记为 `DEVICE_REGISTER_INVALID`，诊断判定明确记录“失败发生在‘匿名播放身份注册’阶段。HTTP 200 · 响应 100 字节 (DEVICE_REGISTER_INVALID)”。
- **`PlaybackDeviceSession.kt` (双端)**：
  - 记录设备轮换、复用本地持久化真实身份、降级使用备用虚拟身份的完整过程。
- **`HongguoStreamResolver.kt` (双端)**：
  - 记录每次取流的起始 VID、清晰度、尝试通道（single_registered / video_tab / multi_video_model / video_model）；
  - 记录每个通道耗时、返回状态与解析出解密 Key 长度；若全部通道失败，记录 `RESOLVE_EMPTY` 诊断汇总。
- **`HongguoLocalServer.kt` (双端)**：
  - 记录客户端 Range 请求、`remote.prepare()` 延迟连接状态、解密流传输异常与状态码。
- **`PlayerController.kt` (TV 端)**：
  - 加载直接播放流与内存解密流日志；记录 `ExoPlayer` 状态变迁（IDLE / BUFFERING / READY / ENDED）；
  - 首帧渲染成功上屏触发 `FIRST_FRAME`（起播正常）；发生 `PlaybackException` 时捕获详细 errorCodeName 与错误消息，更新诊断报告。

### 3. TV 端 Compose for TV 可视化诊断面板集成
- **`PlayerPanel.kt`**：
  - `PanelTab` 枚举扩展 `PanelTab.Diagnostic`（“日记”）；
  - 实现 `DiagnosticTabContent` 组件：
    - 左侧：结构化诊断报告卡片，带正常/异常/待检测状态 Chip、当前阶段、判定结果、判定依据、HTTP 状态码、响应字节数，支持按遥控器确认键一键清空日记；
    - 右侧：可上下滑动的 `LazyColumn` 全链路实时日志流，错误日志使用橙红色高亮，警告日志使用黄色高亮。
- **`PlayerScreen.kt`**：
  - 起播前通过 `HongguoDiagnostic.setContext` 注入当前剧集与 VID；
  - 播放出错时，顶部提示卡片引导“按菜单键呼出面板查看【日记】”，同时 `openPanel()` 自动优先选中 `PanelTab.Diagnostic`。

### 4. 手机端 MethodChannel 桥接与 Flutter UI 落地
- **`MainActivity.kt`**：
  - 暴露 `getDiagnosticLogs`、`getDiagnosticReport`、`clearDiagnosticLogs` 接口。
- **`DuanjuCoreBridge.dart`**：
  - 封装诊断报告获取方法；全链路取流每一步均调用 `DiaryService.add` 写入日志系统。
- **`DiaryScreen.dart`**：
  - 分类 Chip 新增【短剧】专属分类，顶部标题栏增加【同步原生短剧日志】按钮。
- **`PlayerScreen.dart`**：
  - 齿轮设置面板新增【播放诊断与日记】入口；
  - 起播未拿到直链时的提示条新增【查看日记】Action 按钮；
  - 实现 `_showPlaybackDiagnosticSheet()` 弹窗：展示当前剧集诊断结论、全量日志，提供大号【一键复制日记】按钮，长按即可粘贴发送给开发者。

### 5. 静态语法与闭环自检
- 编写 AST 语法扫描脚本，对全部改动文件执行括号对称与语法验证，确保无闭合错误；
- 升级版本为 `2.7.62+20862`，同步更新 `pubspec.yaml`、`FIXLOG.md`、`.github/changelogs.json`。
