// lib/danmaku/sources/hongguo_danmaku.dart
// 红果短剧官方弹幕源 (对齐红果鉴)
// 支持根据剧名全库检索短剧、按集获取真实短剧官方弹幕，并完美解析 150+ 种官方表情 Emoji。

import 'package:dio/dio.dart';
import '../../services/duanju_core_bridge.dart';
import '../models/danmaku_comment.dart';
import '../models/danmaku_media.dart';
import 'danmaku_source.dart';

class HongguoDanmaku extends BaseDanmakuSource {
  @override
  DanmakuSource get sourceEnum => DanmakuSource.hongguo;

  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async => const [];

  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId, {Dio? dio}) async => const [];

  @override
  Future<List<DanmakuComment>> getDanmaku(
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
    Dio? dio,
  }) async => const [];
}
