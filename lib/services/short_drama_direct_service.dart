import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/models/raw_short_drama.dart';
import 'package:luna_tv/services/duanju_core_bridge.dart';

/// 短剧直连服务 (纯净官方原画架构: 100% 红果短剧原生/直连引擎驱动，已彻底移除第三方源).
///
/// 核心特性:
/// 1. **纯正红果官方原画**: 接入 libduanju_core 原生 Go 引擎与官方直连，1080p 超清原画秒开，零跑马灯广告。
/// 2. **AI 漫剧精选**: 首发支持爆款 AI 生成式短剧与动漫漫剧，专区置顶。
/// 3. **极速单源纯净**: 彻底剥离第三方低质采集源与星芽，专注超清水准。
class ShortDramaDirectService {
  /// 官方独家源配置
  static const List<_DirectSource> _sources = [
    _DirectSource(
      name: '红果短剧',
      apiUrl: 'https://api.hongguoduanju.com/api',
      srcKey: 'hongguo',
      pages: 3,
      categories: [
        _SourceCategory(101, 'AI 漫剧'),
        _SourceCategory(102, '红果精选'),
        _SourceCategory(103, '反转爽剧'),
        _SourceCategory(104, '现代都市'),
        _SourceCategory(105, '言情总裁'),
        _SourceCategory(106, '古装仙侠'),
        _SourceCategory(107, '悬疑脑洞'),
      ],
    ),
  ];

  static const List<String> SHORT_DRAMA_KEYWORDS = [
    'AI 漫剧',
    '红果精选',
    '反转爽剧',
    '现代都市',
    '言情总裁',
    '古装仙侠',
    '悬疑脑洞',
  ];

  /// 红果短剧官方原生与真实分类全库拉取
  static Future<List<RawShortDrama>> _fetchHongguoPage(
    int typeId,
    int page,
  ) async {
    try {
      String catKey = 'real-drama';
      String catName = '真人短剧';
      switch (typeId) {
        case 201:
          catKey = 'rank-hot';
          catName = '总热播榜';
          break;
        case 202:
          catKey = 'rank-real';
          catName = '真人热播';
          break;
        case 203:
          catKey = 'rank-comic';
          catName = '漫剧热播';
          break;
        case 204:
          catKey = 'rank-ai';
          catName = 'AI 漫剧';
          break;
        case 101:
          catKey = 'comeback';
          catName = '逆袭爽剧';
          break;
        case 102:
          catKey = 'urban';
          catName = '现代都市';
          break;
        case 103:
          catKey = 'costume';
          catName = '古装仙侠';
          break;
        case 104:
          catKey = 'romance';
          catName = '甜宠言情';
          break;
        case 105:
          catKey = 'suspense';
          catName = '悬疑脑洞';
          break;
        case 106:
          catKey = 'comic-drama';
          catName = '动漫漫剧';
          break;
        default:
          catKey = 'real-drama';
          catName = '真人短剧';
          break;
      }

      final items = await DuanjuCoreBridge.instance.fetchCatalog(
        category: catKey,
        page: page,
        size: 24,
      );

      if (items.isNotEmpty) {
        return items.map((m) {
          final idVal = m['id'] ?? m['drama_id'] ?? m['book_id'] ?? 0;
          final vodId = idVal is int
              ? idVal
              : (int.tryParse(idVal.toString()) ?? idVal.hashCode.abs());
          final name =
              (m['title'] ?? m['name'] ?? m['book_name'] ?? '').toString();
          final cover =
              (m['cover'] ?? m['cover_url'] ?? m['thumb_url'] ?? '').toString();
          final ep = m['episode_count'] ?? m['total_episodes'] ?? m['episodes'] ?? 80;
          final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 80);
          final desc =
              (m['intro'] ?? m['description'] ?? m['summary'] ?? '').toString();

          return RawShortDrama(
            vodId: vodId,
            vodName: RawShortDrama.cleanVodName(name),
            vodPic: RawShortDrama.cleanVodPic(cover),
            vodPicSlide: '',
            vodTime: DateTime.now().toIso8601String(),
            vodScore: 9.6,
            vodRemarksEpisodeCount: epCount,
            vodContent: desc,
            vodBlurb: desc,
            vodActor: catName,
            typeId: typeId,
            typeName: catName,
          );
        }).where((r) => r.vodName.isNotEmpty).toList();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ShortDramaDirect] hongguo error: $e');
    }
    return <RawShortDrama>[];
  }

  /// 单页拉取分发
  static Future<List<RawShortDrama>> _fetchSinglePage(
    _DirectSource src,
    String typeId,
    int page,
  ) async {
    final tid = int.tryParse(typeId) ?? 102;
    return _fetchHongguoPage(tid, page);
  }

  /// 从源并发拉取
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

  /// 关键字搜索 (纯红果全网检索)
  static Future<List<RawShortDrama>> search(String keyword) async {
    if (keyword.trim().isEmpty) return [];

    final cleanKw = keyword.trim();
    final allRaw = <RawShortDrama>[];

    try {
      final nativeItems = await DuanjuCoreBridge.instance.searchDramas(cleanKw);
      if (nativeItems.isNotEmpty) {
        final list = nativeItems.map((m) {
          final idVal = m['id'] ?? m['drama_id'] ?? 0;
          final vodId = idVal is int
              ? idVal
              : (int.tryParse(idVal.toString()) ?? idVal.hashCode.abs());
          final name = (m['title'] ?? m['name'] ?? '').toString();
          final cover = (m['cover'] ?? m['cover_url'] ?? '').toString();
          final ep = m['episode_count'] ?? m['total_episodes'] ?? 80;
          final epCount = ep is int ? ep : (int.tryParse(ep.toString()) ?? 80);
          final desc = (m['intro'] ?? m['description'] ?? '').toString();

          return RawShortDrama(
            vodId: vodId,
            vodName: RawShortDrama.cleanVodName(name),
            vodPic: RawShortDrama.cleanVodPic(cover),
            vodPicSlide: '',
            vodTime: DateTime.now().toIso8601String(),
            vodScore: 9.6,
            vodRemarksEpisodeCount: epCount,
            vodContent: desc,
            vodBlurb: desc,
            vodActor: '红果短剧',
            typeId: 102,
            typeName: '红果精选',
          );
        }).where((r) => r.vodName.isNotEmpty).toList();
        allRaw.addAll(list);
      }
    } catch (_) {}

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    return unique.values.toList();
  }

  /// 搜索短剧返回统一 ShortDrama 列表
  static Future<List<ShortDrama>> searchDramas(String keyword) async {
    final rawList = await search(keyword);
    return rawList.map(_toShortDrama).toList();
  }

  /// 首页"热门短剧"拉取：纯红果官方原画热榜
  static Future<List<ShortDrama>> getRecommend({int size = 60}) async {
    final allRaw = <RawShortDrama>[];

    final futures = <Future<List<RawShortDrama>>>[
      _fetchHongguoPage(101, 1),
      _fetchHongguoPage(102, 1),
      _fetchHongguoPage(103, 1),
      _fetchHongguoPage(104, 1),
    ];

    final results = await Future.wait(futures);
    for (final r in results) {
      allRaw.addAll(r);
    }

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    uniqueList.sort((a, b) {
      final at = DateTime.tryParse(a.vodTime) ?? DateTime(1970);
      final bt = DateTime.tryParse(b.vodTime) ?? DateTime(1970);
      return bt.compareTo(at);
    });

    final sliced = uniqueList.take(size).toList();
    return sliced.map(_toShortDrama).toList();
  }

  /// 短剧专区「全部」tab 分页形式：红果官方聚合 (首屏聚合热播榜，后续支持 34 页全量无限下滑)
  static Future<ShortDramaListResponse> getRecommendResponse({
    int page = 1,
    int size = 40,
    Set<String>? excludeNames,
  }) async {
    final allRaw = <RawShortDrama>[];

    if (page == 1) {
      final futures = <Future<List<RawShortDrama>>>[
        _fetchHongguoPage(201, 1),
        _fetchHongguoPage(101, 1),
        _fetchHongguoPage(102, 1),
      ];
      final results = await Future.wait(futures);
      for (final r in results) {
        allRaw.addAll(r);
      }
    } else {
      final r = await _fetchHongguoPage(0, page);
      allRaw.addAll(r);
    }

    if (allRaw.isEmpty) {
      return const ShortDramaListResponse(list: [], hasMore: false);
    }

    final unique = <String, RawShortDrama>{};
    for (final raw in allRaw) {
      if (raw.vodName.isEmpty) continue;
      unique.putIfAbsent(raw.vodName, () => raw);
    }
    final uniqueList = unique.values.toList();

    final filtered = excludeNames == null || excludeNames.isEmpty
        ? uniqueList
        : uniqueList.where((r) => !excludeNames.contains(r.vodName)).toList();

    return ShortDramaListResponse(
      list: filtered.map(_toShortDrama).toList(),
      hasMore: page < 34,
    );
  }

  /// 单个分类 tab 数据拉取 (榜单整榜加载，题材全库支持 34 页分页)
  static Future<ShortDramaListResponse> getListByTypeId({
    required int typeId,
    int page = 1,
    int size = 20,
  }) async {
    final rawList = await _fetchHongguoPage(typeId, page);
    final bool isRank = typeId >= 200;
    final hasMore = isRank ? false : (rawList.length >= 15 && page < 34);
    return ShortDramaListResponse(
      list: rawList.map(_toShortDrama).toList(),
      hasMore: hasMore,
    );
  }

  /// 红果短剧官方权威十大分类与热播榜单体系
  static Future<List<ShortDramaCategory>> getCategories() async {
    const priority = [
      ShortDramaCategory(typeId: 201, typeName: '总热播榜'),
      ShortDramaCategory(typeId: 202, typeName: '真人热播'),
      ShortDramaCategory(typeId: 203, typeName: '漫剧热播'),
      ShortDramaCategory(typeId: 204, typeName: 'AI 漫剧'),
      ShortDramaCategory(typeId: 101, typeName: '逆袭爽剧'),
      ShortDramaCategory(typeId: 102, typeName: '现代都市'),
      ShortDramaCategory(typeId: 103, typeName: '古装仙侠'),
      ShortDramaCategory(typeId: 104, typeName: '甜宠言情'),
      ShortDramaCategory(typeId: 105, typeName: '悬疑脑洞'),
      ShortDramaCategory(typeId: 106, typeName: '动漫漫剧'),
    ];
    return priority;
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
      author: raw.vodActor.isNotEmpty
          ? raw.vodActor
          : (raw.typeName.isNotEmpty ? raw.typeName : ''),
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
