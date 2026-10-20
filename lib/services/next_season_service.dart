import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/services/duanju_core_bridge.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/douban_service.dart';

/// 连播/推荐剧集候选模型 (用于播放器居中弹窗展示与自动连播)
class NextSeasonCandidate {
  final String title;
  final int seasonNumber;
  final String seasonLabel;
  final String poster;
  final String year;
  final String desc;
  final int totalEpisodes;
  final String source;
  final String sourceName;
  final VideoInfo nextVideoInfo;
  final bool isNextSeason;
  final String bannerTitle;
  final String bannerSubtitle;

  const NextSeasonCandidate({
    required this.title,
    required this.seasonNumber,
    required this.seasonLabel,
    required this.poster,
    required this.year,
    required this.desc,
    required this.totalEpisodes,
    required this.source,
    required this.sourceName,
    required this.nextVideoInfo,
    this.isNextSeason = true,
    this.bannerTitle = '即将播放下一季',
    this.bannerSubtitle = '即将为您连播下一季第一集',
  });
}

/// 下一季剧集推导与匹配服务
class NextSeasonService {
  static final Map<String, NextSeasonCandidate?> _cache = {};

  /// 中文数字映射
  static const Map<String, int> _cnNumberMap = {
    '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
    '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
    '十一': 11, '十二': 12, '十三': 13, '十四': 14, '十五': 15,
  };

  /// 数字转中文数字
  static String toChineseNumber(int n) {
    const list = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
    if (n <= 10 && n >= 0) return list[n];
    if (n < 20) return '十${list[n % 10]}';
    return '$n';
  }

  /// 解析标题与季数
  /// 例如:
  ///   "庆余年 第一季" -> baseTitle: "庆余年", season: 1, nextSeason: 2
  ///   "持械入宋：第一季" -> baseTitle: "持械入宋", season: 1, nextSeason: 2
  ///   "Stranger Things Season 1" -> baseTitle: "Stranger Things", season: 1, nextSeason: 2
  ///   "狂飙" -> baseTitle: "狂飙", season: 1, nextSeason: 2
  static ({String baseTitle, int currentSeason, int nextSeason}) parseSeason(String rawTitle) {
    String title = rawTitle.trim();
    int season = 1;
    String base = title;

    // 1. 中文第X季/部/期
    final zhMatch = RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*[季部期]').firstMatch(title);
    if (zhMatch != null) {
      final sStr = zhMatch.group(1)!;
      final parsed = int.tryParse(sStr) ?? _cnNumberMap[sStr] ?? 1;
      season = parsed;
      base = title.replaceAll(RegExp(r'[:：\s]*第\s*[0-9一二三四五六七八九十]+\s*[季部期]'), '').trim();
    } else {
      // 2. 英文 Season X / S X
      final enMatch = RegExp(r'(?:season|\bS)\s*(\d+)', caseSensitive: false).firstMatch(title);
      if (enMatch != null) {
        final parsed = int.tryParse(enMatch.group(1)!);
        if (parsed != null && parsed > 0) {
          season = parsed;
          base = title.replaceAll(RegExp(r'[:：\s]*(?:season|\bS)\s*\d+', caseSensitive: false), '').trim();
        }
      } else {
        // 3. 标题末尾纯数字季数（如 "庆余年2", "大江大河 2"）
        final tailNumMatch = RegExp(r'[:：\s]*([2-9])\s*$').firstMatch(title);
        if (tailNumMatch != null) {
          final parsed = int.tryParse(tailNumMatch.group(1)!);
          if (parsed != null && parsed > 1) {
            season = parsed;
            base = title.replaceAll(RegExp(r'[:：\s]*[2-9]\s*$'), '').trim();
          }
        }
      }
    }

    base = base.replaceAll(RegExp(r'[:：\s]*完结$'), '').trim();
    if (base.isEmpty) base = rawTitle.trim();

    return (
      baseTitle: base,
      currentSeason: season,
      nextSeason: season + 1,
    );
  }

  /// 异步寻找并解析下一季候选信息（若无下一季自动寻找推荐内容）
  static Future<NextSeasonCandidate?> findNextSeason({
    required VideoInfo currentVideoInfo,
    String? currentSource,
  }) async {
    final title = currentVideoInfo.title.trim();
    if (title.isEmpty) return null;

    final cacheKey = '${currentVideoInfo.source}-${currentVideoInfo.id}-$title';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    try {
      final parsed = parseSeason(title);
      final baseTitle = parsed.baseTitle;
      final nextSeason = parsed.nextSeason;
      final nextSeasonCn = toChineseNumber(nextSeason);

      final isShortDrama = currentVideoInfo.source == 'hongguo' ||
          currentVideoInfo.source == 'shortdrama' ||
          currentSource == 'hongguo' ||
          currentSource == 'shortdrama';

      NextSeasonCandidate? candidate;

      // 1. 短剧专属通道推导下一季
      if (isShortDrama) {
        candidate = await _findNextSeasonShortDrama(
          baseTitle: baseTitle,
          currentVideoInfo: currentVideoInfo,
          nextSeason: nextSeason,
          nextSeasonCn: nextSeasonCn,
        );
      }

      // 2. 通用全网聚合搜索推导下一季 (电视剧 / 番剧 / 普通视频)
      candidate ??= await _findNextSeasonGeneral(
        baseTitle: baseTitle,
        currentVideoInfo: currentVideoInfo,
        nextSeason: nextSeason,
        nextSeasonCn: nextSeasonCn,
      );

      // 3. ★ 若无下一季内容，智能寻找相关/爆款推荐剧集
      candidate ??= await _findRecommendation(
        currentVideoInfo: currentVideoInfo,
        isShortDrama: isShortDrama,
      );

      // 4. ★ 终极保障兜底：无论何种网络环境，100% 确保海报与完结大卡片弹出
      candidate ??= buildFallbackCompletionCandidate(
        currentVideoInfo: currentVideoInfo,
        currentSource: currentSource,
      );

      _cache[cacheKey] = candidate;
      return candidate;
    } catch (e) {
      if (kDebugMode) {
        print('[NextSeasonService] 查找下一季发生异常: $e');
      }
      // 异常时采用兜底大卡片，绝不让海报弹窗丢失
      final fallback = buildFallbackCompletionCandidate(
        currentVideoInfo: currentVideoInfo,
        currentSource: currentSource,
      );
      _cache[cacheKey] = fallback;
      return fallback;
    }
  }

  /// 短剧专属通道查找下一季
  static Future<NextSeasonCandidate?> _findNextSeasonShortDrama({
    required String baseTitle,
    required VideoInfo currentVideoInfo,
    required int nextSeason,
    required String nextSeasonCn,
  }) async {
    final searchQueries = [
      '$baseTitle：第$nextSeasonCn季',
      '$baseTitle 第$nextSeasonCn季',
      '$baseTitle第$nextSeasonCn季',
      '$baseTitle 第二季',
      '$baseTitle第二季',
      '$baseTitle 第$nextSeasonCn部',
      '$baseTitle 第二部',
      '$baseTitle第$nextSeasonCn部',
      '$baseTitle 第$nextSeason季',
      '$baseTitle：第$nextSeason季',
      '$baseTitle Season $nextSeason',
      '$baseTitle 2',
      '${baseTitle}2',
    ];

    for (final q in searchQueries) {
      try {
        final dramas = await DuanjuCoreBridge.instance.searchDramas(q);
        if (dramas.isNotEmpty) {
          for (final d in dramas) {
            final dTitle = (d['title'] ?? '').toString().trim();
            final dParsed = parseSeason(dTitle);

            // 严格验证：核心剧名一致，且季数精确匹配下一季
            final baseMatch = dParsed.baseTitle.contains(baseTitle) || baseTitle.contains(dParsed.baseTitle);
            final seasonMatch = dParsed.currentSeason == nextSeason ||
                (nextSeason == 2 && (
                    dTitle.contains('第二季') ||
                    dTitle.contains('第二部') ||
                    dTitle.contains('第2季') ||
                    dTitle.contains('第2部') ||
                    dTitle.endsWith('2') ||
                    dTitle.contains('$baseTitle 2') ||
                    dTitle.contains('${baseTitle}2')
                ));

            if (baseMatch && seasonMatch) {
              final dramaId = (d['id'] ?? '').toString().trim();
              final poster = (d['cover'] ?? '').toString().trim();
              final desc = (d['desc'] ?? '').toString().trim();
              final total = int.tryParse(d['total']?.toString() ?? '') ?? 0;

              final nextInfo = VideoInfo(
                id: dramaId,
                source: 'hongguo',
                title: dTitle,
                sourceName: '短剧专区',
                year: (d['year'] ?? '').toString(),
                cover: poster.isNotEmpty ? poster : currentVideoInfo.cover,
                index: 1,
                totalEpisodes: total,
                playTime: 0,
                totalTime: 0,
                saveTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                searchTitle: dTitle,
                doubanId: null,
              );

              return NextSeasonCandidate(
                title: dTitle,
                seasonNumber: nextSeason,
                seasonLabel: '第$nextSeasonCn季',
                poster: poster.isNotEmpty ? poster : currentVideoInfo.cover,
                year: nextInfo.year.isNotEmpty ? nextInfo.year : currentVideoInfo.year,
                desc: desc.isNotEmpty ? desc : '精彩好剧抢先连播，5秒后自动开启下一季',
                totalEpisodes: total,
                source: 'hongguo',
                sourceName: '短剧专区',
                nextVideoInfo: nextInfo,
              );
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// 通用全网聚合搜索查找下一季
  static Future<NextSeasonCandidate?> _findNextSeasonGeneral({
    required String baseTitle,
    required VideoInfo currentVideoInfo,
    required int nextSeason,
    required String nextSeasonCn,
  }) async {
    final searchQueries = [
      '$baseTitle 第$nextSeasonCn季',
      '$baseTitle 第$nextSeason季',
      '$baseTitle 第二季',
      '$baseTitle 第二部',
      '$baseTitle 第$nextSeasonCn部',
      '$baseTitle Season $nextSeason',
      '$baseTitle S$nextSeason',
      '$baseTitle 2',
      '${baseTitle}2',
    ];

    for (final q in searchQueries) {
      try {
        final results = await SearchService.searchSync(q);
        if (results.isNotEmpty) {
          // 过滤并寻找最佳匹配
          for (final res in results) {
            final resTitle = res.title.trim();
            // 排除预告、花絮、解说等干扰项
            if (resTitle.contains('预告') ||
                resTitle.contains('花絮') ||
                resTitle.contains('解说') ||
                resTitle.contains('看点') ||
                resTitle.contains('特辑')) {
              continue;
            }

            final resParsed = parseSeason(resTitle);
            final baseMatch = resParsed.baseTitle == baseTitle ||
                resParsed.baseTitle.contains(baseTitle) ||
                baseTitle.contains(resParsed.baseTitle);

            // 严格等于目标季数，或为第二部/2 变体
            final seasonMatch = resParsed.currentSeason == nextSeason ||
                (nextSeason == 2 && (
                    resTitle.contains('第二季') ||
                    resTitle.contains('第二部') ||
                    resTitle.contains('第2季') ||
                    resTitle.contains('第2部') ||
                    resTitle.endsWith('2') ||
                    resTitle.contains('$baseTitle 2') ||
                    resTitle.contains('${baseTitle}2')
                ));

            if (baseMatch && seasonMatch && res.episodes.isNotEmpty) {
              final poster = res.poster.isNotEmpty ? res.poster : currentVideoInfo.cover;
              final nextInfo = res.toVideoInfo();

              return NextSeasonCandidate(
                title: resTitle,
                seasonNumber: nextSeason,
                seasonLabel: '第$nextSeasonCn季',
                poster: poster,
                year: res.year.isNotEmpty ? res.year : currentVideoInfo.year,
                desc: (res.desc?.trim().isNotEmpty == true)
                    ? res.desc!.trim()
                    : '即将无缝连播《$resTitle》，精彩剧情连绵不断。',
                totalEpisodes: res.episodes.length,
                source: res.source,
                sourceName: res.sourceName,
                nextVideoInfo: nextInfo,
              );
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// 构建完结兜底大卡片候选 (保证任何网络状况下海报与完结大卡片 100% 弹出)
  static NextSeasonCandidate buildFallbackCompletionCandidate({
    required VideoInfo currentVideoInfo,
    String? currentSource,
    String? sourceName,
  }) {
    final isMovie = currentVideoInfo.totalEpisodes <= 1;
    final bannerTitle = isMovie ? '本片已播放完毕 · 感谢观看' : '本季已全部完结 · 感谢观看';
    final bannerSub = '精彩剧情已播完，点击可重新播放，或返回选集';
    final seasonLabel = isMovie ? '全片完结' : '全剧完结';

    return NextSeasonCandidate(
      title: currentVideoInfo.title,
      seasonNumber: 1,
      seasonLabel: seasonLabel,
      poster: currentVideoInfo.cover,
      year: currentVideoInfo.year,
      desc: '全集播放完毕，感谢您的观看与陪伴。点击可重新播放，或返回选集重温。',
      totalEpisodes: currentVideoInfo.totalEpisodes > 0 ? currentVideoInfo.totalEpisodes : 1,
      source: currentSource ?? currentVideoInfo.source,
      sourceName: sourceName ?? currentVideoInfo.sourceName,
      nextVideoInfo: currentVideoInfo,
      isNextSeason: false,
      bannerTitle: bannerTitle,
      bannerSubtitle: bannerSub,
    );
  }

  /// 若无下一季，寻找相关或热门推荐内容
  static Future<NextSeasonCandidate?> _findRecommendation({
    required VideoInfo currentVideoInfo,
    required bool isShortDrama,
  }) async {
    final curTitle = currentVideoInfo.title.trim();
    if (isShortDrama) {
      try {
        final dramas = await DuanjuCoreBridge.instance.fetchCatalog(category: 'hot', page: 1, size: 20);
        if (dramas.isNotEmpty) {
          for (final d in dramas) {
            final title = (d['title'] ?? '').toString().trim();
            final id = (d['id'] ?? '').toString().trim();
            if (title.isNotEmpty && id.isNotEmpty && !title.contains(curTitle) && !curTitle.contains(title)) {
              final poster = (d['cover'] ?? '').toString().trim();
              final desc = (d['desc'] ?? '').toString().trim();
              final total = int.tryParse(d['total']?.toString() ?? '') ?? 0;
              final nextInfo = VideoInfo(
                id: id,
                source: 'hongguo',
                title: title,
                sourceName: '短剧专区',
                year: (d['year'] ?? '').toString(),
                cover: poster.isNotEmpty ? poster : currentVideoInfo.cover,
                index: 1,
                totalEpisodes: total,
                playTime: 0,
                totalTime: 0,
                saveTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                searchTitle: title,
                doubanId: null,
              );
              return NextSeasonCandidate(
                title: title,
                seasonNumber: 1,
                seasonLabel: '为你推荐',
                poster: poster.isNotEmpty ? poster : currentVideoInfo.cover,
                year: nextInfo.year.isNotEmpty ? nextInfo.year : currentVideoInfo.year,
                desc: desc.isNotEmpty ? desc : '本剧已完结，为您精选热播好剧，5秒后自动连播',
                totalEpisodes: total,
                source: 'hongguo',
                sourceName: '短剧专区',
                nextVideoInfo: nextInfo,
                isNextSeason: false,
                bannerTitle: '本剧已完结 · 为你推荐精彩好剧',
                bannerSubtitle: '为您精选热播爆款好剧，5秒后自动开播',
              );
            }
          }
        }
      } catch (_) {}
    } else {
      // 长剧/电影/动漫场景: 优先通过豆瓣高分推荐与全网最近热门
      final isMovie = currentVideoInfo.totalEpisodes <= 1;
      final categoryLabel = isMovie ? '本片已完结 · 为你推荐精彩好片' : '本剧已完结 · 为你推荐精彩好剧';
      final categorySub = isMovie ? '为您精选同类高分好片，5秒后自动连播' : '为您精选同类高分好剧，5秒后自动连播';

      // 1. 若含有豆瓣 ID，优先提取豆瓣同类高分关联推荐
      try {
        final doubanId = currentVideoInfo.doubanId;
        if (doubanId != null && doubanId.isNotEmpty) {
          final resDetails = await DoubanService.getDoubanDetails(null, doubanId: doubanId)
              .timeout(const Duration(seconds: 3));
          final detail = resDetails.data;
          if (detail != null && detail.recommends.isNotEmpty) {
            for (final rec in detail.recommends) {
              final recTitle = rec.title.trim();
              if (recTitle.isNotEmpty && recTitle != curTitle) {
                final results = await SearchService.searchSync(recTitle)
                    .timeout(const Duration(seconds: 3));
                if (results.isNotEmpty) {
                  final best = results.firstWhere((r) => r.episodes.isNotEmpty, orElse: () => results.first);
                  if (best.episodes.isNotEmpty) {
                    final nextInfo = best.toVideoInfo();
                    return NextSeasonCandidate(
                      title: best.title,
                      seasonNumber: 1,
                      seasonLabel: '同类高分',
                      poster: best.poster.isNotEmpty ? best.poster : (rec.poster.isNotEmpty ? rec.poster : currentVideoInfo.cover),
                      year: best.year.isNotEmpty ? best.year : currentVideoInfo.year,
                      desc: (best.desc?.isNotEmpty == true) ? best.desc! : '$categoryLabel，5秒后自动开播',
                      totalEpisodes: best.episodes.length,
                      source: best.source,
                      sourceName: best.sourceName,
                      nextVideoInfo: nextInfo,
                      isNextSeason: false,
                      bannerTitle: categoryLabel,
                      bannerSubtitle: categorySub,
                    );
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      // 2. 真实获取豆瓣「最近热门」影视大作榜单，彻底取代失效的采集源盲搜
      try {
        final hotRes = await DoubanService.getCategoryData(
          null as dynamic,
          kind: isMovie ? 'movie' : 'tv',
          category: '最近热门',
          type: isMovie ? 'movie' : 'tv',
          pageLimit: 12,
        ).timeout(const Duration(seconds: 3));

        final hotList = hotRes.data;
        if (hotList != null && hotList.isNotEmpty) {
          for (final m in hotList) {
            final mTitle = m.title.trim();
            if (mTitle.isEmpty || mTitle == curTitle || curTitle.contains(mTitle) || mTitle.contains(curTitle)) {
              continue;
            }
            final mPoster = (m.coverUrl?.isNotEmpty == true) ? m.coverUrl! : m.poster;

            // 快速并发搜源，若有可播放剧集直接组装
            try {
              final searchRes = await SearchService.searchSync(mTitle).timeout(const Duration(seconds: 2));
              final best = searchRes.firstWhere((r) => r.episodes.isNotEmpty, orElse: () => searchRes.isNotEmpty ? searchRes.first : null as dynamic);
              if (best != null && best.episodes.isNotEmpty) {
                final nextInfo = best.toVideoInfo();
                return NextSeasonCandidate(
                  title: best.title,
                  seasonNumber: 1,
                  seasonLabel: '热门推荐',
                  poster: best.poster.isNotEmpty ? best.poster : (mPoster.isNotEmpty ? mPoster : currentVideoInfo.cover),
                  year: best.year.isNotEmpty ? best.year : (m.year.isNotEmpty ? m.year : currentVideoInfo.year),
                  desc: (best.desc?.isNotEmpty == true) ? best.desc! : '$categoryLabel，5秒后自动开播',
                  totalEpisodes: best.episodes.length,
                  source: best.source,
                  sourceName: best.sourceName,
                  nextVideoInfo: nextInfo,
                  isNextSeason: false,
                  bannerTitle: categoryLabel,
                  bannerSubtitle: categorySub,
                );
              }
            } catch (_) {}

            // 若采集源搜索稍有延迟，依然先以豆瓣热门作品（真实海报与标题）即时生成推荐大卡片
            final mockInfo = VideoInfo(
              id: m.id,
              source: 'douban',
              title: mTitle,
              sourceName: '全网热播',
              year: m.year,
              cover: mPoster.isNotEmpty ? mPoster : currentVideoInfo.cover,
              index: 1,
              totalEpisodes: 1,
              playTime: 0,
              totalTime: 0,
              saveTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              searchTitle: mTitle,
              doubanId: m.id,
            );
            return NextSeasonCandidate(
              title: mTitle,
              seasonNumber: 1,
              seasonLabel: '全网热播',
              poster: mPoster.isNotEmpty ? mPoster : currentVideoInfo.cover,
              year: m.year.isNotEmpty ? m.year : currentVideoInfo.year,
              desc: '$categoryLabel，为您精选全网高分热门作《$mTitle》',
              totalEpisodes: 1,
              source: 'douban',
              sourceName: '全网热播',
              nextVideoInfo: mockInfo,
              isNextSeason: false,
              bannerTitle: categoryLabel,
              bannerSubtitle: categorySub,
            );
          }
        }
      } catch (_) {}
    }
    return null;
  }
}
