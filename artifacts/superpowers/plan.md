# 手机端与TV端短剧“卡在选集打不开播放页”及设备注册失效 (DEVICE_REGISTER_INVALID) 彻底自愈计划

## 1. 故障核心定位 (Root Cause Analysis)
1. **视图状态机死锁 (`_phase` 无法切换)**：
   - 手机端从短剧专区或搜索进入 `PlayerScreen` 时，初始状态为 `_phase = 'detail'`，且 `initState` 中未自动触发起播；
   - 用户在详情页选集网格点击某一集时，调用 `_playEpisode(index)`，但由于网络延迟或取流受阻，代码在第 4257 行因为 `!actualSourceUrl.startsWith('http')` 直接执行了 `return`，而 `_phase = 'playing'` 位于第 4345 行，导致永远无法切换到播放器视图，用户被死死卡在选集网格中；
2. **设备注册风控与空身份拦截 (`DEVICE_REGISTER_INVALID`)**：
   - 字节红果服务器在同一宽带 IP 频繁请求时，对 `device_register` 返回 `HTTP 200 · 响应 100 字节`（包含 `device_id: 0`），导致原生层四通道取流排空；
   - 缺少免设备注册的官方 Web 穿透兜底与预置合法会话池轮换；
3. **日记与诊断入口隐蔽过深**：
   - 原日记入口只在播放态（`_phase == 'playing'`）的齿轮设置菜单中，用户在详情态根本无法看到和使用。

## 2. 实施步骤规划 (Implementation Steps)
- **步骤 1：重构 `player_screen.dart` 的起播与视图状态流转**
  - 短剧点击后立即在下一帧自动起播目标集数（支持记忆恢复）；
  - 进入 `_playEpisode` 时第一时间将 `_phase` 切为 `'playing'`，展示沉浸式播放器全屏界面；
  - 若解析受阻，全屏播放器中央展示优雅的错误与诊断卡片（包含【一键复制诊断日记】、【重试】、【换源】等按钮）；
  - 在详情页（`_buildDetailView`）顶部及选集区增加醒目的【播放诊断/日记】按钮。
- **步骤 2：在 `short_drama_screen.dart` 中增加全局日记/诊断入口**
  - 在短剧专区右上角增加【诊断日记】图标，支持随时随地一键复制日志。
- **步骤 3：增强 Android 原生层与 Flutter 端设备注册风控抵御 (`DeviceRegister.kt` / `DuanjuCoreBridge.dart`)**
  - 在遭遇 `DEVICE_REGISTER_INVALID` 时，启用预置高权重合法设备指纹池（Preset Official Profiles），杜绝 `device_id=0`；
  - 完善 Web 官方免注册通道穿透，当设备注册临时受阻时无缝降级直取官方原画流。
- **步骤 4：代码语法静态检查、AST 验证与自检闭环**
  - 运行静态检查，确认无括号缺失与类型错误。
- **步骤 5：升级版本至 `v2.7.63+20863`，同步更新更新日志与发布工件**
  - 提交并推送 GitHub 触发自动化构建发布。
