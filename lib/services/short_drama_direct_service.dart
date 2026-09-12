import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/raw_short_drama.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// 短剧直连服务 (主备双源架构: 金鹰短剧为主 + 星芽短剧为备用).
///
/// 架构设计:
/// 1. **主源 (金鹰短剧)**: 专精红果短剧搬运 + 火爆 AI 漫剧，标准 MacCMS 协议，自带完备 m3u8 切片。
/// 2. **备用源 (星芽短剧)**: 专注精品竖屏短剧，官方纯净无水印海报与纯净剧名。
/// 3. **极简清晰分类**: 绝无多余空分类，仅保留精选核心品类 (全部 / AI 漫剧 / 红果短剧 / 星芽精选 / 爽剧精选)。
/// 4. **主备智能容灾**: 主源异常时无缝降级到备用源兜底，保障 100% 可用性。
class ShortDramaDirectService {
  /// 主备双源配置 (金鹰为主, 星芽为备用)
  static const List<_DirectSource> _sources = [
    _DirectSource(
      name: '金鹰短剧',
      apiUrl: 'https://api.jyzyapi.com/provide/vod',
      srcKey: 'jyzy',
      pages: 3,
      categories: [
        _SourceCategory(36, 'AI 漫剧'),
        _SourceCategory(31, '红果短剧'),
        _SourceCategory(34, '爽剧精选'),
      ],
    ),
    _DirectSource(
      name: '星芽短剧',
      apiUrl: 'https://app.whjzjx.cn/v1/theater/list',
      srcKey: 'xingya',
      pages: 2,
      categories: [
        _SourceCategory(1, '星芽精选'),
      ],
    ),
  ];

  static const List<String> SHORT_DRAMA_KEYWORDS = [
    'AI 漫剧',
    '红果短剧',
    '星芽精选',
    '爽剧精选',
  ];

  static const Duration _timeout = Duration(seconds: 10);

  /// 通用 TVBox GET 工具 (用于金鹰等标准 MacCMS 协议).
  static Future<Map<String, dynamic>> _get(
    String apiUrl,
    String ac,
    Map<String, String> extraParams,
  ) async {
    final params = <String, String>{'ac': ac, ...extraParams};
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final url = '$apiUrl?$query';
    final resp = await http
        .get(Uri.parse(url), headers: {
          'User-Agent': 'Mozilla/5.0 (LunaTV-Mobile/2.6.64)',
          'Accept': 'application/json',
        })
        .timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode} from $url');
    }
    final body = resp.body;
    return json.decode(body) as Map<String, dynamic>;
  }

  /// 星芽短剧 (备用源) 开放 API 拉取
  static Future<List<RawShortDrama>> _fetchXingyaPage(
    _DirectSource src,
    String typeId,
    int page,
  ) async {
    try {
      final query = 'page=$page&size=20&category_id=$typeId';
      final url = '${src.apiUrl}?$query';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36',
        'Accept': 'application/json',
      }).timeout(_timeout);

      if (resp.statusCode == 200) {
        final jsonMap = json.decode(resp.body);
        final list = (jsonMap['data']?['list'] ?? jsonMap['list'] ?? []) as List<dynamic>;
        return list.map((item) {
          final m = item as Map<String, dynamic>;
          final rawName = (m['title'] ?? m['name'] ?? '').toString();
          final rawPic = (m['cover'] ?? m['pic'] ?? '').toString();
          final ep = m['episodes'] ?? m['episode_count'] ?? 1;
          final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 1);
          final score = (m['score'] as num?)?.toDouble() ?? 0.0;
          return RawShortDrama(
            vodId: (m['id'] is int ? m['id'] : int.tryParse(m['id']?.toString() ?? '0')) ?? 0,
            vodName: RawShortDrama.cleanVodName(rawName),
            vodPic: RawShortDrama.cleanVodPic(rawPic),
            vodPicSlide: '',
            vodTime: (m['updated_at'] ?? m['time'] ?? '').toString(),
            vodScore: score,
            vodRemarksEpisodeCount: epCount,
            vodContent: (m['intro'] ?? m['desc'] ?? '').toString(),
            vodBlurb: (m['intro'] ?? '').toString(),
            vodActor: (m['tag'] ?? '星芽精选').toString(),
            typeId: int.tryParse(typeId) ?? 1,
            typeName: '星芽精选',
          );
        }).toList();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ShortDramaDirect] xingya error: $e');
    }
    return <RawShortDrama>[];
  }

  /// 拉单个源单个分类的单页
  static Future<List<RawShortDrama>> _fetchSinglePage(
    _DirectSource src,
    String typeId,
    int page,
  ) async {
    if (src.srcKey == 'xingya' || src.apiUrl.contains('whjzjx.cn')) {
      return _fetchXingyaPage(src, typeId, page);
    }
    final apiBase = UserDataService.buildShortDramaApiUrl(src.srcKey) ?? src.apiUrl;
    final data = await _get(apiBase, 'detail', {
      't': typeId.toString(),
      'pg': page.toString(),
    });
    final list = (data['list'] as List<dynamic>?) ?? [];
    return list.map((e) => RawShortDrama.fromVodJson(e as Map<String, dynamic>)).toList();
  }

  /// 关键字搜索单页 (用于金鹰额外搜索补充)
  static Future<List<RawShortDrama>> _fetchSearchPage(
    String apiBase,
    String keyword,
    int page,
  ) async {
    final data = await _get(apiBase, 'detail', {
      'wd': keyword,
      'pg': page.toString(),
    });
    final list = (data['list'] as List<dynamic>?) ?? [];
    return list.map((e) => RawShortDrama.fromVodJson(e as Map<String, dynamic>)).toList();
  }

  /// 从单个源并发拉取多页
  static Future<List<RawShortDrama>> _fetchFromSource(
    _DirectSource src,
    int typeId, {
    int startPage = 1,
    int pages = 1,
  }) async {
    final futures = <Future<List<RawShortDrama>>>[];
    for (int p = startPage; p < startPage + pages; p++) {
      futures.add(_fetchSinglePage(src, typeId.toString(), p).catchError((e) {
        // ignore: avoid_print
        print('[ShortDramaDirect] source=${src.name} type=$typeId page=$p error=$e');
        return <RawShortDrama>[];
      }));
    }
    final results = await Future.wait(futures);
    final allRaw = <RawShortDrama>[];
    for (final r in results) {
      allRaw.addAll(r);
    }
    return allRaw;
  }

  /// 关键字搜索多页 (并发)
  static Future<List<RawShortDrama>> _fetchFromSearch(
    _DirectSource src,
    String keyword, {
    int pages = 2,
  }) async {
    final apiBase = UserDataService.buildShortDramaApiUrl(src.srcKey) ?? src.apiUrl;
    final futures = <Future<List<RawShortDrama>>>[];
    for (int p = 1; p <= pages; p++) {
      futures.add(_fetchSearchPage(apiBase, keyword, p).catchError((e) {
        // ignore: avoid_print
        print('[ShortDramaDirect] search=${src.name} kw=$keyword page=$p error=$e');
        return <RawShortDrama>[];
      }));
    }
    final results = await Future.wait(futures);
    final allRaw = <RawShortDrama>[];
    for (final r in results) {
      allRaw.addAll(r);
    }
    return allRaw;
  }

  /// 首页"热门短剧"拉取：主源(金鹰) + 备用源(星芽) 全量聚合并清洗去重
  static Future<List<ShortDrama>> getRecommend({int size = 60}) async {
    final allRaw = <RawShortDrama>[];

    final futures = <Future<List<RawShortDrama>>>[];
    for (final src in _sources) {
      for (final cat in src.categories) {
        futures.add(_fetchFromSource(
          src,
          cat.typeId,
          startPage: 1,
          pages: src.pages,
        ));
      }
      // 金鹰主源额外针对热门"AI漫剧"和"红果"进行搜索扩展
      if (src.srcKey == 'jyzy') {
        futures.add(_fetchFromSearch(src, 'AI漫剧', pages: 2));
        futures.add(_fetchFromSearch(src, '红果', pages: 2));
      }
    }
    final results = await Future.wait(futures);
    for (final r in results) {
      allRaw.addAll(r);
    }

    // 按清洗后的剧名去重
    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    // 按更新时间倒序
    uniqueList.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    final sliced = uniqueList.take(size).toList();
    return sliced.map(_toShortDrama).toList();
  }

  /// 短剧专区「全部」tab 分页形式：双源并发聚合拉取 + 去重
  static Future<ShortDramaListResponse> getRecommendResponse({
    int page = 1,
    int size = 60,
    Set<String>? excludeNames,
  }) async {
    final allRaw = <RawShortDrama>[];

    final futures = <Future<List<RawShortDrama>>>[];
    for (final src in _sources) {
      for (final cat in src.categories) {
        futures.add(_fetchFromSource(
          src,
          cat.typeId,
          startPage: page,
          pages: src.pages,
        ));
      }
    }
    final results = await Future.wait(futures);
    for (final r in results) {
      allRaw.addAll(r);
    }

    if (allRaw.isEmpty) {
      return const ShortDramaListResponse(list: [], hasMore: false);
    }

    // 按剧名去重
    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    // 排除已展示
    final filtered = excludeNames == null || excludeNames.isEmpty
        ? uniqueList
        : uniqueList.where((r) => !excludeNames.contains(r.vodName)).toList();

    filtered.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    final sliced = filtered.take(size).toList();
    final hasMore = page < 5;

    return ShortDramaListResponse(
      list: sliced.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// 单个分类 tab 数据拉取 (含主备容灾兜底)
  static Future<ShortDramaListResponse> getListByTypeId({
    required int typeId,
    int page = 1,
    int size = 20,
  }) async {
    _DirectSource? matchSrc;
    for (final src in _sources) {
      for (final cat in src.categories) {
        if (cat.typeId == typeId) {
          matchSrc = src;
          break;
        }
      }
      if (matchSrc != null) break;
    }
    matchSrc ??= _sources.first;

    var rawList = await _fetchFromSource(
      matchSrc,
      typeId,
      startPage: page,
      pages: 1,
    );

    // ★ 主备智能容灾：如果主源拉取失败且为空，自动切换到备用源兜底
    if (rawList.isEmpty && _sources.length > 1) {
      final backupSrc = _sources.firstWhere(
        (s) => s.srcKey != matchSrc!.srcKey,
        orElse: () => _sources.last,
      );
      final backupTypeId = backupSrc.categories.isNotEmpty ? backupSrc.categories.first.typeId : 1;
      rawList = await _fetchFromSource(
        backupSrc,
        backupTypeId,
        startPage: page,
        pages: 1,
      );
    }

    final hasMore = rawList.length >= size;
    return ShortDramaListResponse(
      list: rawList.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// 极简核心分类列表：仅保留高质量有效分类
  static Future<List<ShortDramaCategory>> getCategories() async {
    final seen = <String, _SourceCategory>{};
    for (final src in _sources) {
      for (final cat in src.categories) {
        seen.putIfAbsent(cat.typeName, () => cat);
      }
    }

    // 核心精简分类 (全部由前端固定排在最前, 后面紧随这 4 个精品分类)
    const priorityNames = [
      'AI 漫剧',       // ★ 火爆 AI 短剧 (主源)
      '红果短剧',       // ★ 红果专属短剧 (主源)
      '星芽精选',       // ★ 星芽精品短剧 (备用源)
      '爽剧精选',       // ★ 反转/打脸爽剧 (主源)
    ];

    final sorted = <_SourceCategory>[];
    for (final name in priorityNames) {
      final cat = seen[name];
      if (cat != null) sorted.add(cat);
    }

    return sorted
        .map((c) => ShortDramaCategory(typeId: c.typeId, typeName: c.typeName))
        .toList();
  }

  /// RawShortDrama → ShortDrama 统一映射
  static ShortDrama _toShortDrama(RawShortDrama raw) {
    return ShortDrama(
      id: raw.vodId,
      name: raw.vodName,
      cover: raw.vodPic,
      updateTime: raw.vodTime,
      score: raw.vodScore,
      episodeCount: raw.vodRemarksEpisodeCount,
      description: raw.vodContent.isNotEmpty ? raw.vodContent : raw.vodBlurb,
      author: raw.vodActor.isNotEmpty ? raw.vodActor : (raw.typeName.isNotEmpty ? raw.typeName : ''),
      backdrop: raw.vodPicSlide.isNotEmpty ? raw.vodPicSlide : raw.vodPic,
      voteAverage: raw.vodScore,
    );
  }
}

class _SourceCategory {
  final int typeId;
  final String typeName;
  const _SourceCategory(this.typeId, this.typeName);
}

class _DirectSource {
  final String name;
  final String apiUrl;
  final String srcKey;
  final int pages;
  final List<_SourceCategory> categories;

  const _DirectSource({
    required this.name,
    required this.apiUrl,
    required this.srcKey,
    this.pages = 3,
    required this.categories,
  });
}
