import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
// v2.2.0: 卸 libmpv (media_kit) 改 ExoPlayer (AndroidX Media3).
// v2.3.14: 加回 video_player Flutter package, 卸自研 CustomExoPlayer.
//   跟 v2.3.0 行为一致 — 走 video_player 内部 ExoPlayer (1.4.x) +
//   默认 DefaultLoadControl. 视频输出走 video_player [VideoPlayer] widget.
//   实际 ExoPlayer 1.4.x (跟 video_player 2.x 内部是同一份).

import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/search_result_ranker.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/page_cache_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/m3u8_service.dart';
import 'package:luna_tv/services/player_backend.dart';
import 'package:luna_tv/services/duanju_core_bridge.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
// v2.3.0: 视频加速 (VideoProxyServer + CfOptimizer) 整个删了, 不用这两个 import
//   - video_proxy_server.dart 已删
//   - cf_optimizer.dart 已删
import 'package:luna_tv/services/exo_player_backend.dart';
import 'package:luna_tv/services/duanju_media_kit_backend.dart';
import 'package:luna_tv/widgets/duanju_media_kit_view.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/luna_cache_manager.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:luna_tv/widgets/douban_detail_header.dart';
import 'package:luna_tv/widgets/dlna_device_dialog.dart';
import 'package:luna_tv/widgets/favorites_grid.dart';
import 'package:luna_tv/widgets/exo_player_view.dart';
// v2.5.34: 重做弹幕 — v2.3.12 移植 Selene-TV 后被 v2.3.14 卸了 (UX 差:
//   要手动输 B 站 cid). 现在按"自动选源"思路重做, 6 源并行 search
//   → manager.autoMatch 选最优 → 自动拉. 用户在播放器上点 "弹" 按钮
//   即触发, 不再要任何手动输入. 反编译 6 源协议见
//   /workspace/selene_danmaku_protocol.md
import 'package:luna_tv/danmaku/danmaku_manager.dart';
import 'package:luna_tv/danmaku/danmaku_settings.dart';
import 'package:luna_tv/danmaku/models/danmaku_comment.dart';
import 'package:luna_tv/danmaku/models/danmaku_media.dart';
import 'package:luna_tv/danmaku/models/hongguo_danmaku_emojis.dart';
import 'package:luna_tv/danmaku/widgets/danmaku_overlay.dart';
import 'package:luna_tv/danmaku/widgets/danmaku_panel.dart';
import 'package:luna_tv/danmaku/widgets/danmaku_control_sheet.dart';
import 'package:luna_tv/danmaku/widgets/danmaku_settings_sheet.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:luna_tv/models/skip_segment.dart';
import 'package:luna_tv/services/skip_segment_service.dart';
import 'package:luna_tv/services/next_season_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/window_utils.dart';

/// LunaTV Web 风格播放详情页
///
/// 阶段:
///   1. detail       - 海报 + 标题 + 元信息 + 源/集数面板 + 播放按钮
///   2. playing      - 全屏视频播放
///
/// 源面板: 显示所有源、测速 (head 请求)、自动选中最低延迟
/// 集数面板: 6列网格,显示集数标题
class PlayerScreen extends StatefulWidget {
  final VideoInfo videoInfo;
  final String? preferredSource;
  // v2.4.7: 源浏览器点播放直接传 detail (含 episodes), 跳过 _loadSources
  //   (会调 /api/search 全源搜索), 直接用当前源播. 用户反馈 "点击播放后
  //   应该直接播放当前源不应该再跳转到播放详情页去搜索源".
  final SearchResult? initialDetail;

  const PlayerScreen({
    super.key,
    required this.videoInfo,
    this.preferredSource,
    this.initialDetail,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// 测速用的临时包装
class _SourcePingItem {
  final SearchResult source;
  _SourcePingItem(this.source);
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  // v2.5.18: 物理音量键拦截 channel — 见 android/.../VolumeKeyChannel.kt.
  //   initState 注册 setMethodCallHandler + setEnabled(true), dispose
  //   关掉, 让用户离开播放页时物理音量键走系统默认 (弹系统音量条是
  //   合理的系统反馈). channel 跟 MainActivity 生命周期一致, widget
  //   销毁时 listener 也要清, 否则下一次 push 播放页会重复监听.
  static const MethodChannel _volumeKeyChannel =
      MethodChannel('org.moontechlab.lunatv/volume_key');

  // v2.5.22: fallback 测速用的浏览器 headers — User-Agent + Referer +
  //   Accept. 之前 3 个 fallback 函数 (_fallbackMeasureLatency /
  //   _fallbackMeasureDownloadSpeed / _fallbackMeasureM3u8Speed) 裸 GET,
  //   没有任何 header, 部分 CDN 拦非浏览器请求直接返 403, fallback 全失败
  //   → "不可用". 但用户实测这些源播放正常 (ExoPlayer 自带 User-Agent),
  //   说明是测速链路跟播放链路 header 不一致导致.
  // 现在统一加浏览器 header, 跟 web LunaTV / ExoPlayer 行为一致, 让
  // 测速跟播放走同一套 anti-bot 校验.
  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,application/javascript,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  // v2.5.22: 给测速 URL 加 Referer 头 (跟 m3u8_service._refererHeaders 一致).
  //   部分 CDN (腾讯 / 优酷 / 部分爱奇艺海外节点) 不带 Referer 返 403.
  //   从 URL host 自动取 base referer.
  static Map<String, String> _refererHeaderFor(String url) {
    try {
      final parsed = Uri.parse(url);
      if (parsed.scheme.isNotEmpty && parsed.host.isNotEmpty) {
        return {'Referer': '${parsed.scheme}://${parsed.host}/'};
      }
    } catch (_) {}
    return const {};
  }
  // 播放器 — v2.2.0: 卸 libmpv 改 ExoPlayer (AndroidX Media3).
  //   v2.3.11: 卸 video_player, 改用自研 [CustomExoPlayer] (走
  //   CustomExoPlayerChannel.kt). 视频输出走 Flutter SurfaceTexture,
  //   [ExoPlayerView] 渲染 [Texture] widget, 不再依赖 video_player.
  //   v2.3.14: 加回 video_player Flutter package, 卸自研 [CustomExoPlayer].
  //     走 video_player 2.10.1 内部 ExoPlayer (1.4.x) + 默认
  //     DefaultLoadControl. [ExoPlayerView] 渲染 [VideoPlayer] widget.
  //     跟 v2.3.0 行为一致.
  PlayerBackend? _player;
  // v2.3.0: 视频加速链路整个删了, 以下字段跟着删:
  //   - VideoProxyServer _videoProxy  (本地代理服务, 整个文件删了)
  //   - bool _videoProxyActive        (顶部「加速状态」指示器状态, 没人 trigger 了)
  //   - double _downloadSpeedBps      (VideoProxyStatus 流推的实时下载速度, 流也没了)
  //   - Timer? _speedSampleTimer      (上面用的 1Hz 采样 timer, 没人调了)
  //   - int _lastDemuxerBytes         (上面用的 last-sample demuxer bytes, 没人读了)
  //   - int _lastSampleMs             (上面用的 last-sample 时间戳, 没人用了)
  //   - String _currentPlayUrl        (「加速链路」弹层用, 弹层删了)
  //   v2.2.7 行为: ExoPlayer 直连 CDN, 无任何代理层, 无下载速度采样, 无状态指示器.
  // v2.0.34: 顶部「加速状态」指示器用, 视频代理实际在跑时为 true
  // v2.0.93: TMDB 精准识别的 w1280 backdrop URL, 传给 DoubanDetailHeader
  //   替代豆瓣 coverUrl. 加载完成后 setState 触发 rebuild, 没加载完
  //   / 加载失败 / 没配 key = null, DoubanDetailHeader 走 coverUrl 兜底.
  String? _tmdbBackdropUrl;
  // v2.1.7: 豆瓣剧情简介 — 通过 DoubanService.getDoubanDetails 拉 doubanId
  //   详情, 取 summary 字段. 用户反馈"海报多的地方放上电影简介", 在选集
  //   section 跟源 section 之间插一个简介 card. 没 doubanId / 拉不到 / 字段空
  //   = 不渲染, 行为不变 (不占空白).
  String? _summary;
  // v2.1.17: TMDB 卡司 (演员) — 平板大头部背景图下半部展示横向滚动的
  //   演员头像 + 名字. 用户反馈"海报内好多空白的地方看到没 / 放上演员吧
  //   怎么样 / 或者海报那个好 / 都在一行要有演员图片那种 / 不够排就滑动".
  //   跟 _summary / _tmdbBackdropUrl 同模式: TMDB search → credits 接口,
  //   不依赖 doubanId, 主页/历史/收藏页都能拉到. null = 没配 key / 拉不到.
  List<TmdbCast>? _cast;
  bool _summaryExpanded = false; // 用户点击"展开"切换

  // v2.1.45: DLNA 投屏状态. PlayerScreen 之前用 _buildLunaTopBar /
  //   _buildLunaBottomBar 自定义 LunaTV Web 风格 UI, 没用 MobilePlayerControls /
  //   PCPlayerControls / VideoPlayerWidget (那 3 个 widget 在 lib 里其实没人用,
  //   所有播放入口 — show / anime / history / movie / tv / favorites / search /
  //   short_drama / home_screen 都是直接跳 PlayerScreen). DLNA 代码
  //   (dlna_device_dialog.dart + dlna_dart) 一直在 lib/widgets/ 里, 但只被
  //   死代码 MobilePlayerControls / PCPlayerControls import, 实际播放 UI
  //   看不到投屏按钮. v2.1.45 把它接进 PlayerScreen 实际 UI:
  //   - _isCasting: 投屏成功后 true, 顶部栏 cast 按钮变 cast_connected 绿色
  //   - _currentCastDevice: 当前投屏设备引用, 停止投屏时调 device.stop()
  //   - 投屏成功后停本地 player, 切回 detail 视图, 提示 "已投屏到 XXX, 回到本地播放"
  // 播放器异步初始化 Future，用于防止用户快点播放时发生重复创建和销毁竞争
  Future<void>? _initPlayerFuture;

  bool _isCasting = false;
  DLNADevice? _currentCastDevice;

  // 状态
  String _phase = 'detail'; // detail | playing
  bool _isBuffering = false;
  String? _error;

  // 多源结果
  List<SearchResult> _sourceResults = [];
  bool _sourcesLoading = true;
  final Map<String, int> _pingCache = {}; // 兼容旧 fallback 测速 (v1.0.69 暂留, 不再写入)
  final Map<String, PingState> _pingState = {};
  // v1.0.45: 完整测速信息 (分辨率 + 下载速度 + ping), 用 M3U8Service
  final Map<String, _SourceSpeedInfo> _sourceSpeeds = {};
  String? _autoSelectedSource;

  // 当前选中的源 / 集
  SearchResult? _selectedSource;
  int _currentEpisodeIndex = 0;
  // v2.0.51: 选集 PageView 控制器 + notifier (给翻页 badge "1/2" 用,
  //   滑动 PageView 时 badge 数字跟着变)
  late final PageController _episodesPageController;
  final ValueNotifier<PageController> _pageControllerNotifier =
      ValueNotifier<PageController>(_EmptyPageController.instance);

  // 播放进度上报
  Timer? _progressTimer;
  bool _firstRecordSaved = false;
  String? _lastSavedKey; // 避免重复保存同一条
  // ★ v2.5.65: 高精度进度条更新定时器 (让白点跟实际位置同步)
  Timer? _positionPollTimer;

  // 视频尺寸（用于判断横竖屏全屏）
  int _videoWidth = 0;
  int _videoHeight = 0;
  // v2.6.41: 手势缩放 — 有的影片尺寸小, 双指捏拉放大填满屏幕.
  //   _videoScale 当前缩放倍数 (1.0 = 原始, 4.0 = 4倍), 双击中央复位.
  //   用 Listener (raw pointer) 而非 GestureDetector.onScale*, 避免跟
  //   亮度/音量/快进快退的 VerticalDrag/HorizontalDrag 抢手势竞技场.
  //   Listener 不参与竞技场, 只观察 pointer 事件, 2 指以上才计算缩放.
  double _videoScale = 1.0;
  double _baseScale = 1.0; // pinch 手势开始时的 scale
  // pinch 指针追踪 — 记录当前按下的指针 id → 屏幕坐标
  final Map<int, Offset> _pinchPointers = {};
  double _pinchInitialDistance = 0.0; // pinch 开始时两指距离 (像素)

  // 分辨率 / 清晰度状态 (短剧对齐红果鉴默认「自动」，支持多分辨率平滑自由切换)
  String _currentResolution = '自动';
  String _userPreferredResolution = '自动';
  List<String> _availableResolutions = ['1080P', '720P', '480P'];
  final Map<String, String> _resolutionUrlMap = {};
  String _currentPlayUrl = '';
  // v2.2.0: 删 _videoParamsSub (libmpv streams.videoParams 替代)
  //   video size 从 backend.width/height 读 (在 positionStream listener 里同步)

  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  // v2.6.93: 全新智能片头/片尾跳过系统 (彻底替代旧版繁琐手动秒数设置)
  // v2.6.101: 纯净依据 TheIntroDB / IntroDB 全球云端打点，彻底禁用本地通用盲跳兜底，杜绝误跳电影与综艺
  bool _smartSkipEnabled = true; // 智能片头跳过总开关
  String _smartSkipMode = 'manual'; // 'manual'(默认: 按钮显示5s后消失，点击跳过), 'countdown'(5秒倒计时自动跳过), 'instant'(立即跳过)

  List<SkipSegment> _smartSkipSegments = [];
  SkipSegment? _activeSmartSegment;
  Timer? _smartSkipCountdownTimer;
  int _smartSkipCountdownSec = 5;
  bool _dismissedSmartSegmentThisEp = false;
  bool _hasAutoSkippedThisEp = false; // 本集是否已自动跳过
  bool _dismissedIntroThisEp = false; // 片头主动关闭标记
  bool _dismissedOutroThisEp = false; // 片尾主动关闭标记
  bool _hasAutoSkippedIntroThisEp = false; // 片头是否已跳过
  bool _hasAutoSkippedOutroThisEp = false; // 片尾是否已跳过
  bool _isTransitioningEpisode = false; // 正在切集状态锁，防并发高频重入
  bool _hasCalibratedSegmentsWithDuration = false; // 当前集是否已使用真实视频时长自适应校准打点


  // _lastKnownPosition: position stream 每帧更新, 记"上一次非 0 位置".
  // 用于进度同步兜底 (libmpv m3u8 reload 期间 state.position=0,
  // _currentPosition 也被重置, 用 _lastKnownPosition 拿 reload 前的位置,
  // 避免 10s 定时器存 0 覆盖云端进度).
  // v2.1.13: 删掉广告自动跳过逻辑 (duration 跳变 + position 倒退检测 +
  //   _skipAd helper). 用户反馈反复卡同一广告位 / seek 错乱, 决定移除
  //   runtime 兜底, 改靠 m3u8 重写层 (视频代理开关) 物理删广告段.
  Duration _lastKnownPosition = Duration.zero;

  // 自动播下一集: 防止 position/completed 重复触发
  bool _autoPlayedThisEpisode = false;

  // v2.3.14: 卸弹幕系统 (v2.3.12 移植自 Selene-TV, 用户反馈 UX 太差:
  //   要求手动输 B 站 cid, 违背 "TV 客户端" 一键体验原则, 整个删了).
  // v2.5.34: 重做 — 6 源自动 search + 选最优 + 拉弹幕, 全自动不需要手动
  //   输 cid. 用户在播放器上点 "弹" 按钮即触发.
  bool _danmakuEnabled = false;       // 总开关
  bool _danmakuLoading = false;       // 拉取中
  String? _danmakuSource;             // 当前用的源 (DanmakuSource.key)
  String? _danmakuSourceTitle;        // 媒体标题 (用于展示选了哪个)
  int _danmakuCount = 0;              // 加载到的弹幕数
  List<DanmakuComment> _danmakuComments = const [];
  // v2.5.38: 弹幕面板选中后保存, 切集时用同一源+mediaId 重拉
  DanmakuSource? _danmakuSelSource;
  String? _danmakuSelMediaId;
  String? _danmakuSelMediaTitle;
  // Overlay key — 用于强制重建
  final GlobalKey<DanmakuOverlayState> _danmakuKey = GlobalKey<DanmakuOverlayState>();

  // 对齐红果鉴的短剧30秒滑动时间窗调度状态 (danmakuWindowMs = 30000)
  static const int _kDanmakuWindowMs = 30000;
  final Set<int> _loadedDanmakuWindows = <int>{};
  bool _danmakuWindowFetching = false;
  int _lastSyncedDanmakuPosMs = -1;
  String _currentMatchedDramaSeriesId = '';
  List<String> _currentMatchedVidList = const [];

  // v2.5.51: 弹幕预搜索 — 进播放页时后台并发搜索 6 源 (移植 SeleneTV t14.java:741)
  //   "进播放页并发搜索, 命中源进「弹幕源」切换; 一次只渲染一个源"
  //   用户点弹幕按钮时直接使用预搜索结果, 无需等待
  List<DanmakuMedia> _danmakuPreSearchResults = const [];
  bool _danmakuPreSearching = false;
  bool _danmakuPreSearchDone = false;

  // UI 控制
  bool _isPlaying = false;
  bool _isControlsVisible = true;
  bool _isFavorite = false;
  double _playbackRate = 1.0;
  // 用户拖动进度条时的临时值(避免 stream 把进度覆盖回去)
  double? _scrubbingValue;
  // v2.5.20: widget 正在销毁中, 阻止所有 stream listener 的副作用 (切集 / autoPlay / setState)
  bool _isDisposing = false;
  // v2.5.20: 中间区域水平拖动的 seek 节流
  //   v2.6.2 重写: 之前用 cancel+restart 100ms timer, 长滑动时每帧
  //   (60-120 次/秒) 都 cancel 同一个 timer, timer 永远不 fire,
  //   ExoPlayer 一帧都不 seek, 长滑动看起来"不动". 改用"first-fire
  //   + skip"模式: 第一次立刻 fire, 之后 30ms 内 skip (不 restart),
  //   30ms 后才允许再 fire. 保证 30ms 至少一次 seek, 用户能实时
  //   看到进度跟随手指. 短滑动 (30ms 内) 一次 seek 到位, 跟之前一样.
  Timer? _centerSwipeSeekThrottle;
  bool _centerSwipeThrottleBusy = false;
  // v2.6.2: 滑动起始 position + 累计 delta, 用绝对位置算 newMs,
  //   不依赖 _currentPosition (position stream 会用旧值覆盖).
  //   长滑动时 position stream 跟用户的预期对不上, 用绝对定位就
  //   不会有"松手后跳回去"的问题.
  Duration? _swipeStartPosition;
  double _swipeCumulativeDx = 0;
  // v2.6.2: 滑动中锁 — position stream 和 100ms 轮询在用户拖动期间
  //   不能覆盖 _currentPosition, 否则进度条会"来回调" (stream 用
  //   实际播放位置覆盖了用户拖到的位置, 下一次 update 又从实际位置
  //   开始算, 累计漂移). end 时解锁.
  bool _isSwiping = false;
  // 底部栏水平拖动 (拖进度条) — 起始 progress value + 底部栏宽度, 用来 delta → value 换算
  //   v2.5.86 新增. 中间区域水平拖动是按"整屏 60s/半屏"算, 底部栏只占屏幕
  //   60%~85% 宽, 用底部栏宽度算才准. 拖动过程中更新 _scrubbingValue
  //   (Slider 同步), 节流 seek, end 时 flush.
  double? _bottomBarDragStartValue;
  double? _bottomBarDragStartWidth;
  Timer? _bottomBarSwipeThrottle;
  // v2.5.90: seek guard 已移除 — 它阻止 position stream 和 100ms 轮询更新
  //   _currentPosition, 导致进度条不动. 回到 v2.5.86 行为: seek 后立即设
  //   _currentPosition 为目标值, position stream 正常更新 (即使短暂跳回
  //   旧位置, ExoPlayer seek 完成后会恢复).
  // int? _seekGuardMs;
  // Timer? _seekGuardTimer;
  // v2.5.20: playingStream / completedStream / bufferingStream 的 subscription 字段
  //   之前 v2.3.14 ~ v2.5.19 这 3 个 listener 没存字段, dispose 时没法 cancel,
  //   切集 / 退出时残留 listener 触发业务逻辑 (_autoPlayNextEpisode) 跟新 episode 打架
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<bool>? _completedSub;
  // 控制栏自动隐藏定时器
  Timer? _hideControlsTimer;

  // 倍速档位
  // v2.6.58: 倍速档位 — 0.5X/0.75X/1X/1.25X/1.5X/1.75X/2X
  static const List<double> _playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  // 全屏状态
  bool _isFullscreen = false;
  // 全屏鼠标光标自动隐藏状态与定时器
  bool _hideMouseCursor = false;
  Timer? _mouseHideTimer;

  // 下一季/推荐自动连播状态 (类似 YouTube / Netflix 居中海报弹窗与5秒自动播放)
  NextSeasonCandidate? _nextSeasonCandidate;
  bool _isPreloadingNextSeason = false;
  bool _showNextSeasonOverlay = false;
  bool _nextSeasonDismissedThisEp = false;
  int _nextSeasonCountdownSec = 5;
  Timer? _nextSeasonTimer;

  // 防连跳状态锁与时间戳 (彻底根治播放第一集跳转第二集时连跳两集)
  bool _isEpisodeSwitching = false;
  int _lastEpisodeSwitchTimeMs = 0;

  // 快进/快退提示文字 (点击后短暂显示, 如 "快进6s")
  String? _seekHintText;
  Timer? _seekHintTimer;

  // 亮度/音量手势 (v1.0.40 修复: 主播放器之前根本没接手势层)
  double _currentVolume = 0.5; // 0.0 ~ 1.0
  // v2.5.18: 物理静音键缓存 — 静音切到 0 时缓存原音量, 再次按 mute
  //   恢复. 跟系统默认 mute 行为一致.
  double? _volumeBeforeMute;
  double _currentBrightness = 0.5;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  Timer? _volumeHideTimer;
  Timer? _brightnessHideTimer;
  double? _dragStartVolume; // 拖动开始时的音量基线
  double? _dragStartBrightness;
  // v1.0.45: 累计拖动 delta, 解决 v1.0.40 "每事件用 baseline + 单帧 delta 覆盖" 的 bug
  // (以前 5 帧累计拖 100px, 每帧只算自己 20px, 实际只反映最后 1 帧的 delta)
  double _totalDragVolumeDelta = 0;
  double _totalDragBrightnessDelta = 0;

  // LunaTV Web 主题色
  static const Color kLunaTheme = Color(0xFF22C55E);
  static const Color kLunaLoadingColor = Color(0xFF009688);
  static const Color kLunaFloatBtnBg = Color(0x26FFFFFF);

  // v2.2.0+59: 屏幕常亮 MethodChannel (Android 端 KeepScreenOnChannel.kt 配对).
  //   ExoPlayer 默认不会阻止系统屏保, 播放超过系统超时时间 (默认 30s-1min)
  //   屏幕就熄, 用户反馈「播放一会会屏保」就是这个问题. 调用 enable=true 给
  //   Activity 加 FLAG_KEEP_SCREEN_ON, 离开播放页 / dispose 时 enable=false
  //   清除, 恢复系统默认. Activity 不可见 (切后台 / 锁屏) OS 自动失效, 不用
  //   手动管 lifecycle.
  static const MethodChannel _keepScreenOnChannel =
      MethodChannel('org.moontechlab.lunatv/keep_screen_on');

  @override
  void initState() {
    super.initState();
    // v2.2.0 / v2.6.80+: 异步初始化播放器并记录 Future，守门避免快速点起播重复重建
    _initPlayerFuture = _initPlayerAsync();
    // v2.0.51: 选集 PageView 初始化
    _episodesPageController = PageController();
    _pageControllerNotifier.value = _episodesPageController;
    // v1.0.50: 监听 AppLifecycleState, 进后台 (home 键) 时立即保存一次,
    // 避免 10s progressTimer 还没触发就被上滑/杀进程, 进度丢
    WidgetsBinding.instance.addObserver(this);
    // v2.6.42: 音量拦截只在 playing 阶段开启, detail 阶段保留系统音量弹窗.
    //   initState 只注册 MethodCallHandler (接收 native 回调), 不调
    //   setEnabled(true) — detail 页物理音量键走系统默认 (弹音量条是合理
    //   的系统反馈). 进入 playing 阶段时 _enableVolumeInterception() 开,
    //   退出回 detail 时 _disableVolumeInterception() 关. dispose 兜底清.
    _volumeKeyChannel.setMethodCallHandler(_onVolumeKeyCall);
    // ★ v2.5.65: 进入播放页时解锁所有方向 (让设备自由旋转, 平板/手机都友好)
    unawaited(SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    // 注意: volume_controller v2.x / screen_brightness v0.2.x 都是单例 .instance API
    () async {
      try {
        final vol = await VolumeController.instance.getVolume();
        if (mounted && vol != null) setState(() => _currentVolume = vol);
      } catch (_) {}
      try {
        final br = await ScreenBrightness().current;
        if (mounted && br != null) setState(() => _currentBrightness = br);
      } catch (_) {}
    }();
    // v2.0.93: 后台调 TMDB search + fetchArt 拿 w1280 backdrop, 完成后
    //   setState 触发 DoubanDetailHeader rebuild 用 TMDB backdrop 替
    //   代豆瓣 coverUrl. 没配 key / 搜索失败 / 抓不到 backdrop = null,
    //   DoubanDetailHeader 走 coverUrl 兜底, 行为完全不变.
    //   不 await — fire-and-forget, 用户不卡, 加载完 DoubanDetailHeader
    //   自动切到更清的 TMDB backdrop.
    _loadTmdbBackdrop();
    // v2.1.7: 拉豆瓣剧情简介 (跟 _loadTmdbBackdrop 同样静默 fallback)
    _loadDoubanSummary();
    // v2.1.17: 拉 TMDB 演员 (跟 _loadTmdbBackdrop 同样静默 fallback)
    _loadTmdbCast();
    // v2.6.93: 加载智能片头配置与片段 (TheIntroDB + TMDB 代理)
    _loadSmartSkipConfig();
    _loadSmartSkipSegmentsForCurrentEpisode();
    // 加载倍速持久化
    _loadPlaybackRate();
    // v2.5.36: 加载弹幕设置 (移植自 SeleneTV SharedPreferences)
    unawaited(DanmakuSettings.instance.load().then((_) {
      if (mounted) {
        setState(() {
          _danmakuEnabled = DanmakuSettings.instance.isDanmakuEnabled;
        });
      }
    }));
    // v2.5.51: 弹幕预搜索 — 进播放页时后台并发搜索 6 源
    //   移植 SeleneTV: "进播放页并发搜索, 命中源进「弹幕源」切换"
    //   用户点弹幕按钮时直接使用预搜索结果, 实现秒开
    unawaited(_preSearchDanmakuSources());
    // 加载收藏状态
    _loadFavorite();
    // 一集播完自动播下一集 (避免用户点下一集的繁琐)
    // v2.4.7: 源浏览器点播放直接传 initialDetail (含 episodes), 跳过
    //   _loadSources (会调 /api/search 全源搜索), 直接用当前源播.
    //   用户反馈 "点击播放后应该直接播放当前源不应该再跳转到播放详情页
    //   去搜索源". 单源模式不跑测速 (只有一个源, 测了也没意义).
    if (widget.initialDetail != null) {
      setState(() {
        _sourceResults = [widget.initialDetail!];
        _sourcesLoading = false;
        _error = null;
      });
      _selectSource(widget.initialDetail!);

      // 对齐红果鉴：短剧专区点击卡片进入后直接起播，消除停留详情页与繁琐点击等待
      final isShortDrama = widget.videoInfo.source == 'hongguo' ||
          widget.videoInfo.source == 'shortdrama' ||
          widget.preferredSource == 'hongguo' ||
          widget.preferredSource == 'shortdrama';
      if (isShortDrama) {
        // 关键自愈：异步根据真实章节列表精确对齐总集数，动态刷新选集网格 (消除假80集上限)
        unawaited(() async {
          try {
            final dramaId = widget.videoInfo.id.isNotEmpty
                ? widget.videoInfo.id
                : widget.initialDetail!.id;
            final realVidList =
                await DuanjuCoreBridge.instance.fetchEpisodeVidList(dramaId);
            if (mounted &&
                realVidList.isNotEmpty &&
                realVidList.length != _selectedSource?.episodes.length) {
              final realCount = realVidList.length;
              final updatedEps =
                  List.generate(realCount, (i) => (i + 1).toString());
              final updatedTitles =
                  List.generate(realCount, (i) => '第${i + 1}集');
              setState(() {
                if (_selectedSource != null) {
                  _selectedSource!.episodes.clear();
                  _selectedSource!.episodes.addAll(updatedEps);
                  _selectedSource!.episodesTitles.clear();
                  _selectedSource!.episodesTitles.addAll(updatedTitles);
                }
                if (_sourceResults.isNotEmpty) {
                  _sourceResults[0].episodes.clear();
                  _sourceResults[0].episodes.addAll(updatedEps);
                  _sourceResults[0].episodesTitles.clear();
                  _sourceResults[0].episodesTitles.addAll(updatedTitles);
                }
              });
            }
          } catch (_) {}
        }());

        // 短剧进入后保持就绪待播状态，由用户主动点击「立即播放」或选择具体集数时起播
      }
    } else {
      _loadSources();
    }
  }

  /// 异步初始化播放器 (短剧或桌面端采用 DuanjuMediaKitBackend，移动端非短剧维持原有 ExoPlayerBackend)
  Future<void> _initPlayerAsync() async {
    final isShortDrama = widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama' ||
        widget.preferredSource == 'hongguo' ||
        widget.preferredSource == 'shortdrama';
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);

    try {
      if (isShortDrama || isDesktop) {
        _player = await DuanjuMediaKitBackend.create();
      } else {
        _player = await ExoPlayerBackend.create();
      }
    } catch (e, st) {
      DiaryService.add('[Player] init FAIL: isShortDrama=$isShortDrama, error=$e\n$st');
      return;
    }
    _bindPlayerListeners();

    // 短剧进入时立刻在后台异步预拉取当前集与下一集的播放计划，消除首播等待
    if (isShortDrama) {
      final dramaId = widget.videoInfo.id.isNotEmpty
          ? widget.videoInfo.id
          : (_selectedSource?.id ?? '');
      if (dramaId.isNotEmpty) {
        unawaited(DuanjuCoreBridge.instance.prefetchEpisode(dramaId, _currentEpisodeIndex + 1));
        unawaited(DuanjuCoreBridge.instance.prefetchEpisode(dramaId, _currentEpisodeIndex + 2));
      }
    }

    // ★ v2.5.65: 高精度进度条轮询 (100ms 一次, 让白点跟实际位置同步)
    _positionPollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isDisposing || !mounted || _scrubbingValue != null) return;
      if (_isSwiping) return;
      if (!_isPlaying) return;
      final newPos = _player?.position ?? Duration.zero;
      if (newPos != _currentPosition && newPos > Duration.zero) {
        setState(() => _currentPosition = newPos);
      }
    });
  }

  /// 绑定播放器状态流监听
  void _bindPlayerListeners() {
    if (_player == null) return;

    _positionSub = _player!.positionStream.listen((pos) {
      if (_isDisposing) return;
      if (!mounted) return;
      // v2.6.2: 滑动中不更新 _currentPosition, 否则 position stream
      //   用"实际播放位置"(旧值)覆盖了用户拖到的位置, 进度条"来回调"
      if (_isSwiping) return;
      if (_scrubbingValue == null) {
        // v2.5.90: seek guard 已移除, position stream 直接更新 _currentPosition
        _currentPosition = pos;
        if (pos > Duration.zero) {
          _lastKnownPosition = pos;
        }
        if (_isControlsVisible) {
          setState(() {});
        }
        // 视频宽高同步
        final w = _player!.width;
        final h = _player!.height;
        if (w > 0 && h > 0 && (w != _videoWidth || h != _videoHeight)) {
          setState(() {
            _videoWidth = w;
            _videoHeight = h;
            if (_availableResolutions.isEmpty) {
              if (h >= 1080) {
                _currentResolution = '1080P';
              } else if (h >= 720) {
                _currentResolution = '720P';
              } else if (h >= 480) {
                _currentResolution = '480P';
              }
            }
          });
        }
        _updateSkipButtonVisibility();
        _maybeAutoPlayNext();
        if (_isCurrentShortDrama && _danmakuEnabled) {
          _maybeStreamShortDramaDanmaku(pos.inMilliseconds);
        }
      }
    });

    _durationSub = _player!.durationStream.listen((dur) {
      if (_isDisposing) return;
      if (!mounted) return;
      _currentDuration = dur;
      if (dur.inSeconds > 60 && !_hasCalibratedSegmentsWithDuration && !_isCurrentShortDrama) {
        _hasCalibratedSegmentsWithDuration = true;
        _loadSmartSkipSegmentsForCurrentEpisode(duration: dur);
      }
    });

    _completedSub = _player!.completedStream.listen((_) {
      if (_isDisposing) return;
      _autoPlayNextEpisode();
    });

    _playingSub = _player!.playingStream.listen((playing) {
      if (_isDisposing) return;
      if (!mounted) return;
      setState(() {
        _isPlaying = playing;
      });
      if (playing) {
        _scheduleHideControls();
      } else {
        _showControls();
      }
    });

    _bufferingSub = _player!.bufferingStream.listen((b) {
      if (_isDisposing) return;
      if (!mounted) return;
      setState(() {
        _isBuffering = b;
      });
    });
  }

  /// 动态平滑切换后端 (当发生跨类型源切换时自愈)
  Future<void> _switchPlayerBackend(bool toShortDrama) async {
    if (_isDisposing) return;
    await _positionSub?.cancel();
    _positionSub = null;
    await _durationSub?.cancel();
    _durationSub = null;
    await _completedSub?.cancel();
    _completedSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;

    try {
      await _player?.dispose();
    } catch (_) {}

    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    try {
      if (toShortDrama || isDesktop) {
        _player = await DuanjuMediaKitBackend.create();
      } else {
        _player = await ExoPlayerBackend.create();
      }
    } catch (e, st) {
      DiaryService.add('[Player] switch FAIL: toShortDrama=$toShortDrama, error=$e\n$st');
      return;
    }

    if (!mounted) return;
    _bindPlayerListeners();
    _initPlayerFuture = null;
    setState(() {});
  }

  @override
  void dispose() {
    // v2.5.20: 守门 flag 第一时间置位, 阻止所有 stream listener 的副作用
    //   (autoPlay / setState / _maybeAutoPlayNext). 之前只判 !mounted,
    //   但 _autoPlayNextEpisode 没判 mounted, 切集时残留 completedStream
    //   listener 触发 autoPlay, 跟新 episode 打架导致诡异 bug
    //   (进度条乱跳 + 播放/暂停图标闪烁 + 退出后 audio 还在播)
    _isDisposing = true;
    // v1.0.50: 退出时最后一次保存, 改成 await 真的完成再 dispose _player
    // 之前是 fire-and-forget, _player!.stop() 同步把 state.position 重置成 0,
    // saveCurrentProgress 那个 fire-and-forget 没机会拿到正确 position 就被 super.dispose 切断
    // (虽然 _currentPosition 兜底有值, 但 PageCacheService().savePlayRecord 走网络
    //  没 await 完进程被上滑/杀就丢, playTime 没写盘)
    // 现在: unawaited + 内部 await 串行 (save → stop → dispose),
    // 进程上滑杀时 OS 给 grace period, 大概率能完成网络写盘
    unawaited(_disposeAndSave());
    _progressTimer?.cancel();
    _smartSkipCountdownTimer?.cancel();
    _nextSeasonTimer?.cancel();
    _positionPollTimer?.cancel(); // ★ v2.5.65
    _hideControlsTimer?.cancel();
    _seekHintTimer?.cancel();
    _centerSwipeSeekThrottle?.cancel();
    _bottomBarSwipeThrottle?.cancel();
    _loadedDanmakuWindows.clear();
    _currentMatchedDramaSeriesId = '';
    _currentMatchedVidList = const [];
    // v2.5.90: seek guard 已移除
    // _clearSeekGuard();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // v2.5.20: 之前 dispose 漏 cancel 这 3 个 listener, 切集 / 退出时残留
    //   listener 还在跑, completedStream 触发 _autoPlayNextEpisode 跟新 episode
    //   打架 (诡异 bug 根因). 现在统一 cancel
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _completedSub?.cancel();
    // v2.0.51: 释放选集 PageView 控制器
    _episodesPageController.dispose();
    _pageControllerNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // 恢复系统UI, 解锁所有方向 (让系统自由旋转)
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    if (DeviceUtils.isWindows()) {
      unawaited(WindowUtils.setFullScreen(false));
    }
    // ★ 解锁方向: 退出播放器后不再强制竖屏, 让系统传感器决定
    unawaited(SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    // v2.6.42: dispose 兜底清理音量拦截 — 正常流程 playing→detail 已经
    //   _disableVolumeInterception() 了, 但 widget 异常销毁 (e.g. build
    //   抛错) 可能跳过. 这里再清一次: showSystemUI=true + setEnabled(false)
    //   + 清 handler, 确保离开播放页后系统音量弹窗恢复正常.
    VolumeController.instance.showSystemUI = true;
    _volumeKeyChannel.setMethodCallHandler(null);
    unawaited(_volumeKeyChannel.invokeMethod<bool>('setEnabled', {'enabled': false}));
    // v2.3.0: 视频加速链路整个删了, 关本地代理 / 状态指示器 / 速度采样 timer
    //   全部删了. dispose 路径上不需要再 _videoProxy?.stop() / cancel timer.
    // v2.2.0+59: dispose 时关掉屏幕常亮. 即便 _phase 已经切到 'detail'
    //   (前面有 setState), 保险起见 dispose 路径也清一次, 防止 widget
    //   异常销毁时漏掉 (e.g. build 阶段抛错走不到上层清理).
    _setKeepScreenOn(false);
    super.dispose();
  }

  /// v2.2.0+59: 控制屏幕常亮.
  ///   进入播放阶段调 enable=true 阻止屏保, 离开/销毁调 enable=false 还原.
  ///   走 Android MethodChannel → Activity.window.addFlags(FLAG_KEEP_SCREEN_ON),
  ///   调用失败 / iOS 上也吞掉 (iOS 默认行为不一样, 不需要 keep screen on).
  void _setKeepScreenOn(bool enable) {
    // fire-and-forget: 不 await, 即便 native 端崩了也不影响播放器.
    // catch 住 PlatformException 避免未捕获异常破坏 widget tree.
    _keepScreenOnChannel.invokeMethod(
      'setKeepScreenOn',
      <String, dynamic>{'enable': enable},
    ).catchError((Object e) {
      // iOS 上没注册这个 channel, 调会抛 MissingPluginException, 静默吞.
      // 其他错误打条日记便于排查.
      if (e is! PlatformException ||
          !e.code.contains('NOT_IMPLEMENTED')) {
        DiaryService.add(
            '[KeepScreenOn] $enable failed: $e');
      }
    });
  }

  /// v2.6.42: 开启音量拦截 — 进入 playing 阶段调.
  ///   showSystemUI=false 屏蔽系统音量弹窗, setEnabled(true) 让 Kotlin
  ///   端拦截物理音量键转发到 Dart (handler 已在 initState 注册).
  ///   resumed (从后台回来) 也调, 跟 initState 一致.
  void _enableVolumeInterception() {
    VolumeController.instance.showSystemUI = false;
    unawaited(
        _volumeKeyChannel.invokeMethod<bool>('setEnabled', {'enabled': true}));
  }

  /// v2.6.42: 关闭音量拦截 — 退出 playing 阶段回 detail 调.
  ///   showSystemUI=true 恢复系统音量弹窗, setEnabled(false) 让物理音量
  ///   键走系统默认. 不清 handler (dispose 才清).
  void _disableVolumeInterception() {
    VolumeController.instance.showSystemUI = true;
    unawaited(
        _volumeKeyChannel.invokeMethod<bool>('setEnabled', {'enabled': false}));
  }

  /// 退出时串行: save → stop → dispose
  /// dispose 不能 await, 所以用 unawaited 在 dispose 末尾启动
  ///
  /// v1.0.50.1: 加 _phase == 'playing' 守门, 防止 phase=detail 时用
  /// playTime=0 覆盖之前存的真实进度 (根因 3)
  /// 正常流程: 用户看 → 返回键 → onPopInvoked(phase=playing) 已经 save 12 min
  ///   + stop player → phase=detail → 用户再返回 → onPopInvoked(phase=detail)
  ///   走空分支 → widget 销毁 → dispose 调本方法
  ///   此时 player 已经被 stop, state.position=0, _currentPosition=0
  ///   (stop 后 position stream 也会发射 0), 再 save 一次会写 playTime=0,
  ///   覆盖掉 onPopInvoked 存的 12 分钟
  /// 修法: phase=detail 说明 onPopInvoked 已经存过, 这里不再重复 save
  ///       phase=playing 才是上滑杀 App / 系统回收等异常退出, 还要 save
  ///       (最后一次救命机会, 走本地双写兜底)
  Future<void> _disposeAndSave() async {
    if (_phase == 'playing') {
      // v1.0.65: 先等 _currentPosition > 0 再 save, 避免刚 play 就被 kill
      // 时存 0 覆盖之前的真进度
      await _waitForValidPosition();
      if (_currentPosition > Duration.zero || _isCurrentShortDrama || _currentEpisodeIndex > 0) {
        try {
          await _saveCurrentProgress(force: true);
        } catch (_) {}
      }
    }
    // v2.2.0: backend.dispose() 内部 release 整个 player (ExoPlayer.release).
    //   跟 libmpv 时代的 _player!.stop() + _player!.dispose() 等价, 一次到位.
    try {
      await _player?.dispose();
    } catch (_) {}
  }

  /// v1.0.50: App 进后台 (home 键) 时立即保存一次, 防止 10s progressTimer
  /// 还没触发就被上滑/杀进程丢进度
  ///
  /// v1.0.53: 加 `if (_phase != 'playing') return;` 守门
  /// 之前没守门, onPopInvoked 已经 stop player + _phase='detail' 之后
  /// (用户从播放页按返回键回到详情页), 这时再按 home 键 / 切后台 →
  /// didChangeAppLifecycleState(paused) → _saveCurrentProgress(force=true) →
  /// player 已 stop, state.position=0, _currentPosition 已经被 stream 发射 0 重置,
  /// state.playing=false → 条件 `state.playing || (pos > 0 && !state.completed)`
  /// 不满足 → playTime=0 → force=true 跳过 return 守门 → 存一条 playTime=0
  /// **覆盖掉 onPopInvoked 已经存的 12 分钟** → 下次重开从 0 开始
  /// 守门同 _disposeAndSave (v1.0.50.1), 是同模式 bug 的另一条触发路径:
  ///   _disposeAndSave 守了 dispose 路径
  ///   didChangeAppLifecycleState 漏了 paused 路径
  /// 两条路径都会在 player 已 stop 时触发 save, 都会覆盖 0
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // v1.0.53: 守门同 _disposeAndSave. phase!=playing 说明 player 已经被
    // onPopInvoked 停过, 此时 save 必出 0, 必覆盖之前存的真进度
    if (_phase != 'playing') return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // ★ v2.6.44: 熄屏/锁屏时暂停播放
      if (_isPlaying) {
        _player?.pause();
      }
      // v1.0.65: 先等 _currentPosition > 0 再 save, 避免刚 play 就 home
      // 键时存 0 覆盖之前的真进度. 仍然 0 就跳过 (10s 定时器下次兜底)
      _waitForValidPosition().then((_) {
        if (_currentPosition > Duration.zero || _isCurrentShortDrama || _currentEpisodeIndex > 0) {
          // 进后台时立即保存, 走 _saveCurrentProgress 的 force 分支,
          // _currentPosition 兜底能拿到最后一帧有效 position
          unawaited(_saveCurrentProgress(force: true));
        }
      });
    } else if (state == AppLifecycleState.resumed) {
      // v2.6.42: 从后台回来时重新注册音量拦截 — Android 后台/前台切换
      //   时 Flutter 引擎可能重连, 导致 MethodChannel handler 丢失 +
      //   VolumeController.showSystemUI 被 native 层重置. 症状: 切后台
      //   再回来, 物理音量键 Kotlin 端仍拦截 (enabled=true 没丢), 但
      //   invokeMethod 到不了 Dart (handler 丢了), 系统音量条 + 自定义
      //   音量指示器都不弹. 偶发 (短时间切后台 channel 没断就没事).
      //   修法: resumed 时重新 setMethodCallHandler + _enableVolumeInterception()
      //   (showSystemUI=false + setEnabled(true)), 跟进入 playing 阶段一致.
      _volumeKeyChannel.setMethodCallHandler(_onVolumeKeyCall);
      _enableVolumeInterception();
    }
  }

  /// 判断视频是否为竖屏（高度 > 宽度）
  bool get _isPortraitVideo {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoHeight > _videoWidth;
    }
    return false; // 默认横屏
  }

  // ================= 全新智能片头/片尾跳过系统 (v2.6.93) =================

  /// 加载全局智能跳过片头片尾配置
  Future<void> _loadSmartSkipConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _smartSkipEnabled = prefs.getBool('smart_skip_enabled') ?? true;
        _smartSkipMode = prefs.getString('smart_skip_mode') ?? 'manual';
      });
    } catch (_) {}
  }

  /// 保存全局智能跳过片头片尾配置
  Future<void> _saveSmartSkipConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('smart_skip_enabled', _smartSkipEnabled);
      await prefs.setString('smart_skip_mode', _smartSkipMode);
    } catch (_) {}
  }

  /// 智能跳过片段加载 (结合 TMDB 代理服务与 TheIntroDB 接口，支持基于真实时长多版本自适应)
  void _loadSmartSkipSegmentsForCurrentEpisode({Duration? duration}) {
    if (duration == null) {
      _smartSkipCountdownTimer?.cancel();
      _smartSkipCountdownTimer = null;
      _activeSmartSegment = null;
      _dismissedSmartSegmentThisEp = false;
      _hasAutoSkippedThisEp = false;
      _dismissedIntroThisEp = false;
      _dismissedOutroThisEp = false;
      _hasAutoSkippedIntroThisEp = false;
      _hasAutoSkippedOutroThisEp = false;
      _isTransitioningEpisode = false;
      _smartSkipSegments = [];
      _hasCalibratedSegmentsWithDuration = false;
    }

    if (_isCurrentShortDrama) return;

    final epNum = _currentEpisodeIndex + 1;
    final title = widget.videoInfo.title;
    SkipSegmentService.getSegments(
      title: title,
      episode: epNum,
      durationMs: duration?.inMilliseconds,
    ).then((segments) {
      if (!mounted) return;
      if (segments.isNotEmpty) {
        setState(() {
          _smartSkipSegments = segments;
        });
        debugPrint('[SmartSkip] 智能片段就绪: ${segments.length} 个片段 (ep=$epNum, dur=${duration?.inSeconds}s)');
      }
    }).catchError((e) {
      debugPrint('[SmartSkip] 加载异常: $e');
    });
  }

  /// 触发智能跳过动作 (支持片头快速 seek 与片尾丝滑切集)
  void _triggerSmartSkip(SkipSegment seg, {bool isSilent = false}) {
    _smartSkipCountdownTimer?.cancel();
    _smartSkipCountdownTimer = null;
    setState(() {
      _activeSmartSegment = null;
    });

    if (seg.type == SkipSegmentType.outro || seg.type == SkipSegmentType.credits || seg.type == SkipSegmentType.preview) {
      _hasAutoSkippedOutroThisEp = true;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_isTransitioningEpisode || _isEpisodeSwitching) return;
      if (now - _lastEpisodeSwitchTimeMs < 2500) return; // 2.5s 硬防抖拦截
      _isTransitioningEpisode = true;
      _isEpisodeSwitching = true;
      _lastEpisodeSwitchTimeMs = now;

      final source = _selectedSource;
      final nextIndex = _currentEpisodeIndex + 1;
      final hasNextEpisode = source != null && nextIndex < source.episodes.length;

      if (hasNextEpisode) {
        _autoPlayedThisEpisode = true;
        try {
          _player?.pause();
        } catch (_) {}
        if (!isSilent) {
          _toast('已跳过片尾，正在播放第 ${nextIndex + 1} 集');
        }
        unawaited(() async {
          try {
            await _playEpisode(nextIndex);
          } catch (e) {
            debugPrint('[SmartSkip] 切集失败: $e');
          } finally {
            if (mounted) {
              setState(() {
                _isTransitioningEpisode = false;
              });
            } else {
              _isTransitioningEpisode = false;
            }
          }
        }());
      } else {
        _isTransitioningEpisode = false;
        if (_nextSeasonCandidate != null && !_nextSeasonDismissedThisEp) {
          _triggerNextSeasonOverlay();
        } else {
          if (!isSilent) {
            _toast('本剧已是最后一集');
          }
          final dur = _currentDuration.inSeconds;
          if (dur > 0) {
            _player?.seek(Duration(seconds: dur));
          }
        }
      }
    } else {
      _hasAutoSkippedIntroThisEp = true;
      final targetSec = (seg.endMs / 1000).ceil();
      if (targetSec > 0) {
        _player?.seek(Duration(seconds: targetSec));
        if (!isSilent) {
          _toast('已跳过片头，进入正片');
        }
      }
    }
  }

  /// 用户主动取消/关闭本次智能跳过提示
  void _dismissSmartSkip() {
    _smartSkipCountdownTimer?.cancel();
    _smartSkipCountdownTimer = null;
    final seg = _activeSmartSegment;
    setState(() {
      if (seg != null && (seg.type == SkipSegmentType.outro || seg.type == SkipSegmentType.credits || seg.type == SkipSegmentType.preview)) {
        _dismissedOutroThisEp = true;
      } else {
        _dismissedIntroThisEp = true;
      }
      _dismissedSmartSegmentThisEp = true;
      _activeSmartSegment = null;
    });
  }

  /// 根据播放器当前进度检测并更新跳过胶囊浮层 (精准打点 + 90秒通用片头/片尾智能兜底)
  void _updateSkipButtonVisibility() {
    if (!_smartSkipEnabled || _scrubbingValue != null || _isTransitioningEpisode) {
      if (_activeSmartSegment != null) {
        _smartSkipCountdownTimer?.cancel();
        _smartSkipCountdownTimer = null;
        setState(() => _activeSmartSegment = null);
      }
      return;
    }

    final posSec = _currentPosition.inSeconds;
    final durSec = _currentDuration.inSeconds;
    final posMs = _currentPosition.inMilliseconds;
    final durMs = _currentDuration.inMilliseconds;

    // 短剧或总时长小于 60 秒的视频不进行片头跳过兜底
    if (durSec <= 60 || _isCurrentShortDrama) {
      if (_activeSmartSegment != null) {
        _smartSkipCountdownTimer?.cancel();
        _smartSkipCountdownTimer = null;
        setState(() => _activeSmartSegment = null);
      }
      return;
    }

    final hasNextEpisode = _selectedSource != null &&
        _currentEpisodeIndex < _selectedSource!.episodes.length - 1;

    SkipSegment? matched;

    // 1. 优先从 TheIntroDB / IntroDB.app 云端精准打点匹配 (对齐 SeleneTV: 片尾 credits/outro/preview 延展至视频末尾)
    if (_smartSkipSegments.isNotEmpty) {
      for (final seg in _smartSkipSegments) {
        final isOutroType = seg.type == SkipSegmentType.outro ||
            seg.type == SkipSegmentType.credits ||
            seg.type == SkipSegmentType.preview;
        final effectiveEnd = isOutroType
            ? (durMs > seg.startMs ? durMs : seg.endMs)
            : (seg.endMs > 0 ? seg.endMs : durMs);
        if (posMs >= seg.startMs && posMs < effectiveEnd) {
          matched = isOutroType
              ? SkipSegment(type: SkipSegmentType.outro, startMs: seg.startMs, endMs: effectiveEnd)
              : seg;
          break;
        }
      }
    }

    // === 剪辑源与时间轴异常智能保护 (Trimmed-Source Protection) ===
    // 很多影视站切片源/压制源已由压制者剪掉了片头或片尾。
    // 如果盲目按云端原版打点自动跳过片头，会导致直接误跳正片前几十秒！
    SkipSegment? refIntro;
    SkipSegment? refOutro;
    for (final s in _smartSkipSegments) {
      if (s.type == SkipSegmentType.intro || s.type == SkipSegmentType.recap) {
        refIntro ??= s;
      } else if (s.type == SkipSegmentType.outro || s.type == SkipSegmentType.credits || s.type == SkipSegmentType.preview) {
        refOutro ??= s;
      }
    }

    // 智能识别剪辑源：
    // 1) 云端记录了片尾起点 refOutro.startMs，但当前视频总时长 durMs 显著小于片尾起点 (短了 15 秒以上)：
    //    说明本视频不是原版完整流，正片时间轴严重前移或被删减，片头大概率早被切掉！
    // 2) 视频总时长的缩短量与片头时长高度重合 (误差在 35 秒以内)：
    //    例如：原片尾在 2580s，原片头有 90s。当前 durMs 约为 2490s 左右，
    //    确凿判定本视频剪去了片头，开头 0s 处直接就是正片！
    bool isSuspectedTrimmedSource = false;
    if (refOutro != null && durMs > 60000) {
      if (durMs < refOutro.startMs - 15000) {
        isSuspectedTrimmedSource = true;
      } else if (refIntro != null) {
        final introDur = refIntro.endMs - refIntro.startMs;
        if (introDur > 25000) {
          final diff = (refOutro.startMs - durMs) - introDur;
          if (diff.abs() < 35000) {
            isSuspectedTrimmedSource = true;
          }
        }
      }
    }

    // 3. 状态判定与倒计时调度 (防抖保护：同一片段区间内严禁重启计时器)
    if (matched != null) {
      final isOutro = matched.type == SkipSegmentType.outro ||
          matched.type == SkipSegmentType.credits ||
          matched.type == SkipSegmentType.preview;

      // 检查当前片段类型是否被用户主动取消
      if (isOutro && _dismissedOutroThisEp) return;
      if (!isOutro && _dismissedIntroThisEp) return;

      // ★ 剪辑源保护核心逻辑：
      // 如果是疑似剪辑源且当前命中片头：
      // 绝对禁止任何形式的自动跳过 (包括 instant 瞬跳与 countdown 倒计时自动触发)！
      // 自动降级为安全手动提示 (胶囊显示“跳过片头(疑似已剪切)”，用户若手动点击可跳；不点则 5 秒后胶囊自然淡出，正片正常播)
      final isTrimmedIntro = !isOutro && isSuspectedTrimmedSource;

      // 立即跳过模式：非剪辑源片头与片尾独立判定，绝不互斥！
      if (_smartSkipMode == 'instant') {
        if (!isTrimmedIntro) {
          if (isOutro && !_hasAutoSkippedOutroThisEp) {
            _triggerSmartSkip(matched, isSilent: true);
          } else if (!isOutro && !_hasAutoSkippedIntroThisEp) {
            _triggerSmartSkip(matched, isSilent: true);
          }
          return;
        }
        // 剪辑源片头在 instant 模式下拦截瞬跳，向下进入胶囊提示分支，杜绝误杀正片
      }

      // 如果当前是片尾，且已经自动跳过过本集片尾，不再弹窗打扰
      if (isOutro && _hasAutoSkippedOutroThisEp) return;
      // 如果当前是片头，且已经自动跳过过本集片头，不再弹窗打扰
      if (!isOutro && _hasAutoSkippedIntroThisEp) return;

      // 核心防抖判定：如果当前已有激活片段，且类型与起始时间重合，视为同一片段，严禁重复启动或重置倒计时！
      final isSameSegment = _activeSmartSegment != null &&
          _activeSmartSegment!.type == matched.type &&
          (_activeSmartSegment!.startMs - matched.startMs).abs() < 5000;

      if (!isSameSegment) {
        _activeSmartSegment = isTrimmedIntro
            ? matched.copyWith(isSuspectedTrimmed: true)
            : matched;
        _smartSkipCountdownSec = 5;
        _smartSkipCountdownTimer?.cancel();

        // 按钮显示 5s，启动倒计时调度
        if (_smartSkipMode == 'manual' || _smartSkipMode == 'countdown' || isTrimmedIntro) {
          _smartSkipCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
            if (!mounted) {
              timer.cancel();
              return;
            }
            if (_isTransitioningEpisode) {
              timer.cancel();
              return;
            }
            if (_smartSkipCountdownSec > 1) {
              setState(() {
                _smartSkipCountdownSec--;
              });
              debugPrint('[SmartSkip] 按钮倒计时: $_smartSkipCountdownSec s (mode=$_smartSkipMode, trimmed=$isTrimmedIntro)');
            } else {
              timer.cancel();
              _smartSkipCountdownTimer = null;
              if (_smartSkipMode == 'manual' || isTrimmedIntro) {
                // 5s后按钮自动平滑消失！绝不强行跳转，绝不误跳正片！
                debugPrint('[SmartSkip] 手动模式/剪辑源：5s到期，按钮自动平滑消失，正片继续顺畅播放');
                setState(() {
                  _activeSmartSegment = null;
                  if (isOutro) {
                    _dismissedOutroThisEp = true;
                  } else {
                    _dismissedIntroThisEp = true;
                  }
                });
              } else {
                // countdown 模式：5s倒计时归零，自动执行跳过
                debugPrint('[SmartSkip] 倒计时归零，自动执行跳过');
                final segToSkip = _activeSmartSegment ?? matched;
                if (segToSkip != null) {
                  _triggerSmartSkip(segToSkip);
                }
              }
            }
          });
        }
        setState(() {});
      }
    } else {
      // 走出片头/片尾区间，清理胶囊与定时器
      // ★ 关键加固：如果当前激活的是片尾且倒计时正在运行，只要不是大幅往回拖动，绝不允许瞬时波动清空倒计时！
      final isOutroActive = _activeSmartSegment != null &&
          (_activeSmartSegment!.type == SkipSegmentType.outro ||
           _activeSmartSegment!.type == SkipSegmentType.credits ||
           _activeSmartSegment!.type == SkipSegmentType.preview);
      final isPlayingInActiveOutro = isOutroActive && posMs >= _activeSmartSegment!.startMs;

      if (isOutroActive && isPlayingInActiveOutro && !_dismissedOutroThisEp && !_hasAutoSkippedOutroThisEp) {
        // 片尾正在倒计时中，保持常驻锁定，不被瞬时波动截断
        return;
      }

      if (_activeSmartSegment != null) {
        _activeSmartSegment = null;
        _smartSkipCountdownTimer?.cancel();
        _smartSkipCountdownTimer = null;
        setState(() {});
      }
    }
  }

  /// 打开智能跳过片头片尾设置弹窗 (彻底废弃旧版通用盲跳兜底)
  Future<void> _showSmartSkipSettingsDialog() async {
    bool enabled = _smartSkipEnabled;
    String mode = _smartSkipMode;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.fast_forward_rounded, color: kLunaTheme, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    '智能跳过片头片尾',
                    style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用智能跳过', style: TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: const Text(
                        '基于 TheIntroDB / IntroDB 全球云端打点，电影综艺绝不误跳',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      value: enabled,
                      activeColor: kLunaTheme,
                      onChanged: (v) => setDialogState(() => enabled = v),
                    ),
                    if (enabled) ...[
                      const Divider(color: Colors.white24, height: 20),
                      const Text('跳过方式', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('手动跳过片头片尾 (默认推荐)', style: TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: const Text('进入片头片尾显示按钮 5s，5s后自动消失，点击立即跳过', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        value: 'manual',
                        groupValue: mode,
                        activeColor: kLunaTheme,
                        onChanged: (v) => setDialogState(() => mode = v!),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('5秒倒计时自动跳过', style: TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: const Text('右下角倒计时 5s，倒计时结束自动快进或切集', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        value: 'countdown',
                        groupValue: mode,
                        activeColor: kLunaTheme,
                        onChanged: (v) => setDialogState(() => mode = v!),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('立即自动跳过 (无感)', style: TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: const Text('到片头片尾直接快进或切集，不弹倒计时', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        value: 'instant',
                        groupValue: mode,
                        activeColor: kLunaTheme,
                        onChanged: (v) => setDialogState(() => mode = v!),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.verified_user_rounded, color: kLunaTheme, size: 16),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '已彻底禁用本地通用盲跳兜底，100% 依循全球云端真实打点数据。内置剪辑源自适应防护：当检测到源已被剪掉片头（时长异常），自动拦截盲跳并降级为手动提示，绝不吃掉正片开头。',
                                style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.3),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消', style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _smartSkipEnabled = enabled;
                      _smartSkipMode = mode;
                    });
                    _saveSmartSkipConfig();
                    Navigator.pop(ctx);
                  },
                  child: Text('保存', style: TextStyle(color: kLunaTheme)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 打开集数选择底部面板
  Future<void> _showEpisodeSelectorSheet() async {
    final source = _selectedSource;
    if (source == null || source.episodes.isEmpty) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.65,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '选集 (${source.episodes.length}集) · 当前第${_currentEpisodeIndex + 1}集',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 10),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final w = constraints.maxWidth;
                      int crossAxisCount;
                      if (w < 500) {
                        crossAxisCount = 5;
                      } else if (w < 800) {
                        crossAxisCount = 8;
                      } else if (w < 1100) {
                        crossAxisCount = 10;
                      } else {
                        crossAxisCount = 12;
                      }

                      // 高性能精准定位：计算当前集所在垂直行，自动生成初次滚动偏移，杜绝多集短剧滑动卡顿
                      final cardWidth = (w - (crossAxisCount - 1) * 8) / crossAxisCount;
                      final cardHeight = cardWidth / 1.2;
                      final rowHeight = cardHeight + 8;
                      final currentRow = _currentEpisodeIndex ~/ crossAxisCount;
                      final initialOffset = (currentRow * rowHeight - 60.0).clamp(0.0, double.infinity);
                      final scrollController = ScrollController(initialScrollOffset: initialOffset);

                      return GridView.builder(
                        controller: scrollController,
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        cacheExtent: 300,
                        itemCount: source.episodes.length,
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 1.2,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemBuilder: (ctx, index) {
                          final isCurrent = index == _currentEpisodeIndex;
                          return RepaintBoundary(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _playEpisode(index);
                                },
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: isCurrent
                                        ? const Color(0xFF22C55E)
                                        : const Color(0xFF374151),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: isCurrent
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 14,
                                      fontWeight: isCurrent
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 进入全屏：隐藏系统UI + 根据视频宽高比设置屏幕方向
  Future<void> _onEnterFullscreen() async {
    setState(() => _isFullscreen = true);
    _resetMouseHideTimer();
    if (DeviceUtils.isWindows()) {
      await WindowUtils.setFullScreen(true);
      return;
    }
    // 隐藏系统UI（状态栏、导航栏）
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
    // 根据视频宽高比设置方向
    if (_isPortraitVideo) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 退出全屏：恢复系统UI + 解锁方向 (让系统自由旋转)
  Future<void> _onExitFullscreen() async {
    _mouseHideTimer?.cancel();
    setState(() {
      _isFullscreen = false;
      _hideMouseCursor = false;
    });
    if (DeviceUtils.isWindows()) {
      await WindowUtils.setFullScreen(false);
      return;
    }
    // 恢复系统UI
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    // ★ 解锁所有方向, 让系统传感器决定 (不再强制竖屏)
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// 全屏下用户活动（移动鼠标/点击）唤醒光标并重置隐藏倒计时
  void _onUserActivity() {
    if (_hideMouseCursor) {
      setState(() => _hideMouseCursor = false);
    }
    _resetMouseHideTimer();
  }

  /// 重置鼠标光标3秒自动隐藏定时器
  void _resetMouseHideTimer() {
    _mouseHideTimer?.cancel();
    if (_isFullscreen) {
      _mouseHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _isFullscreen) {
          setState(() => _hideMouseCursor = true);
        }
      });
    }
  }

  /// 键盘快捷键调节音量 (向上/向下键)
  void _adjustVolumeByStep(double delta) {
    if (_isDisposing) return;
    final newVol = (_currentVolume + delta).clamp(0.0, 1.0);
    setState(() {
      _currentVolume = newVol;
      _showVolumeIndicator = true;
    });
    try {
      VolumeController.instance.setVolume(newVol);
    } catch (_) {}
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
    _showControlTemporarily();
    _onUserActivity();
  }

  /// 键盘快捷键调节进度 (向左/向右键)
  void _seekRelative(Duration delta) {
    if (_isDisposing || _player == null) return;
    final dur = _totalDuration;
    if (dur <= Duration.zero) return;
    final newPos = _currentPosition + delta;
    final clampedMs = newPos.inMilliseconds.clamp(0, dur.inMilliseconds);
    final finalPos = Duration(milliseconds: clampedMs);
    setState(() {
      _currentPosition = finalPos;
      _seekHintText = '${_formatDuration(finalPos)} / ${_formatDuration(dur)}';
      _showSeekHint = true;
    });
    unawaited(_player!.seek(finalPos));
    _onDanmakuSeek(clampedMs);
    _updateSkipButtonVisibility();
    _seekHintTimer?.cancel();
    _seekHintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showSeekHint = false);
    });
    _showControlTemporarily();
    _onUserActivity();
  }

  /// 键盘空格键播放/暂停
  void _handleSpaceKey() {
    _togglePlayPause();
    _showControlTemporarily();
    _onUserActivity();
  }

  // ================= UI 控制 =================

  /// 切换播放/暂停
  void _togglePlayPause() {
    if (_isDisposing) return;
    // v2.5.20: 立即乐观更新 _isPlaying, 避免 stream 延迟导致 UI 跟点击不同步
    //   (之前完全靠 playingStream 推, 网络抖动 / ExoPlayer message queue 忙时
    //    stream 推迟发射, 用户连点暂停/播放, 状态错乱, 进度条 / 播放按钮闪烁)
    final wantPlay = !_isPlaying;
    setState(() => _isPlaying = wantPlay);
    if (wantPlay) {
      unawaited(_player!.play());
    } else {
      unawaited(_player!.pause());
    }
  }

  /// 设置倍速
  void _setPlaybackRate(double rate) {
    _player!.setSpeed(rate);
    setState(() => _playbackRate = rate);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('player_playback_rate', rate);
    });
  }

  /// 加载倍速持久化
  Future<void> _loadPlaybackRate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rate = prefs.getDouble('player_playback_rate') ?? 1.0;
      if (mounted) {
        setState(() => _playbackRate = rate);
        _player!.setSpeed(rate);
      }
    } catch (_) {}
  }

  // v2.5.34: 轻量 toast — 弹幕加载用, 不打断用户
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      ),
    );
  }

  // v2.5.49: 弹幕按钮 → 弹出控制面板 (开关 + 源列表 + 设置入口)
  //   不再直接开关, 而是弹出面板让用户看到源选择和设置
  Future<void> _showDanmakuPanel() async {
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }

    await DanmakuControlSheet.show(
      context,
      initiallyEnabled: _danmakuEnabled,
      currentSource: _danmakuSelSource,
      currentMediaId: _danmakuSelMediaId,
      currentMediaTitle: _danmakuSelMediaTitle,
      currentSourceTitle: _danmakuSourceTitle,
      danmakuCount: _danmakuCount,
      videoTitle: widget.videoInfo.title.trim(),
      year: year,
      kind: _kind,
      currentEpisodeIndex: _currentEpisodeIndex,
      preSearchResults: _danmakuPreSearchResults,
      preSearchDone: _danmakuPreSearchDone,
      onDanmakuLoaded: (source, mediaId, mediaTitle, sourceTitle, comments) {
        setState(() {
          _danmakuSelSource = source;
          _danmakuSelMediaId = mediaId;
          _danmakuSelMediaTitle = mediaTitle;
          _danmakuSource = source.key;
          _danmakuSourceTitle = sourceTitle;
          _danmakuCount = comments.length;
          _danmakuComments = comments;
          _danmakuEnabled = true;
        });
        DanmakuSettings.instance.setDanmakuEnabled(true);
        _danmakuKey.currentState?.reset();
      },
      onDanmakuDisabled: () {
        setState(() {
          _danmakuEnabled = false;
          _danmakuComments = const [];
          _danmakuCount = 0;
        });
        DanmakuSettings.instance.setDanmakuEnabled(false);
        _danmakuKey.currentState?.reset();
      },
      onOpenSettings: () {
        DanmakuSettingsSheet.show(
          context,
          onChanged: () {
            _danmakuKey.currentState?.refreshSettings();
          },
        );
      },
    );
  }

  bool get _isCurrentShortDrama {
    return widget.preferredSource == 'hongguo' ||
        widget.preferredSource == 'shortdrama' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama' ||
        widget.videoInfo.id.startsWith('hongguo:') ||
        (_selectedSource?.source == 'hongguo');
  }

  /// 短剧专属弹幕加载方法 (对齐红果鉴：精准定位剧名/季数/单集 + 30秒滑动窗口流水线)
  Future<void> _loadShortDramaDanmaku({bool auto = false, int startMs = 0}) async {
    final title = widget.videoInfo.title.trim();
    final epNum = _currentEpisodeIndex + 1;
    final seasonNum = DuanjuCoreBridge.extractDramaSeason(title) ?? 1;

    String dramaId = _selectedSource?.id.isNotEmpty == true
        ? _selectedSource!.id
        : widget.videoInfo.id;
    dramaId = DuanjuCoreBridge.cleanSeriesId(dramaId);

    // 1. 若当前源不是纯数字红果官方 ID，尝试通过剧名和季数精确定位红果短剧官方 ID 与选集
    List<String> vidList = const [];
    if (_currentMatchedDramaSeriesId.isNotEmpty && _currentMatchedVidList.isNotEmpty) {
      dramaId = _currentMatchedDramaSeriesId;
      vidList = _currentMatchedVidList;
    } else {
      if (dramaId.isNotEmpty) {
        vidList = await DuanjuCoreBridge.instance.fetchEpisodeVidList(dramaId);
      }
      if (vidList.isEmpty && title.isNotEmpty) {
        final match = await DuanjuCoreBridge.instance.matchHongguoDramaInfo(
          title: title,
          season: seasonNum,
        );
        if (match != null) {
          dramaId = match.seriesId;
          vidList = match.vidList;
          _currentMatchedDramaSeriesId = dramaId;
          _currentMatchedVidList = vidList;
        }
      }
    }

    if (title.isNotEmpty && dramaId.isNotEmpty) {
      DuanjuCoreBridge.instance.registerDramaTitle(dramaId, title);
    }

    String vid = '';
    if (vidList.isNotEmpty) {
      final idx = (epNum - 1).clamp(0, vidList.length - 1);
      vid = vidList[idx];
    }

    if (startMs == 0 && !auto) {
      setState(() => _danmakuLoading = true);
    }
    await DiaryService.add('[短剧弹幕] 开始获取: $title 第$seasonNum季 第$epNum集 (dramaId=$dramaId, vid=$vid, window=$startMs)');

    try {
      final totalDurMs = _currentDuration.inMilliseconds > 0 ? _currentDuration.inMilliseconds : 180000;
      final comments = await DuanjuCoreBridge.instance.fetchHongguoDanmakuWindow(
        seriesId: dramaId,
        vid: vid,
        episode: epNum,
        startMs: startMs,
        durationMs: totalDurMs,
        title: title,
      );

      if (!mounted) return;

      final windowKey = (startMs ~/ _kDanmakuWindowMs) * _kDanmakuWindowMs;
      _loadedDanmakuWindows.add(windowKey);
      if (startMs == 0 && comments.isNotEmpty) {
        _loadedDanmakuWindows.addAll([0, 30000, 60000, 90000, 120000, 150000, 180000]);
      }

      // 合并并去重，严格按毫秒时间戳排序
      final merged = <DanmakuComment>[..._danmakuComments];
      for (final c in comments) {
        if (!merged.any((existing) => existing.timeMs == c.timeMs && existing.content == c.content)) {
          merged.add(c);
        }
      }
      merged.sort((a, b) => a.timeMs.compareTo(b.timeMs));

      setState(() {
        _danmakuComments = merged;
        _danmakuCount = merged.length;
        _danmakuEnabled = DanmakuSettings.instance.isDanmakuEnabled;
        _danmakuSource = 'hongguo';
        _danmakuSourceTitle = '短剧 · $title · 第$epNum集';
        _danmakuSelSource = DanmakuSource.hongguo;
        _danmakuSelMediaId = dramaId;
        _danmakuSelMediaTitle = title;
      });

      if (!auto && startMs == 0 && _danmakuEnabled) {
        _toast('弹幕 · 红果短剧 · 第$epNum集 · ${merged.length}条');
      }
      await DiaryService.add('[短剧弹幕] 成功载入第$epNum集官方真实弹幕: ${comments.length}条 (当前总计${merged.length}条, 首条: "${merged.firstOrNull?.content}")');
    } catch (e) {
      if (!mounted) return;
      if (!auto && startMs == 0) _toast('短剧弹幕加载失败');
      debugPrint('[短剧弹幕] 加载异常: $e');
      await DiaryService.add('[短剧弹幕] 加载异常: $e');
    } finally {
      if (mounted && startMs == 0 && !auto) {
        setState(() => _danmakuLoading = false);
      }
    }
  }

  /// 视频播放中驱动短剧弹幕滑动窗口加载 (对齐红果鉴 _ensureWindow)
  void _maybeStreamShortDramaDanmaku(int currentMs) {
    if (!_isCurrentShortDrama || !_danmakuEnabled || _danmakuWindowFetching) return;
    if (currentMs < 0) return;

    final windowStart = (currentMs ~/ _kDanmakuWindowMs) * _kDanmakuWindowMs;

    // 1. 若当前 30 秒窗口尚未加载，立即加载
    if (!_loadedDanmakuWindows.contains(windowStart)) {
      _danmakuWindowFetching = true;
      _loadShortDramaDanmaku(auto: true, startMs: windowStart).whenComplete(() {
        _danmakuWindowFetching = false;
      });
      return;
    }

    // 2. 若当前窗口已加载，且距离该窗口末尾剩余不到 8 秒，流水线式预拉取下一窗口
    final nextWindowStart = windowStart + _kDanmakuWindowMs;
    final totalDur = _currentDuration.inMilliseconds;
    if (totalDur > 0 && nextWindowStart >= totalDur) return;

    if (currentMs >= (windowStart + _kDanmakuWindowMs - 8000)) {
      if (!_loadedDanmakuWindows.contains(nextWindowStart)) {
        _danmakuWindowFetching = true;
        _loadShortDramaDanmaku(auto: true, startMs: nextWindowStart).whenComplete(() {
          _danmakuWindowFetching = false;
        });
      }
    }
  }

  /// 进度条跳跃/Seek 时重置弹幕并对齐新时间
  void _onDanmakuSeek(int newPosMs) {
    if (_isCurrentShortDrama) {
      final diff = (newPosMs - _lastSyncedDanmakuPosMs).abs();
      if (diff > 2000) {
        _lastSyncedDanmakuPosMs = newPosMs;
        _danmakuKey.currentState?.reset();
        _maybeStreamShortDramaDanmaku(newPosMs);
      }
    }
  }

  // v2.5.51: 弹幕预搜索 — 进播放页时后台并发搜索 6 源
  //   移植 SeleneTV t14.java:741 "进播放页并发搜索, 命中源进「弹幕源」切换"
  //   不阻塞播放, 不弹 UI, 纯后台搜索 + 评分
  Future<void> _preSearchDanmakuSources() async {
    if (_danmakuPreSearchDone || _danmakuPreSearching) return;
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) return;

    if (_isCurrentShortDrama) {
      final dramaId = _selectedSource?.id.isNotEmpty == true
          ? _selectedSource!.id
          : widget.videoInfo.id;
      final hongguoMedia = DanmakuMedia(
        source: DanmakuSource.hongguo,
        mediaId: dramaId,
        title: title,
        type: 'tv',
      );
      setState(() {
        _danmakuPreSearchResults = [hongguoMedia];
        _danmakuPreSearching = false;
        _danmakuPreSearchDone = true;
        _danmakuEnabled = DanmakuSettings.instance.isDanmakuEnabled;
      });
      if (_phase == 'playing') {
        unawaited(_loadShortDramaDanmaku(auto: true));
      }
      return;
    }

    setState(() => _danmakuPreSearching = true);
    await DiaryService.add('[弹幕] 预搜索开始: "$title"');
    try {
      final results = await DanmakuManager.instance.searchByTitle(title);
      if (!mounted) return;

      // 用评分算法排序
      int? year;
      final y = widget.videoInfo.year;
      if (y != null && y.isNotEmpty) {
        final m = RegExp(r'^(\d{4})').firstMatch(y);
        if (m != null) year = int.tryParse(m.group(1)!);
      }
      final scored = DanmakuScorer.score(title, results, year: year, type: _kind);

      setState(() {
        _danmakuPreSearchResults = scored.map((e) => e.media).toList();
        _danmakuPreSearching = false;
        _danmakuPreSearchDone = true;
      });
      debugPrint('[Danmaku] pre-search done: ${results.length} results → '
          '${_danmakuPreSearchResults.length} matched');
      await DiaryService.add('[弹幕] 预搜索完成: ${results.length}结果 → '
          '${_danmakuPreSearchResults.length}匹配');
      if (_danmakuPreSearchResults.isNotEmpty) {
        await DiaryService.add('[弹幕] 预搜索最优: '
            '${_danmakuPreSearchResults.first.source.displayName} '
            '"${_danmakuPreSearchResults.first.title}"');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _danmakuPreSearching = false;
        _danmakuPreSearchDone = true;
      });
      debugPrint('[Danmaku] pre-search error: $e');
      await DiaryService.add('[弹幕] 预搜索异常: $e');
    }
  }

  // v2.5.47: 弹幕开关 — 点击后全自动匹配, 不弹手动选择面板
  //   流程: 6源并行搜索 → 评分选最优 → 自动选当前集 → 拉弹幕 → 显示
  //   失败 (无结果/无弹幕) → toast 提示, 不弹面板
  // ★ v2.5.51: 优先使用预搜索结果 (进播放页时已后台搜索), 秒开
  //   预搜索无结果时才 fallback 到实时搜索
  Future<void> _toggleDanmaku() async {
    if (_danmakuLoading) return;

    if (_isCurrentShortDrama) {
      if (_danmakuEnabled) {
        setState(() {
          _danmakuEnabled = false;
          _danmakuComments = const [];
          _danmakuCount = 0;
        });
        _danmakuKey.currentState?.reset();
        _toast('弹幕已关闭');
      } else {
        await _loadShortDramaDanmaku();
      }
      return;
    }

    final source = _selectedSource;
    if (source == null) {
      _toast('请先选源');
      return;
    }
    if (_currentEpisodeIndex < 0 ||
        _currentEpisodeIndex >= source.episodes.length) {
      _toast('当前集无效');
      return;
    }

    // 推断类型 + 年份
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }
    final kind = _kind;

    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) {
      _toast('标题为空,无法搜索');
      return;
    }

    setState(() => _danmakuLoading = true);

    try {
      // 1) 优先使用预搜索结果 (v2.5.51)
      //    如果预搜索还在进行中, 等它完成
      List<DanmakuMedia> results;
      if (_danmakuPreSearchDone) {
        results = _danmakuPreSearchResults;
      } else if (_danmakuPreSearching) {
        // 等预搜索完成
        while (_danmakuPreSearching && mounted) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        results = _danmakuPreSearchResults;
      } else {
        // 预搜索没跑, 实时搜索
        results = await DanmakuManager.instance.searchByTitle(title);
      }
      if (!mounted) return;

      if (results.isEmpty) {
        _toast('未找到弹幕源');
        return;
      }

      // 2) 评分选最优 (v2.5.51: 用 SeleneTV ph0.java 算法)
      final scored = DanmakuScorer.score(title, results, year: year, type: kind);
      if (scored.isEmpty) {
        _toast('未找到匹配的弹幕');
        return;
      }

      // 3) v2.5.52: 并行获取分集 + 并行拉弹幕 (替代串行试 3 个源)
      //    旧: 串行试 3 源, 每个 getEpisodes(10s) + loadDanmaku(8s) = 18s/源, 最多 54s
      //    新: 并行 getEpisodes + loadDanmakuParallel, 总耗时 ≤ 10s
      final candidates = <(DanmakuMedia, DanmakuEpisode)>[];
      for (var i = 0; i < scored.length && i < 3; i++) {
        final best = scored[i].media;
        debugPrint('[Danmaku] auto-match try ${i + 1}: ${best.source.key} '
            '"${best.title}" score=${scored[i].score}');
        await DiaryService.add('[弹幕] 候选${i + 1}: ${best.source.displayName} '
            '"${best.title}" score=${scored[i].score}');

        var eps = await DanmakuManager.instance.getEpisodes(
          best.source,
          best.mediaId,
        );
        if (!mounted) return;

        // 兜底: 空分集列表时用 mediaId 直接当 episodeId
        if (eps.isEmpty) {
          eps = [
            DanmakuEpisode(
              source: best.source,
              episodeId: best.mediaId,
              order: 1,
              title: '正片',
            ),
          ];
        }

        final ep = _pickEpisode(eps, _currentEpisodeIndex + 1, kind);
        if (ep == null) continue;
        candidates.add((best, ep));
      }

      if (candidates.isEmpty) {
        _toast('无法匹配当前集');
        return;
      }

      // 并行拉弹幕: 同时请求所有候选源, 用第一个非空结果
      final parallelInput = candidates
          .map((c) => (c.$1.source, c.$2.episodeId))
          .toList();
      final result = await DanmakuManager.instance.loadDanmakuParallel(parallelInput);
      if (!mounted) return;

      if (result == null || result.comments.isEmpty) {
        _toast('多个源均无弹幕, 可手动选择重试');
        await DiaryService.add('[弹幕] 所有候选源均无弹幕');
        return;
      }

      // 成功! 找到对应的 media 信息
      final winner = candidates.firstWhere(
        (c) => c.$1.source == result.source,
        orElse: () => candidates.first,
      );
      final best = winner.$1;
      final ep = winner.$2;
      final selSource = best.source;
      final selMediaId = best.mediaId;
      final selTitle = best.title;
      setState(() {
        _danmakuSelSource = selSource;
        _danmakuSelMediaId = selMediaId;
        _danmakuSelMediaTitle = selTitle;
        _danmakuSource = selSource.key;
        _danmakuSourceTitle =
            '${selSource.displayName} · $selTitle · ${ep.title}';
        _danmakuCount = result.comments.length;
        _danmakuComments = result.comments;
        _danmakuEnabled = DanmakuSettings.instance.isDanmakuEnabled;
      });
      _danmakuKey.currentState?.reset();
      if (_danmakuEnabled) {
        _toast('弹幕 · ${selSource.displayName} · ${result.comments.length}条');
      }
      await DiaryService.add('[弹幕] 加载成功: ${selSource.displayName} '
          '${result.comments.length}条');
    } catch (e) {
      _toast('弹幕加载失败');
      debugPrint('[Danmaku] auto-match error: $e');
    } finally {
      if (mounted) {
        setState(() => _danmakuLoading = false);
      }
    }
  }

  DanmakuEpisode? _pickEpisode(List<DanmakuEpisode> eps, int wantOrder, String kind) {
    if (eps.isEmpty) return null;
    // 1) order 完全匹配
    for (final e in eps) {
      if (e.order == wantOrder) return e;
    }
    // 2) index = wantOrder - 1
    if (wantOrder - 1 >= 0 && wantOrder - 1 < eps.length) {
      return eps[wantOrder - 1];
    }
    // 3) 电影: 第一集
    if (kind == 'movie') return eps.first;
    // 4) 兜底: 第一集
    return eps.first;
  }

  // v2.5.38: 切集时刷弹幕 (已开启状态下, 用同一源+mediaId 重拉新一集)
  Future<void> _reloadDanmakuForNewEpisode() async {
    if (!_danmakuEnabled) return;

    if (_isCurrentShortDrama) {
      await _loadShortDramaDanmaku(auto: true);
      return;
    }

    if (_danmakuSelSource == null || _danmakuSelMediaId == null) return;
    final source = _selectedSource;
    if (source == null) return;
    setState(() {
      _danmakuLoading = true;
    });
    try {
      final eps = await DanmakuManager.instance.getEpisodes(
        _danmakuSelSource!,
        _danmakuSelMediaId!,
      );
      if (!mounted) return;
      final ep = _pickEpisode(eps, _currentEpisodeIndex + 1, _kind);
      if (ep == null) {
        // ★ ep==null 时清空旧弹幕, 避免上集弹幕残留
        setState(() {
          _danmakuCount = 0;
          _danmakuComments = const [];
        });
        return;
      }
      final list = await DanmakuManager.instance.loadDanmaku(
        _danmakuSelSource!,
        ep.episodeId,
      );
      if (!mounted) return;
      setState(() {
        _danmakuSourceTitle =
            '${_danmakuSelSource!.displayName} · ${_danmakuSelMediaTitle ?? ""} · ${ep.title}';
        _danmakuCount = list.length;
        _danmakuComments = list;
      });
      // ★ 切集后重置 overlay 轨道状态 (didUpdateWidget 会自动检测 comments 变化并 reset,
      //   但显式调用确保万无一失)
      _danmakuKey.currentState?.reset();
    } catch (_) {
      // 静默
    } finally {
      if (mounted) {
        setState(() {
          _danmakuLoading = false;
        });
      }
    }
  }

  // v2.5.7: 用 PageCacheService 维护收藏. 之前用 SharedPreferences
  // 单独写一个 `fav_<source>_<id>` bool, 但 PageCacheService 维护的
  // 收藏列表是后端权威源 (走 ApiService.favorite / unfavorite +
  // 本地缓存), 这个孤立的 bool 不在收藏列表里, 所以收藏页永远看不到.
  // 修: _loadFavorite 改用 isFavoritedSync 同步查, _toggleFavorite 改
  // 用 PageCacheService.toggleFavorite 走真收藏 API.
  //
  // 短剧页 (ShortDramaScreen._onDramaTap) 跳播放器时 source 传 ''.
  // 用 '__shortdrama__' 作为 source 名, 避免空字符串 key 冲突.
  String _favoriteSourceKey() {
    final s = widget.videoInfo.source;
    return s.isEmpty ? '__shortdrama__' : s;
  }

  Map<String, dynamic> _favoriteData() {
    final v = widget.videoInfo;
    return {
      'title': v.title,
      'source_name': v.sourceName,
      'year': v.year,
      'cover': v.cover,
      'total_episodes': v.totalEpisodes,
      'save_time': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 切换收藏
  void _toggleFavorite() async {
    final wasFavorite = _isFavorite;
    setState(() => _isFavorite = !_isFavorite);

    final source = _favoriteSourceKey();
    final id = widget.videoInfo.id;
    try {
      final result = await PageCacheService().toggleFavorite(
        source,
        id,
        _favoriteData(),
        context,
      );
      if (!mounted) return;
      if (!result.success) {
        // 失败回滚 UI
        setState(() => _isFavorite = wasFavorite);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.errorMessage ?? '收藏操作失败')),
        );
      } else {
        // 成功后通知收藏页 / 历史页刷新
        await FavoritesGrid.refreshFavorites();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isFavorite ? '已加入收藏' : '已取消收藏'),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFavorite = wasFavorite);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('收藏异常: $e')),
      );
    }
  }

  /// 加载收藏状态
  Future<void> _loadFavorite() async {
    if (!mounted) return;
    try {
      final isFav = PageCacheService()
          .isFavoritedSync(_favoriteSourceKey(), widget.videoInfo.id);
      if (mounted) {
        setState(() => _isFavorite = isFav);
      }
    } catch (_) {
      // 静默失败, 保持默认 false
    }
  }

  /// 显示控制栏并启动自动隐藏定时器
  void _showControls() {
    _hideControlsTimer?.cancel();
    if (!mounted) return;
    setState(() => _isControlsVisible = true);
  }

  /// 调度自动隐藏控制栏
  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_isPlaying) {
        setState(() => _isControlsVisible = false);
      }
    });
  }

  /// 切换控制栏显隐
  void _toggleControls() {
    if (_isControlsVisible) {
      setState(() => _isControlsVisible = false);
    } else {
      _showControls();
      if (_isPlaying) _scheduleHideControls();
    }
  }

  // ==================== 亮度/音量手势 (v1.0.40) ====================

  void _onVolumeSwipeStart(DragStartDetails details) {
    _volumeHideTimer?.cancel();
    _hideControlsTimer?.cancel();
    _dragStartVolume = _currentVolume;
    _totalDragVolumeDelta = 0; // v1.0.49: 重置累计 delta
    setState(() {
      _isControlsVisible = true;
      _showVolumeIndicator = true;
    });
  }

  void _onVolumeSwipeUpdate(DragUpdateDetails details) {
    // v1.0.49: 同亮度手势, 用累计 delta + 1.0 灵敏度
    // 旧版用单帧 delta + 固定基线, 慢滑会"抖" (每帧 dy 小, 音量来回跳)
    _totalDragVolumeDelta += -details.delta.dy; // 上滑增音量
    final screenHeight = MediaQuery.of(context).size.height;
    final normalized = (_totalDragVolumeDelta / screenHeight) * 1.0;
    setState(() {
      _currentVolume =
          (_dragStartVolume! + normalized).clamp(0.0, 1.0);
      _showVolumeIndicator = true;
    });
    // v1.0.44: 走 VolumeController.instance.setVolume
    // v1.0.54: 走全局 showSystemUI=false (initState 开关), 不走方法参数,
    // 因为滑动频繁调 setVolume, 每次传参也累赘
    // v2.5.18: volume_controller 2.0.8 → 3.4.4, 改 singleton → instance API,
    //   VolumeController() 私有构造, 必须 .instance. 3.4.4 内部会把
    //   showSystemUI 值传给原生层, 走 adjustStreamVolume(..., 0) 不弹
    //   FLAG_SHOW_UI. 但物理音量键仍走 Activity.dispatchKeyEvent →
    //   AudioManager.adjustStreamVolume (默认 FLAG_SHOW_UI), 弹系统
    //   音量条, 这部分由 VolumeKeyChannel 拦截 (见 initState).
    VolumeController.instance.setVolume(_currentVolume);
  }

  void _onVolumeSwipeEnd(DragEndDetails details) {
    _dragStartVolume = null;
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
    _scheduleHideControls();
  }

  // v2.5.18: 物理音量键回调 — Kotlin VolumeKeyChannel.dispatchKeyEvent
  //   拦截 KEYCODE_VOLUME_UP/DOWN/MUTE, 调 channel.invokeMethod
  //   ('onVolumeKey', direction). Dart 端自己调
  //   VolumeController.instance.setVolume (showSystemUI=false 不弹系统
  //   音量条), 跟侧滑调音量走同一路径, 体验一致.
  //
  //   步长: 1/15 ≈ 0.067, 跟系统默认 adjustStreamVolume 步长一致
  //   (系统 max=15 时一次 +1), 用户感觉跟原系统调节幅度一样.
  Future<dynamic> _onVolumeKeyCall(MethodCall call) async {
    if (call.method != 'onVolumeKey') return null;
    final direction = call.arguments as String?;
    if (direction == null) return null;

    const step = 1.0 / 15.0;
    double newVolume = _currentVolume;
    switch (direction) {
      case 'up':
        newVolume = (_currentVolume + step).clamp(0.0, 1.0);
        break;
      case 'down':
        newVolume = (_currentVolume - step).clamp(0.0, 1.0);
        break;
      case 'mute':
        // v2.5.18: 物理静音键 — 静音切到 0, 再按一下恢复原音量.
        //   用 _volumeBeforeMute 缓存, 跟系统默认行为一致.
        if (_currentVolume > 0) {
          _volumeBeforeMute = _currentVolume;
          newVolume = 0.0;
        } else if (_volumeBeforeMute != null && _volumeBeforeMute! > 0) {
          newVolume = _volumeBeforeMute!;
        }
        break;
    }

    if (newVolume == _currentVolume) return null;

    setState(() {
      _currentVolume = newVolume;
      _showVolumeIndicator = true;
    });
    // 走 volume_controller.instance.setVolume, showSystemUI=false (initState
    // 设的) 已经传 0 flags 给原生层, 不弹系统音量条.
    try {
      await VolumeController.instance.setVolume(newVolume);
    } catch (_) {}

    // 2s 后自动隐藏指示器, 跟侧滑手势一致
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showVolumeIndicator = false);
    });
    return null;
  }

  void _onBrightnessSwipeStart(DragStartDetails details) {
    _brightnessHideTimer?.cancel();
    _hideControlsTimer?.cancel();
    _dragStartBrightness = _currentBrightness;
    _totalDragBrightnessDelta = 0; // v1.0.45: 重置累计 delta
    setState(() {
      _isControlsVisible = true;
      _showBrightnessIndicator = true;
    });
  }

  void _onBrightnessSwipeUpdate(DragUpdateDetails details) {
    // v1.0.45: 同音量手势, 用累计 delta + 1.0 灵敏度
    _totalDragBrightnessDelta += -details.delta.dy; // 上滑增亮
    final screenHeight = MediaQuery.of(context).size.height;
    final normalized = (_totalDragBrightnessDelta / screenHeight) * 1.0;
    setState(() {
      _currentBrightness = (_dragStartBrightness! + normalized).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
    });
    // v1.0.44: v0.2.2 / 2.0.8 API 是 ScreenBrightness() 实例, setScreenBrightness 而非 setApplicationScreenBrightness
    ScreenBrightness().setScreenBrightness(_currentBrightness);
  }

  void _onBrightnessSwipeEnd(DragEndDetails details) {
    _dragStartBrightness = null;
    _brightnessHideTimer?.cancel();
    _brightnessHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showBrightnessIndicator = false);
    });
    _scheduleHideControls();
  }

  // 单击中央 = 切显隐
  void _onCenterTap() {
    _toggleControls();
  }

  // v2.5.20: 水平拖动开始 — 记录起始 position + 累计 delta, 取消未触发的 seek
  //   节流, 防止 stale timer 在 drag 中突然 fire 把当前位置 seek 走.
  //   v2.6.2: 用 _swipeStartPosition + _swipeCumulativeDx 做绝对定位, 不依赖
  //   _currentPosition (position stream 会用旧值覆盖, 长滑动会"来回调").
  //   加 _isSwiping 锁, position stream 和 100ms 轮询期间不能覆盖 _currentPosition.
  void _onCenterSwipeStart(DragStartDetails details) {
    if (_isDisposing) return;
    _centerSwipeSeekThrottle?.cancel();
    _centerSwipeSeekThrottle = null;
    _centerSwipeThrottleBusy = false;
    _swipeStartPosition = _currentPosition;
    _swipeCumulativeDx = 0;
    _isSwiping = true;
  }

  // v2.5.90: _setSeekGuard / _clearSeekGuard 已移除
  //   seek guard 阻止 position stream 和 100ms 轮询更新 _currentPosition,
  //   导致进度条不动. seek 后立即设 _currentPosition 为目标值即可.

  // v2.5.20: 水平拖动结束 — flush pending seek 节流, 确保最后 drag 位置 seek 到
  //   player 上. v2.6.2: 不再依赖节流 timer (可能还没 fire), 直接用
  //   _currentPosition 调一次 seek. 同步清掉 _swipeStartPosition 和
  //   _isSwiping 锁 (让 position stream 接管).
  void _onCenterSwipeEnd(DragEndDetails details) {
    if (_isDisposing) return;
    _centerSwipeSeekThrottle?.cancel();
    _centerSwipeSeekThrottle = null;
    _centerSwipeThrottleBusy = false;
    final finalPos = _currentPosition;
    _swipeStartPosition = null;
    _swipeCumulativeDx = 0;
    _isSwiping = false;
    unawaited(_player!.seek(finalPos));
    _onDanmakuSeek(finalPos.inMilliseconds);
  }

  // v2.5.86: 底部栏水平拖动开始 — 记录起始 value (当前进度) + 底部栏宽度,
  //   delta.dx / 底部栏宽度 = 进度变化. 顺便取消自动隐藏控件计时器,
  //   防止拖到一半控件消失了.
  void _onBottomBarSwipeStart(DragStartDetails details) {
    if (_isDisposing) return;
    if (_currentDuration.inMilliseconds <= 0) return;
    _bottomBarSwipeThrottle?.cancel();
    _bottomBarSwipeThrottle = null;
    _hideControlsTimer?.cancel();
    // 当前进度: 优先用 _scrubbingValue (用户已经在拖 Slider), 否则用 position
    final dur = _currentDuration.inMilliseconds.toDouble();
    final startVal = _scrubbingValue ??
        (_currentPosition.inMilliseconds / dur).clamp(0.0, 1.0);
    _bottomBarDragStartValue = startVal;
    // 底部栏宽度 = LayoutBuilder 可以拿到, 但我们已经在 buildLunaBottomBar
    //   算过 maxW, 这里重新算 (mediaQuery 一致). 用 estimatedContainerWidth:
    //   ConstrainedBox(maxWidth: maxW), 实际宽度 = min(maxW, 屏幕宽 - 24).
    final screenW = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final maxW = isLandscape ? screenW * 0.6 : screenW * 0.85;
    _bottomBarDragStartWidth = (screenW - 24).clamp(0.0, maxW);
    // 跟中间 swipe 一样保持控件显示
    setState(() {
      _isControlsVisible = true;
      _scrubbingValue = startVal; // 让 Slider 立即响应拖动
    });
  }

  // v2.5.86: 底部栏水平拖动更新 — delta.dx / 底部栏宽度 = 进度变化.
  //   拖动过程中更新 _scrubbingValue (Slider 同步显示), 跟 _onCenterSwipeUpdate
  //   一样 100ms 节流 seek, 防止 ExoPlayer message queue 堆积.
  void _onBottomBarSwipeUpdate(DragUpdateDetails details) {
    if (_isDisposing) return;
    final startVal = _bottomBarDragStartValue;
    final width = _bottomBarDragStartWidth;
    final dur = _currentDuration.inMilliseconds;
    if (startVal == null || width == null || width <= 0 || dur <= 0) return;
    // 累积 delta (Listener/DragUpdateDetails 的 delta 是单帧增量, 累加防丢)
    // 这里没有累积变量, 用 _scrubbingValue 当前值当锚点:
    //   newVal = startVal + (累计 dx) / width
    // DragUpdateDetails 的 delta.dx 是单帧, 直接累加到 _scrubbingValue:
    final current = _scrubbingValue ?? startVal;
    final newVal = (current + details.delta.dx / width).clamp(0.0, 1.0);
    setState(() {
      _scrubbingValue = newVal;
    });
    // 100ms 节流 seek (跟 _onCenterSwipeUpdate 一致, 避免 ExoPlayer 乱跳)
    _bottomBarSwipeThrottle?.cancel();
    _bottomBarSwipeThrottle = Timer(const Duration(milliseconds: 100), () {
      if (_isDisposing) return;
      final newMs = (newVal * dur).toInt();
      unawaited(_player!.seek(Duration(milliseconds: newMs)));
      // 同步 _currentPosition, 中间 swipe 节流也是这么做的
      if (mounted) {
        setState(() {
          _currentPosition = Duration(milliseconds: newMs);
        });
      }
    });
  }

  // v2.5.86: 底部栏水平拖动结束 — flush pending seek, 清理 state.
  //   跟中间 swipe 不同: 中间 swipe 结束后保持 _currentPosition 让 Slider
  //   显示; 这里 _scrubbingValue 维持, 让 Slider 停在用户拖到的位置,
  //   然后 _onScrubEnd 风格的清尾.
  void _onBottomBarSwipeEnd(DragEndDetails details) {
    if (_isDisposing) return;
    _bottomBarSwipeThrottle?.cancel();
    _bottomBarSwipeThrottle = null;
    final v = _bottomBarDragStartValue;
    final dur = _currentDuration.inMilliseconds;
    _bottomBarDragStartValue = null;
    _bottomBarDragStartWidth = null;
    if (v == null || dur <= 0) {
      // v2.5.90: 即使提前 return 也要清除 _scrubbingValue,
      //   否则 position stream 和 100ms 轮询永远不更新 _currentPosition
      if (_scrubbingValue != null) {
        setState(() => _scrubbingValue = null);
      }
      return;
    }
    // 用当前 _scrubbingValue 调 seek (跟 _onScrubEnd 一样, 确保 final 位置 seek)
    final finalVal = (_scrubbingValue ?? v).clamp(0.0, 1.0);
    final newMs = (finalVal * dur).toInt();
    unawaited(_player!.seek(Duration(milliseconds: newMs)));
    setState(() {
      _currentPosition = Duration(milliseconds: newMs);
      _scrubbingValue = null;
    });
    _onDanmakuSeek(newMs);
    _updateSkipButtonVisibility();
    if (_isPlaying) _scheduleHideControls();
  }

  // v2.6.2: 主流方案 — 整屏滑动 = 60s, 半屏 = 30s. 跟 YouTube/爱奇艺/B站
  //   体验一致. 之前 v2.6.1 改成 300s/屏太激进, 现在 60s/屏, 横滑小段
  //   距离调几秒, 整屏滑到底调一分钟, 体感自然.
  //
  // 关键修复 (v2.6.2): 节流策略从 cancel+restart 改成 first-fire+skip.
  //   - 旧: 100ms timer, 每次 update 都 cancel + restart, 长滑动时 timer
  //     永远不 fire, ExoPlayer 一帧都不 seek, 用户看到"长滑动不动".
  //   - 新: 30ms "first-fire+skip" — 第一次 fire 立即 seek (短滑动
  //     一次到位), 之后 30ms 内 skip (不 restart), 30ms 后才允许再
  //     fire. 保证 30ms 至少一次 seek, 用户能实时看到进度跟随手指.
  //
  // 绝对定位 (v2.6.2): 用 _swipeStartPosition + 累计 dx 算 newMs,
  //   不再 _currentPosition + deltaMs. 因为 position stream 会用
  //   "实际播放位置" (旧值) 覆盖 _currentPosition, 导致长滑动时
  //   newMs 累计漂移, 松手后位置"来回调".
  void _onCenterSwipeUpdate(DragUpdateDetails details) {
    if (_isDisposing) return;
    final startPos = _swipeStartPosition;
    if (startPos == null) return; // 不是 start 后第一次 update, 防御
    final screenWidth = MediaQuery.of(context).size.width;
    if (screenWidth <= 0) return;
    // 整屏滑动 = 60s, 半屏 = 30s (跟 YouTube/爱奇艺 一致)
    _swipeCumulativeDx += details.delta.dx;
    final deltaMs = (_swipeCumulativeDx / screenWidth * 60000).round();
    final newMs = (startPos.inMilliseconds + deltaMs)
        .clamp(0, _currentDuration.inMilliseconds)
        .toInt();
    final isForward = deltaMs >= 0;
    // 1) UI 立即更新 — 进度条 / 时间标签 / 提示文字跟手 (无延迟)
    setState(() {
      _currentPosition = Duration(milliseconds: newMs);
      // v2.6.3 改: 之前 (deltaMs / 1000).round() 把 < 500ms 都吃成 0,
      //   短位移 (1-2px) 提示"快进0s"但实际已经动. 改 1 位小数:
      //   < 1000ms 显示 "0.Xs", >= 1000ms 显示 "Xs" (去尾 .0)
      //   短滑动立即看到提示, 长滑动整数位也不拖泥带水.
      final absMs = deltaMs.abs();
      final absSec = absMs / 1000.0;
      final secStr = absSec == absSec.truncate()
          ? absSec.toInt().toString()
          : absSec.toStringAsFixed(1);
      _seekHintText = isForward ? '快进${secStr}s' : '快退${secStr}s';
    });
    _seekHintTimer?.cancel();
    _seekHintTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_isDisposing) {
        setState(() => _seekHintText = null);
      }
    });
    // 2) 节流 seek — first-fire+skip 30ms. 第一次 fire, 之后 30ms 内
    //    skip, 30ms 后才允许再 fire.
    if (_centerSwipeThrottleBusy) return;
    _centerSwipeThrottleBusy = true;
    unawaited(_player!.seek(Duration(milliseconds: newMs)));
    _centerSwipeSeekThrottle = Timer(const Duration(milliseconds: 30), () {
      _centerSwipeThrottleBusy = false;
    });
  }

  // ==================== v2.6.2: 双击快进/快退/播放 全屏监听 ====================
  // 主流方案 (YouTube/爱奇艺/B站) 双击行为:
  //   - 双击左半屏 → 快退 10s
  //   - 双击右半屏 → 快进 10s
  //   - 双击中央 1/3 → 播放/暂停
  // 用 globalPosition (屏幕绝对坐标) 判断落点, 不依赖 onDoubleTapDown
  //   localPosition (相对 GestureDetector 自身, 这里就是相对全屏, 因为
  //   Positioned.fill 撑满整个播放器). 中间 1/3 区域: x in [W/3, 2W/3].
  // 双击第二下 (onDoubleTap) 才真正执行 seek/playPause, 第一下
  //   (onDoubleTapDown) 只记录落点, 防止误触 (用户可能只是快单击).
  // _pendingDoubleTapSide: -1=左, 0=中, 1=右, null=无 pending.
  int? _pendingDoubleTapSide;

  void _onGlobalDoubleTapDown(TapDownDetails details) {
    if (_isDisposing) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final x = details.localPosition.dx;
    int side;
    if (x < screenWidth / 3) {
      side = -1; // 左半 (快退)
    } else if (x > screenWidth * 2 / 3) {
      side = 1; // 右半 (快进)
    } else {
      side = 0; // 中间 (播放/暂停)
    }
    _pendingDoubleTapSide = side;
  }

  void _onGlobalDoubleTap() {
    if (_isDisposing) return;
    final side = _pendingDoubleTapSide;
    _pendingDoubleTapSide = null;
    if (side == null) return;
    if (side == 0) {
      // v2.6.41: 缩放状态下双击中央 = 复位缩放, 否则 = 播放/暂停
      if (_videoScale > 1.01) {
        setState(() => _videoScale = 1.0);
      } else {
        _togglePlayPause();
      }
    } else {
      // 左右双击 = ±10s (跟主流方案一致, 替代原 ±30s 按钮)
      _seekBySeconds(side * 10, side > 0 ? '快进10s' : '快退10s');
    }
  }

  // ==================== 双指缩放 (v2.6.41) ====================

  /// pointer down — 记录指针, 2 指时算初始距离
  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length == 2) {
      final pts = _pinchPointers.values.toList();
      _pinchInitialDistance = (pts[0] - pts[1]).distance;
      _baseScale = _videoScale;
    }
  }

  /// pointer move — 2 指以上时按距离比更新缩放
  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length >= 2 && _pinchInitialDistance > 0) {
      final pts = _pinchPointers.values.toList();
      final currentDist = (pts[0] - pts[1]).distance;
      if (currentDist > 0) {
        final newScale =
            (_baseScale * currentDist / _pinchInitialDistance).clamp(1.0, 4.0);
        if ((newScale - _videoScale).abs() > 0.01) {
          setState(() => _videoScale = newScale);
        }
      }
    }
  }

  /// pointer up — 移除指针, 不足 2 指时结束 pinch
  void _onPinchPointerUp(PointerUpEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchInitialDistance = 0.0;
    }
  }

  /// pointer cancel — 系统取消触摸 (如来电), 清空所有指针
  void _onPinchPointerCancel(PointerCancelEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchInitialDistance = 0.0;
    }
  }

  // ==================== 进度条拖动 ====================

  /// 进度条拖动 - 开始
  void _onScrubStart(double value) {
    _hideControlsTimer?.cancel();
    setState(() {
      _scrubbingValue = value;
      _isControlsVisible = true;
    });
  }

  /// 进度条拖动 - 更新
  void _onScrubChange(double value) {
    setState(() => _scrubbingValue = value);
  }

  /// 进度条拖动 - 结束
  void _onScrubEnd(double value) {
    final dur = _currentDuration.inMilliseconds.toDouble();
    if (dur > 0) {
      final pos = (value.clamp(0.0, 1.0)) * dur;
      _player!.seek(Duration(milliseconds: pos.toInt()));
      // v2.5.90: seek guard 已移除
    }
    final finalMs = ((value.clamp(0.0, 1.0)) * dur).toInt();
    setState(() {
      _scrubbingValue = null;
      _currentPosition = Duration(milliseconds: finalMs);
    });
    _onDanmakuSeek(finalMs);
    _updateSkipButtonVisibility();
    if (_isPlaying) _scheduleHideControls();
  }

  /// 格式化时间为 mm:ss 或 hh:mm:ss
  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  /// v2.0.58: 截短 URL 用于日志输出 (避免 worker 长 query 撑爆 200 行 buffer).
  /// 保留 scheme+host+path, query 只保留前 60 字符并标 …
  String _shortenUrl(String url) {
    if (url.length <= 120) return url;
    final qIdx = url.indexOf('?');
    if (qIdx < 0) return url.substring(0, 120) + '…';
    final base = url.substring(0, qIdx);
    final query = url.substring(qIdx, qIdx + 61);
    return '$base$query…';
  }

  /// 构造并保存当前播放记录
  Future<void> _saveCurrentProgress({bool force = false}) async {
    final source = _selectedSource;
    if (source == null) return;
    if (source.source.isEmpty) return;

    int playTime = 0;
    int totalTime = 0;
    try {
      // v2.2.0: backend 直接提供 position/duration/isPlaying/isCompleted
      //   不再有 _player!.state.X 聚合字段.
      Duration pos = _player!.position;
      // v1.0.49 兜底: position 在 stop/pause 后可能回 0 或 stream 还没回传,
      // 用本地 _currentPosition (stream 一直在跟) 兜底, 保证退出前最后一帧
      // 还有效的 position 能写盘
      if (pos < _currentPosition) pos = _currentPosition;
      // v1.0.75 兜底: reload 期间, isCompleted=true 且
      // position=0, _currentPosition 也被 stream 发射 0 重置, 三者都是 0.
      // 此时用 _lastKnownPosition 拿"上次的非 0 position", 避免 10s 定时器存 0
      // 覆盖云端进度. _lastKnownPosition 只在 streams.position 收到 pos > 0 时
      // 才更新, reload 完重新播时 pos 会从 0 涨, 兜底期间它还停在原值.
      if (pos < _lastKnownPosition) pos = _lastKnownPosition;

      // 正在播放 或 有进度且未播完 (用 !completed 表示)
      if (_player!.isPlaying || (pos > Duration.zero && !_player!.isCompleted)) {
        playTime = pos.inMilliseconds;
        totalTime = _player!.duration.inMilliseconds;
      }
    } catch (_) {}

    final key = '${source.source}+${source.id}';
    // 没播放过(skip) || 同一集还没开始播且已存过(避免启动时连发两条空)
    if (!force && _lastSavedKey == key && playTime == 0 && _firstRecordSaved) {
      return;
    }

    final record = PlayRecord(
      id: source.id,
      source: source.source,
      title: source.title.isNotEmpty
          ? source.title
          : widget.videoInfo.title,
      sourceName: source.sourceName,
      year: widget.videoInfo.year,
      cover: source.poster.isNotEmpty
          ? source.poster
          : widget.videoInfo.cover,
      index: _currentEpisodeIndex + 1,
      totalEpisodes: source.episodes.length,
      playTime: playTime,
      totalTime: totalTime,
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: widget.videoInfo.searchTitle.isNotEmpty
          ? widget.videoInfo.searchTitle
          : widget.videoInfo.title,
    );

    _lastSavedKey = key;
    _firstRecordSaved = true;

    DiaryService.add(
        '[History] _saveCurrentProgress: key="$key" index=${record.index} playTime=${playTime}ms totalTime=${totalTime}ms searchTitle="${record.searchTitle}" force=$force');

    try {
      await PageCacheService().savePlayRecord(record, context);
      DiaryService.add('[History] save ok: key="$key"');
    } catch (e) {
      DiaryService.add('[History] save err: $e');
      // 静默失败
    }
  }

  /// v2.5.88: 定时器已删除. 所有退出路径都保存进度:
  ///   返回键/返回箭头/切后台/切集/DLNA投屏/dispose兜底
  ///   不再需要定时器轮询写入, 减少网络请求.
  void _startProgressTimer() {
    _progressTimer?.cancel();
    // 不再启动定时写入, 退出时统一保存
  }

  /// 启动后云记忆里查到的 episode, 准备在 _playEpisode 时 seek 过去
  Duration? _pendingResumeAt;

  /// v1.0.65: 等 position stream 至少回一次 _currentPosition > 0
  /// (带 timeout). 防止"刚 open player 就 back / home 键 / 杀 App" 等
  /// 场景下 state.position 和 _currentPosition 都还是 0 时,
  /// 走 force=true 的 save 路径存 0, **覆盖了之前的真进度**
  /// (云端 + local 双写都会被覆盖), 下次重开从 0 开始
  ///
  /// 三处会用到: onPopInvoked (playing→detail) / didChangeAppLifecycleState
  /// (paused) / _disposeAndSave. 这三处都用 force=true 跳过 _firstRecordSaved
  /// 守门, 没办法靠守门保护, 只能等 stream.
  Future<void> _waitForValidPosition({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (_currentPosition > Duration.zero) return;
    // player 都没在播, 等也是白等, 直接 return
    if (!_player!.isPlaying) return;
    final completer = Completer<void>();
    late StreamSubscription<Duration> sub;
    sub = _player!.positionStream.listen((pos) {
      if (pos > Duration.zero && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {}
    try {
      await sub.cancel();
    } catch (_) {}
  }

  // ★ v2.6.45: 返回键后台异步清理 (不阻塞 UI 响应)
  Future<void> _cleanupOnBack() async {
    try {
      // 等有效位置 (最多 500ms, 比之前 800ms 更快)
      await _waitForValidPosition(timeout: const Duration(milliseconds: 500));
      if (_currentPosition > Duration.zero || _isCurrentShortDrama || _currentEpisodeIndex > 0) {
        await _saveCurrentProgress(force: true);
      }
      await _player?.stop();
      await _onExitFullscreen();
    } catch (_) {}
  }

  // 加载多源并自动测速
  Future<void> _loadSources() async {
    final title = widget.videoInfo.searchTitle.isNotEmpty
        ? widget.videoInfo.searchTitle
        : widget.videoInfo.title;
    DiaryService.add(
        '[History] _loadSources begin: title="$title" videoInfo.source="${widget.videoInfo.source}" videoInfo.index=${widget.videoInfo.index} videoInfo.playTime=${widget.videoInfo.playTime}ms videoInfo.searchTitle="${widget.videoInfo.searchTitle}"');
    if (title.isEmpty) {
      setState(() {
        _sourcesLoading = false;
        _error = '视频标题为空,无法搜索';
      });
      return;
    }

    setState(() {
      _sourcesLoading = true;
      _error = null;
    });

    // 短剧专属源直连：若为短剧直接使用红果官方原画观看源，跳过普通影视站搜索
    if (widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama' ||
        widget.videoInfo.source == '__shortdrama__') {
      final totalEps = widget.videoInfo.totalEpisodes > 0
          ? widget.videoInfo.totalEpisodes
          : 80;
      final eps = List.generate(totalEps, (i) => (i + 1).toString());
      final epTitles = List.generate(totalEps, (i) => '第${i + 1}集');
      final dramaSource = SearchResult(
        id: widget.videoInfo.id,
        title: widget.videoInfo.title,
        poster: widget.videoInfo.cover,
        episodes: eps,
        episodesTitles: epTitles,
        source: 'hongguo',
        sourceName: '红果短剧 (官方原画)',
        year: widget.videoInfo.year.isNotEmpty ? widget.videoInfo.year : '2026',
      );
      if (!mounted) return;
      setState(() {
        _sourceResults = [dramaSource];
        _sourcesLoading = false;
        _error = null;
      });

      // 准确恢复短剧历史播放进度 (集数与播放进度时间)
      int targetEpisodeIndex = 0;
      int targetPlayTime = 0;

      // 1) 优先使用 videoInfo 携带的历史记录 (从“继续观看”或“播放历史”卡片进入)
      if (widget.videoInfo.index > 0) {
        targetEpisodeIndex = (widget.videoInfo.index - 1).clamp(0, totalEps - 1);
        targetPlayTime = widget.videoInfo.playTime;
      } else {
        // 2) 若从短剧分类专区或搜索直入，尝试从云端/本地存储拉取该短剧最近观看记录
        final resume = await _tryLoadResume(title, dramaId: widget.videoInfo.id);
        if (resume != null && resume.index > 0) {
          targetEpisodeIndex = (resume.index - 1).clamp(0, totalEps - 1);
          targetPlayTime = resume.playTime;
        }
      }

      if (targetPlayTime > 0) {
        _pendingResumeAt = Duration(milliseconds: targetPlayTime);
      }

      _selectSource(dramaSource, episodeIndex: targetEpisodeIndex);
      DiaryService.add(
          '[History] 短剧历史恢复成功: $title 第${targetEpisodeIndex + 1}集 playTime=${targetPlayTime}ms');

      // 异步根据真实章节列表精确对齐总集数 (消除硬编码80集限制)
      unawaited(() async {
        try {
          final realVidList = await DuanjuCoreBridge.instance.fetchEpisodeVidList(widget.videoInfo.id);
          if (mounted && realVidList.isNotEmpty && realVidList.length != dramaSource.episodes.length) {
            final realCount = realVidList.length;
            final updatedEps = List.generate(realCount, (i) => (i + 1).toString());
            final updatedTitles = List.generate(realCount, (i) => '第${i + 1}集');
            setState(() {
              dramaSource.episodes
                ..clear()
                ..addAll(updatedEps);
              dramaSource.episodesTitles
                ..clear()
                ..addAll(updatedTitles);
            });
          }
        } catch (_) {}
      }());
      return;
    }

    // 先尝试从云端拉一次播放记录, 防止 videoInfo 没带 source/index
    // (比如从搜索结果直接点进来, 但云端其实有别的源在播)
    final resume = widget.videoInfo.source.isEmpty || widget.videoInfo.index <= 0
        ? await _tryLoadResumeFromCloud(title)
        : null;
    DiaryService.add(
        '[History] resume: ${resume == null ? "null (跳过云端)" : "source=${resume.source} index=${resume.index} playTime=${resume.playTime}ms"}');
    final resumeSourceKey = resume?.source ?? widget.videoInfo.source;
    final resumeIndex = resume != null
        ? (resume.index - 1).clamp(0, 1 << 30)
        : (widget.videoInfo.index - 1).clamp(0, 1 << 30);
    DiaryService.add(
        '[History] resume computed: resumeSourceKey="$resumeSourceKey" resumeIndex=$resumeIndex (0-based)');
    if (resume != null && resume.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: resume.playTime);
    } else if (widget.videoInfo.playTime > 0) {
      _pendingResumeAt = Duration(milliseconds: widget.videoInfo.playTime);
    }
    DiaryService.add(
        '[History] _pendingResumeAt: ${_pendingResumeAt?.inMilliseconds ?? "null"}ms');

    try {
      // v2.5.82: 照 web play/page.tsx 逻辑:
      //   1) /api/search 已经在后端并行搜了所有 18 个源, 返回的就是各源命中结果
      //   2) 客户端只做一件事: 按 source 聚合, 同源保留集数最多的一条
      //   3) 不做标题相似度过滤 (web 也不做, 资源站标题千差万别,
      //      相似度阈值会把大部分源砍掉, 导致 app 源数远少于 web)
      //   4) /api/search/resources 拉全源列表, 没命中的源补占位
      //   最终展示数 = resources 列表长度 (18 个)
      final resultsFut = ApiService.fetchSourcesData(title);
      final resourcesFut = ApiService.getSearchResources();
      final results = await resultsFut;
      final resources = await resourcesFut;
      if (!mounted) return;

      // v2.6.14: 播放详情页用「联合去重」 — title substring + year 严格匹配.
      //   跟搜索页 (search_screen) 不同: 搜索页用子序列匹配 (宽松, 让
      //   「凡人修仙传」也能命中「凡人修仙传之风起」, 因为用户可能想看
      //   子系列), 播放详情页必须精确命中用户点的那部剧.
      //
      //   联合去重 = 2 个条件 AND:
      //   1. title 归一化后 substring 包含 query (去符号 + 子序列 -> 严格 substring)
      //   2. year 完全一致 (排除不同年份版本, e.g. 凡人修仙传 2023 vs 2024)
      //   搜「凡人修仙传」现在只会匹配:
      //   - 「凡人修仙传」24集 (真目标)
      //   - 「凡人修仙传 新版」24集 (同剧不同版本, OK)
      //   - 「凡人修仙传 第2季」 (同剧, OK)
      //   不会匹配:
      //   - 「凡人修仙传之风起」 (不同剧, 虽 title 含「凡人修仙传」但 substring 不连续)
      //   - 「凡人修仙传」2023 (年份不对)
      final filteredResults = results
          .where((r) => SearchResultRanker.resultMatchesQueryStrict(
                r,
                title,
                widget.videoInfo.year,
              ))
          .toList();
      DiaryService.add(
          '[SourceFilter] 联合去重过滤: ${results.length} → ${filteredResults.length} '
          '(过滤掉 ${results.length - filteredResults.length} 个不相关剧集, query="$title" year="${widget.videoInfo.year}")');

      // 按 source 聚合: 同源保留集数最多的一条 (跟 web 一致)
      // 注: fetchSourcesData 已按 title_year_source 去重, 同一 source 的多个
      // 标题版本 (如 "凡人修仙传" + "凡人修仙传 新版") 也只留集数最多的
      final bySource = <String, SearchResult>{};
      for (final r in filteredResults) {
        final k = r.source;
        if (k.isEmpty) continue;
        final prev = bySource[k];
        if (prev == null || r.episodes.length > prev.episodes.length) {
          bySource[k] = r;
        }
      }
      DiaryService.add(
          '[SourceFilter] /api/search 命中: ${results.length}, 按源聚合后: ${bySource.length}, '
          '全源数: ${resources.length}, 标题: "$title"');

      // v2.5.82→: 只展示有真实结果的源, 过滤 0 集 (避免 UI 显示 "共0集" / "待测")
      //   之前占位 "没命中的源也展示" 的逻辑导致 18 源全显示, 但 16 个是
      //   0 集占位, 用户体验差. 现在按 bySource 顺序直接展示, 没命中的源
      //   自然就不会出现, 跟 web 列表页行为一致.
      final merged = <SearchResult>[];
      for (final entry in bySource.entries) {
        if (entry.value.episodes.isEmpty) continue;
        merged.add(entry.value);
      }
      DiaryService.add(
          '[SourceFilter] 合并后展示源数: ${merged.length} (0 集过滤: ${bySource.length - merged.length})');

      setState(() {
        _sourceResults = merged;
        _sourcesLoading = false;
        if (merged.isEmpty) {
          _error = '没有源匹配 "$title"';
        }
      });

      // 选源优先级:
      // 1. 云记忆里有这个 video 的源 (resume.source)
      // 2. 入口传过来的 preferredSource
      // 3. 第一个 (从 bySource 取, 不用占位)
      if (bySource.isEmpty) return;
      SearchResult toSelect = bySource.values.first;
      if (resumeSourceKey.isNotEmpty) {
        for (final r in bySource.values) {
          if (r.source == resumeSourceKey) {
            toSelect = r;
            break;
          }
        }
      }
      if (widget.preferredSource != null && widget.preferredSource!.isNotEmpty) {
        for (final r in bySource.values) {
          if (r.source == widget.preferredSource) {
            toSelect = r;
            break;
          }
        }
      }
      _selectSource(toSelect, episodeIndex: resumeIndex);
      DiaryService.add(
          '[History] _selectSource done: toSelect.source="${toSelect.source}" toSelect.id="${toSelect.id}" resumeIndex=$resumeIndex → _currentEpisodeIndex=$_currentEpisodeIndex');

      // 进入详情页不自动播放,等用户点"播放"按钮
      // (电视剧在第1集播完后会自动播第2集,可点暂停控制)

      // 启动后台测速,测完后自动切到最快源
      _testAllSourcesInBackground();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sourcesLoading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  /// 过滤相关源：根据标题相似度和年份匹配
  /// 返回过滤后的源列表，至少保留 1 个源（避免全部过滤掉）
  List<SearchResult> _filterRelevantSources(
      String searchTitle, String searchYear, List<SearchResult> results) {
    if (results.isEmpty) return results;

    final scored = results.map((r) {
      final titleScore = _calculateTitleSimilarity(searchTitle, r.title);
      final yearMatch = _isYearMatch(searchYear, r.year);
      return (result: r, titleScore: titleScore, yearMatch: yearMatch);
    }).toList();

    // 过滤策略：
    // 1. 标题相似度 >= 0.6 且年份匹配（或年份未知）
    // 2. 如果过滤后为空，则放宽到标题相似度 >= 0.4
    // 3. 如果还为空，返回原始结果（至少保留 1 个）
    
    var filtered = scored.where((s) => 
      s.titleScore >= 0.6 && (s.yearMatch || s.result.year.isEmpty || searchYear.isEmpty)
    ).toList();

    if (filtered.isEmpty) {
      filtered = scored.where((s) => s.titleScore >= 0.4).toList();
    }

    if (filtered.isEmpty) {
      // 兜底：按标题相似度排序，取最高的
      scored.sort((a, b) => b.titleScore.compareTo(a.titleScore));
      return [scored.first.result];
    }

    // 按标题相似度降序排序
    filtered.sort((a, b) => b.titleScore.compareTo(a.titleScore));
    return filtered.map((s) => s.result).toList();
  }

  /// 计算两个标题的相似度（0.0 - 1.0）
  /// 使用字符级别的编辑距离算法，适合中文标题比较
  double _calculateTitleSimilarity(String title1, String title2) {
    if (title1.isEmpty || title2.isEmpty) return 0.0;
    
    // 完全匹配
    if (title1 == title2) return 1.0;
    
    // 包含关系（如 "流浪地球" 包含在 "流浪地球2" 中）
    if (title1.contains(title2) || title2.contains(title1)) {
      final shorter = title1.length < title2.length ? title1 : title2;
      final longer = title1.length >= title2.length ? title1 : title2;
      return shorter.length / longer.length;
    }
    
    // 计算编辑距离相似度
    final distance = _editDistance(title1, title2);
    final maxLen = title1.length > title2.length ? title1.length : title2.length;
    if (maxLen == 0) return 1.0;
    
    return 1.0 - (distance / maxLen);
  }

  /// 计算两个字符串的编辑距离（Levenshtein distance）
  int _editDistance(String s1, String s2) {
    final m = s1.length;
    final n = s2.length;
    
    // 创建 DP 表
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    
    // 初始化边界
    for (int i = 0; i <= m; i++) {
      dp[i][0] = i;
    }
    for (int j = 0; j <= n; j++) {
      dp[0][j] = j;
    }
    
    // 填充 DP 表
    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        if (s1[i - 1] == s2[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1];
        } else {
          dp[i][j] = 1 + [dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]].reduce((a, b) => a < b ? a : b);
        }
      }
    }
    
    return dp[m][n];
  }

  /// 检查年份是否匹配
  /// 允许 ±1 年的容差（处理不同平台年份记录差异）
  bool _isYearMatch(String year1, String year2) {
    if (year1.isEmpty || year2.isEmpty) return true; // 年份未知时不过滤
    
    final y1 = int.tryParse(year1);
    final y2 = int.tryParse(year2);
    
    if (y1 == null || y2 == null) return true; // 无法解析时不过滤
    
    return (y1 - y2).abs() <= 1; // 允许 ±1 年容差
  }

  /// 智能检索播放记录 (双轨制: PageCacheService 云端/缓存优先 + LocalModeStorageService 本地降级容灾)
  /// 支持短剧唯一 ID 精准匹配与标题匹配，彻底杜绝历史集数丢失
  Future<PlayRecord?> _tryLoadResume(String searchTitle, {String? dramaId}) async {
    try {
      List<PlayRecord> records = const [];
      final result = await PageCacheService().getPlayRecords(context);
      if (result.success && result.data != null && result.data!.isNotEmpty) {
        records = result.data!;
      }
      // 若云端未就绪或为空，无缝降级读取本地实时存储
      if (records.isEmpty) {
        records = await LocalModeStorageService.getPlayRecords();
      }
      if (records.isEmpty) return null;

      // 1. 若提供了 dramaId，优先按短剧唯一 ID 精准匹配 (最稳定可靠)
      if (dramaId != null && dramaId.isNotEmpty) {
        final cleanTargetId = DuanjuCoreBridge.cleanSeriesId(dramaId);
        final idMatches = records.where((r) {
          final cleanRecordId = DuanjuCoreBridge.cleanSeriesId(r.id);
          return cleanRecordId == cleanTargetId || r.id == dramaId;
        }).toList();
        if (idMatches.isNotEmpty) {
          idMatches.sort((a, b) => b.saveTime.compareTo(a.saveTime));
          return idMatches.first;
        }
      }

      // 2. 其次按 searchTitle 完全匹配
      final matches = records
          .where((r) => r.searchTitle == searchTitle || r.title == searchTitle)
          .toList();
      if (matches.isNotEmpty) {
        matches.sort((a, b) => b.saveTime.compareTo(a.saveTime));
        return matches.first;
      }
    } catch (_) {
      try {
        final localRecords = await LocalModeStorageService.getPlayRecords();
        if (dramaId != null && dramaId.isNotEmpty) {
          final cleanTargetId = DuanjuCoreBridge.cleanSeriesId(dramaId);
          final idMatches = localRecords.where((r) {
            final cleanRecordId = DuanjuCoreBridge.cleanSeriesId(r.id);
            return cleanRecordId == cleanTargetId || r.id == dramaId;
          }).toList();
          if (idMatches.isNotEmpty) {
            idMatches.sort((a, b) => b.saveTime.compareTo(a.saveTime));
            return idMatches.first;
          }
        }
        final matches = localRecords
            .where((r) => r.searchTitle == searchTitle || r.title == searchTitle)
            .toList();
        if (matches.isNotEmpty) {
          matches.sort((a, b) => b.saveTime.compareTo(a.saveTime));
          return matches.first;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 兼容老调用代理
  Future<PlayRecord?> _tryLoadResumeFromCloud(String searchTitle) =>
      _tryLoadResume(searchTitle);

  /// v1.0.47: episodeIndex 默认值改成 _currentEpisodeIndex 而不是 0
  /// 之前默认值是 0, 导致用户手动切源时 episode 被静默重置 (明明看到第 3 集,
  /// 点切源就被弹回第 1 集, 因为新源默认从 0 开始播)
  void _selectSource(SearchResult result, {int? episodeIndex}) {
    // 不传 episodeIndex: 尽量保留当前 episode
    //   - 切到的就是当前源 (罕见, 防呆): 不动 episode
    //   - 切到新源: 尽量用当前 episode (新源可能有这么多集)
    final int target = episodeIndex ?? _currentEpisodeIndex;
    final maxIdx = result.episodes.isEmpty ? 0 : result.episodes.length - 1;
    final clampedIndex = target.clamp(0, maxIdx);
    setState(() {
      _selectedSource = result;
      _currentEpisodeIndex = clampedIndex;
    });
    // v2.0.51: 切源后 PageView 跳到当前 episode 所在页
    final newPage = (clampedIndex ~/ _episodesPerPage).clamp(0, 999);
    if (_episodesPageController.hasClients &&
        _episodesPageController.page?.round() != newPage) {
      _episodesPageController.jumpToPage(newPage);
    }
    // v2.6.93: 切源时重置智能跳过状态
    _hasAutoSkippedThisEp = false;
    _dismissedSmartSegmentThisEp = false;
    _dismissedIntroThisEp = false;
    _dismissedOutroThisEp = false;
    _hasAutoSkippedIntroThisEp = false;
    _hasAutoSkippedOutroThisEp = false;
    _isTransitioningEpisode = false;
    // v2.6.41: 切集时重置缩放 — 上一集放大了, 新一集不该沿用.
    _videoScale = 1.0;
    _pinchPointers.clear();
    _pinchInitialDistance = 0.0;
  }

  /// 后台测速所有源：并发用 M3U8Service 测速, 并按综合分从高到低排序源列表
  /// v1.0.45: 完整测速 (分辨率 + 下载速度 + ping) 替代 v1.0.40 之前的简单 HEAD ping
  ///
  /// v2.3.30 测速 UX 改进: 测一个源出一个结果, 排一次.
  ///   用户反馈 "能不能测快点太慢了" + "测一个出一个结果测一次测一个源排一次排行"
  ///   v2.3.23 注释里写的 "颜色变化 = 排序错觉" 已经是过虑:
  ///     - 之前 _pingState 渐变 (testing → fast/slow) 但 _sourceResults 顺序没动
  ///       → 用户看到的 "颜色变" 跟 "排" 不一致, 所以才是错觉
  ///   v2.3.30 改: 测完一源就 setState + _sortSourcesBySpeed, 颜色变 + 列表
  ///     顺序变同步发生, 不再是错觉. 用户能立刻看到结果跟排行变化.
  ///   3 并发 batch 内, 最多 3 次连续 setState (一个完成 setState 一次),
  ///   Flutter 内部 frame scheduler 合并, 实际渲染帧数 ≈ 批大小. 性能
  ///   跟 v2.3.23 一次 setState 几乎一致.
  Future<void> _testAllSourcesInBackground() async {
    // 先标记所有源为测速中
    final pending = <_SourcePingItem>[];
    for (final s in _sourceResults) {
      if (s.episodes.isEmpty) continue;
      _pingState[s.source] = PingState.testing;
      pending.add(_SourcePingItem(s));
    }
    if (mounted) setState(() {});

    // v2.3.23 提速: m3u8_service.dart 内部 4 步串行变 1 步并发,
    //   单源测速从 ~6s → ~2s, 3 并发批 6 个源 6s 测完, 比 v2.3.22 12s 快 2 倍
    // v2.3.30: 测一个源出一个结果 — 测完一源立即 setState + 排序
    const maxConcurrent = 3;
    final m3u8 = M3U8Service();
    for (var i = 0; i < pending.length; i += maxConcurrent) {
      final batch = pending.skip(i).take(maxConcurrent);
      await Future.wait(batch.map((item) async {
        final speed = await _testSourceSpeed(m3u8, item.source);
        if (!mounted) return;
        _sourceSpeeds[item.source.source] = speed;
        _pingState[item.source.source] = _stateFromSpeed(speed);
        // v2.3.30: 每源测完立即 setState + 排序, 用户能看到 "测一个出一个,
        //   测一次排一次". _sortSourcesBySpeed 内部已经 setState.
        _sortSourcesBySpeed();
      }));
    }

    if (!mounted) return;

    // 自动选最快源 (除非用户已经主动选过, 或从历史点进来明确指定了源)
    // v1.0.46 fix: 之前从历史进来也会被自动改源, 因为 _selectSource 不传 episodeIndex
    //   会重置到 0, 导致每次历史播放都从第 1 集开始
    // v2.3.14: 跟 v2.3.0 score 公式方向一致, 越小越好. 失败源 (score = 1<<30) 排最后.
    final cameFromHistory = widget.videoInfo.source.isNotEmpty && widget.videoInfo.index > 0;
    if (!cameFromHistory && _autoSelectedSource == null && _sourceResults.isNotEmpty) {
      _SourceSpeedInfo? bestSpeed;
      String? bestSource;
      for (final s in _sourceResults) {
        final sp = _sourceSpeeds[s.source];
        if (sp == null) continue;
        if (bestSpeed == null || sp.score < bestSpeed.score) {
          bestSpeed = sp;
          bestSource = s.source;
        }
      }
      if (bestSource != null) {
        _autoSelectedSource = bestSource;
        final src = _sourceResults.firstWhere((s) => s.source == bestSource);
        if (_selectedSource?.source != bestSource) {
          _selectSource(src);
        }
      }
    } else if (cameFromHistory) {
      // 从历史进来的: 标记自动已选 (用历史源), 防止后续逻辑再触发自动切源
      _autoSelectedSource = _selectedSource?.source ?? widget.videoInfo.source;
    }
    // v2.3.30: 不再末尾统一 sort, 上面 Future.wait 里每源测完就调过
    //   _sortSourcesBySpeed. 列表顺序在每源测完时已经最终化.
  }

  /// v2.3.0: 测速链路简化. 之前逻辑:
  ///   1. URL 走 `buildProxiedUrl`: 视频代理 on 拿 worker URL, 视频代理 off 拿原 URL
  ///      (buildProxiedUrl 内部 `_isCfWorkerUsableSync` 已经按「视频代理」开关处理,
  ///       开关没开就原样返回, 不需要外部 if/else)
  ///      v2.0.76: 改用「视频代理」开关 (之前是「总开关」, 新语义下总开关没了)
  ///   2. 外层 timeout 4s → 8s, 让 worker 代理下 \`getStreamInfo\` 有时间跑完
  ///   3. **fallback 升级**: 之前 \`_fallbackHeadPing\` 只 HEAD 测一次 ms,
  ///      loadSpeedKBps 永远 0 → UI 只显示 ms 看不到 KB/s (用户上条反馈的现象)
  ///      现在改成 \`_fallbackLightSpeed\`: HEAD 测 ms + Range 测 KB/s 并发,
  ///      即使 getStreamInfo 全失败 fallback 也能给出完整测速结果
  ///
  /// 现在 buildProxiedUrl / CfOptimizer / VideoProxyServer 整个删了, 测速
  ///   直接用 originalUrl, 不用 worker 包装, 不用 originalUrl 二次 fallback
  ///   (因为 url == originalUrl, 测一次就够).
  Future<_SourceSpeedInfo> _testSourceSpeed(M3U8Service m3u8, SearchResult s) async {
    if (s.episodes.isEmpty) return _SourceSpeedInfo.unavailable();
    // v2.3.5: 测速必须跟播放使用同一个最终 URL。
    //   播放会先跑 _resolveSharePageUrl() 把 /share/xxx HTML 分享页解析成
    //   真实 m3u8; 旧测速直接拿 episodes.first, 等于拿 HTML / 跳转页测速,
    //   UI 就会出现只有延迟、0KB/s、1KB/s 等假数据。
    final rawUrl = s.episodes.first;
    final url = await _resolveSharePageUrl(rawUrl);
    DiaryService.add(
        '[Video] _testSourceSpeed begin: title=${s.title}, isProxied=false, rawUrl=$rawUrl, resolvedUrl=$url (v2.3.5 same as playback URL)');
    return _testOneUrl(m3u8, url, originalUrl: url);
  }

  /// 单 URL 测速, 内部走 m3u8.getStreamInfo
  ///
  /// v2.3.9: getStreamInfo 改成 3 步并发 (HEAD latency + 下 256KB 测速 +
  ///   m3u8 解析) 整体 2.5s 内跑完. 之前的 6s timeout 仍然能 cover 整个
  ///   链路, 不会出现"测速永远跑不完外层 timeout" 的问题.
  ///
  /// v2.3.11: getStreamInfo 内部 speed 任务可能要 m3u8 链 (master →
  ///   variant → segment, 3 次 GET 各 1.8s = 5.4s 最坏), 加上 latency
  ///   / resolution 各自 1.5s, 整函数 max 5.4s. 外层 timeout 从 5s 提到
  ///   7s 留余量. 截图反馈 "完全没速度显示了" 的根因是 m3u8 master
  ///   playlist < 32KB 被旧版 _measureDownloadSpeedFast256K 拒掉,
  ///   v2.3.11 m3u8_service.dart 内部已修, 走 variant/segment 真实分片.
  /// v2.3.24: 外层 timeout 5s → 12s, 跟 m3u8 master→variant 8s 链 + 2.8s
  ///   seg 测速 + 5s latency 链路对齐. 之前 v2.3.23 5s outer 是基于
  ///   「4 步并发, 4s 跑完」 算的, 但实际 m3u8 拉 master→variant 是
  ///   串行 4+4=8s, outer 5s 在 chain 阶段就砍, 猫眼/非凡这种 master
  ///   playlist 源 100% "不可用". v2.3.24 latency 跟 m3u8 fetch 并发
  ///   (在 m3u8_service.dart 里), 整链路 max(8s 链, 5s latency) + 2.8s
  ///   seg = 10.8s 最坏, 12s outer 留 1.2s buffer.
  ///
  /// v2.5.21: 加 fallback 链. 之前 v2.3.9 直接把 fallback _fallbackLightSpeed
  ///   拿掉, 理由是"行为重复容易全 timeout". 但用户反馈"测速太多不可用",
  ///   实际是 v2.3.9 之后很多"勉强能播"的源 (慢但可用, 或 share page 解析
  ///   失败但顶层 URL 还能响应) 全部归到"不可用"了. 现在两段式:
  ///     1. 完整 m3u8 测速 (10s): 拿到 resolution + segment speed + latency
  ///     2. fallback (5s): getStreamInfo 失败时, 用 HEAD + Range 64KB 测
  ///        顶层 URL, 拿到 ms + KB/s (没 resolution, 跟旧 v2.3.7 行为一致)
  ///   总预算 15s, 跟单源 v2.3.24 12s outer 相比多 3s, 但能多救 30% 源.
  ///
  /// v2.5.22: fallback outer 3s → 5s. 之前 v2.5.21 把 3 个 fallback 函数
  ///   的内部 timeout 都调长了 (latency 2s→3s, download 1.5s→2.5s, m3u8
  ///   2s→3s), 3s outer 反而把调长后的链路重新砍掉, 走不到 success 分支.
  ///   现在 5s outer 跟 m3u8 测速内部 3s + latency 3s + download 2.5s 串起来
  ///   最坏 8.5s 留 -3.5s 余量. 实际 Future.wait 是并发, 端到端 max(3s, 2.5s)=3s,
  ///   5s outer 留 2s 余量. 测速单源总预算 15s (10s + 5s), 6 源 3 并发
  ///   30s 内测完, 用户体验几乎无感.
  Future<_SourceSpeedInfo> _testOneUrl(
    M3U8Service m3u8,
    String url, {
    String? originalUrl,
  }) async {
    // v2.5.21: 第 1 段 — 完整 m3u8 测速 (10s 预算, 跟 v2.3.24 12s 留 2s 给 fallback)
    try {
      final result = await m3u8.getStreamInfo(
        url,
        // v2.3.0: 视频加速删了, 不用 originalUrl 二次 fallback (url==originalUrl)
        originalUrl: originalUrl,
        // v2.3.0: 视频加速删了, 不用 urlWrapper 包装段 URL
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => <String, dynamic>{
          'resolution': {'width': 0, 'height': 0},
          'downloadSpeed': 0.0,
          'latency': 0,
          'success': false,
          'error': 'timeout',
        },
      );
      if (result['success'] == true) {
        final res = (result['resolution'] as Map).cast<String, int>();
        final h = res['height'] ?? 0;
        return _SourceSpeedInfo(
          resolution: _formatResolution(h),
          loadSpeedKBps: (result['downloadSpeed'] as num).toDouble(),
          pingMs: (result['latency'] as num).toInt(),
          success: true,
        );
      }
    } catch (_) {}

    // v2.5.21: 第 2 段 — fallback. getStreamInfo 失败/timeout 时, 用
    //   _fallbackLightSpeed (HEAD + Range 64KB) 测顶层 URL. 之前 v2.3.9
    //   直接 unavailable, 很多 "能响但 m3u8 解析失败" 的源 (CDN 403 /
    //   限流 / 分享页跳转 / 跨域广告段) 全死, 用户看到 "测速全不可用".
    //   现在 fallback 给 ms + KB/s, UI 拼 "Xms · YMB/s" (没分辨率空着).
    // v2.5.22: outer 3s → 5s, 跟调长后的 fallback 内部 timeout 对齐.
    try {
      final fallback = await _fallbackLightSpeed(url).timeout(
        const Duration(seconds: 5),
        onTimeout: () => _SourceSpeedInfo.unavailable(),
      );
      if (fallback.success) {
        return fallback;
      }
    } catch (_) {}

    return _SourceSpeedInfo.unavailable();
  }

  String _formatResolution(int h) {
    if (h <= 0) return '';
    if (h >= 2160) return '4K';
    return '${h}p';
  }

  /// v1.0.69: fallback 升级 — HEAD 测 ms + Range 测 KB/s 并发
  ///
  /// 之前 \`_fallbackHeadPing\` 只 HEAD 测一次 ms, loadSpeedKBps 永远 0,
  /// UI 走 success 分支但 KB/s 段为空, 只显示 "Xms" 看不到速度 (用户上条反馈).
  /// 现在 HEAD + Range 并发, 即使 getStreamInfo 全失败, fallback 也能给
  /// 完整 ms + KB/s 数据, UI 拼成 "Xms · YMB/s".
  ///
  /// 行为细节:
  ///   - HEAD: 测 worker 转发到 upstream 的"首字节延迟" (worker URL 下)
  ///           测 client 到 upstream 的延迟 (原始 URL 下)
  ///   - Range bytes=0-65535: 取前 64KB 算下载速度
  ///     跟 [m3u8_service.dart] 的 \`_measureDownloadSpeedFast\` 同思路
  ///   - 两者都 1.5s 超时, 失败分别返回 3000ms / 0KB/s
  ///   - 用一个共享 http.Client, 测完 finally 关闭避免泄漏
  ///
  /// v1.0.74: 调 [_testOneUrl] 时传的 url 改成 originalUrl (上游 m3u8 URL),
  /// 这样 worker 配错时 fallback 测的是源真实速度, 不是 worker 限制撞墙.
  Future<_SourceSpeedInfo> _fallbackLightSpeed(String url, {String? altUrl}) async {
    final httpClient = http.Client();
    // v2.1.34: 优先用 altUrl (worker URL) 测 latency, 因为 worker URL 走
    //   CDN 加速 + 跨域代理, 在国内网络上更稳, 不容易被 upstream 拦
    //   (e.g. 某些 m3u8 upstream 拒直连). 测不到再退到 originalUrl.
    final latencyTarget = altUrl ?? url;
    try {
      final results = await Future.wait([
        _fallbackMeasureLatency(httpClient, latencyTarget),
        _fallbackMeasureDownloadSpeed(httpClient, url),
      ]).timeout(const Duration(milliseconds: 6500));
      // v2.5.32: 2500 → 6500ms. 内部 latency 3s + download 2.8s 是并发,
      //   但 2.5s 外层连一次 download 都跑不完, 直接砍 → kbps=0 → UI
      //   只显示延迟没速度 (v2.5.22 调长内部 timeout 后更严重, 注释里
      //   "总预算 15s (10s+5s)" 跟这里 2.5s 对不上). 提到 6.5s 跟
      //   m3u8_service._measureDownloadSpeedFast 的 6s 单源预算对齐.
      final ms = (results[0] as num).toInt();
      final kbps = (results[1] as num).toDouble();
      // v2.1.38: 严格 success — ms>0 (没掉到 -1 哨兵) 或 kbps>0 (下载真成功).
      //   旧判断 `ms > 0 && ms < 5000` 已废弃, 3000 不再返回, 但 ms<5000
      //   还包含 -1 (latency 失败) + 真数据 组合场景, 也会漏出.
      //   改 ms>0 || kbps>0 — 任一成功就算部分成功, 不让 -1 假数据漏出.
      final latencyOk = ms > 0;
      final downloadOk = kbps > 0;
      if (!latencyOk && !downloadOk) {
        return _SourceSpeedInfo.unavailable();
      }
      return _SourceSpeedInfo(
        resolution: '',
        loadSpeedKBps: downloadOk ? kbps : 0,
        // 测不到延迟时 pingMs=0, UI 端 `if (speed.pingMs > 0)` 自动过滤, 不会显示 "0ms"
        pingMs: latencyOk ? ms : 0,
        success: true,
      );
    } catch (_) {
      // v2.1.34: 兜底再试一次 originalUrl (如果 altUrl 失败)
      if (altUrl != null && altUrl != url) {
        try {
          final ms = await _fallbackMeasureLatency(httpClient, url)
              .timeout(const Duration(milliseconds: 1500));
          if (ms > 0) {
            return _SourceSpeedInfo(
              resolution: '',
              loadSpeedKBps: 0,
              pingMs: ms,
              success: true,
            );
          }
        } catch (_) {}
      }
      return _SourceSpeedInfo.unavailable();
    } finally {
      httpClient.close();
    }
  }

  /// v2.1.38: 改用 GET 测延迟 + 失败返回 -1 哨兵 (不再用 3000 模糊值)
  ///   - 旧版本用 HEAD 测, 但 m3u8 源很多不支持 HEAD (405/501), 走到 catch
  ///     返回 3000, 外面 success 检查 `ms > 0 && ms < 5000` 居然把 3000 当成
  ///     成功, UI 显示假数据 "0KB/s · 3000ms" / "38KB/s · 3000ms".
  ///   - 改用 GET Range: 0-0 拿 1 字节, 强制 drain stream 拿真实首字节延迟.
  ///   - 失败返回 -1 (跟 m3u8_service._measureLatency 保持一致), success 改
  ///     `ms > 0` 严格过滤.
  ///
  /// v2.5.22: 加浏览器 headers (User-Agent + Referer + Accept). 之前裸 GET
  ///   部分 CDN 返 403 → fallback 全失败 → "不可用". 现在跟 ExoPlayer
  ///   播放链路 header 一致, 让测速能通过 anti-bot 校验.
  ///   timeout 2s → 3s: 慢网下 2s 经常截断返 -1, 现在拉到 3s 跟主链路
  ///   (m3u8_service._measureLatency 5s) 留 2s 余量.
  Future<int> _fallbackMeasureLatency(http.Client client, String url) async {
    final start = DateTime.now();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2
        ..headers.addAll(_browserHeaders)
        ..headers.addAll(_refererHeaderFor(url))
        ..headers['Range'] = 'bytes=0-0';
      final resp = await client.send(req).timeout(const Duration(milliseconds: 3000));
      // 关掉 stream 释放连接 (Range: 0-0 拿 0~1 字节, 读完就 OK)
      try {
        await resp.stream.drain<void>().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
      return DateTime.now().difference(start).inMilliseconds;
    } catch (_) {
      return -1; // v2.1.38: 失败明确返回 -1, 不再用 3000 模糊
    }
  }

  Future<double> _fallbackMeasureDownloadSpeed(http.Client client, String url) async {
    try {
      // v2.3.7: fallback 也要对 m3u8 测真实分片速度，不再直接返回 0
      //   当 URL 是 m3u8 时，解析 playlist 并下载真实分片测速
      if (_looksLikeM3u8Url(url)) {
        return await _fallbackMeasureM3u8Speed(client, url);
      }
      final stopwatch = Stopwatch()..start();
      final req = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 2
        ..headers.addAll(_browserHeaders)
        ..headers.addAll(_refererHeaderFor(url))
        ..headers['Range'] = 'bytes=0-65535';
      // v2.5.22: timeout 1.5s → 2.5s. 之前 1.5s 在慢网下经常截断, 现在
      //   跟 m3u8_service._measureDownloadSpeedFast 6s 留 3.5s 余量.
      final resp = await client.send(req).timeout(const Duration(milliseconds: 2500));
      // 把 body 读完才能算下载速度
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 65536) break; // Range 只取 64KB, 收够就停
        if (stopwatch.elapsedMilliseconds > 2400) break; // 兜底
      }
      stopwatch.stop();
      final n = bytes.length;
      if (n == 0) return 0.0;
      final sec = stopwatch.elapsedMilliseconds / 1000.0;
      if (sec <= 0) return 0.0;
      return (n / 1024) / sec; // KB/s
    } catch (_) {
      return 0.0;
    }
  }

  /// v2.3.7: fallback m3u8 测速 - 解析 playlist 并下载真实分片
  ///   跟 m3u8_service 的 _measureSegmentSpeeds 思路一致，但用 http.Client
  ///   避免创建新的 Dio 实例。解析 m3u8 获取分片 URL，下载前几个分片测速。
  ///
  /// v2.5.22: 加浏览器 headers + 调长 timeout. 之前裸 GET 部分 CDN 403,
  ///   m3u8 拉取失败 → 返回 0.0 → fallback unavailable.
  ///   timeout 2s → 3s, segment 1.5s → 2.5s 跟 m3u8_service 对齐.
  Future<double> _fallbackMeasureM3u8Speed(http.Client client, String m3u8Url) async {
    try {
      // 1. 下载 m3u8 playlist
      final playlistReq = http.Request('GET', Uri.parse(m3u8Url))
        ..followRedirects = true
        ..maxRedirects = 2
        ..headers.addAll(_browserHeaders)
        ..headers.addAll(_refererHeaderFor(m3u8Url));
      final playlistResp = await client.send(playlistReq).timeout(const Duration(milliseconds: 3000));
      final playlistContent = await playlistResp.stream.bytesToString();

      // 2. 解析分片 URL
      final segments = _parseM3u8Segments(playlistContent, m3u8Url);
      if (segments.isEmpty) return 0.0;

      // 3. 下载前 2 个分片测速（跳过可能的 init 段）
      final testSegments = segments.length > 2 ? segments.skip(1).take(2) : segments.take(2);
      final stopwatch = Stopwatch()..start();
      int totalBytes = 0;

      for (final segmentUrl in testSegments) {
        try {
          final segReq = http.Request('GET', Uri.parse(segmentUrl))
            ..followRedirects = true
            ..maxRedirects = 2
            ..headers.addAll(_browserHeaders)
            ..headers.addAll(_refererHeaderFor(segmentUrl));
          final segResp = await client.send(segReq).timeout(const Duration(milliseconds: 2500));
          await for (final chunk in segResp.stream) {
            totalBytes += chunk.length;
            if (totalBytes >= 512 * 1024) break; // 最多 512KB
            if (stopwatch.elapsedMilliseconds > 2400) break; // 最多 2.4s
          }
        } catch (_) {
          // 单个分片失败不影响整体
        }
        if (stopwatch.elapsedMilliseconds > 2400) break;
      }

      stopwatch.stop();
      if (totalBytes < 64 * 1024) return 0.0; // 样本太小
      final sec = stopwatch.elapsedMilliseconds / 1000.0;
      if (sec <= 0) return 0.0;
      return (totalBytes / 1024) / sec; // KB/s
    } catch (_) {
      return 0.0;
    }
  }

  /// 解析 m3u8 playlist 获取分片 URL 列表
  List<String> _parseM3u8Segments(String content, String baseUrl) {
    final segments = <String>[];
    final lines = content.split('\n');
    
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      
      // 跳过子 playlist（master playlist 中的 variant）
      if (trimmed.endsWith('.m3u8') || trimmed.endsWith('.m3u')) continue;
      
      // 解析相对/绝对 URL
      String segmentUrl;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        segmentUrl = trimmed;
      } else if (trimmed.startsWith('/')) {
        final uri = Uri.parse(baseUrl);
        segmentUrl = '${uri.scheme}://${uri.host}$trimmed';
      } else {
        final uri = Uri.parse(baseUrl);
        final basePath = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
        segmentUrl = '${uri.scheme}://${uri.host}$basePath$trimmed';
      }
      
      segments.add(segmentUrl);
    }
    
    return segments;
  }

  bool _looksLikeM3u8Url(String url) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      return path.endsWith('.m3u8') || path.endsWith('.m3u');
    } catch (_) {
      final lower = url.toLowerCase();
      return lower.contains('.m3u8') || lower.contains('.m3u');
    }
  }

  PingState _stateFromSpeed(_SourceSpeedInfo s) {
    if (!s.success) return PingState.unavailable;
    // 速度 > 500KB/s 且 ping < 1000ms = fast
    // 速度 < 100KB/s 或 ping > 2000ms = slow
    if (s.loadSpeedKBps >= 500 && s.pingMs < 1000) return PingState.fast;
    if (s.loadSpeedKBps >= 200 && s.pingMs < 2000) return PingState.medium;
    return PingState.slow;
  }

  /// 按测速综合分从低到高排序源列表
  /// v2.3.0 ~ v2.3.5: 跟 score 公式方向一致 (越小越好), 排序从小到大.
  ///   失败源 (score = 1<<30) 自动排最后.
  /// v2.3.12 改大到小, v2.3.14 回到小到大.
  void _sortSourcesBySpeed() {
    setState(() {
      _sourceResults.sort((a, b) {
        final sa = _sourceSpeeds[a.source];
        final sb = _sourceSpeeds[b.source];
        if (sa == null && sb == null) return 0;
        if (sa == null) return 1; // 未测的排后面
        if (sb == null) return -1;
        return sa.score.compareTo(sb.score); // 小到大
      });
    });
  }

  // v1.0.45: 删了 v1.0.40 之前的 _pingSource (简单 HEAD ping) 和 _stateFromMs,
  // 改用 M3U8Service 测速 + _stateFromSpeed. 老方法没人调, 留在这里只是 dead code.
  // 如需 HEAD ping fallback, 看 _fallbackHeadPing.

  /// position stream 触发的检查: 距离结尾 < 1.5s 时尝试自动切下一集
  void _maybeAutoPlayNext() {
    if (_autoPlayedThisEpisode) return;
    final dur = _currentDuration;
    if (dur <= Duration.zero) return; // 时长还没拿到, 不要误判
    final remainMs = dur.inMilliseconds - _currentPosition.inMilliseconds;
    if (remainMs > 1500) return; // 还没到结尾附近
    _autoPlayNextEpisode();
  }

  /// 切到下一集: 只有在「还有下一集」时才自动播放
  /// 最后一集播完就停在播放页, 不再继续
  ///
  /// v1.0.55: 加 pos + dur 兜底守门
  /// 之前没守门, 走 streams.completed listener 直接调本函数时
  /// (line 198 `streams.completed.listen((_) { _autoPlayNextEpisode(); })`)
  /// 不经过 _maybeAutoPlayNext 的 remainMs > 1500 守门, 一发就切
  /// 用户场景: 播放第2集没看完, 重开第2集 → video open 后 m3u8 源立刻发
  /// streams.completed=true (直播流 / 解析失败 / seek 到 duration 附近) →
  /// _autoPlayNextEpisode → 切第3集
  /// 修法: pos 必须 ≥ dur - 1.5s 才允许切 (跟 _maybeAutoPlayNext 同阈值),
  ///       dur < 30s 也跳过 (直播流 / 异常源)
  void _autoPlayNextEpisode() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isEpisodeSwitching || _isTransitioningEpisode || _autoPlayedThisEpisode) return;
    if (now - _lastEpisodeSwitchTimeMs < 2500) return; // 2.5s 硬防抖拦截
    if (_phase != 'playing') return;
    final source = _selectedSource;
    if (source == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex >= source.episodes.length) {
      // 本季最后一集播完！触发居中连播/推荐弹层
      _handleLastEpisodeCompletion();
      return;
    }

    final isShortDrama = source.source == 'hongguo' ||
        source.source == 'shortdrama' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama';

    // 短剧通过 getPlaybackPlan 动态取流与获取解密密钥，非短剧才需校验预填充直链
    if (!isShortDrama && source.episodes[nextIndex].isEmpty) return; // 下一集没 url

    // v1.0.55: 兜底守门 (堵 streams.completed 误触发)
    final dur = _currentDuration;
    if (dur <= Duration.zero) return; // 时长还没拿到
    if (!isShortDrama && dur < const Duration(seconds: 30)) return; // 传统影视时长太短防异常，短剧不拦截
    if (_currentPosition < dur - const Duration(milliseconds: 1500)) {
      // pos 还没到结尾附近, completed 误触发, 不切
      return;
    }

    _autoPlayedThisEpisode = true; // 立刻上锁, 防止 position/completed 双触发
    _isEpisodeSwitching = true;
    _isTransitioningEpisode = true;
    _lastEpisodeSwitchTimeMs = now;
    _playEpisode(nextIndex);
  }

  /// v2.0.33: 手动「下一集」— 用户主动点播控上的 skip_next 按钮.
  void _playNextEpisode() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isEpisodeSwitching || _isTransitioningEpisode || _autoPlayedThisEpisode) return;
    if (now - _lastEpisodeSwitchTimeMs < 2500) return;
    if (_phase != 'playing') return;
    final source = _selectedSource;
    if (source == null) return;
    final nextIndex = _currentEpisodeIndex + 1;
    if (nextIndex >= source.episodes.length) return; // 最后一集

    final isShortDrama = source.source == 'hongguo' ||
        source.source == 'shortdrama' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama';

    if (!isShortDrama && source.episodes[nextIndex].isEmpty) return; // 下一集没 url
    _autoPlayedThisEpisode = true;
    _isEpisodeSwitching = true;
    _isTransitioningEpisode = true;
    _lastEpisodeSwitchTimeMs = now;
    _playEpisode(nextIndex);
    // 给个轻提示 (主路是控制栏图标变了, 提示只是兜底)
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在切换下一集…'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// v2.3.0: 删了 _ensureVideoProxy / _startSpeedSampling / _playbackStateText.
  ///   视频加速链路整个删了, 不再启本地代理, 不再 1Hz 采样下载速度,
  ///   不再维护「已暂停 / 缓冲中 / 测量中」文本状态. playUrl = url 原源直连,
  ///   ExoPlayer 直连 CDN 拉 m3u8 / 段, 无任何代理层. 行为跟 v2.2.7 一致.

  /// v2.0.64: 解析分享页 HTML 提取真实视频 URL.
  ///
  /// 上游 CMS API 有时返回 /share/xxx 分享页 (HTML), 里面 JS 变量 url
  /// 才是真正的 m3u8 流. libmpv 不执行 JS, 直接 open 分享页 → 拿到 HTML
  /// → "Failed to recognize file format".
  ///
  /// 策略:
  ///   1. URL 看起来已经是视频流 (.m3u8/.mp4/.ts/.flv 后缀) → 直接返回, 不 fetch
  ///   2. fetch URL (带 5s 超时), 看 Content-Type:
  ///      - 是 text/html → 在 HTML 里找 m3u8/mp4 链接 (JS 变量 url / iframe / source)
  ///      - 不是 HTML → 直接返回原 URL (可能是二进制流, 别动)
  ///   3. 找到链接是相对路径 → 拼成绝对 URL (用 fetch 的最终 URL 作 base)
  ///   4. 找不到 → 返回原 URL, 让 libmpv 自己处理
  ///
  /// 失败 (超时/网络错) 不抛异常, 返回原 URL — 不影响播放, 最多就是
  /// 分享页解析失败退化成原来的"播不了"行为, 跟修之前一样.
  Future<String> _resolveSharePageUrl(String originalUrl) async {
    if (originalUrl.isEmpty) return originalUrl;

    // 1. 已经是视频流后缀 → 不解析
    final lower = originalUrl.toLowerCase();
    final videoExts = ['.m3u8', '.mp4', '.ts', '.flv', '.mkv', '.avi', '.mov'];
    // 去掉 query string 再判断后缀 (index.m3u8?sign=xxx 也要认)
    final pathPart = lower.split('?').first;
    if (videoExts.any((ext) => pathPart.endsWith(ext))) {
      return originalUrl;
    }

    // 2. fetch 看是不是 HTML. v2.5.21: 加 User-Agent + Range (1 字节) +
    //   接受 text/html 之外的内容类型 (部分 share page 返 application/javascript
    //   或 text/plain), 跟慢 CDN 兼容 (timeout 5s → 6s)
    try {
      // v2.5.21: 加 User-Agent, 部分 share page (DPlayer 模板 / 飞飞通用) 拦
      //   非浏览器请求返 403, 没 UA 会被识别成 bot 直接拒绝. 跟 Safari 18 UA
      //   拿一致, 跟 web LunaTV 一致
      final resp = await http.get(Uri.parse(originalUrl), headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,application/javascript,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      }).timeout(
        const Duration(seconds: 6),
      );
      final contentType = resp.headers['content-type'] ?? '';
      // v2.5.21: 不止看 text/html, 部分 share page 返 application/javascript
      //   (DPlayer 模板) 或 text/plain, 走同样解析流程
      final lowerCT = contentType.toLowerCase();
      final looksLikePage = lowerCT.contains('text/html') ||
          lowerCT.contains('application/xhtml') ||
          lowerCT.contains('application/javascript') ||
          lowerCT.contains('text/plain') ||
          lowerCT.contains('text/xml') ||
          lowerCT.contains('application/json');
      // 没 content-type 或非 HTML/JS 类型的响应, 跳过 (可能是二进制)
      if (contentType.isNotEmpty && !looksLikePage) {
        return originalUrl;
      }

      final html = resp.body;
      if (html.isEmpty) return originalUrl;

      // 3. 在 HTML/JS 里找 m3u8/mp4 链接
      //   常见模式 (dytt-tvs 实测):
      //     const url = "/20260627/.../index.m3u8?sign=xxx";
      //     var url = "https://.../video.m3u8";
      //   优先找带 .m3u8 / .mp4 的字符串
      final baseUri = resp.request?.url ?? Uri.parse(originalUrl);

      // v2.5.21: 多种 share page 模板匹配 (按命中率从高到低)
      //   - 飞飞通用: var main = "..."  /  var url = "..."
      //   - DPlayer 模板: url: 'https://...m3u8' (光速/玉兔/部分 ffzy 镜像)
      //   - <source src="..."> / <video src="..."> (HTML5 标签)
      //   - meta refresh: <meta http-equiv="refresh" content="0;url=...">
      //   - 任何 .m3u8 / .mp4 字符串匹配
      String? resolved;
      // 模式 1: const/let/var 关键字 + 名字 + = + URL
      for (final kw in const ['const', 'let', 'var']) {
        if (resolved != null) break;
        for (final name in const [
          'main', 'url', 'playurl', 'playUrl', 'hlsUrl', 'src', 'm3u8',
          'videoUrl', 'file', 'link', 'play_url', 'source'
        ]) {
          final m = RegExp(
            """\\b$kw\\s+$name\\s*=\\s*['"]([^'"]+\\.(?:m3u8|mp4)[^'"]*)['"]""",
            caseSensitive: false,
          ).firstMatch(html);
          if (m != null) {
            resolved = _resolveAbsoluteUrl(m.group(1)!, baseUri);
            break;
          }
        }
      }
      // 模式 2: 对象字面量 url: '...' (DPlayer)
      if (resolved == null) {
        final m = RegExp(
          """\\burl\\s*:\\s*['"]([^'"]+\\.(?:m3u8|mp4)[^'"]*)['"]""",
          caseSensitive: false,
        ).firstMatch(html);
        if (m != null) resolved = _resolveAbsoluteUrl(m.group(1)!, baseUri);
      }
      // 模式 3: <source src="..."> / <video src="...">
      if (resolved == null) {
        final m = RegExp(
          """<(?:source|video)[^>]+src=['"]([^'"]+\\.(?:m3u8|mp4)[^'"]*)['"]""",
          caseSensitive: false,
        ).firstMatch(html);
        if (m != null) resolved = _resolveAbsoluteUrl(m.group(1)!, baseUri);
      }
      // 模式 4: meta refresh 跳 m3u8
      if (resolved == null) {
        final m = RegExp(
          """<meta[^>]+http-equiv=["']?refresh["']?[^>]+url=([^'">\\s]+)""",
          caseSensitive: false,
        ).firstMatch(html);
        if (m != null) {
          final refreshUrl = m.group(1)!.trim();
          if (refreshUrl.contains('.m3u8') || refreshUrl.contains('.mp4')) {
            resolved = _resolveAbsoluteUrl(refreshUrl, baseUri);
          }
        }
      }
      // 模式 5: 任何 .m3u8 / .mp4 字符串 (兜底)
      if (resolved == null) {
        final m = RegExp(
          """['"]([^'"]+\\.(?:m3u8|mp4)[^'"]*)['"]""",
        ).firstMatch(html);
        if (m != null) resolved = _resolveAbsoluteUrl(m.group(1)!, baseUri);
      }
      // 模式 6: 兜底 — originalUrl + '/index.m3u8' (跟 m3u8_service._resolveSharePage
      //   一致, 处理 "v2.3.27 拼 base 路径会丢末段" 那个 bug, 直接 originalUrl 拼)
      if (resolved == null) {
        if (!originalUrl.endsWith('/') && !originalUrl.contains('.m3u8')) {
          resolved = '$originalUrl/index.m3u8';
        }
      }
      if (resolved != null && resolved != originalUrl) {
        return resolved;
      }
      return originalUrl; // 没找到, 原样返回
    } catch (e) {
      // 超时/网络错, 不影响播放, 原样返回
      return originalUrl;
    }
  }

  /// 把相对 URL 拼成绝对 URL.
  /// [relative] 可能是绝对 URL (http://...) 也可能是相对路径 (/path/...).
  /// [baseUrl] 是 fetch 的最终 URL (跟过 302 后的), 用来解析相对路径.
  String _resolveAbsoluteUrl(String relative, Uri baseUrl) {
    if (relative.startsWith('http://') || relative.startsWith('https://')) {
      return relative;
    }
    if (relative.startsWith('//')) {
      return '${baseUrl.scheme}:$relative';
    }
    // 相对路径 — 用 Uri.resolve 拼接 (会正确处理 /path 和 path 两种情况)
    return baseUrl.resolve(relative).toString();
  }

  /// 播放指定集数
  Future<void> _playEpisode(int index) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _isEpisodeSwitching = true;
    _autoPlayedThisEpisode = true;
    _lastEpisodeSwitchTimeMs = now;
    _smartSkipCountdownTimer?.cancel();
    _smartSkipCountdownTimer = null;
    try {
      _player?.pause();
    } catch (_) {}
    _currentPosition = Duration.zero;
    _lastKnownPosition = Duration.zero;

    final source = _selectedSource;
    if (source == null) return;
    if (index < 0 || index >= source.episodes.length) return;
    final originalUrl = source.episodes[index];
    if (originalUrl.isEmpty) return;
    // v2.0.23: 播放 URL 不再走 buildProxiedUrl 包 worker
    //   v2.0.14 把播放 URL 包了一层 CF Worker (https://<worker>/m3u8?url=...),
    //   导致"从 v2.0.14 开始没速度, 关掉 CF 加速就正常".
    //   根因: CF Worker 做视频流代理时, 每个 .ts 段都要 worker fetch 再返回,
    //   worker 有 CPU 时间限制 + subrequest 限制 + 不能高效流式转发大 body,
    //   长 HLS 几百段累计后视频流就断了 → "没速度" (不是慢, 是断了)
    //   v1.0.77 时播放走原 URL 直连 (worker 只给测速用), 所以没问题.
    //
    //   现在的加速方案:
    //   - VideoProxyServer (v2.0.16+, v2.0.22 修好) 通过 --http-proxy 让
    //     libmpv 走本地代理 → 竞速拨号优选 IP → CF edge, 不经过 worker
    //   - 代理没起 (条件不满足) → 直连原 URL, 用户反馈直连正常
    //   - 测速 (_testSourceSpeed) 继续走 buildProxiedUrl, 不受影响
    // v2.0.64: 解析分享页 HTML 提取真实视频 URL.
    //   上游 CMS API 有时返回 /share/xxx 分享页 (HTML), 里面 JS 变量 url 才是
    //   真正的 m3u8 流. libmpv 不执行 JS, 直接 open 分享页 → 拿到 HTML →
    //   "Failed to recognize file format". 修法: 检测是 HTML 就提取 m3u8.
    //   只对明显不是视频流 (非 .m3u8/.mp4/.ts/.flv 后缀) 的 URL 做 fetch,
    //   避免对正常视频流多一次 HTTP 请求.
    // 红果短剧专属直解：精准调用单集专属直链解析通道 (切集必须独立换流，绝不冒充)
    final isShortDrama = source.source == 'hongguo' ||
        source.source == 'shortdrama' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama';

    // 等待异步初始化完成，杜绝快速点击播放时并发重建播放器
    if (_initPlayerFuture != null) {
      await _initPlayerFuture;
    }

    // 播放器后端类型自适应：桌面端或短剧使用 DuanjuMediaKitBackend，移动端非短剧维持 ExoPlayerBackend
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if ((isShortDrama || isDesktop) && _player is! DuanjuMediaKitBackend) {
      await _switchPlayerBackend(true);
    } else if (!isShortDrama && !isDesktop && _player is! ExoPlayerBackend) {
      await _switchPlayerBackend(false);
    }

    String actualSourceUrl = originalUrl;
    DuanjuPlaybackPlan? duanjuPlan;
    if (isShortDrama || !originalUrl.startsWith('http')) {
      final dramaId = source.id.isNotEmpty ? source.id : widget.videoInfo.id;
      // 优先获取短剧专属播放计划 (包含真实 CENC 解密密钥与直链)
      duanjuPlan = await DuanjuCoreBridge.instance.getPlaybackPlan(
        dramaId: dramaId,
        episode: index + 1,
      );

      if (duanjuPlan != null && duanjuPlan.url.isNotEmpty) {
        actualSourceUrl = duanjuPlan.url;
        unawaited(_loadShortDramaDanmaku(auto: true));
        if (index < source.episodes.length) {
          source.episodes[index] = duanjuPlan.url;
        }
        final multiMap = duanjuPlan.multiMap.isNotEmpty
            ? duanjuPlan.multiMap
            : (DuanjuCoreBridge.instance.getEpisodeMultiResolutions(dramaId, index + 1) ??
                DuanjuCoreBridge.buildMultiResolutionUrls(duanjuPlan.url));
        _resolutionUrlMap
          ..clear()
          ..addAll(multiMap);
        // 对齐红果鉴：真实支持的分辨率列表
        if (duanjuPlan.qualities.isNotEmpty) {
          _availableResolutions = duanjuPlan.qualities.map((q) => '${q}P').toList();
        }
        if (_userPreferredResolution == '自动' || _userPreferredResolution.isEmpty) {
          _currentResolution = '自动';
          actualSourceUrl = duanjuPlan.url;
        } else if (multiMap.containsKey(_userPreferredResolution)) {
          final prefUrl = multiMap[_userPreferredResolution];
          if (prefUrl != null && prefUrl.isNotEmpty) {
            actualSourceUrl = prefUrl;
            _currentResolution = _userPreferredResolution;
          }
        } else {
          _currentResolution = '${duanjuPlan.actualQuality}P';
        }
      } else {
        // 兼容兜底: 走 resolvePlaybackUrl
        final candidateRawUrl = (index == 0 && originalUrl.startsWith('http')) ? originalUrl : null;
        String? resolved = await DuanjuCoreBridge.instance.resolvePlaybackUrl(
          dramaId: dramaId,
          episode: index + 1,
          rawUrl: candidateRawUrl,
        );
        // 增强兜底：若首次解析未拿到有效直链，强制重试解析一次
        if (resolved == null || resolved.isEmpty) {
          resolved = await DuanjuCoreBridge.instance.resolvePlaybackUrl(
            dramaId: dramaId,
            episode: index + 1,
          );
        }
        // 校验防冒充：若非第1集，且返回的地址与第1集完全一样，说明拿到试看集，强制重试解析
        if (resolved != null && index > 0 && source.episodes.isNotEmpty && resolved == source.episodes[0]) {
          resolved = await DuanjuCoreBridge.instance.resolvePlaybackUrl(
            dramaId: dramaId,
            episode: index + 1,
          );
        }

        if (resolved != null && resolved.isNotEmpty) {
          actualSourceUrl = resolved;
          if (index < source.episodes.length) {
            source.episodes[index] = resolved;
          }
          final multiMap = DuanjuCoreBridge.instance.getEpisodeMultiResolutions(dramaId, index + 1) ??
              DuanjuCoreBridge.buildMultiResolutionUrls(resolved);
          _resolutionUrlMap
            ..clear()
            ..addAll(multiMap);
          if (multiMap.containsKey(_userPreferredResolution)) {
            final prefUrl = multiMap[_userPreferredResolution];
            if (prefUrl != null && prefUrl.isNotEmpty) {
              actualSourceUrl = prefUrl;
              _currentResolution = _userPreferredResolution;
            }
          }
        }
      }
    }

    // 绝对安全防线：若尚未成功解析为 http 直链，尝试进行短剧专属强制重试
    if (!actualSourceUrl.startsWith('http') && isShortDrama) {
      final dramaId = source.id.isNotEmpty ? source.id : widget.videoInfo.id;
      final retryPlan = await DuanjuCoreBridge.instance.getPlaybackPlan(
        dramaId: dramaId,
        episode: index + 1,
      );
      if (retryPlan != null && retryPlan.url.startsWith('http')) {
        actualSourceUrl = retryPlan.url;
        duanjuPlan = retryPlan;
        unawaited(_loadShortDramaDanmaku(auto: true));
      }
    }

    // 绝对安全防线：若尚未成功解析为 http 直链，绝不将纯数字占位符传给播放内核
    if (!actualSourceUrl.startsWith('http')) {
      if (mounted) {
        final hintText = (isShortDrama && index >= 3)
            ? '第${index + 1}集为官方VIP保护剧集，前3集可免费秒开体验'
            : '第${index + 1}集视频地址解析中，请稍候重试...';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(hintText),
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() {
          _isBuffering = false;
        });
      }
      return;
    }

    final String url;
    if (isShortDrama) {
      // 短剧直链由官方接口生成并具备完整解密契约，严禁走 _resolveSharePageUrl 下载视频导致卡顿与数秒超时
      url = actualSourceUrl;
    } else {
      url = await _resolveSharePageUrl(actualSourceUrl);
      // 传统流异步分析当前播放流的分辨率，无多分辨率时常驻显示「原画」
      unawaited(_checkStreamResolutions(url));
    }
    _currentPlayUrl = url;

    // 切集时清零 _lastKnownPosition, 避免上一集的"主片位置"被新一集沿用
    // 导致进度同步兜底用错位置 (v2.1.13 起 _lastKnownPosition 只用于进度
    // 同步兜底, 广告跳过逻辑已移除, 不需要清其他字段).
    _lastKnownPosition = Duration.zero;
    // v2.6.93: 切集时重置智能跳过状态
    _hasAutoSkippedThisEp = false;
    _dismissedSmartSegmentThisEp = false;
    _dismissedIntroThisEp = false;
    _dismissedOutroThisEp = false;
    _hasAutoSkippedIntroThisEp = false;
    _hasAutoSkippedOutroThisEp = false;
    // v2.6.41: 切集时重置缩放 — 上一集放大了, 新一集不该沿用.
    _videoScale = 1.0;
    _pinchPointers.clear();
    _pinchInitialDistance = 0.0;

    // 记住这次要 seek 到的位置, 等 player 缓冲到可以 seek 时用
    // 仅在用户主动开新集时且和云记忆吻合的那次才用
    Duration? resumeAt;
    if (_pendingResumeAt != null && index == _currentEpisodeIndex) {
      resumeAt = _pendingResumeAt;
    }
    // 用完清掉, 避免切下一集时还 seek 回去
    _pendingResumeAt = null;

    // 切集时先保存上一条的进度
    //
    // v1.0.56: 必须在 setState 之前调! 之前是 setState 之后调,
    // setState 改了 _currentEpisodeIndex 成新集, _saveCurrentProgress
    // 内部 `index: _currentEpisodeIndex + 1` 算出的是**新集 index**,
    // 但此时 _player!.stop() 还没调, pos / _currentPosition / state.duration
    // 都还是**旧集**的值 — 错配 (playTime=旧集, index=新集)
    //
    // 用户场景 (v1.0.54 之前 streams.completed 误触发):
    //   1. 用户看第2集 30 分钟, 10s 定时器存 {index:2, playTime:30min} ✓
    //   2. streams.completed 误触发 → 切第3集 (v1.0.55 已修误触发)
    //   3. setState _currentEpisodeIndex=2 (第3集 0-based)
    //   4. _saveCurrentProgress(force:true) 存 {index:2+1=3, playTime:30min}
    //      ← 错误! 应该是 {index:2, playTime:30min}
    //   5. 覆盖云端 index=2 那条! 下次重开历史显示第3集
    //   6. 而且 playTime=30min 还是第2集的位置, 跟第3集 index 错配
    //      (用户报告"进度条记忆问题我也怀疑存的问题"就是这个)
    //
    // 修法: 把 setState 挪到 _saveCurrentProgress 之后, 让
    //       _currentEpisodeIndex 在 save 时还是旧值, 自动得到旧集 index
    if (_firstRecordSaved) {
      _saveCurrentProgress(force: true);
    }

    setState(() {
      _currentEpisodeIndex = index;
      _currentPosition = Duration.zero;
      _lastKnownPosition = Duration.zero;
      _isBuffering = true;
      _phase = 'playing';
      if (_isCurrentShortDrama) {
        _loadedDanmakuWindows.clear();
        _lastSyncedDanmakuPosMs = -1;
        _danmakuComments = const [];
        _danmakuCount = 0;
      }
    });
    if (_isCurrentShortDrama) {
      _danmakuKey.currentState?.reset();
    }
    // v2.6.92: 加载当前集的智能跳过片段 (TheIntroDB + TMDB 代理)
    _loadSmartSkipSegmentsForCurrentEpisode();
    // 若当前播放的是本季最后一集，静默预拉取下一季候选信息
    if (source.episodes.isNotEmpty && index >= source.episodes.length - 1) {
      _nextSeasonDismissedThisEp = false;
      _checkAndPreloadNextSeason();
    } else {
      _nextSeasonCandidate = null;
      _nextSeasonDismissedThisEp = false;
    }
    // 切集后立即重置并保存新集初始进度 (index=新集), 确保用户哪怕刚切完就退出也能记住新集
    _lastSavedKey = null;
    unawaited(_saveCurrentProgress(force: true));
    // v2.2.0+59: 进入播放阶段, 屏幕常亮 (ExoPlayer 默认不阻止屏保).
    //   离开播放页 (detail) 时会 clearFlags. 切集的话 _phase 还是 'playing',
    //   这里 enable=true 多次调无副作用 (addFlags 重复设置是幂等的).
    _setKeepScreenOn(true);
    // v2.6.42: 进入播放阶段, 开启音量拦截 (屏蔽系统音量弹窗 + 物理键接管).
    //   切集时 _phase 已经是 'playing', 重复调无副作用.
    _enableVolumeInterception();
    // v2.0.51: 切集后 PageView 跳到当前 episode 所在页 (用 jumpToPage, 静默切)
    final newPage = (index ~/ _episodesPerPage).clamp(0, 999);
    if (_episodesPageController.hasClients &&
        _episodesPageController.page?.round() != newPage) {
      _episodesPageController.jumpToPage(newPage);
    }

    // v2.3.0: playUrl 退化成原源直连 CDN. 视频加速链路整个删了:
    //   - 不 wrap (不调 buildProxiedUrl, 已删)
    //   - 不经本地代理 (不调 _ensureVideoProxy, 已删)
    //   - 不经 CF Worker 视频代理 (不调 videoProxy / CfOptimizer, 已删)
    //   - playUrl = url (原源 m3u8), ExoPlayer 直连 CDN 拉 m3u8 / 段
    //   跟 v2.2.7 行为一致.
    //   代价: 完全失去 worker 加速 + 手动优选 IP 优化. 国内用户可能遇到
    //     CDN 慢 / 不可达, 用户得自己判断要不要挂 VPN / 换源.
    final playUrl = url;
    DiaryService.add(
        '[Video] playUrl build: path=direct_cdn (v2.3.0 worker+local_proxy+optimization all removed), originalUrl=$url');

    // v2.0.58: 记录实际播放 URL + 代理状态, 分析 "4s/6s 时长" bug 的关键信号.
    //   v2.3.0: 不再有 buildProxiedUrl (CF Worker) + _videoProxy (本地代理),
    //   只剩原源直连 playUrl. _currentPlayUrl 字段已删, 加速链路弹层也删了.
    try {
      await _player!.stop();
      // v2.3.13 hotfix: 云记忆恢复 (resume) 改用 open(startAt:) 而不是
      //   open() + 之后 play() + seek(). 之前 v2.3.11 自研 CustomExoPlayer
      //   时, seek 放在 play() 之后, ExoPlayer 在 buffer 没填满时经常
      //   静默丢 seek, 用户从历史点进来还是从 0 开始.
      //
      //   v1.0.61 时 (走 media_kit / libmpv), video_player / libmpv 内部
      //   已经处理了 "prepare + startAt 在 play 前" 这套逻辑, 所以 seek
      //   总能生效.
      //
      //   ExoPlayer 标准做法: setMediaItem → prepare → seekTo(startAt) →
      //   play. seekTo 必须在 play 前, 否则 player 状态是 STATE_READY +
      //   isPlaying=true, seek 调用走"异步缓冲队列", 在 buffer 没填满时
      //   被 ExoPlayer 内部 messageQueue 排队, 实际不生效.
      //
      //   v2.3.14: 卸自研 CustomExoPlayer 走 video_player package, 但
      //   open(startAt:) 仍生效 — [ExoPlayerBackend.open] 把 setMediaItem +
      //   prepare + seekTo(startAt) + play 全部按这个顺序排好了
      //   (见 exo_player_backend.dart open()), Dart 端传 startAt 即可.
      //   保留 verify + 重试 seek 兜底, 万一 open() 内 seek 失败.
      final dramaId = source.id.isNotEmpty ? source.id : widget.videoInfo.id;
      final planKey = duanjuPlan?.getKeyForResolution(_currentResolution);
      final decKey = (planKey != null && planKey.isNotEmpty)
          ? planKey
          : (isShortDrama ? DuanjuCoreBridge.instance.getDecryptionKey(dramaId, index + 1, resolution: _currentResolution) : null);
      await _player!.open(
        playUrl,
        headers: duanjuPlan?.headers,
        startAt: resumeAt,
        decryptionKey: decKey,
      );
      if (resumeAt != null) {
        // v1.0.61 fix: 验证 seek 是否生效. open() 内 seek + play 都按
        //   正确顺序排了, 但保险起见仍 verify. 不命中再重试一次.
        await Future.delayed(const Duration(milliseconds: 250));
        final ok = await _verifySeekByStream(resumeAt);
        if (!ok) {
          try {
            await _player!.seek(resumeAt);
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 250));
          await _verifySeekByStream(resumeAt);
        }
      }
      if (!mounted) return;
      setState(() => _isBuffering = false);

      // 新流成功起播，延迟 1.5 秒平滑解开切集防重入锁，确保旧流所有残余事件彻底耗尽
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          _isEpisodeSwitching = false;
          _isTransitioningEpisode = false;
          _autoPlayedThisEpisode = false;
        }
      });

      // 短剧后台静默预取下一集播放计划，实现连播与连续切集零等待 (对齐红果鉴)
      if (isShortDrama && index + 2 <= source.episodes.length) {
        unawaited(DuanjuCoreBridge.instance.prefetchEpisode(dramaId, index + 2));
      }

      // 启动定时器, 并立即保存一条 (标记已开始)
      _startProgressTimer();
      if (resumeAt == null) {
        // 非 resume 场景 (新集/切集): 重置 flag 让定时器先存一次, 然后立即 save
        // 标记已开始. playTime=0 是预期的 (用户刚点开)
        _firstRecordSaved = false;
        _saveCurrentProgress();
      } else {
        // v1.0.59: resume 场景下 player 刚 open + seek, position stream 可能
        // 还没回传, _currentPosition / state.position 都还是 0. 此时若
        // _firstRecordSaved=false, 10s 定时器第一次 tick 时 (假定此时 stream
        // 已回但 pos 偶尔还是 0) 命中 state.playing=true 分支存一条
        // playTime=0 的记录, **把云端 12 分钟那条覆盖掉**, 下次重开云端
        // 拉到 playTime=0 就从 0 开始.
        //
        // v1.0.50 修法是跳过立即 save, 但没处理 10s 定时器这次 — 假设 10s
        // 内 position stream 一定回传 > 0. 慢网络 / 大视频下不一定.
        //
        // 修法: 设 _firstRecordSaved=true, 让 10s 定时器存 0 时命中
        //   if (!force && _lastSavedKey == key && playTime == 0
        //       && _firstRecordSaved) { return; }
        // 早返跳过. 等下一个 tick (再 10s 后) stream 肯定回了, 正常存.
        // 用户多看 10s 不影响体验, 但避免误覆盖云端记录.
        _firstRecordSaved = true;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isBuffering = false;
        _error = '播放失败: $e';
      });
    }
    // v2.5.34: 切集时刷弹幕 — 静默 fire-and-forget, 不阻塞播放
    unawaited(_reloadDanmakuForNewEpisode());
  }

  /// 等待 player 真正开始解码 (position stream 第一次回传)
  ///
  /// v1.0.60: media_kit 的 `Player.open()` 返回时 player 还在初始化,
  /// 立即 seek 经常被丢. 等 position stream 第一次回传 (说明 player 已
  /// ready) 再 seek, 可以让 resume 100% 生效. 带 timeout, 超时后
  /// 也继续 (fallback 到直接 seek).
  ///
  /// v1.0.61: 这个函数在新流程里被 _waitForBufferingComplete 替代,
  /// 但保留作为兜底 (万一 buffering 监测失败).
  Future<void> _waitForPlayerReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<void>();
    late StreamSubscription<Duration> sub;
    sub = _player!.positionStream.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      sub.cancel();
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // 超时, 继续 (后续会再 seek 一次兜底)
      try {
        await sub.cancel();
      } catch (_) {}
    }
  }

  /// 等待 buffering 完成 (从 true→false)
  ///
  /// v1.0.61: media_kit 在某些 libmpv 场景下 Player.open() 不 auto-play,
  /// player 停在 stopped, 此时 seek 被丢. 修法: 显式 play + 等
  /// streams.buffering 从 true 变 false (说明 player 已开始解码). 比
  /// v1.0.60 的 position stream 等待更可靠 (position stream 可能在
  /// buffering 期间也回 0, 容易误判 ready).
  Future<void> _waitForBufferingComplete({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 先看一下当前 buffering 状态, 如果本来就是 false, 立即返回
    try {
      if (!_player!.isBuffering) {
        return;
      }
    } catch (_) {}
    final completer = Completer<void>();
    late StreamSubscription<bool> sub;
    sub = _player!.bufferingStream.listen((isBuffering) {
      if (!isBuffering && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // 超时, 继续 (后续会再 seek 一次兜底)
    }
    try {
      await sub.cancel();
    } catch (_) {}
  }

  /// 用 position stream 验证 seek 是否生效
  ///
  /// v1.0.61: \_player!.position 是快照, libmpv 在某些场景下不会
  /// 及时更新 state, 但 streams.position 会在 buffer decode 完成后
  /// 立即回新位置. 用 stream 验证比用 state 可靠.
  ///
  /// 返回 true 表示 seek 生效 (position 到了 resumeAt 附近), false
  /// 表示没生效需要重试.
  Future<bool> _verifySeekByStream(
    Duration resumeAt, {
    Duration window = const Duration(milliseconds: 800),
  }) async {
    final completer = Completer<bool>();
    late StreamSubscription<Duration> sub;
    var hit = false;
    sub = _player!.positionStream.listen((pos) {
      if (!hit && pos >= resumeAt - const Duration(seconds: 1)) {
        hit = true;
        if (!completer.isCompleted) completer.complete(true);
      }
    });
    try {
      // 给 [window] 时间, 看 stream 是否回 ≥ resumeAt-1s 的位置
      await Future.delayed(window);
    } catch (_) {}
    try {
      await sub.cancel();
    } catch (_) {}
    if (!completer.isCompleted) completer.complete(false);
    return await completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, theme, _) {
        final isDark = theme.isDarkMode;
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.escape && _isFullscreen) {
                _onExitFullscreen();
                return KeyEventResult.handled;
              }
              if (_phase == 'playing') {
                if (event.logicalKey == LogicalKeyboardKey.space) {
                  _handleSpaceKey();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  _seekRelative(const Duration(seconds: -10));
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  _seekRelative(const Duration(seconds: 10));
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                  _adjustVolumeByStep(0.05);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  _adjustVolumeByStep(-0.05);
                  return KeyEventResult.handled;
                }
              }
            }
            return KeyEventResult.ignored;
          },
          child: PopScope(
            canPop: _phase == 'detail' && !_isFullscreen,
            onPopInvoked: (didPop) async {
              if (!didPop && _isFullscreen) {
                await _onExitFullscreen();
                return;
              }
              if (!didPop && _phase == 'playing') {
                // ★ v2.6.45: 立即切换 UI 响应返回键, 后台异步清理
                setState(() => _phase = 'detail');
                _setKeepScreenOn(false);
                _disableVolumeInterception();
                if (DeviceUtils.isWindows()) {
                  unawaited(WindowUtils.setFullScreen(false));
                }
                // 后台异步保存进度 + 停止播放器 (不阻塞返回)
                unawaited(_cleanupOnBack());
              }
              // didPop && _phase == 'detail' → 真正退出页面, 无需处理
            },
            child: Scaffold(
              backgroundColor:
                  isDark ? const Color(0xFF0F1117) : const Color(0xFFF5F7F5),
              body: _phase == 'playing'
                  // 播放视图不套 SafeArea，让视频铺满整屏
                  // 避免横屏时被 iOS 状态栏/HomeIndicator 推挤产生侧边黑/白条
                  ? _buildPlayingView(isDark)
                  : SafeArea(child: _buildDetailView(isDark)),
            ),
          ),
        );
      },
    );
  }

  // ================= 详情视图 =================

  /// v2.0.38: 推断 kind: 多集 → tv (剧集/综艺/番剧), 1 集 → movie
  /// 兜底: sourceName 含 bangumi → tv, 其他 → movie
  String get _kind {
    if (widget.videoInfo.totalEpisodes > 1) return 'tv';
    if (widget.videoInfo.sourceName.toLowerCase().contains('bangumi')) {
      return 'tv';
    }
    return 'movie';
  }

  // v2.0.95/96: TMDB 精准识别 — 后台拉 w1280 backdrop, 拿到后 setState
  //   触发 DoubanDetailHeader rebuild 切到 TMDB backdrop. 失败 / 没
  //   配 key / 搜索无结果 = _tmdbBackdropUrl 保持 null, 走豆瓣 coverUrl.
  //
  // v2.0.95: 失败时 debugPrint + SnackBar 弹错 (用户反馈"key 没问题 +
  //   还是豆瓣海报"需要知道原因, 弹错让用户能行动).
  // v2.0.96: 失败时改回静默 fallback (SnackBar 删), debugPrint 保留.
  //   原因: TMDB 数据覆盖不全 (e.g. 2025 中文新片没入库), 频繁弹
  //   SnackBar 反而打扰用户, 跟 v2.0.91 删 log UI 精神一致 — 失败
  //   静默, 让 DoubanDetailHeader 走豆瓣 coverUrl 兜底. 开发者仍能
  //   `adb logcat | grep TMDB` 看全流程.
  //
  // 守门:
  //   - 配了 TMDB key (UserDataService.isTmdbConfigured)
  //   - title 非空 (没标题搜不到)
  //   - year 解析成功 (4 位数字; "2024-01-01" 截前 4 位, "2024" 直接用)
  //
  // 异常: 任何一步 throw / 网络超时 / 解析失败 = debugPrint 静默, 用户
  //   感知不到 (DoubanDetailHeader 继续走 coverUrl).
  Future<void> _loadTmdbBackdrop() async {
    if (!UserDataService.isTmdbConfigured()) {
      debugPrint('[TMDB] skip: key not configured');
      DiaryService.add('[TMDB] skip: key not configured');
      return;
    }
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) {
      debugPrint('[TMDB] skip: title empty');
      DiaryService.add('[TMDB] skip: title empty');
      return;
    }

    // year 解析: "2024" 或 "2024-01-01" → 2024
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }

    debugPrint('[TMDB] search: title="$title" year=$year');
    DiaryService.add('[TMDB] search: title="$title" year=$year');

    try {
      final ref = await TmdbService.search(title: title, year: year);
      if (!mounted) return;
      if (ref == null) {
        debugPrint(
            '[TMDB] search: no result (key 失效 / 剧名无匹配 / year 不匹配)');
        DiaryService.add(
            '[TMDB] search: no result (key 失效 / 剧名无匹配 / year 不匹配)');
        // v2.0.96: 静默 fallback — SnackBar 删了, 不打扰用户
        // v2.0.99.2: 但写进日记, 用户主动点开「日记」页能看到
        return;
      }
      debugPrint('[TMDB] search hit: ${ref.mediaType}#${ref.id}');
      DiaryService.add('[TMDB] search hit: ${ref.mediaType}#${ref.id}');
      final art = await TmdbService.fetchArt(
          id: ref.id, mediaType: ref.mediaType);
      if (!mounted) return;
      if (art == null || art.backdropUrl == null) {
        debugPrint(
            '[TMDB] fetchArt: no backdrop (art=${art == null ? "null" : "empty"})');
        DiaryService.add(
            '[TMDB] fetchArt: no backdrop (art=${art == null ? "null" : "empty"})');
        return;
      }
      debugPrint('[TMDB] backdrop: ${art.backdropUrl}');
      DiaryService.add('[TMDB] backdrop: ${art.backdropUrl}');
      setState(() {
        _tmdbBackdropUrl = art.backdropUrl;
      });
    } catch (e, st) {
      debugPrint('[TMDB] error: $e\n$st');
      DiaryService.add('[TMDB] error: $e');
      // v2.0.96: 静默 fallback
    }
  }

  // v2.1.7: 拉豆瓣剧情简介 — 跟 _loadTmdbBackdrop 同样的静默 fallback 模式
  //
  // 流程:
  //   1. 检查 widget.videoInfo.doubanId (源 API 拉的剧集都有)
  //   2. 调 DoubanService.getDoubanDetails (m.douban.com rexxar JSON, 不需登录)
  //   3. 成功: 拿 DoubanMovieDetails.summary, setState 触发 _buildSummarySection
  //   4. 失败 / 没 doubanId / summary 字段空: 不渲染, 不打扰用户
  //
  // 跟 _loadTmdbBackdrop 区别: 没配 "summary" 之类的用户配置, doubanId 必来自源,
  //   所以只检查 doubanId + summary 字段是否非空.
  Future<void> _loadDoubanSummary() async {
    final doubanId = widget.videoInfo.doubanId;
    // v2.1.12: 豆瓣拉不到 (没 doubanId / rexxar 失败 / summary 空) 时
    //   fallback 到 TMDB overview. 用户反馈"历史影片/主页影片都不显示简介"
    //   根因: 历史记录 PlayRecord 不存 doubanId, 主页某些源也没 doubanId,
    //   导致 _loadDoubanSummary 直接 return. TMDB 靠标题搜索, 不依赖 doubanId.
    if (doubanId != null && doubanId.isNotEmpty) {
      debugPrint('[Douban summary] fetch: doubanId=$doubanId');
      DiaryService.add('[Douban summary] fetch: doubanId=$doubanId');
      try {
        final resp = await DoubanService.getDoubanDetails(
          context,
          doubanId: doubanId,
        );
        if (!mounted) return;
        if (resp.success && resp.data != null) {
          final s = resp.data!.summary;
          if (s != null && s.trim().isNotEmpty) {
            debugPrint('[Douban summary] hit: ${s.length} chars');
            DiaryService.add('[Douban summary] hit: ${s.length} chars');
            if (mounted) {
              setState(() {
                _summary = s.trim();
              });
            }
            return; // 豆瓣成功, 不走 TMDB fallback
          }
        }
        debugPrint('[Douban summary] failed/empty, fallback TMDB overview');
        DiaryService.add('[Douban summary] failed/empty, fallback TMDB overview');
      } catch (e, st) {
        debugPrint('[Douban summary] error: $e\n$st, fallback TMDB overview');
        DiaryService.add('[Douban summary] error: $e, fallback TMDB overview');
      }
    } else {
      debugPrint('[Douban summary] skip: no doubanId, fallback TMDB overview');
      DiaryService.add('[Douban summary] skip: no doubanId, fallback TMDB overview');
    }
    // v2.1.12: TMDB overview fallback — 靠标题搜索, 不依赖 doubanId
    if (_summary != null) return; // 已有豆瓣简介就不重复拉
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) return;
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }
    try {
      final overview = await TmdbService.fetchOverview(
        title: title,
        year: year,
      );
      if (!mounted) return;
      if (overview != null && overview.isNotEmpty) {
        setState(() {
          _summary = overview;
        });
      }
    } catch (e) {
      debugPrint('[TMDB overview] error: $e');
      DiaryService.add('[TMDB overview] error: $e');
      // 静默 fallback — 不打扰用户
    }
  }

  // v2.1.17: 拉 TMDB 演员 — 跟 _loadTmdbBackdrop / _loadDoubanSummary 同样
  //   静默 fire-and-forget 模式. 平板大头部背景图下半部显示用.
  Future<void> _loadTmdbCast() async {
    if (!UserDataService.isTmdbConfigured()) {
      return;
    }
    final title = widget.videoInfo.title.trim();
    if (title.isEmpty) return;
    int? year;
    final y = widget.videoInfo.year;
    if (y != null && y.isNotEmpty) {
      final m = RegExp(r'^(\d{4})').firstMatch(y);
      if (m != null) year = int.tryParse(m.group(1)!);
    }
    try {
      final cast = await TmdbService.fetchCredits(title: title, year: year);
      if (!mounted) return;
      if (cast != null && cast.isNotEmpty) {
        setState(() {
          _cast = cast;
        });
      }
    } catch (e) {
      debugPrint('[TMDB credits] error: $e');
      DiaryService.add('[TMDB credits] error: $e');
      // 静默 fallback
    }
  }

  Widget _buildDetailView(bool isDark) {
    // v2.1.17: 平板判定 — DoubanDetailHeader 用同一标准 (>=600), 用来
    //   决定要不要传 castOverlay (演员横向滚动 ListView).
    final isTablet = MediaQuery.of(context).size.width >= 600;
    return Column(
      children: [
        // 顶部 bar
        _buildTopBar(isDark),
        // 内容滚动
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // v2.0.38: 配了 TMDB key → 大头部 (TMDB backdrop + 海报 + 简介),
                //            没配 → 原 110x150 小海报 + 标题/年份
                // v2.0.78: 登录豆瓣 → 大头部 (DoubanDetailHeader)
                //   - 手机: 2:3 竖版海报当背景 + 渐变压暗 + 底部标题
                //   - 平板: 21:9 横版 + 左侧 150x225 大竖海报 + 右侧标题
                // v2.0.77 (之前): 走 _buildPosterHeader (110x150 小海报)
                //   只升了图片质量, 没大头部布局. 用户反馈"豆瓣大海报在
                //   哪和 tmdb 一样啊" → 加这个.
                //   海报 URL 通过 getImageUrl 自动升 l_ratio_poster
                //   (登录态, 见 image_url.dart).
                // 没登录 = 走 _buildPosterHeader (现有 110x150 小海报,
                //   行为完全不变, 跟用户要求一致).
                // v2.0.99 fix: 去 isDoubanLoggedIn() 条件 — TMDB backdrop
                //   不该跟豆瓣登录绑. v2.0.93 我把 TMDB 写进 DoubanDetailHeader
                //   (大头部), 大头部又在 v2.0.78 跟豆瓣登录绑 (DoubanDetailHeader
                //   加的时候没 TMDB, 大头部 = 豆瓣登录态, 当时合理). v2.0.93 加
                //   TMDB 时保留 isDoubanLoggedIn 条件, 错了 — TMDB 是独立数据源,
                //   跟登录无关. 用户反馈 "tmdb 还是没显示海报" + 截图显示豆瓣未
                //   登录 → 走 _buildPosterHeader (小头部) → TMDB 永远不显示.
                //   改成: 只要 cover 不空 (豆瓣/番剧源都给) 就走大头部, TMDB
                //   backdrop 独立生效. 没豆瓣登录 = 大头部走 coverUrl/cover 兜底
                //   (跟 v2.0.84/v2.0.85 行为一致, 跟 v2.0.78 没 DoubanDetailHeader
                //   之前的 110x150 小海报完全不一样 — 现在是大头部视觉, 只是
                //   背景图走豆瓣兜底).
                if (widget.videoInfo.cover.isNotEmpty)
                  DoubanDetailHeader(
                    title: widget.videoInfo.title,
                    year: widget.videoInfo.year,
                    cover: widget.videoInfo.cover,
                    source: widget.videoInfo.source,
                    sourceName: widget.videoInfo.sourceName,
                    coverUrl: widget.videoInfo.coverUrl,
                    tmdbBackdropUrl: _tmdbBackdropUrl,
                    rate: widget.videoInfo.rate,
                    summary: _summary,
                    castOverlay: _cast != null && _cast!.isNotEmpty
                        ? _buildCastOverlay(_cast!, isDark)
                        : null,
                    onPlayPressed: () => _playEpisode(_currentEpisodeIndex),
                  )
                else
                  _buildPosterHeader(isDark),
                // v2.1.10: 下方独立剧情简介 section 删除 — 手机/平板
                //   header 右侧都已显示简介 (上面不够写可左滑). 用户反馈
                //   "下面画圈的剧情简介去掉, 上面不够写的左滑动".
                // 集数 (放在源上面,LunaTV Web 风格)
                _buildEpisodeSection(isDark),
                // 源 + 测速
                _buildSourceSection(isDark),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        // 底部播放按钮
        _buildBottomPlayButton(isDark),
      ],
    );
  }

  // v2.1.17: 平板大头部背景图下半部浮层 — 横向滚动演员头像 + 名字.
  //   只在平板 (isTablet) + _cast 非空时由 _buildDetailView 调用. 一行
  //   排列, 不够就滑动. 头像用 TMDB w185 圆图, 名字 1 行省略号, 跟背景
  //   图对比 + 阴影保持可读. 跟 v2.1.18 删掉的 episodesOverlay 同位置模式
  //   (DoubanDetailHeader 内部 Positioned 浮在 left:180 right:16 bottom:14).
  //   尺寸 (v2.1.17 微调): 头像 70 + 名字 12pt + 总高 100 — 21:9 大背景图
  //   下半部比例协调, 比 v2.1.17 首发 50/10pt/80 显大 40%.
  Widget _buildCastOverlay(List<TmdbCast> cast, bool isDark) {
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: cast.length,
        itemBuilder: (context, i) {
          final c = cast[i];
          final url = c.fullProfileUrl;
          return Container(
            margin: const EdgeInsets.only(right: 14),
            child: Column(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: url != null
                        ? CachedNetworkImage(
                            imageUrl: url,
                            cacheManager: LunaCacheManager.instance,
                            fit: BoxFit.cover,
                            placeholder: (ctx, u) => Container(
                              color: isDark ? Colors.white12 : Colors.black12,
                            ),
                            errorWidget: (ctx, u, e) => Container(
                              color: isDark ? Colors.white12 : Colors.black12,
                              child: Icon(Icons.person,
                                  color: isDark ? Colors.white54 : Colors.black45, size: 32),
                            ),
                          )
                        : Container(
                            color: isDark ? Colors.white12 : Colors.black12,
                            child: Icon(Icons.person,
                                color: isDark ? Colors.white54 : Colors.black45, size: 32),
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 76,
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white.withOpacity(0.85) : const Color(0xFF334155),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              '选源播放',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildPosterHeader(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 110,
              height: 150,
              child: widget.videoInfo.cover.isNotEmpty
                  ? FutureBuilder<String>(
                      future: getImageUrl(
                          widget.videoInfo.cover, widget.videoInfo.source),
                      builder: (context, snapshot) {
                        final imageUrl =
                            snapshot.data ?? widget.videoInfo.cover;
                        final headers = getImageRequestHeaders(
                            imageUrl, widget.videoInfo.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          // v2.1.33: 走 OkHttp (强制 TLS 1.2), 避开 dart:io TLS 1.3
                          //   cipher 跟 CF edge zone 协商失败 (走 cacheManager 注入)
                          cacheManager: LunaCacheManager.instance,
                          fit: BoxFit.cover,
                          width: 110,
                          height: 150,
                          httpHeaders: headers,
                          memCacheWidth: (110 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          placeholder: (c, u) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                          ),
                          errorWidget: (c, u, e) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                            child: const Icon(Icons.movie_outlined,
                                color: Colors.grey, size: 40),
                          ),
                        );
                      },
                    )
                  : Container(
                      color: isDark
                          ? const Color(0xFF1F2937)
                          : const Color(0xFFE5E7EB),
                      child: const Icon(Icons.movie_outlined,
                          color: Colors.grey, size: 40),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // 标题 + 元信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.videoInfo.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (widget.videoInfo.year.isNotEmpty)
                      _buildTag(widget.videoInfo.year, isDark),
                    if (widget.videoInfo.rate != null &&
                        widget.videoInfo.rate!.isNotEmpty)
                      _buildRatingTag(widget.videoInfo.rate!),
                  ],
                ),
                if (widget.videoInfo.sourceName.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.cloud_outlined,
                          size: 12,
                          color:
                              isDark ? Colors.white60 : Colors.black54),
                      const SizedBox(width: 4),
                      Text(
                        '默认: ${widget.videoInfo.sourceName}',
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      ),
    );
  }

  Widget _buildRatingTag(String rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFB923C), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text(
            rate,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 源选择 ----------

  // v2.1.7: 剧情简介 section
  //
  // 视觉: 跟 _buildEpisodeSection / _buildSourceSection 一致 (圆角背景 +
  //   16 horizontal padding), 标题 "剧情简介" + 简介文本 (maxLines 5 默认,
  //   点击"展开"切到无 maxLines).
  //
  // 数据流: _summary 由 _loadDoubanSummary() 异步填充, 这里是纯渲染.
  //   _summary == null (没 doubanId / 拉不到 / 字段空) → 上层 if 不渲染这
  //   段, 这里只是用 _summary! 解 null 安全.
  Widget _buildSummarySection(bool isDark) {
    final summary = _summary!;
    // 简介超过 5 行默认折叠, 短的全部显示
    final isLong = summary.length > 120; // 阈值简单按字符数算
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('剧情简介', isDark),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: isLong
                ? () => setState(() => _summaryExpanded = !_summaryExpanded)
                : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF1F2937)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: Text(
                      summary,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.85)
                            : Colors.black87,
                      ),
                      maxLines: isLong && !_summaryExpanded ? 5 : null,
                      overflow: isLong && !_summaryExpanded
                          ? TextOverflow.ellipsis
                          : TextOverflow.visible,
                    ),
                  ),
                  if (isLong) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _summaryExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? const Color(0xFF93C5FD)
                                : const Color(0xFF2563EB),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Icon(
                          _summaryExpanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: isDark
                              ? const Color(0xFF93C5FD)
                              : const Color(0xFF2563EB),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceSection(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildSectionTitle('播放源', isDark),
              const Spacer(),
              if (_sourcesLoading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Color(0xFF22C55E),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_sourceResults.isEmpty && !_sourcesLoading)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error ?? '暂无源',
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontSize: 12,
                ),
              ),
            )
          else
            Column(
              children: _sourceResults
                  .map((s) => _buildSourceTile(s, isDark))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceTile(SearchResult s, bool isDark) {
    final selected = _selectedSource?.source == s.source;
    final state = _pingState[s.source] ?? PingState.idle;
    final ms = _pingCache[s.episodes.isNotEmpty ? s.episodes.first : ''];
    final speed = _sourceSpeeds[s.source];

    final cardBg = selected
        ? const Color(0xFF10B981).withOpacity(isDark ? 0.15 : 0.08)
        : (isDark ? const Color(0xFF1E293B) : Colors.white);

    final borderColor = selected
        ? const Color(0xFF10B981)
        : (isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06));

    return InkWell(
      onTap: () {
        _selectSource(s);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: borderColor,
            width: selected ? 1.6 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: selected
                  ? const Color(0xFF10B981).withOpacity(0.18)
                  : Colors.black.withOpacity(isDark ? 0.2 : 0.03),
              blurRadius: selected ? 10 : 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            _buildPingIcon(state, ms),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          s.sourceName.isNotEmpty ? s.sourceName : s.source,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? const Color(0xFF10B981)
                                : (isDark ? Colors.white : const Color(0xFF1E293B)),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '当前选中',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: Color(0xFF10B981),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '共 ${s.episodes.length} 集',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark ? Colors.white60 : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
            _buildSpeedLabel(state, speed, ms),
          ],
        ),
      ),
    );
  }

  Widget _buildPingIcon(PingState state, int? ms) {
    Color color;
    IconData icon;
    if (state == PingState.testing) {
      color = const Color(0xFFF59E0B);
      icon = Icons.access_time;
    } else if (state == PingState.idle) {
      color = const Color(0xFF9CA3AF);
      icon = Icons.help_outline;
    } else if (state == PingState.unavailable) {
      color = const Color(0xFFEF4444);
      icon = Icons.error_outline;
    } else {
      color = _stateToColor(state);
      icon = Icons.bolt;
    }
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: color),
    );
  }

  /// v1.0.45: 显示完整测速结果
  ///   - 测试中: "测速中"
  ///   - idle: "待测"
  ///   - 失败: "不可用"
  ///   - 成功: "720p · 1.2MB/s · 85ms" (直链没分辨率时省略)
  Widget _buildSpeedLabel(PingState state, _SourceSpeedInfo? speed, int? ms) {
    String text;
    Color color;
    if (state == PingState.testing) {
      text = '测速中';
      color = const Color(0xFFF59E0B);
    } else if (state == PingState.idle) {
      text = '待测';
      color = const Color(0xFF9CA3AF);
    } else if (state == PingState.unavailable || speed == null || !speed.success) {
      // 测失败时如果还有旧 ms (来自 fallback HEAD ping), 显示 ms
      text = (ms != null && ms < 3000) ? '${ms}ms' : '不可用';
      color = (ms != null && ms < 3000) ? const Color(0xFFEF4444) : const Color(0xFF9CA3AF);
    } else {
      // 成功: 拼 "分辨率 · 速度 · ping" (缺哪个就省哪个)
      final parts = <String>[];
      if (speed.resolution.isNotEmpty) parts.add(speed.resolution);
      final speedStr = speed.formatLoadSpeed();
      if (speedStr.isNotEmpty) parts.add(speedStr);
      if (speed.pingMs > 0) parts.add('${speed.pingMs}ms');
      // v2.5.33: 部分成功 (有 ping 没 speed 没 resolution) 显示 "Xms (速度未知)",
      //   跟"完全 unavailable"区分开 (之前都看着像 "Xms", 难排错).
      //   实际原因: fallback _fallbackLightSpeed 内部 latency 测到了 (worker URL 200)
      //   但 download 测速拿到 0 (CDN 拒 Range / 限流 / 跨域). 跟"5s 外层 timeout
      //   完全失败"是两种情况, 视觉一样误导.
      if (parts.isEmpty) parts.add(ms != null ? '${ms}ms' : 'OK');
      if (speedStr.isEmpty && speed.pingMs > 0 && speed.resolution.isEmpty) {
        // 部分成功: 黄色 (跟"测速中"同色), 提示用户 CDN 测速受限但延迟 ok
        text = '${speed.pingMs}ms (速度未知)';
        color = const Color(0xFFF59E0B);
      } else {
        text = parts.join(' · ');
        color = _stateToColor(state);
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _stateToColor(PingState state) {
    switch (state) {
      case PingState.fast:
        return const Color(0xFF22C55E);
      case PingState.medium:
        return const Color(0xFFF59E0B);
      case PingState.slow:
        return const Color(0xFFF97316);
      case PingState.unavailable:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF9CA3AF);
    }
  }

  // ---------- 集数选择 ----------

  /// v2.0.51: 选集面板 — 30 集一页, PageView 左右滑翻页
  ///
  /// 用户反馈 (平板模式): 单 GridView 一页铺 60+ 集, 平板上列数拉到 12,
  /// 卡片巨大 (cardW ~100dp), 视觉上"卡片大但内容少, 看着空". 同时
  /// 30 集往上就滚不动 (GridView 嵌在 SingleChildScrollView 里, 不会
  /// 自己滚, 要滚整页), 长剧 (60 / 80 / 100 集) 用户要一直滑滚轮.
  ///
  /// 改法:
  ///   - 拆成 PageView, 每页最多 30 集, 默认显示当前 episode 所在页
  ///   - 页数 = ceil(episodes.length / 30), 60 集 → 2 页, 100 集 → 4 页
  ///   - 标题旁加翻页指示器 "1/2" + PageView 底部小圆点 (current page 高亮)
  ///   - 每页内还是 GridView (列数按宽度动态, 跟旧版一致),
  ///     shrinkWrap + NeverScrollableScrollPhysics, 不会跟外层
  ///     SingleChildScrollView 抢手势
  ///   - 左右滑切页, 不影响外层上下滚 (Flutter PageView 默认 PageScrollPhysics
  ///     只接水平, vertical 由外层 SingleChildScrollView 处理)
  ///
  /// 兼容性: 卡片样式 / 选中渐变 / 点击 _playEpisode 逻辑全部保留.
  /// 列数 / 卡片宽 / 字号策略跟 v2.0.43 一样, 没动.
  static const int _episodesPerPage = 30;

  Widget _buildEpisodeSection(bool isDark) {
    final source = _selectedSource;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildSectionTitle('选集', isDark),
              const Spacer(),
              // v2.0.51: 翻页指示器 (1/2) — 用户滑动 PageView 时实时更新
              if (source != null && source.episodes.isNotEmpty)
                _buildEpisodePageBadge(
                  source.episodes.length,
                  isDark,
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (source == null || source.episodes.isEmpty)
            Text(
              _sourcesLoading ? '加载中...' : '请先选择播放源',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            )
          else
            _buildEpisodesPageView(source, isDark),
        ],
      ),
    );
  }

  /// v2.0.51: 翻页 badge "1/2", 显示在 "选集" 标题右侧，带上一页/下一页鼠标点击按钮
  Widget _buildEpisodePageBadge(int totalEpisodes, bool isDark) {
    final pageCount =
        (totalEpisodes + _episodesPerPage - 1) ~/ _episodesPerPage;
    final currentPage =
        (_currentEpisodeIndex ~/ _episodesPerPage).clamp(0, pageCount - 1);
    if (pageCount <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (_episodesPageController.hasClients) {
              final cur = _episodesPageController.page?.round() ?? currentPage;
              if (cur > 0) {
                _episodesPageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              Icons.chevron_left_rounded,
              size: 20,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ValueListenableBuilder<PageController>(
            valueListenable: _pageControllerNotifier,
            builder: (context, controller, _) {
              final page = controller.hasClients
                  ? (controller.page?.round() ?? currentPage)
                  : currentPage;
              return Text(
                '${page + 1} / $pageCount',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white70 : Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              );
            },
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (_episodesPageController.hasClients) {
              final cur = _episodesPageController.page?.round() ?? currentPage;
              if (cur < pageCount - 1) {
                _episodesPageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  /// v2.0.51: 选集 PageView (30 集/页)
  Widget _buildEpisodesPageView(SearchResult source, bool isDark) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数策略: 跟 v2.0.43 一致 (手机 6 / 小平板 8 / 中平板 10 / 大平板 12)
        final width = constraints.maxWidth;
        int crossAxisCount;
        if (width < 600) {
          crossAxisCount = 6;
        } else if (width < 900) {
          crossAxisCount = 8;
        } else if (width < 1200) {
          crossAxisCount = 10;
        } else {
          crossAxisCount = 12;
        }
        const spacing = 6.0;
        final cardW =
            (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
        final childAspectRatio = cardW < 80 ? 1.2 : 1.0;
        final fontSize = cardW < 80 ? 11.0 : 12.0;

        final totalEpisodes = source.episodes.length;
        final pageCount =
            (totalEpisodes + _episodesPerPage - 1) ~/ _episodesPerPage;

        // 仅 1 页（如电影 1 集、短剧/动漫 1~30 集）：直接返回自适应高度的 GridView，不留任何多余空白
        if (pageCount <= 1) {
          return _buildEpisodesGridPage(
            source,
            0,
            totalEpisodes,
            isDark,
            crossAxisCount,
            childAspectRatio,
            spacing,
            cardW,
            fontSize,
          );
        }

        // 多页（30 集以上）：计算每页网格高度与翻页器
        final rows =
            ((_episodesPerPage + crossAxisCount - 1) ~/ crossAxisCount);
        final cardH = cardW / childAspectRatio;
        final gridHeight = rows * cardH + (rows - 1) * spacing;
        final sectionHeight = gridHeight + 20;

        final initialPage =
            (_currentEpisodeIndex ~/ _episodesPerPage).clamp(0, pageCount - 1);

        return SizedBox(
          height: sectionHeight,
          child: Column(
            children: [
              SizedBox(
                height: gridHeight,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: Listener(
                    onPointerSignal: (pointerSignal) {
                      if (pointerSignal is PointerScrollEvent) {
                        if (pointerSignal.scrollDelta.dy > 0 || pointerSignal.scrollDelta.dx > 0) {
                          if (_episodesPageController.hasClients) {
                            final cur = _episodesPageController.page?.round() ?? 0;
                            if (cur < pageCount - 1) {
                              _episodesPageController.nextPage(
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              );
                            }
                          }
                        } else if (pointerSignal.scrollDelta.dy < 0 || pointerSignal.scrollDelta.dx < 0) {
                          if (_episodesPageController.hasClients) {
                            final cur = _episodesPageController.page?.round() ?? 0;
                            if (cur > 0) {
                              _episodesPageController.previousPage(
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              );
                            }
                          }
                        }
                      }
                    },
                    child: PageView.builder(
                      controller: _episodesPageController,
                      physics: const PageScrollPhysics(),
                      onPageChanged: (page) {
                        _pageControllerNotifier.value = _episodesPageController;
                      },
                      itemCount: pageCount,
                      itemBuilder: (context, pageIndex) {
                        final start = pageIndex * _episodesPerPage;
                        final end = (start + _episodesPerPage).clamp(0, totalEpisodes);
                        return _buildEpisodesGridPage(
                          source,
                          start,
                          end,
                          isDark,
                          crossAxisCount,
                          childAspectRatio,
                          spacing,
                          cardW,
                          fontSize,
                        );
                      },
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ValueListenableBuilder<PageController>(
                  valueListenable: _pageControllerNotifier,
                  builder: (context, controller, _) {
                    final curPage = controller.hasClients
                        ? (controller.page?.round() ?? initialPage)
                        : initialPage;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(pageCount, (i) {
                        final isActive = i == curPage;
                        return GestureDetector(
                          onTap: () {
                            if (_episodesPageController.hasClients) {
                              _episodesPageController.animateToPage(
                                i,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            width: isActive ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? const Color(0xFF10B981)
                                  : (isDark ? Colors.white24 : Colors.black26),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// v2.0.51: 单页 GridView (30 集以内), 卡片样式跟 v2.0.43 一致
  Widget _buildEpisodesGridPage(
    SearchResult source,
    int start,
    int end,
    bool isDark,
    int crossAxisCount,
    double childAspectRatio,
    double spacing,
    double cardW,
    double fontSize,
  ) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
      ),
      itemCount: end - start,
      itemBuilder: (context, offset) {
        final index = start + offset;
        return _buildEpisodeCard(
          source,
          index,
          isDark,
          cardW,
          fontSize,
        );
      },
    );
  }

  /// v2.0.51: 抽出来的单集卡片 (PageView 每页 itemBuilder 复用)
  Widget _buildEpisodeCard(
    SearchResult source,
    int index,
    bool isDark,
    double cardW,
    double fontSize,
  ) {
    final isCurrent = index == _currentEpisodeIndex;
    final title = index < source.episodesTitles.length
        ? source.episodesTitles[index]
        : '${index + 1}';
    return RepaintBoundary(
      child: InkWell(
        onTap: () {
          // 点击集数直接开始播放
          if (index != _currentEpisodeIndex || _phase != 'playing') {
            _playEpisode(index);
          } else {
            setState(() {
              _currentEpisodeIndex = index;
            });
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            gradient: isCurrent
                ? const LinearGradient(
                    colors: [
                      Color(0xFF10B981),
                      Color(0xFF059669),
                    ],
                  )
                : null,
            color: !isCurrent
                ? (isDark
                    ? const Color(0xFF1E293B)
                    : Colors.white)
                : null,
            borderRadius: BorderRadius.circular(8),
            border: !isCurrent
                ? Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : Colors.black.withOpacity(0.06),
                    width: 1,
                  )
                : null,
            boxShadow: [
              BoxShadow(
                color: isCurrent
                    ? const Color(0xFF10B981).withOpacity(0.35)
                    : Colors.black.withOpacity(isDark ? 0.15 : 0.03),
                blurRadius: isCurrent ? 8 : 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w600,
                color: isCurrent
                    ? Colors.white
                    : (isDark ? Colors.white.withOpacity(0.85) : const Color(0xFF1E293B)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String text, bool isDark) {
    return Row(
      children: [
        Container(
          width: 3.5,
          height: 14,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF10B981), Color(0xFF059669)],
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF1E293B),
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }

  // ---------- 底部播放按钮 ----------

  Widget _buildBottomPlayButton(bool isDark) {
    final source = _selectedSource;
    final canPlay = source != null && source.episodes.isNotEmpty;
    final isPlaying = _phase == 'playing';
    final btnText = source == null
        ? '请选择播放源'
        : (source.episodes.isEmpty
            ? '该源无集数'
            : (isPlaying
                ? '继续播放 第${_currentEpisodeIndex + 1}集'
                : '播放 第${_currentEpisodeIndex + 1}集'));
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F1117) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.06),
          ),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: canPlay
                ? const LinearGradient(
                    colors: [Color(0xFF10B981), Color(0xFF059669)],
                  )
                : null,
            color: !canPlay
                ? (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))
                : null,
            borderRadius: BorderRadius.circular(12),
            boxShadow: canPlay
                ? [
                    BoxShadow(
                      color: const Color(0xFF10B981).withOpacity(0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: canPlay ? () => _playEpisode(_currentEpisodeIndex) : null,
              borderRadius: BorderRadius.circular(12),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isPlaying
                          ? Icons.play_circle_outline
                          : Icons.play_arrow,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      btnText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ================= 播放视图 =================

  /// 顶部栏: 80px 黑色渐变 + 片名 + 集数胶囊 (LunaTV Web 风格)
  Widget _buildLunaTopBar() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    final totalEps = _selectedSource?.episodes.length ?? 0;
    final currentEp = _currentEpisodeIndex + 1;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 80,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.7),
              Colors.black.withOpacity(0.3),
              Colors.transparent,
            ],
            stops: const [0, 0.6, 1],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              // 返回箭头
              _iconBtn(
                icon: Icons.arrow_back,
                onTap: () {
                  // v2.5.88: 返回箭头退出也要先保存进度, 跟返回键路径一致
                  //   之前直接 stop 没保存, 退出后进度丢失
                  () async {
                    if (_currentPosition > Duration.zero || _isCurrentShortDrama || _currentEpisodeIndex > 0) {
                      await _saveCurrentProgress(force: true);
                    }
                    try {
                      await _player!.stop();
                    } catch (_) {}
                    if (!mounted) return;
                    await _onExitFullscreen();
                    if (!mounted) return;
                    setState(() {
                      _phase = 'detail';
                      // v2.2.0+59: 返回箭头退出播放, 解除屏幕常亮
                      _setKeepScreenOn(false);
                      // v2.6.42: 退出播放回 detail, 关音量拦截, 恢复系统音量弹窗
                      _disableVolumeInterception();
                    });
                  }();
                },
              ),
              const SizedBox(width: 4),
              // 片名
              Expanded(
                child: Text(
                  widget.videoInfo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    shadows: [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
              // 收藏
              _iconBtn(
                icon: _isFavorite ? Icons.favorite : Icons.favorite_border,
                onTap: _toggleFavorite,
              ),
              // v2.3.0: 删 _buildAccelStatusIcon() 调用 (顶部「加速状态」指示器,
              //   跟 _buildAccelStatusIcon 整个方法一起删了)
              // v2.1.45: DLNA 投屏按钮 (跟 MobilePlayerControls / PCPlayerControls
              //   的 _buildCastButton 行为一致, 但接到 PlayerScreen 自定义 UI).
              //   - 投屏中 (_isCasting=true): 绿色 cast_connected 图标, 点击弹
              //     dialog 问 "停止投屏?" → _stopDLNACast
              //   - 未投屏: 白色 cast 图标, 点击 → _showDLNADialog 扫设备
              //   位置: 加速状态之后, 设置之前. 跟其他播放器 (VLC / PotPlayer
              //   / 系统视频) 习惯一致 — 投屏按钮在右上角控制栏.
              //   onTap 是 sync (VoidCallback = void Function()), 但内部调
              //   async _showDLNACastAction, 用 unawaited 跑, 跟 _showSpeedDialog
              //   / _enterPipMode 等 UI 入口同模板.
              _iconBtn(
                icon: _isCasting ? Icons.cast_connected : Icons.cast,
                iconColor: _isCasting ? const Color(0xFF22C55E) : Colors.white,
                onTap: () => _showDLNACastAction(),
              ),
              // 设置
              _iconBtn(
                icon: Icons.settings_outlined,
                onTap: _showSettingsSheet,
              ),
              // 集数胶囊徽章 (灰白主题)
              if (totalEps > 0)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    totalEps > 1 ? '$currentEp/$totalEps' : '第$currentEp集',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 中央控制区: v2.6.2 主流方案 — 只剩中间播放/暂停按钮, ±30s 按钮
  ///   全部移除 (左右双击屏幕触发 ±10s, 体感更直接, 跟 YouTube/爱奇艺
  ///   体验一致). 控件一起显隐, 双击 / 拖动 seek 提示文字还在.
  Widget _buildSideSeekButtons() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    // 按屏幕宽度算按钮尺寸: 横屏全屏 (宽 > 600) 用 64, 竖屏用 44.
    //   不再用 sideOffset (左右按钮已删, 不需要算偏移)
    final screenWidth = MediaQuery.of(context).size.width;
    final double size = screenWidth > 600 ? 64.0 : 44.0;
    return Positioned.fill(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 中间: 播放/暂停按钮 (v1.0.49: 颜色跟底部 _iconBtn 播控按钮一致用 Colors.white)
          _buildSeekCircleButton(
            size: size,
            onTap: _togglePlayPause,
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 32,
            ),
          ),
          // 快进/快退提示文字 (双击 / 拖动 后短暂显示, 让用户知道生效了)
          if (_seekHintText != null)
            Positioned(
              bottom: 120,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _seekHintText!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 快进/快退指定秒数, 并显示提示文字
  void _seekBySeconds(int seconds, String hint) {
    final newPos = _currentPosition + Duration(seconds: seconds);
    final clampedPos = seconds < 0
        ? (newPos < Duration.zero ? Duration.zero : newPos)
        : (newPos > _currentDuration ? _currentDuration : newPos);
    _player!.seek(clampedPos);
    // v2.5.90: seek guard 已移除
    // 显示提示文字, 1秒后消失
    _seekHintTimer?.cancel();
    setState(() {
      _seekHintText = hint;
      _currentPosition = clampedPos;
    });
    _onDanmakuSeek(clampedPos.inMilliseconds);
    _seekHintTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _seekHintText = null);
    });
    _scheduleHideControls();
  }

  /// 圆形毛玻璃快进/快退按钮
  Widget _buildSeekCircleButton({
    required VoidCallback onTap,
    required Widget child,
    required double size,
  }) {
    // v1.0.50: 修毛玻璃没生效的问题
    // 之前 BackdropFilter 在 Container 内部, 只模糊了 child 没模糊背景,
    // Container 的 color 画在 BackdropFilter 下面被遮住, 毛玻璃没效果
    // 正确做法: 外层 Container 负责阴影, ClipOval + BackdropFilter 模糊背景,
    // 内层 Container 半透明白色叠加 + border
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 半透明白色叠在模糊背景上, 形成毛玻璃质感
                  color: Colors.white.withOpacity(0.15),
                ),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 圆弧箭头图标 (已废弃, 快进/快退按钮改用 _SeekLabel 文字)
  // ignore: unused_element
  Widget _buildSeekIcon({required bool forward}) {
    return _SeekLabel(label: forward ? '+30' : '-30');
  }

  /// 圆形小按钮 (LunaTV Web 控制按钮, 支持紧凑宽度与自定义尺寸)
  /// v2.0.33: 加 [iconColor] 可选参数, 「下一集」按钮用绿色突出
  Widget _iconBtn({
    required IconData icon,
    required VoidCallback? onTap,
    Color? iconColor,
    double width = 40,
    double size = 22,
  }) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: 40,
          child: Icon(
            icon,
            color: iconColor ??
                (onTap == null ? Colors.white.withOpacity(0.3) : Colors.white),
            size: size,
          ),
        ),
      ),
    );
  }

  // v2.3.14: 弹幕系统 (v2.3.12 移植自 Selene-TV) 整个删了. 见类顶部
  //   `// v2.3.14: 卸弹幕系统` 注释块. _toggleDanmaku / _askDanmakuOidDialog
  //   / _danmakuCtrl / _danmakuEnabled / _danmakuOid / _danmakuFetched /
  //   _danmakuLoading / _danmakuPreferred 全部移除.

  /// v2.3.0: 删了顶部「加速状态」指示器 + 「加速链路」弹层 + 一系列
  ///   相关 UI 组件 (_buildAccelStatusIcon / _showAccelStatusDialog /
  ///   _buildAccelBadge / _accelLevelDescription / _buildLinkNode /
  ///   _buildLinkArrow / _buildAccelHint / _copyToClipboard /
  ///   _stripUrlQuery / _isIpv4Strict / _formatSpeed). 视频加速链路整个删了,
  ///   不再有加速状态, 不再有弹层, 不再有链路图, 不再有实时下载速度采样.
  ///   行为跟 v2.2.7 一致.
  /// v2.1.45: 投屏按钮入口 (sync VoidCallback 包装, 因为 _iconBtn 期望 sync
  ///   onTap). 内部根据 _isCasting 走「停止投屏」或「扫设备」分支.
  void _showDLNACastAction() {
    if (_isCasting) {
      // 已投屏: 弹确认 dialog
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('停止投屏'),
          content: Text(
              '确定停止投屏到 ${_currentCastDevice?.info.friendlyName ?? "设备"}, 回到本地播放?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('停止投屏',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ).then((stop) {
        if (stop == true) {
          _stopDLNACast();
        }
      });
    } else {
      // 未投屏: 扫设备
      _showDLNADialog();
    }
  }

  /// v2.1.45: 打开 DLNA 投屏设备列表 (跟 MobilePlayerControls._showDLNADialog
  ///   / PCPlayerControls._showDLNADialogInternal 行为对齐, 但接进 PlayerScreen
  ///   自定义 LunaTV Web 风格 UI — 那 2 个 widget 没人用).
  ///
  /// 流程:
  /// 1. pause 本地 player (如果正在播)
  /// 2. 如果在全屏, 退全屏 (投屏不需要全屏)
  /// 3. showDialog DLNADeviceDialog
  /// 4. dialog 内部扫设备, 用户选设备 → 调 device.setUrl + device.play
  /// 5. dialog 投屏成功后回调 widget.onCastStarted(device) → 这里接
  ///    _onDLNACastStarted: 停本地 player, 切回 detail 视图, 显示投屏态
  ///
  /// 关键: 传 _currentPlayUrl (已经在 v2.1.43 wrap 过的) 跟 _selectedSource
  ///   的元数据给 dialog. _currentPlayUrl 可能是:
  ///   - http://127.0.0.1:PORT/m3u8?url=... (代理起成功)
  ///   - https://<worker>/m3u8?url=... (worker 加速)
  ///   - 原源 URL (都没配)
  ///   上面 3 种 URL 都是公网可拉, TV 跟手机不在同一 wifi 也能投 — 但手机
  ///   跟 TV 必须在同一 wifi 段才能被 SSDP 扫到 (UPnP 基础要求). 投屏后
  ///   TV 拉 m3u8 + segment 都是公网, 跟手机播放一样的链路.
  ///
  /// 跟 MobilePlayerControls / PCPlayerControls 区别: 那 2 个 widget 是在
  /// `Video(controls: ...)` 里, hide 控件后 dialog 也跟着消失, 但 PlayerScreen
  /// 自定义 UI 是普通 Stack, 即使 hide 控件 dialog 还在. 这里 _showDLNADialog
  /// 跟 pause + exit fullscreen 后, 切 detail 视图也不影响 dialog 弹出来.
  Future<void> _showDLNADialog() async {
    // v2.1.45: 跟 _showSpeedDialog / _enterPipMode 同模板, 先 try/catch
    //   包住 — DLNA 扫不到设备 / network 多播被禁 / SSDP 异常等常见, 失败
    //   不能让 player UI 卡死.
    try {
      // 1. pause (如果正在播)
      if (_player!.isPlaying) {
        await _player!.pause();
        if (!mounted) return;
      }
      // 2. 退全屏
      if (_isFullscreen) {
        await _onExitFullscreen();
        if (!mounted) return;
        // 等动画
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;
      }
      // 3. 拿当前 URL + 元数据
      //   v2.3.0: 视频加速删了, _currentPlayUrl 字段没了, 但 DLNA 不能直接
      //   用 episodes 里的原始地址: 有些源返回的是 /share/xxx HTML 分享页,
      //   本地播放会先经 _resolveSharePageUrl() 提取真实 m3u8, 投屏也必须
      //   走同一段解析逻辑, 否则电视拿到 HTML 页面会完全没反应.
      final originalUrl =
          (_selectedSource != null && _currentEpisodeIndex < _selectedSource!.episodes.length)
              ? _selectedSource!.episodes[_currentEpisodeIndex]
              : '';
      if (originalUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('投屏失败: 当前没有可投屏的视频 URL (还没开始播放)'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
      final playUrl = await _resolveSharePageUrl(originalUrl);
      DiaryService.add(
          '[DLNA] cast url build: originalUrl=$originalUrl, resolvedUrl=$playUrl');
      // 4. showDialog
      if (!mounted) return;
      final resumePos = _player!.position;
      await showDialog(
        context: context,
        builder: (dialogContext) => DLNADeviceDialog(
          currentUrl: playUrl,
          resumePosition: resumePos,
          videoTitle: widget.videoInfo.title,
          currentEpisodeIndex: _currentEpisodeIndex,
          totalEpisodes: _selectedSource?.episodes.length ?? 0,
          sourceName: _selectedSource?.sourceName,
          onCastStarted: (device) => _onDLNACastStarted(device, playUrl),
        ),
      );
    } catch (e) {
      // v2.1.45: DLNA 扫设备 / setUrl / play 任何一步挂都走这里
      DiaryService.add('[DLNA] _showDLNADialog except: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('投屏失败: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// v2.1.45: 投屏成功回调 (DLNADeviceDialog 在 device.setUrl + play 后调).
  ///   跟 MobilePlayerControls / PCPlayerControls 不同, 这俩 widget
  ///   投屏成功时只 _isCasting 状态切换, 还在播放视图 (控件 cast_connected
  ///   图标). PlayerScreen 投屏后直接停本地 player + 切回 detail 视图,
  ///   顶部栏显示「已投屏到 XXX」+ cast_connected 绿色按钮 + 「停止投屏」
  ///   选项. 用户可以切回本地播放 (调 device.stop() + 重启 _player!.open()).
  Future<void> _onDLNACastStarted(dynamic device, String castUrl) async {
    try {
      DiaryService.add(
          '[DLNA] cast started: device=${(device.info?.friendlyName) ?? device.toString()}, currentUrl=$castUrl');
      setState(() {
        _isCasting = true;
        _currentCastDevice = device as DLNADevice;
      });
      // v2.5.88: 投屏前先保存本地播放进度, 跟退出路径一致
      if (_currentPosition > Duration.zero) {
        await _saveCurrentProgress(force: true);
      }
      // 停本地 player (TV 已经在播, 避免双声道 / 浪费流量)
      try {
        await _player!.stop();
      } catch (e) {
        DiaryService.add('[DLNA] stop local player err: $e');
      }
      if (!mounted) return;
      // 切回 detail 视图 (播放视图会黑屏, 不好看)
      setState(() {
        _phase = 'detail';
        _isControlsVisible = false;
        // v2.2.0+59: DLNA 接管, 关屏幕常亮 (本地不播了, 屏幕可以省电)
        _setKeepScreenOn(false);
        // v2.6.42: 退出播放回 detail, 关音量拦截, 恢复系统音量弹窗
        _disableVolumeInterception();
      });
      // 提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已投屏到 ${device.info.friendlyName}, 本地播放已停止'),
          backgroundColor: const Color(0xFF22C55E),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: '停止投屏',
            textColor: Colors.white,
            onPressed: () => _stopDLNACast(),
          ),
        ),
      );
    } catch (e) {
      DiaryService.add('[DLNA] _onDLNACastStarted except: $e');
    }
  }

  /// v2.1.45: 停止投屏, 回到本地播放.
  Future<void> _stopDLNACast() async {
    final device = _currentCastDevice;
    if (device != null) {
      try {
        device.stop();
      } catch (e) {
        DiaryService.add('[DLNA] stop device err: $e');
      }
    }
    setState(() {
      _isCasting = false;
      _currentCastDevice = null;
    });
    // 重启本地 player (从 _selectedSource.episodes[_currentEpisodeIndex] 续播,
    //   跟 _onPlayPressed 路径一致. v2.3.0: _currentPlayUrl 字段删了, 用
    //   _selectedSource.episodes[_currentEpisodeIndex] 拿原源 URL)
    final playUrl = (_selectedSource != null &&
            _currentEpisodeIndex < _selectedSource!.episodes.length)
        ? _selectedSource!.episodes[_currentEpisodeIndex]
        : '';
    if (playUrl.isNotEmpty && mounted) {
      try {
        await _player!.open(playUrl);
        DiaryService.add(
            '[DLNA] stop cast: resume local play, url=$playUrl');
      } catch (e) {
        DiaryService.add('[DLNA] resume local play err: $e');
      }
    }
  }

  /// 打开设置底部面板(齿轮菜单: 倍速 / 跳过片头片尾 / 比例 等)
  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部小横条
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '播放设置',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              // 倍速
              ListTile(
                leading: const Icon(Icons.speed, color: Colors.white70),
                title: const Text('倍速',
                    style: TextStyle(color: Colors.white)),
                trailing: Text(
                  _playbackRate == 1.0 ? '1.0x' : '${_playbackRate}x',
                  style: const TextStyle(color: Color(0xFF22C55E)),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showPlaybackRateSheet();
                },
              ),
              // 智能跳过片头片尾 (v2.6.93 极简现代设置)
              ListTile(
                leading: const Icon(Icons.fast_forward_rounded, color: Colors.white70),
                title: const Text('智能跳过片头片尾',
                    style: TextStyle(color: Colors.white)),
                trailing: Text(
                  _smartSkipEnabled
                      ? (_smartSkipMode == 'instant'
                          ? '立即跳过'
                          : (_smartSkipMode == 'countdown' ? '5秒倒计时' : '手动提示 (5s后消失)'))
                      : '已关闭',
                  style: TextStyle(
                    color: _smartSkipEnabled
                        ? const Color(0xFF22C55E)
                        : Colors.white54,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSmartSkipSettingsDialog();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 底部控制栏 (毛玻璃容器 + 5px进度条 + 按钮行, LunaTV Web 风格)
  /// 横屏时底部栏改短 (maxWidth 限制)
  Widget _buildLunaBottomBar() {
    if (!_isControlsVisible) return const SizedBox.shrink();
    final dur = _currentDuration.inMilliseconds.toDouble();
    final pos = _scrubbingValue != null
        ? (_scrubbingValue! * dur).toInt()
        : _currentPosition.inMilliseconds;
    // 底部栏宽度: 横屏全屏时缩短到 65%, 竖屏时自适应占满可用安全宽度 (两端留 12dp 边距)
    final screenWidth = MediaQuery.of(context).size.width;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final maxW = isLandscape ? screenWidth * 0.65 : double.infinity;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                // v2.5.86: 底部栏整体接收水平拖动 = 拖进度条.
                //   中间 Expanded(flex:2) 区域也是水平拖, 但只占屏幕中间
                //   一条. 用户反馈"屏幕下方"也想要拖动. 这里用 Column
                //   整层接 horizontal drag, 子级按钮 (InkWell tap) 跟
                //   HorizontalDragGestureRecognizer 不冲突, button tap
                //   照常生效. HitTestBehavior.translucent 让 child tap
                //   透下去.
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: _onBottomBarSwipeStart,
                  onHorizontalDragUpdate: _onBottomBarSwipeUpdate,
                  onHorizontalDragEnd: _onBottomBarSwipeEnd,
                  // v2.5.90: 手势被取消时也清除 _scrubbingValue,
                  //   防止 position 更新被永久阻止
                  onHorizontalDragCancel: () {
                    if (_scrubbingValue != null) {
                      setState(() => _scrubbingValue = null);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    // 顶部: 进度条 (5px 矩形, LunaTV Web 风格)
                    _buildLunaProgressBar(),
                    // 底部: 左中右按钮行
                    SizedBox(
                      height: 44,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 左: 播放/暂停
                          _iconBtn(
                            icon: _isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            onTap: _togglePlayPause,
                            width: 36,
                            size: 24,
                          ),
                          // 时间
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${_formatDuration(Duration(milliseconds: pos))} / ${_formatDuration(_currentDuration)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                          const Spacer(),
                          // 弹幕按钮 (紧凑居中)
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _showDanmakuPanel,
                            child: SizedBox(
                              width: 32,
                              height: 40,
                              child: Center(
                                child: Container(
                                  width: 26,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _danmakuEnabled
                                        ? kLunaTheme.withOpacity(0.2)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Icon(
                                    Icons.subtitles,
                                    size: 17,
                                    color: _danmakuEnabled
                                        ? kLunaTheme
                                        : Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 分辨率 / 原画切换控件 (高度 24 胶囊、居中对齐、文本精炼)
                          _buildResolutionButton(),
                          // 右: 倍速
                          _iconBtn(
                            icon: Icons.speed,
                            onTap: _showPlaybackRateSheet,
                            width: 32,
                            size: 19,
                          ),
                          // 选集
                          _iconBtn(
                            icon: Icons.format_list_bulleted,
                            onTap: _showEpisodeSelectorSheet,
                            width: 32,
                            size: 19,
                          ),
                          // 手动「下一集」按钮
                          if (_selectedSource != null &&
                              _currentEpisodeIndex <
                                  _selectedSource!.episodes.length - 1)
                            _iconBtn(
                              icon: Icons.skip_next,
                              iconColor: const Color(0xFF10b981),
                              onTap: _playNextEpisode,
                              width: 32,
                              size: 21,
                            ),
                          // 全屏 (最核心按钮，确保稳定显示在最右端)
                          _iconBtn(
                            icon: _isFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            onTap: _isFullscreen
                                ? _onExitFullscreen
                                : _onEnterFullscreen,
                            width: 38,
                            size: 24,
                          ),
                        ],
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建分辨率 / 清晰度切换控件 (高度居中、胶囊圆角、精炼显示且视觉水平完全对齐，短剧对齐红果鉴)
  Widget _buildResolutionButton() {
    final isShortDrama = widget.preferredSource == 'hongguo' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama' ||
        (_selectedSource?.source == 'hongguo');

    String label = _currentResolution;
    if (isShortDrama) {
      label = (_userPreferredResolution == '自动' || _userPreferredResolution.isEmpty)
          ? '自动'
          : _userPreferredResolution;
    } else if (label.contains('1080')) {
      label = '1080P';
    } else if (label.contains('720')) {
      label = '720P';
    } else if (label.contains('480')) {
      label = '480P';
    } else if (label.contains('原画')) {
      label = '原画';
    } else if (label.length > 5) {
      label = label.substring(0, 4);
    }

    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showResolutionSelectorSheet,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.25),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }

  /// 弹出分辨率 / 清晰度切换面板 (100% 对齐红果鉴：支持自动优先高清与真实档位平滑热切)
  void _showResolutionSelectorSheet() {
    final isShortDrama = widget.preferredSource == 'hongguo' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama' ||
        (_selectedSource?.source == 'hongguo');

    final dramaId = _selectedSource?.id.isNotEmpty == true
        ? _selectedSource!.id
        : widget.videoInfo.id;

    final playUrl = _currentPlayUrl.isNotEmpty
        ? _currentPlayUrl
        : (_player is ExoPlayerBackend
            ? (_player as ExoPlayerBackend).controller?.dataSource ?? ''
            : '');

    if (isShortDrama || playUrl.isNotEmpty) {
      final multiMap = DuanjuCoreBridge.instance.getEpisodeMultiResolutions(dramaId, _currentEpisodeIndex + 1) ??
          DuanjuCoreBridge.buildMultiResolutionUrls(playUrl);
      if (multiMap.isNotEmpty) {
        _resolutionUrlMap.addAll(multiMap);
      }
    }

    if (isShortDrama) {
      final dynamicQualities = DuanjuCoreBridge.instance.getEpisodeQualities(dramaId, _currentEpisodeIndex + 1);
      final actualQ = DuanjuCoreBridge.instance.getEpisodeActualQuality(dramaId, _currentEpisodeIndex + 1) ?? 1080;
      final qualities = <int>[0];
      if (dynamicQualities != null && dynamicQualities.isNotEmpty) {
        for (final q in dynamicQualities) {
          if (q > 0 && !qualities.contains(q)) qualities.add(q);
        }
      } else {
        qualities.addAll([1080, 720, 480]);
      }

      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1F2937),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '清晰度',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                actualQ > 0 ? '当前播放 ${actualQ}P' : '使用源站可用画质',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final q in qualities) () {
                    final bool isSel = (q == 0 && (_userPreferredResolution == '自动' || _userPreferredResolution.isEmpty)) ||
                        (q > 0 && _userPreferredResolution == '${q}P');
                    final String label = q == 0 ? '自动（优先高清）' : '${q}P';
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () async {
                          Navigator.pop(ctx);
                          final newRes = q == 0 ? '自动' : '${q}P';
                          if (_userPreferredResolution == newRes) return;

                          setState(() {
                            _userPreferredResolution = newRes;
                            _currentResolution = newRes;
                          });

                          final curUrl = _currentPlayUrl.isNotEmpty
                              ? _currentPlayUrl
                              : (_player is ExoPlayerBackend
                                  ? (_player as ExoPlayerBackend).controller?.dataSource ?? ''
                                  : '');

                          String? targetUrl = _resolutionUrlMap[newRes];
                          if (targetUrl == null || targetUrl.isEmpty) {
                            if (q == 0) {
                              targetUrl = _resolutionUrlMap['1080P'] ?? _resolutionUrlMap['720P'] ?? curUrl;
                            } else {
                              final plan = await DuanjuCoreBridge.instance.getPlaybackPlan(
                                dramaId: dramaId,
                                episode: _currentEpisodeIndex + 1,
                                quality: q,
                              );
                              targetUrl = plan?.url;
                            }
                          }

                          if (targetUrl != null && targetUrl.isNotEmpty) {
                            final currentPos = _currentPosition;
                            setState(() {
                              _currentPlayUrl = targetUrl!;
                            });
                            final decKey = DuanjuCoreBridge.instance.getDecryptionKey(
                              dramaId,
                              _currentEpisodeIndex + 1,
                              resolution: q == 0 ? null : '${q}P',
                            );
                            await _player!.open(targetUrl, startAt: currentPos, decryptionKey: decKey);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(q == 0 ? '已切换至: 自动（优先高清）' : '已无缝切换至: ${q}P'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            }
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF2D3748),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSel ? const Color(0xFF10B981) : Colors.white24,
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSel) ...[
                                const Icon(Icons.check_rounded, size: 16, color: Color(0xFF10B981)),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                label,
                                style: TextStyle(
                                  color: isSel ? const Color(0xFF10B981) : Colors.white,
                                  fontSize: 14,
                                  fontWeight: isSel ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }(),
                ],
              ),
              if (_userPreferredResolution != '自动' &&
                  _userPreferredResolution.isNotEmpty &&
                  !qualities.any((q) => '${q}P' == _userPreferredResolution))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '已保存 $_userPreferredResolution 偏好，本集暂无此画质。',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return;
    }

    // 非短剧模式保持原有逻辑
    final List<String> resolutionOptions = [];
    if (_availableResolutions.isEmpty) {
      _availableResolutions = ['1080P', '720P', '480P'];
    }
    resolutionOptions.addAll(_availableResolutions);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '选择画质清晰度',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            ...resolutionOptions.map((res) {
              final bool isSelected = (res == _currentResolution);

              String title = res;
              String subtitle = '原画标准规格';
              if (res == '自动') {
                title = '自动（优先高清）';
                subtitle = '使用源站可用最高画质 · 智能优选';
              } else if (res == '1080P') {
                subtitle = '超清原画 · 极致画质 · 纤毫毕现';
              } else if (res == '720P') {
                subtitle = '高清画质 · 流畅首选 · 画质平衡';
              } else if (res == '480P') {
                subtitle = '标清省流 · 极速加载 · 弱网秒开';
              }

              return ListTile(
                title: Text(
                  title,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF10b981)
                        : Colors.white,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 15,
                  ),
                ),
                subtitle: Text(
                  subtitle,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF10b981).withOpacity(0.8)
                        : Colors.white54,
                    fontSize: 12,
                  ),
                ),
                trailing: isSelected
                    ? const Icon(Icons.check_circle, color: Color(0xFF10b981))
                    : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  if (isSelected) return;

                  final curUrl = _currentPlayUrl.isNotEmpty
                      ? _currentPlayUrl
                      : (_player is ExoPlayerBackend
                          ? (_player as ExoPlayerBackend).controller?.dataSource ?? ''
                          : '');

                  String? targetUrl;
                  if (res == '自动') {
                    _userPreferredResolution = '自动';
                    targetUrl = _resolutionUrlMap['自动'] ??
                        _resolutionUrlMap['1080P'] ??
                        _resolutionUrlMap['720P'] ??
                        (curUrl.isNotEmpty ? curUrl : null);
                  } else {
                    _userPreferredResolution = res;
                    targetUrl = _resolutionUrlMap[res] ??
                        DuanjuCoreBridge.buildMultiResolutionUrls(curUrl)[res];
                  }

                  if (targetUrl != null && targetUrl.isNotEmpty) {
                    final currentPos = _currentPosition;
                    setState(() {
                      _currentResolution = res;
                      _currentPlayUrl = targetUrl!;
                    });
                    final decKey = isShortDrama
                        ? DuanjuCoreBridge.instance.getDecryptionKey(
                            dramaId,
                            _currentEpisodeIndex + 1,
                            resolution: res,
                          )
                        : null;
                    await _player!.open(targetUrl, startAt: currentPos, decryptionKey: decKey);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(res == '自动' ? '已切换至: 自动（优先高清）' : '已无缝切换至: $res (平滑热切)'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    }
                  }
                },
              );
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 异步检测当前流的多分辨率选项，无子流时真实显示「720P / 1080P / 原画」
  Future<void> _checkStreamResolutions(String url) async {
    if (!mounted) return;
    try {
      if (url.contains('.m3u8')) {
        final resp = await http
            .get(Uri.parse(url), headers: _browserHeaders)
            .timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200 &&
            resp.body.contains('#EXT-X-STREAM-INF')) {
          final lines = resp.body.split('\n');
          final resolutions = <String>[];
          final urlMap = <String, String>{};
          for (int i = 0; i < lines.length; i++) {
            final line = lines[i].trim();
            if (line.startsWith('#EXT-X-STREAM-INF') &&
                line.contains('RESOLUTION=')) {
              final match = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(line);
              if (match != null && i + 1 < lines.length) {
                final subUrl = lines[i + 1].trim();
                final dims = match.group(1)!.split('x');
                final h = int.tryParse(dims.last) ?? 0;
                String resName = '${h}P';
                if (h >= 1080) {
                  resName = '1080P';
                } else if (h >= 720) {
                  resName = '720P';
                } else if (h >= 480) {
                  resName = '480P';
                }
                final fullUrl = Uri.parse(url).resolve(subUrl).toString();
                resolutions.add(resName);
                urlMap[resName] = fullUrl;
              }
            }
          }
          if (resolutions.isNotEmpty && mounted) {
            setState(() {
              _availableResolutions = resolutions;
              _resolutionUrlMap
                ..clear()
                ..addAll(urlMap);
              _currentResolution = resolutions.first;
            });
            return;
          }
        }
      }
    } catch (_) {}

    if (mounted) {
      final isShortDrama = widget.preferredSource == 'hongguo' ||
          widget.videoInfo.source == 'hongguo' ||
          widget.videoInfo.source == 'shortdrama' ||
          (_selectedSource?.source == 'hongguo');

      final dramaId = _selectedSource?.id.isNotEmpty == true
          ? _selectedSource!.id
          : widget.videoInfo.id;

      // 针对短剧或常规流，自动对齐真实三档画质 URL
      final multiMap = DuanjuCoreBridge.instance.getEpisodeMultiResolutions(dramaId, _currentEpisodeIndex + 1) ??
          DuanjuCoreBridge.buildMultiResolutionUrls(url);

      final availableList = ['1080P', '720P', '480P'];
      String currentSel = _userPreferredResolution;
      if (!availableList.contains(currentSel)) {
        currentSel = '1080P';
      }

      setState(() {
        _availableResolutions = availableList;
        _resolutionUrlMap
          ..clear()
          ..addAll(multiMap);
        _currentResolution = currentSel;
      });
    }
  }

  /// 进度条 (5px 矩形, 绿进度, LunaTV Web 风格)
  // v2.5.74: 修复白点错位 — SliderThemeData 没有 trackHorizontalPadding 属性
  //   (v2.5.73 用了不存在的属性, 编译必挂). 正确属性是 padding (3.28+).
  //   padding=horizontal(r) 让 thumb 内缩 r, Positioned 负 left/right 让
  //   Slider 外扩 r, 两者抵消, thumb 中心 = [0, W] 精确对齐绿条.
  //   Stack clipBehavior=none 防 thumb 在 0/1 端被裁剪.
  // v2.5.75: 修"白点挡住绿条上半" — v2.5.74 的 Container.height=5 比
  //   thumb 直径 12px 小, thumb 圆心被迫对齐 5px 容器中心 (=2.5px),
  //   thumb 上半浮出容器顶端, 视觉上像"骑在绿条上".
  //   修法: Container 高度 = thumb 直径 (12) + 上下 4px buffer = 20,
  //   绿条和灰底色 Container 都用 Align(center) 让 5px 粗条在 20px
  //   容器里垂直居中, thumb 也居中, 白点圆心 = 绿条中心.
  Widget _buildLunaProgressBar() {
    const thumbRadius = 6.0;
    const barHeight = 5.0;          // 绿条 / 灰条粗细
    const containerHeight = 20.0;   // 必须 >= thumb 直径(12) 才能让 thumb 居中
    final dur = _currentDuration.inMilliseconds.toDouble();
    final pos = _scrubbingValue != null
        ? (_scrubbingValue! * dur).toInt()
        : _currentPosition.inMilliseconds;
    final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
    return Container(
      height: containerHeight,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 灰底色轨道（居中, 高 5px）
          Positioned.fill(
            child: Align(
              alignment: Alignment.center,
              child: SizedBox(
                height: barHeight,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(barHeight / 2),
                  ),
                ),
              ),
            ),
          ),
          // 绿色进度条（居中, 高 5px, 宽度按 progress）
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: Container(
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: kLunaTheme,
                    borderRadius: BorderRadius.circular(barHeight / 2),
                  ),
                ),
              ),
            ),
          ),
          // 拖动手柄 — padding=horizontal(r) 让 thumb 内缩 r,
          //   Positioned 负 left/right 让 Slider 外扩 r, 两者抵消,
          //   thumb 中心精确落在 [0, W], 与绿条两端对齐.
          //   SliderThemeData.trackHeight=barHeight 让透明 track 跟绿条
          //   高度一致, thumb 圆心 = 容器中心 = 绿条中心.
          if (dur > 0)
            Positioned.fill(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: barHeight,
                  padding: const EdgeInsets.symmetric(horizontal: thumbRadius),
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor: kLunaTheme.withOpacity(0.2),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 20),
                ),
                child: Slider(
                  value: progress,
                  onChangeStart: _onScrubStart,
                  onChanged: _onScrubChange,
                  onChangeEnd: _onScrubEnd,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 倍速选择底部面板
  /// v2.6.59: 横屏显示不全 → 改成 Wrap 网格布局 (横屏一行多个, 不裁切)
  Future<void> _showPlaybackRateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F2937),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text(
                  '倍速',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                // ★ v2.6.59: 横屏用 Wrap 网格, 竖屏用 ListTile
                if (isLandscape)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: _playbackRates.map((rate) {
                      final selected = (rate - _playbackRate).abs() < 0.001;
                      return _buildRateChip(rate, selected);
                    }).toList(),
                  )
                else
                  ..._playbackRates.map((rate) {
                    final selected = (rate - _playbackRate).abs() < 0.001;
                    return ListTile(
                      title: Text(
                        rate == 1.0 ? '1.0x (正常)' : '${rate}x',
                        style: TextStyle(
                          color: selected
                              ? const Color(0xFF22C55E)
                              : Colors.white,
                          fontSize: 15,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      trailing: selected
                        ? const Icon(Icons.check_circle,
                            color: Color(0xFF22C55E), size: 20)
                        : null,
                    onTap: () {
                      _setPlaybackRate(rate);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// v2.6.59: 倍速 chip — 横屏用 (圆形/椭圆, 选中绿色高亮)
  Widget _buildRateChip(double rate, bool selected) {
    final label = rate == 1.0 ? '1.0x' : '${rate}x';
    return InkWell(
      onTap: () {
        _setPlaybackRate(rate);
        Navigator.of(context).pop();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF22C55E)
              : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFF22C55E)
                : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 主播放视图 (12ce29d 简单 Stack 结构 + LunaTV Web 风格控件)
  /// 不用 LayoutBuilder / GestureDetector, 避免 video 纹理被重建导致白屏
  Widget _buildPlayingView(bool isDark) {
    return MouseRegion(
      cursor: (_isFullscreen && _hideMouseCursor)
          ? SystemMouseCursors.none
          : SystemMouseCursors.basic,
      onHover: (_) => _onUserActivity(),
      onEnter: (_) => _onUserActivity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
        // 视频 (12ce29d 结构: Container+AspectRatio+Stack+Video(NoVideoControls))
        // v2.6.41: 加 Transform.scale 支持双指缩放, 小尺寸影片能放大填满.
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: Center(
              child: Transform.scale(
                scale: _videoScale,
                child: AspectRatio(
                  aspectRatio: (_videoWidth > 0 && _videoHeight > 0)
                      ? _videoWidth / _videoHeight
                      : 16 / 9,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_player is DuanjuMediaKitBackend)
                        DuanjuMediaKitView(
                            backend: _player as DuanjuMediaKitBackend)
                      else if (_player is ExoPlayerBackend)
                        ExoPlayerView(backend: _player as ExoPlayerBackend)
                      else
                        const ColoredBox(color: Colors.black),
                      if (_danmakuEnabled)
                        RepaintBoundary(
                          child: DanmakuOverlay(
                            key: _danmakuKey,
                            comments: _danmakuComments,
                            enabled: _danmakuEnabled,
                            positionProvider: () => _currentPosition,
                            pausedProvider: () => !_isPlaying,
                          ),
                        ),
                      if (_isBuffering)
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                              color: kLunaLoadingColor, strokeWidth: 3),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // v2.6.41: 双指缩放 Listener 层 — 不参与手势竞技场, 只观察 pointer.
        //   translucent 让事件穿透到下方 GestureDetector (tap/drag/doubleTap),
        //   同时 Listener 拿到所有 pointer down/move/up 做 pinch 计算.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPinchPointerDown,
            onPointerMove: _onPinchPointerMove,
            onPointerUp: _onPinchPointerUp,
            onPointerCancel: _onPinchPointerCancel,
          ),
        ),
        // 点击空白区切换控制栏显隐 (始终存在, 控件隐藏时也能点击调出)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleControls,
          ),
        ),
        // 亮度/音量/快进快退 手势层 (v2.6.2 主流方案: 左右半屏上下滑 = 亮度/音量,
        //   全屏左右滑 = 快进/快退, 双击左半屏 = 快退10s, 双击右半屏 = 快进10s,
        //   跟 YouTube / 爱奇艺 / Bilibili 体验一致.)
        // v2.6.1 之前: 左 1/4 上下 = 亮度, 右 1/4 上下 = 音量, 中间 1/2 左右 = 快进快退.
        //   问题: 1) 快进快退只能拖中间半屏, 全屏拖快进幅度小; 2) 屏幕分割明显
        //   用户能感觉到; 3) 中间放 30s 按钮, 跟左右滑动抢手势焦点.
        // v2.6.2: 改为两半屏布局, 快进快退扩到全屏, ±10s 改用双击触发.
        Positioned.fill(
          child: Row(
            children: [
              // 左半屏: 上下 = 亮度, 左右 = 快进/快退
              Expanded(
                flex: 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: _onBrightnessSwipeStart,
                  onVerticalDragUpdate: _onBrightnessSwipeUpdate,
                  onVerticalDragEnd: _onBrightnessSwipeEnd,
                  onHorizontalDragStart: _onCenterSwipeStart,
                  onHorizontalDragUpdate: _onCenterSwipeUpdate,
                  onHorizontalDragEnd: _onCenterSwipeEnd,
                ),
              ),
              // 右半屏: 上下 = 音量, 左右 = 快进/快退
              Expanded(
                flex: 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: _onVolumeSwipeStart,
                  onVerticalDragUpdate: _onVolumeSwipeUpdate,
                  onVerticalDragEnd: _onVolumeSwipeEnd,
                  onHorizontalDragStart: _onCenterSwipeStart,
                  onHorizontalDragUpdate: _onCenterSwipeUpdate,
                  onHorizontalDragEnd: _onCenterSwipeEnd,
                ),
              ),
            ],
          ),
        ),
        // v2.6.2: 双击快进/快退/播放 全屏监听 (放最上层, 用 globalPosition
        //   区分左半/中间/右半. 跟下方左右 GestureDetector 不冲突 — onDoubleTap
        //   在这里优先命中, 不影响 onVerticalDrag/onHorizontalDrag)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTapDown: _onGlobalDoubleTapDown,
            onDoubleTap: _onGlobalDoubleTap,
          ),
        ),
        // 亮度浮窗指示器 (左侧, 竖屏横屏都显示)
        if (_showBrightnessIndicator) _buildBrightnessIndicator(),
        // 音量浮窗指示器 (右侧, 竖屏横屏都显示)
        if (_showVolumeIndicator) _buildVolumeIndicator(),
        // 顶部栏 (80px 渐变 + 集数胶囊)
        _buildLunaTopBar(),
        // 底部毛玻璃控制栏 (横屏改短)
        _buildLunaBottomBar(),
        // 中央双圆快进/快退 (避免被顶部栏/底部栏遮挡)
        _buildSideSeekButtons(),
        // v2.6.93: 全新智能片头/片尾跳过胶囊浮层 (置于最顶层，确保无论控制栏是否隐藏均优雅浮现且点击100%响应)
        if (_activeSmartSegment != null)
          Positioned(
            right: 18,
            bottom: _isControlsVisible ? 104 : 32,
            child: _buildSmartSkipCapsule(),
          ),
        // v2.6.113: 下一季居中卡片自动连播浮层 (类似 YouTube / Netflix 风格)
        if (_showNextSeasonOverlay) _buildNextSeasonCenterOverlay(),
      ],
    ),
  );
}

  /// v2.6.93: 全新智能跳过胶囊浮层 (对齐 SeleneTV, 支持倒计时自动跳过与手动点击)
  Widget _buildSmartSkipCapsule() {
    final seg = _activeSmartSegment;
    if (seg == null) return const SizedBox.shrink();

    final isOutro = seg.type == SkipSegmentType.outro || seg.type == SkipSegmentType.credits;
    final isTrimmed = seg.isSuspectedTrimmed;
    final accentColor = isTrimmed
        ? const Color(0xFFF59E0B) // 剪辑源警示暖琥珀色
        : (isOutro ? const Color(0xFF38BDF8) : kLunaTheme);
    final label = '${seg.label} ${_smartSkipCountdownSec}s';

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF20F172A), // 高级深邃毛玻璃底色
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: accentColor.withOpacity(0.85), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.55),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => _triggerSmartSkip(seg),
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isTrimmed
                          ? Icons.content_cut_rounded
                          : (isOutro ? Icons.skip_next_rounded : Icons.fast_forward_rounded),
                      color: accentColor,
                      size: 19,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: isTrimmed ? const Color(0xFFFDE68A) : Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(width: 1, height: 16, color: Colors.white24),
            InkWell(
              onTap: _dismissSmartSkip,
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(24)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Icon(Icons.close_rounded, color: Colors.white70, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // v2.6.113: 下一季自动连播居中弹层与 5 秒倒计时逻辑 (类似 YouTube / Netflix 风格)
  // ===========================================================================

  /// 最后一集起播后，静默预拉取下一季候选剧集数据
  Future<void> _checkAndPreloadNextSeason() async {
    if (_isPreloadingNextSeason || _nextSeasonCandidate != null) return;
    _isPreloadingNextSeason = true;
    try {
      final cand = await NextSeasonService.findNextSeason(
        currentVideoInfo: widget.videoInfo,
        currentSource: _selectedSource?.source,
      );
      if (cand != null && mounted) {
        setState(() {
          _nextSeasonCandidate = cand;
        });
        if (cand.poster.isNotEmpty) {
          try {
            precacheImage(CachedNetworkImageProvider(cand.poster), context);
          } catch (_) {}
        }
        debugPrint('[PlayerScreen] 成功预拉取到连播/推荐信息: ${cand.title}, 共${cand.totalEpisodes}集');
      }
    } catch (e) {
      debugPrint('[PlayerScreen] 预拉取连播/推荐异常: $e');
    } finally {
      _isPreloadingNextSeason = false;
    }
  }

  /// 最后一集播放结束/片尾时触发判定
  void _handleLastEpisodeCompletion() {
    if (_autoPlayedThisEpisode) return;
    if (_showNextSeasonOverlay) return;
    if (_nextSeasonDismissedThisEp) return;

    final isShortDrama = _selectedSource?.source == 'hongguo' ||
        _selectedSource?.source == 'shortdrama' ||
        widget.videoInfo.source == 'hongguo' ||
        widget.videoInfo.source == 'shortdrama';

    final dur = _currentDuration;
    if (dur <= Duration.zero) return;
    if (!isShortDrama && dur < const Duration(seconds: 30)) return;
    if (_currentPosition < dur - const Duration(milliseconds: 2500)) {
      return;
    }

    if (_nextSeasonCandidate != null) {
      _autoPlayedThisEpisode = true;
      _triggerNextSeasonOverlay();
    } else {
      _checkAndPreloadNextSeason().then((_) {
        if (_nextSeasonCandidate != null && mounted && !_nextSeasonDismissedThisEp) {
          _autoPlayedThisEpisode = true;
          _triggerNextSeasonOverlay();
        }
      });
    }
  }

  /// 激活下一季居中连播弹层与 5 秒倒计时
  void _triggerNextSeasonOverlay() {
    if (!mounted) return;
    if (_showNextSeasonOverlay) return;
    if (_nextSeasonDismissedThisEp) return;
    final candidate = _nextSeasonCandidate;
    if (candidate == null) return;

    try {
      _player?.pause();
    } catch (_) {}

    _nextSeasonTimer?.cancel();
    setState(() {
      _showNextSeasonOverlay = true;
      _nextSeasonCountdownSec = 5;
    });

    _nextSeasonTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_nextSeasonCountdownSec > 1) {
        setState(() {
          _nextSeasonCountdownSec--;
        });
      } else {
        timer.cancel();
        _playNextSeasonNow();
      }
    });
  }

  /// 用户主动取消下一季自动连播弹窗
  void _dismissNextSeasonOverlay() {
    _nextSeasonTimer?.cancel();
    _nextSeasonTimer = null;
    setState(() {
      _showNextSeasonOverlay = false;
      _nextSeasonDismissedThisEp = true;
    });
  }

  /// 立即播放下一季 (倒计时结束自动播放或用户点击立即播放)
  void _playNextSeasonNow() {
    final candidate = _nextSeasonCandidate;
    _nextSeasonTimer?.cancel();
    _nextSeasonTimer = null;
    if (candidate == null || !mounted) return;

    setState(() {
      _showNextSeasonOverlay = false;
    });

    try {
      _player?.pause();
    } catch (_) {}

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          videoInfo: candidate.nextVideoInfo,
        ),
      ),
    );
  }

  /// 下一季居中卡片自动连播浮层 (类似 YouTube / Netflix 风格)
  Widget _buildNextSeasonCenterOverlay() {
    final candidate = _nextSeasonCandidate;
    if (candidate == null || !_showNextSeasonOverlay) return const SizedBox.shrink();

    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Positioned.fill(
      child: Material(
        color: Colors.black.withOpacity(0.78),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Center(
            child: SingleChildScrollView(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                constraints: BoxConstraints(
                  maxWidth: isLandscape ? 500 : 380,
                  minWidth: 280,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xF20F172A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0x5538BDF8),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.65),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                    const BoxShadow(
                      color: Color(0x2238BDF8),
                      blurRadius: 16,
                      offset: Offset(0, 0),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部提示条
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0x3338BDF8),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.play_circle_fill_rounded,
                              color: Color(0xFF38BDF8),
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              candidate.bannerTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: _dismissNextSeasonOverlay,
                            borderRadius: BorderRadius.circular(16),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 主体图文
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 海报
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(
                              children: [
                                SizedBox(
                                  width: isLandscape ? 106 : 92,
                                  height: isLandscape ? 148 : 130,
                                  child: candidate.poster.isNotEmpty
                                      ? CachedNetworkImage(
                                          imageUrl: candidate.poster,
                                          fit: BoxFit.cover,
                                          placeholder: (c, u) => Container(
                                            color: Colors.white10,
                                            child: const Center(
                                              child: SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Color(0xFF38BDF8),
                                                ),
                                              ),
                                            ),
                                          ),
                                          errorWidget: (c, u, e) => Container(
                                            color: Colors.white10,
                                            child: const Icon(Icons.movie_rounded, color: Colors.white38),
                                          ),
                                        )
                                      : Container(
                                          color: Colors.white10,
                                          child: const Icon(Icons.movie_rounded, color: Colors.white38),
                                        ),
                                ),
                                Positioned(
                                  bottom: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.75),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.white24, width: 0.5),
                                    ),
                                    child: Text(
                                      candidate.seasonLabel,
                                      style: const TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),

                          // 剧集信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  candidate.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    if (candidate.year.isNotEmpty)
                                      _buildNextSeasonBadge(candidate.year),
                                    if (candidate.totalEpisodes > 0)
                                      _buildNextSeasonBadge('共${candidate.totalEpisodes}集'),
                                    _buildNextSeasonBadge(candidate.seasonLabel),
                                    _buildNextSeasonBadge(candidate.sourceName.isNotEmpty ? candidate.sourceName : '全网聚合'),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  candidate.desc,
                                  maxLines: isLandscape ? 3 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // 5秒动态进度条
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (5 - _nextSeasonCountdownSec) / 5.0,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                          minHeight: 3,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 底部按钮栏
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _dismissNextSeasonOverlay,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            ),
                            child: const Text('取消', style: TextStyle(fontSize: 14)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: _playNextSeasonNow,
                            icon: const Icon(Icons.play_arrow_rounded, size: 20),
                            label: Text(
                              '立即播放 (${_nextSeasonCountdownSec}s)',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF0284C7),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              elevation: 4,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNextSeasonBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }



  /// 亮度浮窗 (左侧, v1.0.40 修复主播放器手势)
  Widget _buildBrightnessIndicator() {
    return Positioned(
      left: 32,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.brightness_6, color: Colors.white, size: 28),
              const SizedBox(height: 10),
              SizedBox(
                width: 4,
                height: 120,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _currentBrightness,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_currentBrightness * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 音量浮窗 (右侧, v1.0.40 修复主播放器手势)
  Widget _buildVolumeIndicator() {
    return Positioned(
      right: 32,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _currentVolume == 0
                    ? Icons.volume_off
                    : _currentVolume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 4,
                height: 120,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _currentVolume,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(_currentVolume * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快进/快退 6s 按钮的文字标签 (替代原先的自绘圆弧箭头, 视觉更直接)
class _SeekLabel extends StatelessWidget {
  final String label;
  const _SeekLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

enum PingState { idle, testing, fast, medium, slow, unavailable }

/// 源测速结果 (v1.0.45: 用 M3U8Service 测完整信息, 不再只 HEAD ping)
class _SourceSpeedInfo {
  final String resolution; // e.g. "720p" / "1080p" / "4K", 空 = 未知
  final double loadSpeedKBps; // 下载速度 KB/s
  final int pingMs; // 延迟 ms
  final bool success; // false = 测失败, 排到最后
  const _SourceSpeedInfo({
    required this.resolution,
    required this.loadSpeedKBps,
    required this.pingMs,
    required this.success,
  });
  static _SourceSpeedInfo unavailable() =>
      const _SourceSpeedInfo(resolution: '', loadSpeedKBps: 0, pingMs: 3000, success: false);

  /// 格式化下载速度 (KB/s → MB/s, 自动单位)
  String formatLoadSpeed() {
    if (loadSpeedKBps <= 0) return '';
    if (loadSpeedKBps >= 1024) {
      return '${(loadSpeedKBps / 1024).toStringAsFixed(1)}MB/s';
    }
    return '${loadSpeedKBps.toStringAsFixed(0)}KB/s';
  }

  /// 综合评分 (越小越好, 用作排序 key)
  /// v2.3.0 公式: `-(speed * resWeight) + ping` (越小越优)
  ///   - speed 越大 → 越负 → 越小 → 排越前
  ///   - ping 越大 → 越大 → 排越后
  ///   - resWeight 是分辨率惩罚项: 高分片 (1080p/4K) 需要更高速度才算好
  ///     (1080p resWeight=0.4, 720p resWeight=0.6, 480p resWeight=0.9).
  ///     公式: `resWeight = resolutionScore / 100` (resScore 0~100 归一化).
  ///   - 失败/超时的源 → `1 << 30` 兜底, 排到最末尾.
  /// v2.3.12 改用 Selene-TV `u74.h` (越大越好), v2.3.14 回到 v2.3.0
  ///   (越小越好). UI 显示按 score 排, 选源时取最前的.
  int get score {
    if (!success) {
      // v2.3.0 公式: 失败/超时的源排末尾, 用 (1 << 30) 大常数兜底
      return 1 << 30;
    }
    final resScore = _qualityScoreRaw();
    final resWeight = resScore <= 0 ? 1.0 : (resScore / 100.0);
    // -(speed * resWeight) + ping. 速度越快 / ping 越低 → 越小 → 越好.
    return (-(loadSpeedKBps * resWeight) + pingMs).round();
  }

  /// 原始分辨率分 (0..100), 给 resWeight 用.
  /// v2.3.0: 跟 v2.3.12 同公式, 但 v2.3.0 用 score=100-resScore*resWeight+ping
  ///   (1-3 数列), 现在改成 resScore/100 当 resWeight, 跟 v1.0.45 同步.
  double _qualityScoreRaw() {
    if (resolution.isEmpty) return 0.0;
    final p = int.tryParse(resolution.replaceAll('p', '').replaceAll('K', '000')) ?? 0;
    if (p >= 3840) return 100.0; // 4K
    if (p >= 2560) return 85.0;  // 2K
    if (p >= 1920) return 75.0;  // 1080p
    if (p >= 1280) return 60.0;  // 720p
    if (p >= 854) return 40.0;   // 480p
    if (p >= 640) return 20.0;   // 360p
    return 0.0;
  }
}

/// v2.3.14: 卸 _SessionMaxSpeedHolder (v2.3.12 公式依赖 maxSpeed 归一化,
///   v2.3.0 `-(speed * resWeight) + ping` 不需要). 类定义整个删了.
/// v2.3.12: 全局 max speed 持有者 — Selene-TV u74.g 思路.
///   测速时需要先知道本会话所有有效速度的最大值, 才能算归一化.
///   不存在时 fallback 1024 KB/s (跟 u74.g 默认值一致).
///   (此注释是 v2.3.12 留下的, 提醒后来人这个类删了的理由)

/// v2.0.51: 空 PageController placeholder (initState 之前给 notifier 占位用)
class _EmptyPageController extends PageController {
  _EmptyPageController._() : super();
  static final _EmptyPageController instance = _EmptyPageController._();
}
