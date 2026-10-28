// lib/danmaku/widgets/danmaku_overlay.dart
// 弹幕浮层 — 视频上层透明 Stack, 满帧丝滑硬件渲染 (CustomPainter + repaint)
//
// v2.6.91: 彻底重构弹幕动力学引擎与渲染管线:
//   1. 彻底根治"一走一停一走一停"顿挫:
//      - 解耦底层播放器低频(100~250ms)阶梯式进度通知;
//      - 物理位移改由真实高精度物理时钟(Wall-Clock Delta)驱动, 保证每一帧严格匀速连续向前推进;
//      - 移除 50ms (20fps) 人为锁帧门槛, CustomPainter 直接绑定 repaint: _ctrl 享受 60Hz/120Hz 满帧高刷;
//   2. 预排版与零内存抖动:
//      - 弹幕在装填(spawn)时一次性完成 TextPainter 排版并缓存, 彻底消除每帧 paint 内部重复 new 和 layout;
//   3. 完美出屏与防重叠:
//      - 修正滚动弹幕完全滑出屏幕左边缘(x <= -textWidth)后再移除, 杜绝屏幕左侧突兀截断闪退;
//      - 基于实时物理几何边缘判定轨道防重叠, 既无碰撞又无空档;
//   4. 智能 Seek 对齐与暂停保持:
//      - 检测到拖拽进度条(>1.5s 突变)时秒级清场重填, 正常微小抖动时柔性阻尼对齐;
//      - 暂停时原地定格, 恢复播放时无缝平滑连贯启动.

import 'package:flutter/material.dart';

import '../danmaku_settings.dart';
import '../models/danmaku_comment.dart';
import '../models/hongguo_danmaku_emojis.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuComment> comments;
  final bool enabled;
  final double opacity;
  final double fontSize;
  final double speed;
  final Duration Function()? positionProvider;
  final bool Function()? pausedProvider;

  const DanmakuOverlay({
    super.key,
    required this.comments,
    this.enabled = true,
    this.opacity = 1.0,
    this.fontSize = 16,
    this.speed = 1.0,
    this.positionProvider,
    this.pausedProvider,
  });

  @override
  State<DanmakuOverlay> createState() => DanmakuOverlayState();
}

class DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final List<_LiveBullet> _live = [];

  List<DanmakuComment> _sorted = const [];
  final Set<int> _spawnedHashes = {};
  bool _commentsChanged = false;
  bool _needsBackfill = true;

  static const int _maxScrollRows = 20;
  final List<_TrackState> _scrollTracks = List.generate(_maxScrollRows, (_) => _TrackState());
  static const int _maxFixedRows = 8;
  final List<_TrackState> _topTracks = List.generate(_maxFixedRows, (_) => _TrackState());
  final List<_TrackState> _bottomTracks = List.generate(_maxFixedRows, (_) => _TrackState());

  // 平滑物理时钟与视频时间
  double _smoothMediaMs = 0;
  DateTime _lastWallTime = DateTime.now();
  bool _paused = false;

  double _lastWidth = 0;
  double _lastHeight = 0;

  DanmakuRenderSettings _settings = const DanmakuRenderSettings();
  DanmakuAreaOption _area = DanmakuAreaOption.full;
  DanmakuMode _mode = DanmakuMode.all;

  int _densityCounter = 0;

  static const double _baseFontSize = 16.0;
  static const int _scrollDurationMs = 8000;
  static const int _fixedDurationMs = 4000;
  static const double _trackGap = 4.0;
  static const double _antiOverlapGap = 16.0;

  void syncPosition(Duration pos) {
    _smoothMediaMs = pos.inMilliseconds.toDouble();
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    _paused = false;
    _lastWallTime = DateTime.now();
  }

  int get liveCount => _live.length;

  void reset() {
    for (final b in _live) {
      b.dispose();
    }
    _live.clear();
    for (final t in _scrollTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _topTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _bottomTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    _densityCounter = 0;
    _spawnedHashes.clear();
    _commentsChanged = true;
    _needsBackfill = true;
    _lastWallTime = DateTime.now();
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comments, widget.comments)) {
      _commentsChanged = true;
      // 彻底根治卡顿：增量拉取或更新弹幕时绝不销毁已有飞行弹幕与重置轨道！
      // 只有在列表彻底被清空（例如切集换源）时才重置
      if (widget.comments.isEmpty) {
        reset();
      }
    } else if (oldWidget.opacity != widget.opacity ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.speed != widget.speed) {
      reset();
    }
  }

  void refreshSettings() {
    final s = DanmakuSettings.instance;
    setState(() {
      _settings = s.render;
      _area = s.area;
      _mode = s.mode;
    });
    reset();
  }

  @override
  void initState() {
    super.initState();
    final s = DanmakuSettings.instance;
    _settings = s.render;
    _area = s.area;
    _mode = s.mode;
    _lastWallTime = DateTime.now();

    // 异步预加载红果高清表情
    HongguoEmojiLoader.preloadAll();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(days: 1),
    )..addListener(_onTick);
    _ctrl.repeat();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    for (final b in _live) {
      b.dispose();
    }
    _live.clear();
    super.dispose();
  }

  void _onTick() {
    final now = DateTime.now();
    final dtMicro = now.difference(_lastWallTime).inMicroseconds;
    _lastWallTime = now;
    final dtMs = (dtMicro / 1000.0).clamp(0.0, 100.0);

    final pausedExt = widget.pausedProvider?.call() ?? _paused;
    if (pausedExt || !widget.enabled) return;

    // 1. 同步视频进度与处理用户 Seek
    if (widget.positionProvider != null) {
      final realMediaMs = widget.positionProvider!.call().inMilliseconds.toDouble();
      final diff = (realMediaMs - _smoothMediaMs).abs();
      if (diff > 1500) {
        // 用户快进/快退/切集 Seek
        _smoothMediaMs = realMediaMs;
        _handleSeek();
      } else {
        // 正常播放: 真实物理增量自然推进, 并用 10% 柔性阻尼消除播放器阶梯抖动
        _smoothMediaMs += dtMs + (realMediaMs - _smoothMediaMs) * 0.1;
      }
    } else {
      _smoothMediaMs += dtMs;
    }

    // 2. 满帧高刷推进所有活跃弹幕的物理位移
    for (int i = 0; i < _live.length; i++) {
      _live[i].step(dtMs);
    }

    // 3. 及时回收滚出屏幕的弹幕并释放排版对象
    _live.removeWhere((b) {
      if (b.done) {
        _spawnedHashes.remove(identityHashCode(b.comment));
        b.dispose();
        return true;
      }
      return false;
    });

    // 4. 定期生成新弹幕
    if (_lastWidth > 0 && _lastHeight > 0) {
      _spawn(_lastWidth, _lastHeight);
    }
  }

  void _handleSeek() {
    for (final b in _live) {
      b.dispose();
    }
    _live.clear();
    for (final t in _scrollTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _topTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    for (final t in _bottomTracks) {
      t.freeAtMs = 0;
      t.lastBullet = null;
    }
    _spawnedHashes.clear();
    _needsBackfill = true;
  }

  double _effectiveSpeed() {
    return widget.speed != 1.0 ? widget.speed : _settings.speed;
  }

  double _effectiveOpacity() {
    return widget.opacity != 1.0 ? widget.opacity : _settings.opacity;
  }

  double _effectiveFontSize() {
    return _baseFontSize * _settings.fontScale;
  }

  bool _shouldShowByMode(int mode) {
    switch (_mode) {
      case DanmakuMode.all:
      case DanmakuMode.top:
      case DanmakuMode.bottom:
        return true;
      case DanmakuMode.scroll:
        return mode == 1;
    }
  }

  int _effectiveRenderMode(int originalMode) {
    switch (_mode) {
      case DanmakuMode.top:
        return 5;
      case DanmakuMode.bottom:
        return 4;
      default:
        return originalMode;
    }
  }

  bool _shouldShowByDensity() {
    if (_settings.densityPct >= 100) return true;
    _densityCounter = (_densityCounter + 1) % 100;
    return _densityCounter < _settings.densityPct;
  }

  static _DanmakuLayout _calcLayout(
    double availH,
    double lineH,
    DanmakuMode mode,
  ) {
    int maxScrollRows, maxTopRows, maxBottomRows;

    switch (mode) {
      case DanmakuMode.top:
        maxTopRows = (availH / lineH).floor().clamp(1, _maxFixedRows);
        maxScrollRows = 0;
        maxBottomRows = 0;
        break;
      case DanmakuMode.bottom:
        maxBottomRows = (availH / lineH).floor().clamp(1, _maxFixedRows);
        maxScrollRows = 0;
        maxTopRows = 0;
        break;
      case DanmakuMode.scroll:
        maxScrollRows = (availH / lineH).floor().clamp(1, _maxScrollRows);
        maxTopRows = 0;
        maxBottomRows = 0;
        break;
      case DanmakuMode.all:
        final fixedH = availH * 0.25;
        maxTopRows = (fixedH / lineH).floor().clamp(1, _maxFixedRows);
        maxBottomRows = (fixedH / lineH).floor().clamp(1, _maxFixedRows);
        final scrollH = availH - maxTopRows * lineH - maxBottomRows * lineH;
        maxScrollRows = (scrollH / lineH).floor().clamp(1, _maxScrollRows);
        break;
    }

    final topH = maxTopRows * lineH;
    final bottomH = maxBottomRows * lineH;
    final scrollH = (availH - topH - bottomH).clamp(0.0, availH);
    final rowH = maxScrollRows > 0 ? scrollH / maxScrollRows : 0.0;

    return _DanmakuLayout(
      maxScrollRows: maxScrollRows,
      maxTopRows: maxTopRows,
      maxBottomRows: maxBottomRows,
      topH: topH,
      bottomH: bottomH,
      scrollH: scrollH,
      rowH: rowH,
      lineH: lineH,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_area.key == 'off') return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        if (w <= 0 || h <= 0) return const SizedBox.shrink();

        _lastWidth = w;
        _lastHeight = h;
        _spawn(w, h);

        return IgnorePointer(
          child: CustomPaint(
            painter: _DanmakuPainter(
              repaint: _ctrl, // 绑定 AnimationController, vsync 满帧驱动重绘
              bullets: _live,
              width: w,
              height: h,
              fontSize: _effectiveFontSize(),
              areaRatio: _area.ratio,
              mode: _mode,
            ),
            size: Size(w, h),
          ),
        );
      },
    );
  }

  void _spawn(double w, double h) {
    final current = _smoothMediaMs.round();
    final lineH = _effectiveFontSize() + _trackGap;
    final availH = h * _area.ratio;

    final layout = _calcLayout(availH, lineH, _mode);

    if (_commentsChanged) {
      _sorted = List.of(widget.comments)
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
      _commentsChanged = false;
    }
    if (_sorted.isEmpty) return;

    final windowEnd = current + 300;
    final int windowStart;
    if (_needsBackfill) {
      windowStart = (current - 500).clamp(0, current);
      _needsBackfill = false;
    } else {
      windowStart = current - 5000;
    }

    int lo = 0, hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].timeMs <= windowStart) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    int spawnedThisFrame = 0;
    for (var i = lo; i < _sorted.length; i++) {
      final c = _sorted[i];
      if (c.timeMs > windowEnd) break;
      // 单帧最多装填 2 条弹幕，将 TextPainter.layout 耗时平摊至多帧，杜绝 CPU/UI 线程峰值掉帧
      if (spawnedThisFrame >= 2) break;

      final hash = identityHashCode(c);
      if (_spawnedHashes.contains(hash)) continue;
      if (_live.any((b) => identical(b.comment, c))) continue;

      if (!_shouldShowByMode(c.mode)) continue;
      if (!_shouldShowByDensity()) continue;

      final renderMode = _effectiveRenderMode(c.mode);
      final track = _pickTrack(renderMode, current, w, layout);
      if (track < 0) continue;

      final speed = _effectiveSpeed();
      final scrollMs = (_scrollDurationMs / speed).round();

      final bullet = _LiveBullet(
        comment: c,
        row: track,
        spawnedAtMediaMs: current,
        screenWidth: w,
        scrollDurationMs: scrollMs,
        fixedDurationMs: _fixedDurationMs,
        fontSize: _effectiveFontSize(),
        renderMode: renderMode,
        opacity: _effectiveOpacity(),
      );
      _live.add(bullet);
      _spawnedHashes.add(hash);
      spawnedThisFrame++;

      if (renderMode == 1) {
        _scrollTracks[track].lastBullet = bullet;
      } else if (renderMode == 5) {
        _topTracks[track].lastBullet = bullet;
      } else if (renderMode == 4) {
        _bottomTracks[track].lastBullet = bullet;
      }
    }
  }

  int _pickTrack(
    int mode,
    int nowMs,
    double w,
    _DanmakuLayout layout,
  ) {
    if (mode == 5) {
      // 顶部固定
      for (var i = 0; i < layout.maxTopRows; i++) {
        if (_topTracks[i].freeAtMs <= nowMs) {
          _topTracks[i].freeAtMs = nowMs + _fixedDurationMs;
          return i;
        }
      }
      return -1;
    }
    if (mode == 4) {
      // 底部固定
      for (var i = 0; i < layout.maxBottomRows; i++) {
        if (_bottomTracks[i].freeAtMs <= nowMs) {
          _bottomTracks[i].freeAtMs = nowMs + _fixedDurationMs;
          return i;
        }
      }
      return -1;
    }

    // 滚动模式: 精确物理几何防重叠
    final speed = _effectiveSpeed();
    final scrollMs = (_scrollDurationMs / speed).round();
    for (var i = 0; i < layout.maxScrollRows; i++) {
      final track = _scrollTracks[i];
      if (track.freeAtMs <= nowMs) {
        if (_settings.antiOverlap && track.lastBullet != null) {
          final last = track.lastBullet!;
          if (!last.done) {
            // 前一条弹幕尾部位置: x + textWidth
            final lastRightEdge = last.x + last.textWidth;
            if (lastRightEdge > w - _antiOverlapGap) {
              continue; // 尾部未留出安全间隙, 寻找其他轨道
            }
          }
        }
        track.freeAtMs = nowMs + (scrollMs * 0.35).round();
        return i;
      }
    }
    return -1;
  }
}

class _DanmakuLayout {
  final int maxScrollRows;
  final int maxTopRows;
  final int maxBottomRows;
  final double topH;
  final double bottomH;
  final double scrollH;
  final double rowH;
  final double lineH;

  const _DanmakuLayout({
    required this.maxScrollRows,
    required this.maxTopRows,
    required this.maxBottomRows,
    required this.topH,
    required this.bottomH,
    required this.scrollH,
    required this.rowH,
    required this.lineH,
  });
}

class _TrackState {
  int freeAtMs = 0;
  _LiveBullet? lastBullet;
}

class _LiveBullet {
  final DanmakuComment comment;
  final int row;
  final int spawnedAtMediaMs;
  final double screenWidth;
  final int scrollDurationMs;
  final int fixedDurationMs;
  final double fontSize;
  final int renderMode; // 1: 滚动, 5: 顶部固定, 4: 底部固定

  double elapsedWallMs = 0; // 真实物理流逝时间 (ms)
  double x = 0;
  double textWidth = 0;
  double textHeight = 0;
  bool done = false;
  TextPainter? painter;
  List<DanmakuSegment>? segments;

  _LiveBullet({
    required this.comment,
    required this.row,
    required this.spawnedAtMediaMs,
    required this.screenWidth,
    required this.scrollDurationMs,
    required this.fixedDurationMs,
    required this.fontSize,
    required this.renderMode,
    required double opacity,
  }) {
    _initPainter(opacity);
  }

  void _initPainter(double opacity) {
    final text = comment.content;
    final alpha = (255 * opacity).round().clamp(0, 255);
    final c = comment.color;
    final r = (c >> 16) & 0xFF;
    final g = (c >> 8) & 0xFF;
    final bv = c & 0xFF;
    final color = Color.fromARGB(alpha, r, g, bv);

    final textStyle = TextStyle(
      fontSize: fontSize,
      color: color,
      fontWeight: FontWeight.w500,
      shadows: const [
        Shadow(blurRadius: 3, color: Colors.black87, offset: Offset(0, 0)),
        Shadow(blurRadius: 2, color: Colors.black54, offset: Offset(1, 1)),
      ],
    );

    if (HongguoEmojiLoader.hasEmoji(text)) {
      segments = HongguoEmojiLoader.parseSegments(
        text: text,
        style: textStyle,
        fontSize: fontSize,
      );
      textWidth = segments!.fold(0.0, (sum, seg) => sum + seg.width);
      textHeight = fontSize * 1.25;
    } else {
      painter = TextPainter(
        text: TextSpan(
          text: text,
          style: textStyle,
        ),
        textDirection: TextDirection.ltr,
      );
      painter!.layout();
      textWidth = painter!.width;
      textHeight = painter!.height;
    }
    x = screenWidth;
  }

  void dispose() {
    painter?.dispose();
    painter = null;
    if (segments != null) {
      for (final s in segments!) {
        s.dispose();
      }
      segments = null;
    }
  }

  /// 真实高精物理时钟步进
  void step(double dtMs) {
    elapsedWallMs += dtMs;
    if (renderMode == 1) {
      // 匀速物理滚动: 从 screenWidth 到 -(textWidth + 8)
      final totalDist = screenWidth + textWidth + 8.0;
      final progress = elapsedWallMs / scrollDurationMs;
      x = screenWidth - totalDist * progress;
      if (x <= -(textWidth + 8.0) || progress >= 1.0) {
        done = true;
      }
    } else {
      if (elapsedWallMs >= fixedDurationMs) {
        done = true;
      }
    }
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_LiveBullet> bullets;
  final double width;
  final double height;
  final double fontSize;
  final double areaRatio;
  final DanmakuMode mode;

  static final Paint _emojiPaint = Paint()..filterQuality = FilterQuality.medium;

  _DanmakuPainter({
    required super.repaint, // 继承自 Listenable, 满帧直接重绘
    required this.bullets,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.areaRatio,
    required this.mode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bullets.isEmpty) return;
    final lineH = fontSize + 4;
    final availH = height * areaRatio;

    final layout = DanmakuOverlayState._calcLayout(availH, lineH, mode);

    for (final b in bullets) {
      if (b.done) continue;

      final m = b.renderMode;
      double y;
      if (m == 5) {
        y = 8 + b.row * lineH;
      } else if (m == 4) {
        y = availH - layout.bottomH + 8 + b.row * lineH;
      } else {
        y = layout.topH + b.row * layout.rowH;
      }

      double curX = m == 1 ? b.x : (width - b.textWidth) / 2;

      if (b.segments != null) {
        for (final seg in b.segments!) {
          if (seg is TextDanmakuSegment) {
            seg.painter.paint(canvas, Offset(curX, y));
            curX += seg.width;
          } else if (seg is ImageDanmakuSegment) {
            final img = seg.image ?? HongguoEmojiLoader.getImage(seg.code);
            if (img != null) {
              final srcRect = Rect.fromLTWH(
                0,
                0,
                img.width.toDouble(),
                img.height.toDouble(),
              );
              final dstRect = Rect.fromLTWH(
                curX + 2.0,
                y + (lineH - seg.size) / 2 - 1.0,
                seg.size,
                seg.size,
              );
              canvas.drawImageRect(img, srcRect, dstRect, _emojiPaint);
            }
            curX += seg.width;
          }
        }
      } else if (b.painter != null) {
        b.painter!.paint(canvas, Offset(curX, y));
      }
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter old) =>
      old.fontSize != fontSize ||
      old.areaRatio != areaRatio ||
      old.mode != mode;
}
