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

  /// 搜索红果短剧剧目
  @override
  Future<List<DanmakuMedia>> searchMedia(String keyword, {Dio? dio}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];

    try {
      final dramas = await DuanjuCoreBridge.instance.searchDramas(kw);
      if (dramas.isEmpty) return const [];

      return dramas.map((d) {
        final dramaId = (d['drama_id'] ?? d['series_id'] ?? d['id'] ?? d['book_id'] ?? '').toString();
        final title = (d['title'] ?? d['name'] ?? d['book_name'] ?? kw).toString();
        final cover = (d['cover'] ?? d['cover_url'] ?? d['thumb_url'] ?? '').toString();
        final ep = d['episode_count'] ?? d['total_episodes'] ?? d['episodes'] ?? 80;
        final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 80);

        return DanmakuMedia(
          source: DanmakuSource.hongguo,
          mediaId: dramaId,
          title: title,
          type: 'tv',
          poster: cover.isNotEmpty ? cover : null,
          episodeCount: epCount,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 获取短剧分集列表 (返回每集对应的真实 vid)
  @override
  Future<List<DanmakuEpisode>> getEpisodes(String mediaId, {Dio? dio}) async {
    final cleanId = DuanjuCoreBridge.cleanSeriesId(mediaId);
    if (cleanId.isEmpty) return const [];

    try {
      final vidList = await DuanjuCoreBridge.instance.fetchEpisodeVidList(cleanId);
      if (vidList.isEmpty) return const [];

      final episodes = <DanmakuEpisode>[];
      for (int i = 0; i < vidList.length; i++) {
        final vid = vidList[i];
        final order = i + 1;
        // 编码为 cleanId:vid:order 便于精确反解
        episodes.add(DanmakuEpisode(
          source: DanmakuSource.hongguo,
          episodeId: '$cleanId:$vid:$order',
          order: order,
          title: '第$order集',
        ));
      }
      return episodes;
    } catch (_) {
      return const [];
    }
  }

  /// 拉取指定集的红果官方弹幕
  @override
  Future<List<DanmakuComment>> getDanmaku(
    String episodeId, {
    int startSec = 0,
    int endSec = 0,
    Dio? dio,
  }) async {
    if (episodeId.isEmpty) return const [];

    String seriesId = '';
    String vid = episodeId;
    int episode = 1;

    // 解析复合 episodeId (cleanId:vid:order)
    if (episodeId.contains(':')) {
      final parts = episodeId.split(':');
      if (parts.length >= 3) {
        seriesId = parts[0];
        vid = parts[1];
        episode = int.tryParse(parts[2]) ?? 1;
      } else if (parts.length == 2) {
        seriesId = parts[0];
        vid = parts[1];
      }
    }

    try {
      final durationMs = (endSec > startSec && endSec > 0)
          ? ((endSec - startSec) * 1000)
          : 180000;

      return await DuanjuCoreBridge.instance.fetchHongguoDanmaku(
        seriesId: seriesId,
        vid: vid,
        episode: episode,
        durationMs: durationMs,
      );
    } catch (_) {
      return const [];
    }
  }
}
