# 播放诊断日记系统实施计划

## 1. 目标与背景
用户反馈在 TV 端和手机端仍然无法播放短剧（卡在 00:00 或加载失败），要求增加**日记/诊断功能**，在 TV 端和手机端记录全链路报错日志，使用户可以随时查看、复制并提供给开发者进行精准修复。

## 2. 架构设计与实施模块

### 模块 A：全链路播放日志收集器 (PlaybackLogCollector / HongguoDiagnostic)
- **TV 端原生 (Kotlin)**：`org.moontechlab.selenetv.hongguo.HongguoDiagnostic`
  - 维护内存环形日志队列（最大 200 条），记录关键时间戳、模块分类、级别（INFO / WARN / ERROR）、详情。
  - 覆盖全链路：
    1. **设备注册 (DeviceRegister)**：请求 URL、HTTP 状态码、响应字节数、解析出的 did/iid、是否触发 100 字节防刷或空 did。
    2. **解析与取流 (HongguoStreamResolver)**：剧集 ID、VID、尝试通道（single_registered / multi_video_model / video_model / fallback_api）、HTTP 状态、Key 提取状态、解析耗时。
    3. **本地解密服务 (HongguoLocalServer)**：服务启动端口、客户端 Range 请求范围、分片下载字节、AES-128-CBC 解密状态、下游写入状态与耗时。
    4. **播放器核心 (PlayerController / ExoPlayer)**：加载 URL、准备阶段、缓冲进度、首帧是否渲染、播放器异常 (PlaybackException) 详细错误码与堆栈。
  - 状态快照与判定引擎：自动生成类似标杆 app 的诊断报告（当前阶段、失败判定依据、核心指标、简明排查建议）。

- **手机端原生 (Kotlin) 与 Flutter 桥接**：`org.moontechlab.lunatv.hongguo.HongguoDiagnostic`
  - 手机端原生层与 TV 端完全同步全链路事件。
  - 通过 `MethodChannel('com.example.lunatv/hongguo_resolver')` 暴露获取诊断日志接口：`getDiagnosticLogs`、`getDiagnosticReport`、`clearDiagnosticLogs`。
  - Dart 侧 `DuanjuCoreBridge` 与播放器日志整合，记录 Dart 层取流重试、播放器启动及抛出的错误。

### 模块 B：TV 端「播放诊断日记」弹窗与快捷交互
- 在 `PlayerScreen.kt` 与控制栏面板 `PlayerPanel.kt` 中：
  - 控制栏快捷菜单增加「播放诊断」入口（显示为诊断/日志图标或文本）。
  - 支持遥控器按键快捷唤起（长按菜单键或在控制栏一键点击）。
  - 弹窗采用深色透明悬浮卡片（Compose for TV）：
    - 顶部：直观的状态指示（✅ 取流成功 / ⚠️ 设备异常 / ❌ 播放失败）、阶段、判定依据。
    - 中部：关键指标网格（Device ID、HTTP 状态、响应字节、本地代理端口、ExoPlayer 状态）。
    - 底部：滚动的最近全链路实时日志详情（带时间戳和高亮颜色区分 INFO/WARN/ERROR）。

### 模块 C：手机端「播放诊断日记」面板与一键复制功能
- 在 Flutter 播放页面（或短剧详情/设置菜单）：
  - 播放器控制面板增加「日记/诊断」按钮。
  - 点击弹出优雅的底部抽屉（BottomSheet）或弹窗：
    - 展示当前播放的剧集、VID、诊断报告。
    - 实时滚动展示日志。
    - 提供【一键复制日记】按钮，一键将完整诊断报告和日志复制到系统剪贴板，带有 Toast 提示，方便用户长按直接粘贴发送。
    - 提供【清空重测】按钮。

### 模块 D：双端代码审查与编译验证
- 严格代码审查：检查语法、空指针、类型推断、导入路径、AST 闭合。
- 升级版本号至 `v2.7.62+20862`，更新 `pubspec.yaml`、`FIXLOG.md`、`.github/changelogs.json`。
- 推送代码并提交 Release 构建。
