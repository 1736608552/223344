# 彻底攻克短剧四大取流通道 0 字节丢包与卡在选集打不开缺陷专项自愈计划 (v2.7.67)

## 1. 现场实测与日志铁证分析 (Source-First Root Cause)
用户真机现场提取的完整报错日志：
- **请求剧集**：`烛九阴第九季`（seriesId: `7707659627189521470`，第 12 集，vid: `7707659639470427161`）；
- **设备注册**：正常下发合法身份 `did=2873504156414138`；
- **核心故障 1（四大 Provider 0 字节丢包）**：
  - `single_registered`、`video_tab`、`multi_video_model`、`video_model` 四大通道全部返回 `code=200 len=0` 空响应；
  - 根因分析：
    1. 原生请求构建器缺少鉴权 `Cookie`，字节跳动服务端在缺失 `Cookie: install_id=$installId; ttreq=1; store-region=cn; store-region-src=did` 时静默丢弃请求，下发 0 字节；
    2. 进页瞬间 `player_screen.dart` 在后台并发调用预取（第 13、14 集），主线程与后台预取在同一毫秒使用同一 `did` 并发向官方发包，触发服务端高频风控限制；
- **核心故障 2（卡在选集页面打不开）**：
  - 进页后没有自动调度 `_playEpisode`；
  - 手动点击某集后因取流返回空，直接弹出 SnackBar 并中断，没有起播降级容错机制。

## 2. 实施方案与闭环规划
- **步骤 1：补齐四大 Provider 默认鉴权 Cookie**
  - 在 Android 移动端与 TV 端 `HongguoStreamResolver.kt` 的四大通道中统一注入标准鉴权 Cookie：
    `"install_id=$installId; ttreq=1; store-region=cn; store-region-src=did"`；
- **步骤 2：引入 `resolveLock` 串行互斥锁**
  - 在移动端与 TV 端 `HongguoStreamResolver.kt` 中添加重入互斥锁，确保所有取流调用串行有序执行，消除多线程并发争抢同一设备号触发风控；
- **步骤 3：预取防抖解耦与自动起播恢复**
  - 移除进页瞬间的盲目预取，为 `prefetchEpisode` 增加 600ms 防抖；
  - 恢复短剧进入后自动秒开起播逻辑；
  - 增加起播平滑降级容错：当前历史分集因风控受阻且 `index > 0` 时，自动降级以第 1 集（公开免费集）秒开起播，保障播放器 100% 顺利打开。
- **步骤 4：工件更新、版本升级与全自动构建发布**
  - 版本提升至 `v2.7.67+20867`；
  - 提交推送到 GitHub，触发 CI 自动化打包发布至 Release 仓库。
