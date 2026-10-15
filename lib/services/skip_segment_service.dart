// lib/services/skip_segment_service.dart
// 智能片头/片尾/前情回顾跳过数据服务
// 对齐 SeleneTV 逆向逻辑, 融合 TMDB 代理加速 (用户自建 CF Worker 链路) + TheIntroDB / IntroDB 双轨容灾

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/skip_segment.dart';
import 'diary_service.dart';
import 'tmdb_service.dart';
import 'user_data_service.dart';

class SkipSegmentService {
  static const String _theIntroDbHost = 'https://api.theintrodb.org';
  static const String _introDbAppHost = 'https://api.introdb.app';
  static const Duration _timeout = Duration(seconds: 4);

  // 内存 LRU / 快速缓存
  static final Map<String, List<SkipSegment>> _memoryCache = {};

  /// 解析标题与季数 (Season)
  /// 例如: "庆余年 第二季" -> title: "庆余年", season: 2
  ///      "Stranger Things Season 4" -> title: "Stranger Things", season: 4
  static ({String cleanTitle, int season}) parseTitleAndSeason(String rawTitle) {
    var title = rawTitle.trim();
    int season = 1;

    // 1. 中文第X季匹配
    final zhSeasonMatch = RegExp(r'第\s*([0-9一二三四五六七八九十百]+)\s*[季期]').firstMatch(title);
    if (zhSeasonMatch != null) {
      final sStr = zhSeasonMatch.group(1)!;
      final parsed = _parseChineseNumber(sStr);
      if (parsed > 0) season = parsed;
    }

    // 2. 英文 Season X 匹配
    final enSeasonMatch = RegExp(r'(?:season|\bS)\s*(\d+)', caseSensitive: false).firstMatch(title);
    if (enSeasonMatch != null) {
      final parsed = int.tryParse(enSeasonMatch.group(1)!);
      if (parsed != null && parsed > 0) season = parsed;
    }

    // 使用 TmdbService 清洗剧名标题
    final clean = TmdbService.cleanTitle(title);
    return (cleanTitle: clean.isNotEmpty ? clean : title, season: season);
  }

  static int _parseChineseNumber(String str) {
    final direct = int.tryParse(str);
    if (direct != null) return direct;
    const digits = {
      '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
    };
    if (digits.containsKey(str)) return digits[str]!;
    if (str.startsWith('十') && str.length == 2) {
      return 10 + (digits[str[1]] ?? 0);
    }
    return 1;
  }

  /// 获取指定剧集某集的跳过片段列表
  /// [title]: 视频标题/剧名
  /// [episode]: 单集序号 (从 1 开始, 如第 1 集为 1)
  /// [year]: 选填年份
  /// [customSeason]: 可手动指定季数
  static Future<List<SkipSegment>> getSegments({
    required String title,
    required int episode,
    int? year,
    int? customSeason,
  }) async {
    final info = parseTitleAndSeason(title);
    final cleanTitle = info.cleanTitle;
    final season = customSeason ?? info.season;

    if (cleanTitle.isEmpty || episode <= 0) return const [];

    final cacheKey = 'skip_seg_${cleanTitle}_${season}_$episode';

    // 1. 检查内存缓存
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey]!;
    }

    // 2. 检查本地磁盘持久化缓存 (SharedPreferences)
    try {
      final prefs = await SharedPreferences.getInstance();
      final localJson = prefs.getString(cacheKey);
      if (localJson != null && localJson.isNotEmpty) {
        final decoded = jsonDecode(localJson) as List;
        final list = decoded.map((e) => SkipSegment.fromJson(e as Map<String, dynamic>)).toList();
        _memoryCache[cacheKey] = list;
        return list;
      }
    } catch (_) {}

    // 3. 获取 TMDB 引用 (★ 严格经过用户的 TMDB 代理链接)
    // TmdbService.search 内部已经完全接入了 UserDataService.getTmdbProxyDomainSync() 与 tmdb_proxy 加速
    int? tmdbId;
    String mediaType = 'tv';
    try {
      final ref = await TmdbService.search(title: cleanTitle, year: year);
      if (ref != null) {
        tmdbId = ref.id;
        mediaType = ref.mediaType;
      }
    } catch (e) {
      DiaryService.add('[SkipSegment] TMDB search err: $e');
    }

    if (tmdbId == null) {
      DiaryService.add('[SkipSegment] 无对应 TMDB 词条: cleanTitle="$cleanTitle"');
      return const [];
    }

    DiaryService.add('[SkipSegment] 命中 TMDB: id=$tmdbId, type=$mediaType, season=$season, ep=$episode');

    // 4. 双轨请求 (TheIntroDB 主源 + IntroDB.app 备用源，对齐 SeleneTV lt1.smali)
    final results = <SkipSegment>[];
    final theIntroFuture = _fetchFromTheIntroDb(tmdbId, season, episode);
    final imdbIdFuture = TmdbService.fetchImdbId(id: tmdbId, mediaType: mediaType);

    // 4.1 主源结果
    final theIntroSegments = await theIntroFuture;
    results.addAll(theIntroSegments);

    // 4.2 检查是否缺少片头或片尾
    final hasIntro = results.any((s) => s.type == SkipSegmentType.intro || s.type == SkipSegmentType.recap);
    final hasOutro = results.any((s) => s.type == SkipSegmentType.outro || s.type == SkipSegmentType.credits);

    // 4.3 若数据不全，尝试使用 imdb_id 从 IntroDB.app 补充
    if (!hasIntro || !hasOutro) {
      final imdbId = await imdbIdFuture;
      if (imdbId != null && imdbId.isNotEmpty) {
        DiaryService.add('[SkipSegment] 触发 IntroDB.app 补充查询: imdbId=$imdbId, s=$season, e=$episode');
        final introDbSegments = await _fetchFromIntroDbApp(imdbId, season, episode);
        for (final seg in introDbSegments) {
          final isIntroType = seg.type == SkipSegmentType.intro || seg.type == SkipSegmentType.recap;
          final isOutroType = seg.type == SkipSegmentType.outro || seg.type == SkipSegmentType.credits;
          if (isIntroType && hasIntro) continue;
          if (isOutroType && hasOutro) continue;
          results.add(seg);
        }
      }
    }

    // 5. 写入缓存并返回
    if (results.isNotEmpty) {
      _memoryCache[cacheKey] = results;
      try {
        final prefs = await SharedPreferences.getInstance();
        final encoded = jsonEncode(results.map((e) => e.toJson()).toList());
        await prefs.setString(cacheKey, encoded);
      } catch (_) {}
    }

    return results;
  }

  static const Duration _timeout = Duration(seconds: 7);
  static const Map<String, String> _browserHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  };

  /// 请求 TheIntroDB 接口 (严格经过软件设置里的代理, 失败则直连兜底)
  static Future<List<SkipSegment>> _fetchFromTheIntroDb(int tmdbId, int season, int episode) async {
    final path = '/v3/media?tmdb_id=$tmdbId&season=$season&episode=$episode';
    final directUrl = '$_theIntroDbHost$path';

    final source = UserDataService.getTmdbDataSourceSync();
    final proxy = UserDataService.normalizeProxyDomain(UserDataService.getTmdbProxyDomainSync());

    // 1. 如果用户配置了 tmdb_proxy, 优先调用软件设置里的 Worker 代理
    if (source == 'tmdb_proxy' && proxy.isNotEmpty) {
      final proxyUrl = '$proxy/theintrodb$path';
      try {
        DiaryService.add('[SkipSegment] 调用设置代理拉取 TheIntroDB: $proxyUrl');
        final resp = await http.get(Uri.parse(proxyUrl), headers: _browserHeaders).timeout(_timeout);
        DiaryService.add('[SkipSegment] TheIntroDB 代理响应: code=${resp.statusCode}');
        if (resp.statusCode == 200) {
          final list = _parseTheIntroDbJson(resp.body);
          if (list.isNotEmpty) {
            DiaryService.add('[SkipSegment] TheIntroDB 代理命中: ${list.length} 个片段');
            return list;
          }
        }
      } catch (e) {
        DiaryService.add('[SkipSegment] TheIntroDB 代理异常: $e, 平滑降级直连');
      }
    }

    // 2. 直连请求 TheIntroDB (注入真实浏览器 UA 杜绝 Cloudflare WAF 拦截)
    try {
      DiaryService.add('[SkipSegment] 发起 TheIntroDB 直连: $directUrl');
      final resp = await http.get(Uri.parse(directUrl), headers: _browserHeaders).timeout(_timeout);
      DiaryService.add('[SkipSegment] TheIntroDB 直连响应: code=${resp.statusCode}');
      if (resp.statusCode == 200) {
        final list = _parseTheIntroDbJson(resp.body);
        DiaryService.add('[SkipSegment] TheIntroDB 直连获取成功: ${list.length} 个片段');
        return list;
      }
    } catch (e) {
      DiaryService.add('[SkipSegment] TheIntroDB 直连失败: $e');
    }

    return const [];
  }

  /// 请求 IntroDB.app 接口 (基于 IMDB ID 查询, 严格经过设置代理与直连双轨)
  static Future<List<SkipSegment>> _fetchFromIntroDbApp(String imdbId, int season, int episode) async {
    final path = '/segments?imdb_id=$imdbId&season=$season&episode=$episode';
    final directUrl = '$_introDbAppHost$path';

    final source = UserDataService.getTmdbDataSourceSync();
    final proxy = UserDataService.normalizeProxyDomain(UserDataService.getTmdbProxyDomainSync());

    // 1. 优先调用软件设置里的代理
    if (source == 'tmdb_proxy' && proxy.isNotEmpty) {
      final proxyUrl = '$proxy/introdb$path';
      try {
        DiaryService.add('[SkipSegment] 调用设置代理拉取 IntroDB.app: $proxyUrl');
        final resp = await http.get(Uri.parse(proxyUrl), headers: _browserHeaders).timeout(_timeout);
        DiaryService.add('[SkipSegment] IntroDB.app 代理响应: code=${resp.statusCode}');
        if (resp.statusCode == 200) {
          final list = _parseIntroDbAppJson(resp.body);
          if (list.isNotEmpty) {
            DiaryService.add('[SkipSegment] IntroDB.app 代理命中: ${list.length} 个片段');
            return list;
          }
        }
      } catch (e) {
        DiaryService.add('[SkipSegment] IntroDB.app 代理异常: $e, 平滑降级直连');
      }
    }

    // 2. 直连请求 IntroDB.app
    try {
      DiaryService.add('[SkipSegment] 发起 IntroDB.app 直连: $directUrl');
      final resp = await http.get(Uri.parse(directUrl), headers: _browserHeaders).timeout(_timeout);
      DiaryService.add('[SkipSegment] IntroDB.app 直连响应: code=${resp.statusCode}');
      if (resp.statusCode == 200) {
        final list = _parseIntroDbAppJson(resp.body);
        DiaryService.add('[SkipSegment] IntroDB.app 直连获取成功: ${list.length} 个片段');
        return list;
      }
    } catch (e) {
      DiaryService.add('[SkipSegment] IntroDB.app 直连失败: $e');
    }

    return const [];
  }

  /// 解析 TheIntroDB JSON 格式 (对齐 SeleneTV mt1.e)
  static List<SkipSegment> _parseTheIntroDbJson(String body) {
    final List<SkipSegment> list = [];
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic> || data.containsKey('error')) {
        return list;
      }

      void extract(String key, SkipSegmentType type) {
        final items = data[key];
        if (items is List) {
          for (final item in items) {
            if (item is Map) {
              final start = (item['start_ms'] as num?)?.toInt() ?? 0;
              final end = (item['end_ms'] as num?)?.toInt() ?? 0;
              if (end > start) {
                list.add(SkipSegment(type: type, startMs: start, endMs: end));
              }
            }
          }
        }
      }

      extract('intro', SkipSegmentType.intro);
      extract('recap', SkipSegmentType.recap);
      extract('credits', SkipSegmentType.credits);
      extract('preview', SkipSegmentType.preview);
    } catch (e) {
      DiaryService.add('[SkipSegment] parse json err: $e');
    }
    return list;
  }

  /// 解析 IntroDB.app JSON 格式 (对齐 SeleneTV mt1.b 与 lt1.smali:1374)
  static List<SkipSegment> _parseIntroDbAppJson(String body) {
    final List<SkipSegment> list = [];
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic> || data.containsKey('error')) {
        return list;
      }

      void parseSection(String key, SkipSegmentType type) {
        final sec = data[key];
        if (sec is Map<String, dynamic>) {
          final confidence = (sec['confidence'] as num?)?.toDouble() ?? 0.0;
          final submissionCount = (sec['submission_count'] as num?)?.toInt() ?? 0;
          // 对齐 SeleneTV: 置信度 >= 0.5 或者至少 2 人提交，才采纳
          if (confidence >= 0.5 || submissionCount >= 2) {
            final start = (sec['start_ms'] as num?)?.toInt() ?? 0;
            final end = (sec['end_ms'] as num?)?.toInt() ?? 0;
            if (end > start) {
              list.add(SkipSegment(
                type: type,
                startMs: start,
                endMs: end,
                confidence: confidence,
              ));
            }
          }
        }
      }

      parseSection('intro', SkipSegmentType.intro);
      parseSection('recap', SkipSegmentType.recap);
      parseSection('outro', SkipSegmentType.outro);
    } catch (e) {
      DiaryService.add('[SkipSegment] IntroDB.app parse json err: $e');
    }
    return list;
  }
}
