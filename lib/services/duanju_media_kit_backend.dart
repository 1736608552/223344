import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/player_backend.dart';

/// 短剧专属 MediaKit (libmpv/FFmpeg) 解密推流播放后端
/// 专用于红果等火山 CDN CENC (AES-128-CTR) 加密短剧的硬件解密播放
class DuanjuMediaKitBackend implements PlayerBackend {
  final Player _player;
  VideoController? _videoController;

  VideoController? get videoController => _videoController;
  Player get player => _player;

  // ── 内部状态 ──────────────────────────────────────────
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  double _speed = 1.0;
  int _width = 0;
  int _height = 0;
  bool _disposed = false;

  // ── 流控制器 (broadcast 多订阅) ────────────────────────
  final _playingCtl = StreamController<bool>.broadcast();
  final _bufferingCtl = StreamController<bool>.broadcast();
  final _completedCtl = StreamController<bool>.broadcast();
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _bandwidthCtl = StreamController<BandwidthSample>.broadcast();

  final List<StreamSubscription> _subscriptions = [];

  DuanjuMediaKitBackend._(this._player, this._videoController) {
    _initListeners();
  }

  /// 工厂构造方法
  static Future<DuanjuMediaKitBackend> create() async {
    final player = Player(
      configuration: PlayerConfiguration(
        bufferSize: Platform.isAndroid ? 16 * 1024 * 1024 : 32 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );

    final videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );

    // 确保播放器内部音频输出起播默认 100% 满额推流
    try {
      await player.setVolume(100.0);
    } catch (_) {}

    DiaryService.add('[DuanjuMediaKit] 初始化成功，就绪状态');
    return DuanjuMediaKitBackend._(player, videoController);
  }

  void _initListeners() {
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        _isPlaying = playing;
        _safeAdd(_playingCtl, playing);
      }),
    );

    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (_disposed) return;
        _isBuffering = buffering;
        _safeAdd(_bufferingCtl, buffering);
      }),
    );

    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (_disposed) return;
        _isCompleted = completed;
        _safeAdd(_completedCtl, completed);
      }),
    );

    _subscriptions.add(
      _player.stream.position.listen((pos) {
        if (_disposed) return;
        _position = pos;
        _safeAdd(_positionCtl, pos);
      }),
    );

    _subscriptions.add(
      _player.stream.duration.listen((dur) {
        if (_disposed) return;
        _duration = dur;
        _safeAdd(_durationCtl, dur);
      }),
    );

    _subscriptions.add(
      _player.stream.width.listen((w) {
        if (_disposed) return;
        _width = w ?? 0;
      }),
    );

    _subscriptions.add(
      _player.stream.height.listen((h) {
        if (_disposed) return;
        _height = h ?? 0;
      }),
    );
  }

  void _safeAdd<T>(StreamController<T> ctl, T val) {
    if (!ctl.isClosed) {
      ctl.add(val);
    }
  }

  // ── PlayerBackend 接口实现 ──────────────────────────────
  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isBuffering => _isBuffering;

  @override
  bool get isCompleted => _isCompleted;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  double get volume => _volume;

  @override
  double get speed => _speed;

  @override
  int get width => _width;

  @override
  int get height => _height;

  @override
  Stream<bool> get playingStream => _playingCtl.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingCtl.stream;

  @override
  Stream<Duration> get positionStream => _positionCtl.stream;

  @override
  Stream<Duration> get durationStream => _durationCtl.stream;

  @override
  Stream<bool> get completedStream => _completedCtl.stream;

  @override
  Stream<BandwidthSample> get bandwidthStream => _bandwidthCtl.stream;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startAt,
    String? decryptionKey,
  }) async {
    if (_disposed) return;
    _isBuffering = true;
    _safeAdd(_bufferingCtl, true);

    try {
      _isCompleted = false;
      _safeAdd(_completedCtl, false);

      // 关键解密注入：对齐 guoapp 底层解密参数 (向 demuxer-lavf-o 注入 decryption_key)
      if (_player.platform is dynamic) {
        final dynamic platform = _player.platform;
        final rawKey = decryptionKey?.trim() ?? '';
        final cleanKey = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(rawKey) ? rawKey.toLowerCase() : '';
        final options = <String>[
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
          if (cleanKey.isNotEmpty) 'decryption_key=$cleanKey',
        ].join(',');

        try {
          await platform.setProperty('demuxer-lavf-o', options);
          await platform.setProperty('network-timeout', '10');
          // 极速探测起播：缩短 lavf 分析时长与探测尺寸，大幅缩短首帧与起播等待 (完全对齐红果鉴)
          await platform.setProperty('demuxer-lavf-analyzeduration', '1000000');
          await platform.setProperty('demuxer-lavf-probesize', '1048576');
          await platform.setProperty('force-seekable', 'yes');
          await platform.setProperty('hr-seek', 'default');
          await platform.setProperty('hwdec', 'auto-safe');
          await platform.setProperty('hwdec-codecs', 'all');
          await platform.setProperty('framedrop', 'no');
          await platform.setProperty('video-sync', 'audio');
          await platform.setProperty('scale', 'bilinear');
          await platform.setProperty('demuxer-max-bytes', '${16 * 1024 * 1024}');
          await platform.setProperty('demuxer-max-back-bytes', '${2 * 1024 * 1024}');
          await platform.setProperty('demuxer-readahead-secs', '10');
          await platform.setProperty('audio-buffer', '0.8');
          await platform.setProperty('audio-pitch-correction', 'no');
          await platform.setProperty('autosync', '0');
          // 彻底对齐红果官方短剧音量与响度：禁用自动电平衰减，放开音量上限，注入动态响度增强与平滑限幅
          await platform.setProperty('replaygain', 'no');
          await platform.setProperty('volume-max', '150');
          await platform.setProperty('af', 'lavfi=[dynaudnorm=f=150:g=15:m=8.0:p=0.95]');
        } catch (e) {
          if (kDebugMode) {
            print('[DuanjuMediaKit] setProperty error (handled): $e');
          }
        }
      }

      await _player.open(
        Media(
          url,
          httpHeaders: headers,
          start: startAt,
        ),
        play: true,
      );

      DiaryService.add('[DuanjuMediaKit] open 成功: keyLen=${decryptionKey?.trim().length ?? 0}, startAt=$startAt');
    } catch (e, st) {
      DiaryService.add('[DuanjuMediaKit] open 失败: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    await _player.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0);
    // media_kit volume 范围为 0.0 ~ 100.0
    await _player.setVolume(_volume * 100.0);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_disposed) return;
    _speed = speed.clamp(0.25, 4.0);
    await _player.setRate(_speed);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    await _player.dispose();
    _videoController = null;

    unawaited(_playingCtl.close());
    unawaited(_bufferingCtl.close());
    unawaited(_completedCtl.close());
    unawaited(_positionCtl.close());
    unawaited(_durationCtl.close());
    unawaited(_bandwidthCtl.close());

    DiaryService.add('[DuanjuMediaKit] 资源释放完毕');
  }

  @override
  List<MediaTrackInfo> get audioTracks => const [];

  @override
  List<MediaTrackInfo> get subtitleTracks => const [];

  @override
  Future<void> selectAudioTrack(String id) async {}

  @override
  Future<void> selectSubtitleTrack(String id) async {}

  @override
  Future<void> setSubtitleTrackEnabled(bool enabled) async {}
}
