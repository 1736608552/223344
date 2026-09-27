import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 短剧播放计划与CENC解密包模型 (100%对齐红果鉴)
class DuanjuPlaybackPlan {
  final String url;
  final String decryptionKey;
  final Map<String, String> headers;
  final Map<String, String> multiMap;
  final String resolution;
  final int quality;
  final int actualQuality;
  final List<int> qualities;

  const DuanjuPlaybackPlan({
    required this.url,
    this.decryptionKey = '',
    this.headers = const {},
    this.multiMap = const {},
    this.resolution = '1080P',
    this.quality = 0,
    this.actualQuality = 1080,
    this.qualities = const [1080, 720, 480],
  });
}

/// 短剧核心原生引擎与直连桥接 (支持 libduanju_core.so FFI 加速 + HTTP 智能降级)
class DuanjuCoreBridge {
  static DuanjuCoreBridge? _instance;
  static DuanjuCoreBridge get instance => _instance ??= DuanjuCoreBridge._();

  DuanjuCoreBridge._() {
    _initNativeLibrary();
  }

  DynamicLibrary? _dylib;
  Pointer<Utf8> Function(Pointer<Utf8>)? _nativeRequest;
  void Function(Pointer<Utf8>)? _nativeFree;
  bool _isNativeAvailable = false;
  bool _isInitialized = false;
  Future<void>? _initFuture;

  /// 检查原生 Go 核心动态库是否就绪
  bool get isNativeAvailable => _isNativeAvailable;

  /// 统一清洗短剧剧集 ID（去除 hongguo: 前缀并保留纯数字大 ID）
  static String cleanSeriesId(dynamic raw) {
    if (raw == null) return '';
    var s = raw.toString().trim();
    if (s.startsWith('hongguo:')) {
      s = s.substring('hongguo:'.length).trim();
    }
    return s;
  }

  /// 初始化动态库加载
  void _initNativeLibrary() {
    if (!Platform.isAndroid) {
      if (kDebugMode) {
        print('[DuanjuBridge] 非 Android 平台，原生库略过，启用直连降级模式');
      }
      return;
    }

    try {
      // 1. 尝试从应用系统库路径加载
      try {
        _dylib = DynamicLibrary.open('libduanju_core.so');
      } catch (e) {
        // 2. 备用尝试进程全局作用域
        _dylib = DynamicLibrary.process();
      }

      if (_dylib != null) {
        _nativeRequest = _dylib!
            .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
                Pointer<Utf8> Function(Pointer<Utf8>)>('DuanjuRequest');
        _nativeFree = _dylib!
            .lookupFunction<Void Function(Pointer<Utf8>),
                void Function(Pointer<Utf8>)>('DuanjuFree');
        _isNativeAvailable = true;
        if (kDebugMode) {
          print('[DuanjuBridge] 成功载入原生短剧核心库 libduanju_core.so');
        }
        // 异步静默触发核心引擎初始化
        unawaited(ensureInitialized());
      }
    } catch (e) {
      _isNativeAvailable = false;
      if (kDebugMode) {
        print('[DuanjuBridge] 原生库加载失败，已自动降级到 HTTP 协议直连: $e');
      }
    }
  }

  /// 确保原生 Go 核心引擎初始化 (传入应用存储目录，建立 nativeEngine)
  Future<void> ensureInitialized() async {
    if (_isInitialized || !_isNativeAvailable) return;
    if (_initFuture != null) return _initFuture;
    _initFuture = _doInitialize();
    await _initFuture;
  }

  Future<void> _doInitialize() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final res = await invokeNative('initialize', {
        'directory': dir.path,
      });
      if (res != null && res['ok'] == true) {
        _isInitialized = true;
        if (kDebugMode) {
          print('[DuanjuBridge] 原生核心引擎初始化成功: directory=${dir.path}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] 原生核心引擎初始化失败: $e');
      }
    }
  }

  /// 通过原生 FFI 派发请求给 Go 核心引擎 (直接传递扁平结构体，对齐 Go nativeInput 结构体)
  Future<Map<String, dynamic>?> invokeNative(
      String action, Map<String, dynamic> params) async {
    if (!_isNativeAvailable || _nativeRequest == null || _nativeFree == null) {
      return null;
    }

    if (action != 'initialize' && !_isInitialized) {
      await ensureInitialized();
    }

    final reqData = <String, dynamic>{
      'action': action,
      ...params,
    };

    return compute(_isolateCall, reqData);
  }

  /// 供 Isolate 中执行的 FFI 请求逻辑，避免阻塞 Flutter UI 渲染
  static Map<String, dynamic>? _isolateCall(Map<String, dynamic> reqData) {
    try {
      final dylib = DynamicLibrary.open('libduanju_core.so');
      final requestFn = dylib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)>('DuanjuRequest');
      final freeFn = dylib.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('DuanjuFree');

      final reqJson = jsonEncode(reqData);
      final reqPtr = reqJson.toNativeUtf8();

      try {
        final respPtr = requestFn(reqPtr);
        if (respPtr == nullptr) return null;

        try {
          final respStr = respPtr.toDartString();
          final parsed = jsonDecode(respStr);
          if (parsed is Map<String, dynamic>) {
            return parsed;
          }
        } finally {
          freeFn(respPtr);
        }
      } finally {
        malloc.free(reqPtr);
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge/Isolate] 原生请求异常: $e');
      }
    }
    return null;
  }

  // -------------------------------------------------------------
  // 业务层通用包装：智能原生优先 + HTTP 协议自愈降级
  // -------------------------------------------------------------

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  /// 拉取红果精选分类短剧列表
  /// 拉取红果精选分类短剧列表 (原生引擎优先 + 官方真实 Web 协议抓取自愈)
  Future<List<Map<String, dynamic>>> fetchCatalog({
    String category = 'hot',
    int page = 1,
    int size = 20,
  }) async {
    // 1. 优先调用红果官方 App 原生 Landpage 接口 (对齐红果鉴 provider_hongguo_catalog.go，100% 官方原生排序与海报)
    final appResult = await _fetchHongguoAppLandpageCatalog(category: category, page: page, size: size);
    if (appResult.isNotEmpty) {
      return appResult;
    }

    // 2. 尝试原生 Go 核心引擎解析 (若就绪)
    if (_isNativeAvailable) {
      try {
        final nativeRes = await invokeNative('catalog', {
          'source': 'hongguo',
          'category': (category == 'hot' || category == 'all') ? 'all' : category,
          'page': page,
          'size': size,
        });
        if (nativeRes != null && nativeRes['ok'] == true) {
          final data = nativeRes['data'];
          final rawItems = (data is Map && data['items'] is List)
              ? (data['items'] as List)
              : (nativeRes['list'] is List ? nativeRes['list'] as List : null);
          if (rawItems != null && rawItems.isNotEmpty) {
            final list = <Map<String, dynamic>>[];
            for (final it in rawItems) {
              if (it is Map) {
                list.add(_formatHongguoItem(Map<String, dynamic>.from(it)));
              }
            }
            if (list.isNotEmpty) {
              return list;
            }
          }
        }
      } catch (_) {}
    }

    // 3. 官方真实 Web 协议 SSR 数据抓取通道兜底
    final result = await _fetchOfficialHongguoCatalog(category: category, page: page, size: size);
    if (result.isNotEmpty) {
      return result;
    }

    return [];
  }

  /// 请求红果 App 官方分类 Landpage 接口 (对齐红果鉴 provider_hongguo_catalog.go)
  Future<List<Map<String, dynamic>>> _fetchHongguoAppLandpageCatalog({
    required String category,
    required int page,
    required int size,
  }) async {
    final catLower = category.trim().toLowerCase();
    final isAll = catLower == 'all' || catLower == 'hot' || catLower.isEmpty || catLower == '全部';

    if (isAll) {
      // 聚合流：对标红果鉴并发调度短剧官方 3 大核心分类 (真人剧、漫剧、AI剧) 并穿插聚合
      try {
        final results = await Future.wait([
          _fetchHongguoSingleGenreLandpage(genreKey: 'short_play', reqScene: 'default', page: page, size: 12),
          _fetchHongguoSingleGenreLandpage(genreKey: 'comic_series', reqScene: 'comic_series', page: page, size: 6),
          _fetchHongguoSingleGenreLandpage(genreKey: 'ai_series', reqScene: 'ai_series', page: page, size: 6),
        ]);

        final realList = results[0];
        final comicList = results[1];
        final aiList = results[2];

        final combined = <Map<String, dynamic>>[];
        final maxLen = [realList.length, comicList.length, aiList.length].reduce((a, b) => a > b ? a : b);

        for (int i = 0; i < maxLen; i++) {
          if (i * 2 < realList.length) combined.add(realList[i * 2]);
          if (i * 2 + 1 < realList.length) combined.add(realList[i * 2 + 1]);
          if (i < comicList.length) combined.add(comicList[i]);
          if (i < aiList.length) combined.add(aiList[i]);
        }

        if (combined.isNotEmpty) {
          final uniqueMap = <String, Map<String, dynamic>>{};
          for (final it in combined) {
            final key = it['drama_id'] ?? it['id']?.toString() ?? '';
            if (key.isNotEmpty && !uniqueMap.containsKey(key)) {
              uniqueMap[key] = it;
            }
          }
          return uniqueMap.values.toList();
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 聚合流拉取异常: $e');
        }
      }
      // 聚合异常时走 short_play 兜底
      return _fetchHongguoSingleGenreLandpage(genreKey: 'short_play', reqScene: 'default', page: page, size: size);
    }

    // 单分类定向拉取：真人剧 / 漫剧 / AI剧
    String genreKey = 'short_play';
    String reqScene = 'default';

    if (catLower.contains('comic') || catLower == 'comic_series' || catLower.contains('漫剧')) {
      genreKey = 'comic_series';
      reqScene = 'comic_series';
    } else if (catLower.contains('ai') || catLower == 'ai_series' || catLower.contains('ai剧')) {
      genreKey = 'ai_series';
      reqScene = 'ai_series';
    }

    return _fetchHongguoSingleGenreLandpage(genreKey: genreKey, reqScene: reqScene, page: page, size: size);
  }

  /// 请求红果 App 单个题材官方接口
  Future<List<Map<String, dynamic>>> _fetchHongguoSingleGenreLandpage({
    required String genreKey,
    required String reqScene,
    required int page,
    required int size,
  }) async {
    try {
      final offset = (page - 1) * size;
      final payload = {
        'req_scene': reqScene,
        'offset': offset,
        'limit': size > 0 ? size : 18,
        'req_type': 'only_content',
        'need_selector_panel': false,
        'client_req_type': offset > 0 ? 2 : 3,
        'session_id': '',
        'filter_ids': '',
        'select_items': {
          'genre': [genreKey],
          'sort': ['online_time'],
          'gender': [],
          'category_dim_theme': [],
          'category_dim_role': [],
          'category_dim_epoch': [],
          'online_time': [],
          'creation_status': [],
        },
      };

      final bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
      const qStr = 'aid=8662&app_name=novelread&version_code=73532&device_platform=android&os=android';
      final uri = Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v/?$qStr');

      final resp = await http.post(
        uri,
        headers: {
          'User-Agent': 'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)',
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
          'X-XS-From-Web': '0',
          'Sdk-Version': '2',
        },
        body: bodyBytes,
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode == 200) {
        final resJson = jsonDecode(resp.body);
        if (resJson is Map && resJson['code'] == 0) {
          final data = resJson['data'];
          if (data is Map) {
            final rawList = data['video_data'];
            if (rawList is List && rawList.isNotEmpty) {
              final list = <Map<String, dynamic>>[];
              for (final it in rawList) {
                if (it is Map) {
                  list.add(_formatHongguoItem(Map<String, dynamic>.from(it)));
                }
              }
              if (list.isNotEmpty) {
                return list;
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] App Landpage 接口拉取异常 (genre=$genreKey): $e');
      }
    }
    return [];
  }

  /// 真实抓取红果官网 SSR 数据并智能解析分类
  /// 真实抓取红果官网 SSR 数据并智能解析分类 (对齐官方 4 大真实分类与分页)
  Future<List<Map<String, dynamic>>> _fetchOfficialHongguoCatalog({
    required String category,
    required int page,
    required int size,
  }) async {
    try {
      final List<Map<String, dynamic>> allItems = [];

      // 1. 处理官方各大热播榜单页面抓取 (/rank/hot-drama, /rank/hot-real-drama 等)
      if (category.startsWith('rank-')) {
        String rankPath = 'hot-drama';
        if (category == 'rank-real') {
          rankPath = 'hot-real-drama';
        } else if (category == 'rank-comic') {
          rankPath = 'hot-comic-drama';
        } else if (category == 'rank-ai') {
          rankPath = 'hot-ai-drama';
        }

        final rankUri = Uri.parse('https://hongguoduanju.com/rank/$rankPath');
        final rankResp = await http.get(rankUri, headers: {
          'User-Agent': _defaultUserAgent,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        }).timeout(const Duration(seconds: 8));

        if (rankResp.statusCode == 200) {
          final rankItems = _parseHongguoRankHtml(rankResp.body);
          allItems.addAll(rankItems);
        }

        if (allItems.isNotEmpty) {
          return allItems;
        }
      }

      // 2. 映射到红果短剧官方真实分类路由 (支持 RESTful 子分类与全库分页)
      String catUrl;
      if (category == 'ai' || category == 'ai-drama') {
        catUrl = 'https://hongguoduanju.com/category/ai-drama?page=$page';
      } else if (category == 'comic') {
        catUrl = 'https://hongguoduanju.com/category/comic?page=$page';
      } else if (category == 'comic-drama') {
        catUrl = 'https://hongguoduanju.com/category/comic-drama?page=$page';
      } else if (category == 'comeback') {
        catUrl = 'https://hongguoduanju.com/category/real-drama/comeback?page=$page';
      } else if (category == 'urban') {
        catUrl = 'https://hongguoduanju.com/category/real-drama/urban?page=$page';
      } else if (category == 'costume') {
        catUrl = 'https://hongguoduanju.com/category/real-drama/costume?page=$page';
      } else if (category == 'romance') {
        catUrl = 'https://hongguoduanju.com/category/real-drama/romance?page=$page';
      } else if (category == 'suspense') {
        catUrl = 'https://hongguoduanju.com/category/real-drama/suspense?page=$page';
      } else {
        catUrl = 'https://hongguoduanju.com/category/real-drama?page=$page';
      }

      // 抓取真实分类分页页 (单页24部, 支持 1~34 页无限翻页)
      final catUri = Uri.parse(catUrl);
      final catResp = await http.get(catUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (catResp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true).firstMatch(catResp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final recList = data['loaderData']?['category_\$']?['recommendList'];
          if (recList is List) {
            for (final it in recList) {
              if (it is Map<String, dynamic>) {
                allItems.add(_formatHongguoItem(it));
              }
            }
          }
        }
      }

      // 3. 全局智能去重
      final Map<String, Map<String, dynamic>> uniqueMap = {};
      for (final item in allItems) {
        final id = item['id']?.toString() ?? '';
        final title = item['title']?.toString() ?? '';
        if (id.isNotEmpty && !uniqueMap.containsKey(id)) {
          uniqueMap[id] = item;
        } else if (title.isNotEmpty && !uniqueMap.values.any((e) => e['title'] == title)) {
          uniqueMap[title] = item;
        }
      }

      return uniqueMap.values.toList();
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] 官方通道抓取异常: $e');
      }
      return [];
    }
  }

  /// 精准解析红果短剧官方热播排行榜 HTML 页面 (100% 对齐红果鉴 DOM 结构与绝对顺序)
  List<Map<String, dynamic>> _parseHongguoRankHtml(String html) {
    final List<Map<String, dynamic>> rankList = [];
    try {
      // 1. 优先精准匹配现代官方排行榜 article 条目容器（与红果鉴 parseHongguoRankingArticle 100%一致）
      final articles = RegExp(
        r'<article[^>]*aria-labelledby=[\x22\x27]rank-title-([0-9]+)[\x22\x27][^>]*>([\s\S]*?)</article>',
      ).allMatches(html);

      for (final m in articles) {
        final sid = m.group(1)!;
        final c = m.group(2) ?? '';

        // 提取标题：优先从查看链接的 aria-label 或 h2/h3 标题中提取
        final mTitle = RegExp(r'aria-label=[\x22\x27]查看([^\x22\x27]+)[\x22\x27]').firstMatch(c) ??
            RegExp(r'<h[23][^>]*id=[\x22\x27]rank-title-' + sid + r'[\x22\x27][^>]*>([^<]+)<').firstMatch(c) ??
            RegExp(r'<h[0-9][^>]*class=[\x22\x27][^\x22\x27]*title[^\x22\x27]*[\x22\x27][^>]*>([^<]+)<').firstMatch(c);
        final title = mTitle != null ? mTitle.group(1)!.trim() : '';
        if (title.isEmpty) continue;

        // 提取高清封面 (优先获取字节跳动高清原画 .image 直链)
        final mImg = RegExp(r'<img[^>]+src=[\x22\x27](https?://[^\x22\x27]+)[\x22\x27]').firstMatch(c) ??
            RegExp(r'https?://[^\s\x22\x27]*(?:byteimg\.com/novel-pic|tplv-shrink)[^\s\x22\x27]*').firstMatch(c);
        var cover = mImg != null ? (mImg.group(1) ?? mImg.group(0)!).replaceAll('&amp;', '&') : '';
        if (cover.endsWith('.webp')) {
          cover = cover.replaceFirst(RegExp(r'\.webp$'), '.image');
        }

        // 提取热度与评分
        final mHeat = RegExp(r'([0-9.]+[万亿]?热度)').firstMatch(c);
        final heat = mHeat != null ? mHeat.group(1)! : '';

        final mScore = RegExp(r'评分([0-9.]+)').firstMatch(c);
        final score = mScore != null ? double.tryParse(mScore.group(1)!) ?? 9.5 : 9.5;

        // 提取简介
        final mDesc = RegExp(r'<p[^>]*class=[\x22\x27][^\x22\x27]*description[^\x22\x27]*[\x22\x27][^>]*>([^<]+)<').firstMatch(c) ??
            RegExp(r'<p>([^<]+)</p>').firstMatch(c);
        final desc = mDesc != null ? mDesc.group(1)!.trim() : '';

        final idInt = int.tryParse(sid) ?? sid.hashCode.abs();
        if (!rankList.any((x) => x['drama_id'] == sid)) {
          rankList.add({
            'id': idInt,
            'drama_id': sid,
            'title': title,
            'cover': cover,
            'cover_url': cover,
            'episode_count': 80,
            'intro': desc.isNotEmpty ? desc : (heat.isNotEmpty ? '全网热播 $heat' : ''),
            'description': desc,
            'score': score,
            'tags': ['热播榜', if (heat.isNotEmpty) heat],
          });
        }
      }

      // 2. 若无 article 则尝试 li 容器匹配兼容
      if (rankList.isEmpty) {
        final items = RegExp(r'<li[^>]*class=[\x22\x27][^\x22\x27]*item[^\x22\x27]*[\x22\x27][^>]*>([\s\S]*?)</li>').allMatches(html);
        for (final m in items) {
          final c = m.group(1) ?? '';
          final mId = RegExp(r'/detail\?series_id=([0-9]+)').firstMatch(c);
          if (mId == null) continue;
          final sid = mId.group(1)!;

          final mTitle = RegExp(r'<h[0-9][^>]*class=[\x22\x27][^\x22\x27]*title[^\x22\x27]*[\x22\x27][^>]*>([^<]+)<').firstMatch(c) ??
              RegExp(r'aria-label=[\x22\x27]查看([^\x22\x27]+)[\x22\x27]').firstMatch(c);
          final title = mTitle != null ? mTitle.group(1)!.trim() : '';
          if (title.isEmpty) continue;

          final mImg = RegExp(r'<img[^>]+src=[\x22\x27](https?://[^\x22\x27]+)[\x22\x27]').firstMatch(c) ??
              RegExp(r'https?://[^\s\x22\x27]*(?:byteimg\.com/novel-pic|tplv-shrink)[^\s\x22\x27]*').firstMatch(c);
          var cover = mImg != null ? (mImg.group(1) ?? mImg.group(0)!).replaceAll('&amp;', '&') : '';
          if (cover.endsWith('.webp')) {
            cover = cover.replaceFirst(RegExp(r'\.webp$'), '.image');
          }

          final mHeat = RegExp(r'([0-9.]+[万亿]?热度)').firstMatch(c);
          final heat = mHeat != null ? mHeat.group(1)! : '';

          final mScore = RegExp(r'评分([0-9.]+)').firstMatch(c);
          final score = mScore != null ? double.tryParse(mScore.group(1)!) ?? 9.5 : 9.5;

          final mDesc = RegExp(r'<p[^>]*class=[\x22\x27][^\x22\x27]*description[^\x22\x27]*[\x22\x27][^>]*>([^<]+)<').firstMatch(c);
          final desc = mDesc != null ? mDesc.group(1)!.trim() : '';

          final idInt = int.tryParse(sid) ?? sid.hashCode.abs();
          if (!rankList.any((x) => x['drama_id'] == sid)) {
            rankList.add({
              'id': idInt,
              'drama_id': sid,
              'title': title,
              'cover': cover,
              'cover_url': cover,
              'episode_count': 80,
              'intro': desc.isNotEmpty ? desc : (heat.isNotEmpty ? '全网热播 $heat' : ''),
              'description': desc,
              'score': score,
              'tags': ['热播榜', if (heat.isNotEmpty) heat],
            });
          }
        }
      }

      // 3. 最终兜底按 /detail 出现顺序提取
      if (rankList.isEmpty) {
        final allSids = RegExp(r'/detail\?series_id=([0-9]+)').allMatches(html);
        final Set<String> seen = {};
        for (final sm in allSids) {
          final sid = sm.group(1)!;
          if (!seen.add(sid)) continue;
          final idx = html.indexOf('/detail?series_id=$sid');
          final sub = html.substring(idx > 100 ? idx - 100 : 0, (idx + 1200 < html.length) ? idx + 1200 : html.length);
          final mTitle = RegExp(r'class=[\x22\x27][^\x22\x27]*title[^\x22\x27]*[\x22\x27][^>]*>([^<]+)<').firstMatch(sub);
          final title = mTitle != null ? mTitle.group(1)!.trim() : '';
          final mImg = RegExp(r'https?://[^\s\x22\x27]*(?:byteimg\.com/novel-pic|tplv-shrink)[^\s\x22\x27]*').firstMatch(sub);
          var cover = mImg != null ? mImg.group(0)!.replaceAll('&amp;', '&') : '';
          if (cover.endsWith('.webp')) cover = cover.replaceFirst(RegExp(r'\.webp$'), '.image');
          final idInt = int.tryParse(sid) ?? sid.hashCode.abs();
          if (title.isNotEmpty && !rankList.any((x) => x['drama_id'] == sid)) {
            rankList.add({
              'id': idInt,
              'drama_id': sid,
              'title': title,
              'cover': cover,
              'cover_url': cover,
              'episode_count': 80,
              'intro': '',
              'description': '',
              'score': 9.5,
              'tags': ['热播榜'],
            });
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] 解析红果热播榜异常: $e');
      }
    }
    return rankList;
  }

  /// 格式化红果单部短剧数据
  Map<String, dynamic> _formatHongguoItem(Map<String, dynamic> it, {String? extraTabType}) {
    final rawId = it['sourceId'] ??
        it['source_id'] ??
        it['series_id'] ??
        it['id'] ??
        it['book_id'] ??
        0;
    final cleanDramaId = cleanSeriesId(rawId);
    final idVal = int.tryParse(cleanDramaId) ?? (rawId is int ? rawId : rawId.hashCode.abs());
    final title = (it['series_name'] ?? it['series_title'] ?? it['title'] ?? it['name'] ?? '').toString();
    var cover = (it['series_cover'] ?? it['cover'] ?? it['cover_url'] ?? it['coverUrl'] ?? '').toString().trim();
    if (cover.startsWith('//')) {
      cover = 'https:$cover';
    }
    if (cover.endsWith('.webp')) {
      cover = cover.replaceFirst(RegExp(r'\.webp$'), '.image');
    }
    
    // 优先从接口读取真实的集数（全量兼容 Go 原生核心与 Web/App 接口）
    int finalEpCount = 0;
    final epRaw = it['episodes'] ??
        it['episode_cnt'] ??
        it['episode_count'] ??
        it['episodeCount'] ??
        it['total_episodes'] ??
        it['total_episode'] ??
        it['totalEpisode'] ??
        it['chapter_count'] ??
        it['chapterCount'] ??
        it['total'];
    if (epRaw is int) {
      finalEpCount = epRaw;
    } else if (epRaw != null) {
      finalEpCount = int.tryParse(epRaw.toString().replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
    }

    final intro = (it['series_intro'] ?? it['intro'] ?? it['description'] ?? it['desc'] ?? '').toString();
    
    final tags = <String>[];
    if (extraTabType != null && extraTabType.isNotEmpty) {
      tags.add(extraTabType);
    }
    if (it['tags'] is List) {
      tags.addAll((it['tags'] as List).map((e) => e.toString()));
    }
    if (it['category_list'] is List) {
      for (final c in it['category_list']) {
        if (c is Map && c['name'] != null) {
          tags.add(c['name'].toString());
        }
      }
    }

    final rawVidList = it['vid_list'];
    List<String>? vidList;
    if (rawVidList is List && rawVidList.isNotEmpty) {
      vidList = rawVidList.map((e) => e.toString()).toList();
      // 关键防污染：列表/搜索页返回的 vid_list 通常仅为 3 集试看，绝不能污染全剧集缓存！
      // 只有当 vidList 达到全量集数时，才认定为完整章节并缓存
      if (finalEpCount > 0 && vidList.length >= finalEpCount) {
        _vidListCache[cleanDramaId] = vidList;
      }
    }

    final firstVid = (it['vid'] ?? it['first_vid'])?.toString() ?? '';
    if (firstVid.isNotEmpty && !_vidListCache.containsKey(cleanDramaId)) {
      // 仅用于单集保底，不污染全剧列表
    }

    final epCountResult = finalEpCount > 0
        ? finalEpCount
        : (vidList != null && vidList.isNotEmpty ? vidList.length : 80);

    return {
      'id': idVal,
      'drama_id': cleanDramaId,
      'series_id': cleanDramaId,
      'title': title,
      'cover': cover,
      'cover_url': cover,
      'episode_count': epCountResult,
      'episode_cnt': epCountResult,
      'episodes': epCountResult,
      'intro': intro,
      'description': intro,
      'tags': tags,
      if (firstVid.isNotEmpty) 'first_vid': firstVid,
      if (vidList != null) 'vid_list': vidList,
    };
  }

  /// 搜索短剧 (直连红果全网检索)
  Future<List<Map<String, dynamic>>> searchDramas(String query,
      {int page = 1}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    if (_isNativeAvailable) {
      try {
        final nativeRes = await invokeNative('catalog', {
          'source': 'hongguo',
          'query': q,
          'page': page,
        });
        if (nativeRes != null && nativeRes['ok'] == true) {
          final data = nativeRes['data'];
          final rawItems = (data is Map && data['items'] is List)
              ? (data['items'] as List)
              : (nativeRes['list'] is List ? nativeRes['list'] as List : null);
          if (rawItems != null && rawItems.isNotEmpty) {
            final list = <Map<String, dynamic>>[];
            for (final it in rawItems) {
              if (it is Map) {
                list.add(_formatHongguoItem(Map<String, dynamic>.from(it)));
              }
            }
            if (list.isNotEmpty) {
              return list;
            }
          }
        }
      } catch (_) {}
    }

    // 官方搜索接口通道
    try {
      final searchUri = Uri.parse('https://hongguoduanju.com/search/${Uri.encodeComponent(q)}');
      final resp = await http.get(searchUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true).firstMatch(resp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final sList = data['loaderData']?['search_(keyword)/page']?['searchList'] ??
              data['loaderData']?['search_page']?['searchList'];
          if (sList is List && sList.isNotEmpty) {
            final List<Map<String, dynamic>> result = [];
            for (final it in sList) {
              if (it is Map<String, dynamic>) {
                final vData = it['video_data'];
                if (vData is Map<String, dynamic>) {
                  final merged = Map<String, dynamic>.from(it)..addAll(vData);
                  result.add(_formatHongguoItem(merged));
                } else if (it['series_name'] != null || it['title'] != null) {
                  result.add(_formatHongguoItem(it));
                }
              }
            }
            if (result.isNotEmpty) return result;
          }
        }
      }
    } catch (_) {}

    return [];
  }

  // -------------------------------------------------------------
  // 官方短剧分集与真实直链高效内存缓存 (保证切集精准、秒开)
  // -------------------------------------------------------------
  final Map<String, List<String>> _vidListCache = {};
  final Map<String, String> _playbackUrlCache = {};
  final Map<String, String> _playbackResolutionCache = {};
  final Map<String, Map<String, String>> _playbackMultiResCache = {};

  /// 构建火山/红果真实三档画质 (1080P超清 / 720P高清 / 480P标清) 独立播放流
  static Map<String, String> buildMultiResolutionUrls(String mainUrl) {
    if (mainUrl.isEmpty) return {};
    final map = <String, String>{};
    // 1080P 超清无损原画流
    map['1080P'] = mainUrl;

    // 针对火山/字节跳动 CDN 进行多参数动态采样匹配
    String url720 = mainUrl;
    String url480 = mainUrl;

    bool hasParam = false;
    if (mainUrl.contains('bt=')) {
      hasParam = true;
      url720 = url720.replaceAll(RegExp(r'bt=\d+'), 'bt=1024');
      url480 = url480.replaceAll(RegExp(r'bt=\d+'), 'bt=512');
    }
    if (mainUrl.contains('qs=')) {
      hasParam = true;
      url720 = url720.replaceAll(RegExp(r'qs=\d+'), 'qs=4');
      url480 = url480.replaceAll(RegExp(r'qs=\d+'), 'qs=8');
    }
    if (mainUrl.contains('ratio=')) {
      hasParam = true;
      url720 = url720.replaceAll(RegExp(r'ratio=[^&]+'), 'ratio=720p');
      url480 = url480.replaceAll(RegExp(r'ratio=[^&]+'), 'ratio=480p');
    }
    if (mainUrl.contains('resolution=')) {
      hasParam = true;
      url720 = url720.replaceAll(RegExp(r'resolution=[^&]+'), 'resolution=720p');
      url480 = url480.replaceAll(RegExp(r'resolution=[^&]+'), 'resolution=480p');
    }

    if (!hasParam) {
      final separator = mainUrl.contains('?') ? '&' : '?';
      url720 = '$mainUrl${separator}ratio=720p&resolution=720p&bt=1024&qs=4';
      url480 = '$mainUrl${separator}ratio=480p&resolution=480p&bt=512&qs=8';
    }

    map['720P'] = url720;
    map['480P'] = url480;
    return map;
  }

  /// 获取某集真实多清晰度 URL 字典 (1080P/720P/480P)
  Map<String, String>? getEpisodeMultiResolutions(String dramaId, int episode) {
    final cleanId = dramaId.trim();
    return _playbackMultiResCache['$cleanId-$episode'];
  }

  /// 获取某集已解析的真实清晰度 (如 720P, 1080P, 原画)
  String? getEpisodeResolution(String dramaId, int episode) {
    return _playbackResolutionCache['$dramaId-$episode'];
  }

  /// 获取某集真实支持的清晰度档位列表 (对齐红果鉴, 如 [1080, 720, 480])
  List<int>? getEpisodeQualities(String dramaId, int episode) {
    final cleanId = dramaId.trim();
    return _planCache['$cleanId-$episode']?.qualities;
  }

  /// 获取某集实际播放的清晰度数值 (如 1080)
  int? getEpisodeActualQuality(String dramaId, int episode) {
    final cleanId = dramaId.trim();
    return _planCache['$cleanId-$episode']?.actualQuality;
  }

  final Map<String, Future<List<String>>> _pendingVidRequests = {};
  final Map<String, Future<DuanjuPlaybackPlan?>> _pendingPlanRequests = {};

  /// 获取短剧全部选集 vid 列表与详情 (原生Go核心优先 + 官方Web双重解析 + 内存高速缓存 + In-Flight合并)
  Future<List<String>> fetchEpisodeVidList(String dramaId) async {
    final cleanId = dramaId.trim();
    if (cleanId.isEmpty) return [];

    if (_vidListCache.containsKey(cleanId) &&
        _vidListCache[cleanId]!.isNotEmpty &&
        _vidListCache[cleanId]!.length > 3) {
      return _vidListCache[cleanId]!;
    }

    if (_pendingVidRequests.containsKey(cleanId)) {
      return await _pendingVidRequests[cleanId]!;
    }

    final future = _doFetchEpisodeVidList(cleanId);
    _pendingVidRequests[cleanId] = future;
    try {
      return await future;
    } finally {
      _pendingVidRequests.remove(cleanId);
    }
  }

  Future<List<String>> _doFetchEpisodeVidList(String cleanId) async {
    // 通道 1: 原生 Go 核心 detail 接口 (对齐鱼佬 guoapp，双通道 App + Web 提取全部分集 chapters)
    if (_isNativeAvailable) {
      try {
        await ensureInitialized();
        final res = await invokeNative('detail', {
          'drama': {
            'id': 'hongguo:$cleanId',
            'source': 'hongguo',
            'title': '短剧',
          },
        });
        if (res != null && res['ok'] == true) {
          final data = res['data'];
          final rawChapters = (data is Map && data['chapters'] is List)
              ? (data['chapters'] as List)
              : ((data is Map && data['episodes'] is List) ? (data['episodes'] as List) : null);
          if (rawChapters != null && rawChapters.isNotEmpty) {
            final list = <String>[];
            for (final ch in rawChapters) {
              if (ch is Map) {
                // 关键兼容：Go 核心 Chapter 结构体为 json:"videoUrl"，同时向下兼容 video_url
                final vUrl = (ch['videoUrl'] ?? ch['video_url'] ?? ch['url'])?.toString() ?? '';
                var vid = vUrl.replaceFirst('hongguo-cenc://', '').trim();
                if (vid.isEmpty) {
                  final idStr = (ch['id'] ?? ch['vid'])?.toString() ?? '';
                  if (idStr.contains(':')) {
                    vid = idStr.split(':').last.trim();
                  } else {
                    vid = idStr.trim();
                  }
                }
                if (vid.isNotEmpty) {
                  list.add(vid);
                }
              }
            }
            if (list.isNotEmpty) {
              _vidListCache[cleanId] = list;
              if (kDebugMode) {
                print('[DuanjuBridge] 原生 Go 核心解析章节成功: 剧集=$cleanId, 共${list.length}集');
              }
              return list;
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 原生 Go 核心获取章节失败: $e');
        }
      }
    }

    // 通道 2: 官方 Web 协议 SSR 数据提取
    try {
      final detailUri =
          Uri.parse('https://hongguoduanju.com/detail?series_id=$cleanId');
      final resp = await http.get(detailUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true)
            .firstMatch(resp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final loaderData = data['loaderData'];
          if (loaderData is Map) {
            dynamic vList =
                loaderData['detail_page']?['seriesDetail']?['vid_list'];
            if (vList == null) {
              for (final k in loaderData.keys) {
                final kStr = k.toString();
                if (kStr.contains('detail')) {
                  final page = loaderData[k];
                  if (page is Map) {
                    vList = page['seriesDetail']?['vid_list'] ??
                        page['vid_list'] ??
                        page['video_list'];
                    if (vList != null) break;
                  }
                }
              }
            }

            if (vList is List && vList.isNotEmpty) {
              final list = vList.map((e) => e.toString()).toList();
              _vidListCache[cleanId] = list;
              return list;
            }
          }
        }

        // 通道 3: 正则全量扫描兜底 (直接匹配 HTML 中的字节跳动视频 ID)
        final allVids = RegExp(r'[\x22\x27](v0[0-9a-zA-Z]{16,40})[\x22\x27]').allMatches(resp.body);
        if (allVids.isNotEmpty) {
          final Set<String> seen = {};
          final list = <String>[];
          for (final vm in allVids) {
            final v = vm.group(1)!;
            if (seen.add(v)) {
              list.add(v);
            }
          }
          if (list.length >= 3) {
            _vidListCache[cleanId] = list;
            return list;
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] fetchEpisodeVidList 异常: $e');
      }
    }
    return [];
  }

  final Map<String, DuanjuPlaybackPlan> _planCache = {};

  /// 获取单集短剧的解密密钥 (供播放器注入底层解密参数)
  String? getDecryptionKey(String dramaId, int episode) {
    final key = '$dramaId-$episode';
    return _planCache[key]?.decryptionKey;
  }

  /// 异步预取单集或相邻集的播放计划，提前注入内存缓存，实现秒开起播
  Future<void> prefetchEpisode(String dramaId, int episode, {int quality = 0}) async {
    final cleanId = dramaId.trim();
    if (cleanId.isEmpty || episode < 1) return;
    final cacheKey = quality == 0 ? '$cleanId-$episode' : '$cleanId-$episode-$quality';
    if (_planCache.containsKey(cacheKey)) return;
    unawaited(getPlaybackPlan(dramaId: cleanId, episode: episode, quality: quality));
  }

  /// 获取单集短剧的完整播放计划（包含直链、CENC解密密钥与多分辨率映射 + In-Flight合并）
  Future<DuanjuPlaybackPlan?> getPlaybackPlan({
    required String dramaId,
    required int episode,
    int quality = 0,
  }) async {
    final cleanId = dramaId.trim();
    final cacheKey = quality == 0 ? '$cleanId-$episode' : '$cleanId-$episode-$quality';

    if (_planCache.containsKey(cacheKey)) {
      return _planCache[cacheKey];
    }

    if (_pendingPlanRequests.containsKey(cacheKey)) {
      return await _pendingPlanRequests[cacheKey]!;
    }

    final future = _doGetPlaybackPlan(cleanId, episode, quality, cacheKey);
    _pendingPlanRequests[cacheKey] = future;
    try {
      return await future;
    } finally {
      _pendingPlanRequests.remove(cacheKey);
    }
  }

  Future<DuanjuPlaybackPlan?> _doGetPlaybackPlan(
    String cleanId,
    int episode,
    int quality,
    String cacheKey,
  ) async {
    // 获取短剧选集 vid 列表
    final vidList = await fetchEpisodeVidList(cleanId);
    String vid = '';
    if (vidList.isNotEmpty) {
      final idx = (episode - 1).clamp(0, vidList.length - 1);
      vid = vidList[idx];
    }

    // 通道 1: 官方 App 原生接口（带 X-Gorgon 签名 + spade_a 解密提取真实 CENC Key）
    if (vid.isNotEmpty) {
      final appPlan = await _fetchHongguoAppPlaybackPlan(cleanId, vid, episode, quality: quality);
      if (appPlan != null && appPlan.url.isNotEmpty) {
        _planCache[cacheKey] = appPlan;
        _playbackUrlCache[cacheKey] = appPlan.url;
        _playbackMultiResCache[cacheKey] = appPlan.multiMap;
        _playbackResolutionCache[cacheKey] = appPlan.resolution;
        if (kDebugMode) {
          print('[DuanjuBridge] 官方App接口解析成功: ep=$episode, decKey=${appPlan.decryptionKey}, url=${appPlan.url}, quality=${appPlan.resolution}, qualities=${appPlan.qualities}');
        }
        return appPlan;
      }
    }

    // 通道 2: 原生 Go 核心引擎解析 (完全对齐鱼佬 guoapp 原生核心调度与解密推流)
    if (_isNativeAvailable && vid.isNotEmpty) {
      try {
        await ensureInitialized();
        final nativeRes = await invokeNative('resolve', {
          'drama': {
            'id': 'hongguo:$cleanId',
            'source': 'hongguo',
            'title': '短剧',
          },
          'chapter': {
            'id': 'hongguo:$cleanId:$vid',
            'source': 'hongguo',
            'title': '第$episode集',
            'videoUrl': 'hongguo-cenc://$vid',
            'video_url': 'hongguo-cenc://$vid',
            'currentEpisode': episode,
            'current_episode': '$episode',
          },
          'index': episode,
          'quality': quality,
          'sequence': DateTime.now().millisecondsSinceEpoch,
        });

        if (nativeRes != null && nativeRes['ok'] == true) {
          final data = nativeRes['data'];
          if (data is Map) {
            final nativeUrl = data['url']?.toString();
            final decKey = data['decryptionKey']?.toString() ?? data['key']?.toString() ?? '';
            final dynamic rawQualities = data['qualities'];
            final qualities = (rawQualities is List)
                ? rawQualities.map((e) => int.tryParse(e.toString()) ?? 0).where((q) => q > 0).toList()
                : [1080, 720, 480];
            final actQ = int.tryParse(data['quality']?.toString() ?? '') ?? (qualities.isNotEmpty ? qualities.first : 1080);
            if (nativeUrl != null && nativeUrl.isNotEmpty) {
              final multiMap = buildMultiResolutionUrls(nativeUrl);
              multiMap['自动'] = nativeUrl;
              final plan = DuanjuPlaybackPlan(
                url: nativeUrl,
                decryptionKey: decKey,
                headers: {
                  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1',
                  'Referer': 'https://novel.snssdk.com/',
                },
                multiMap: multiMap,
                resolution: '${actQ}P',
                quality: quality,
                actualQuality: actQ,
                qualities: qualities,
              );
              _planCache[cacheKey] = plan;
              _playbackResolutionCache[cacheKey] = '${actQ}P';
              _playbackUrlCache[cacheKey] = nativeUrl;
              _playbackMultiResCache[cacheKey] = multiMap;
              if (kDebugMode) {
                print('[DuanjuBridge] 原生 Go 核心解析成功: ep=$episode, decKey=$decKey, url=$nativeUrl');
              }
              return plan;
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 原生 Go 核心解析异常: $e');
        }
      }
    }

    // 通道 3: 官方网页解析通道兜底
    final legacyUrl = await _resolveLegacyWebUrl(cleanId, vid, episode, cacheKey);
    if (legacyUrl != null && legacyUrl.isNotEmpty) {
      final multiMap = buildMultiResolutionUrls(legacyUrl);
      multiMap['自动'] = legacyUrl;
      final plan = DuanjuPlaybackPlan(
        url: legacyUrl,
        headers: {
          'User-Agent': _defaultUserAgent,
          'Referer': 'https://hongguoduanju.com/',
        },
        multiMap: multiMap,
        resolution: '1080P',
        quality: quality,
        actualQuality: 1080,
        qualities: const [1080, 720, 480],
      );
      _planCache[cacheKey] = plan;
      return plan;
    }

    return null;
  }

  /// 官方 App 接口请求与 CENC 解密密钥提取
  Future<DuanjuPlaybackPlan?> _fetchHongguoAppPlaybackPlan(
    String seriesId,
    String videoId,
    int episode, {
    int quality = 0,
  }) async {
    try {
      final now = DateTime.now();
      const devId = '3748291048294829104';
      const iid = '1928374650192837465';
      final q = <String, String>{
        'aid': '8662',
        'app_name': 'novelread',
        'version_code': '73532',
        'version_name': '7.3.5.32',
        'manifest_version_code': '73532',
        'update_version_code': '73532',
        'channel': 'update_64',
        'device_platform': 'android',
        'os': 'android',
        'ssmix': 'a',
        'device_type': '25053RT47C',
        'device_brand': 'Redmi',
        'language': 'zh',
        'os_api': '36',
        'os_version': '16',
        'resolution': '1280*2772',
        'dpi': '520',
        'ac': 'wifi',
        'device_id': devId,
        'iid': iid,
        '_rticket': '${now.millisecondsSinceEpoch}',
      };

      final queryStr = q.entries.map((e) => '${e.key}=${e.value}').join('&');
      final payloadMap = {
        'video_id': videoId,
        'content_type': 1,
        'biz_param': {'need_all_video_definition': true, 'video_platform': 3},
      };
      final bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(payloadMap)));
      final signHeaders = _signHongguo(queryStr, bodyBytes, now);

      final uri = Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?$queryStr');
      final resp = await http.post(
        uri,
        headers: {
          'User-Agent': 'com.dragon.read/7.3.5.32 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250305.002; Cronet/TTNetVersion:07a97ae8 2026-03-05 QuicVersion:f2324900 2026-02-05)',
          'Accept': 'application/json',
          'Content-Type': 'application/json; charset=utf-8',
          'X-XS-From-Web': '0',
          'Sdk-Version': '2',
          ...signHeaders,
        },
        body: bodyBytes,
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final resJson = jsonDecode(resp.body);
        if (resJson is Map && resJson['code'] == 0) {
          final data = resJson['data'];
          if (data is Map) {
            dynamic vm = data['video_model'];
            if (vm is String) {
              vm = jsonDecode(vm);
            }
            if (vm is Map) {
              final vl = vm['video_list'];
              final List<dynamic> options = (vl is List) ? vl : (vl is Map ? vl.values.toList() : []);
              final multiMap = <String, String>{};
              final qualityToUrl = <int, String>{};
              final qualitiesSet = <int>{};
              String cencKey = '';

              for (final opt in options) {
                if (opt is! Map) continue;
                final meta = opt['video_meta'] is Map ? opt['video_meta'] as Map : {};
                final codec = meta['codec_type']?.toString().toLowerCase() ?? '';
                if (codec == 'bytevc2') continue; // 跳过不支持的 H.266

                final defName = meta['definition']?.toString().toLowerCase() ?? '';
                final enc = opt['encrypt_info'] is Map ? opt['encrypt_info'] as Map : {};
                final spade = enc['spade_a']?.toString() ?? '';

                if (spade.isNotEmpty && cencKey.isEmpty) {
                  cencKey = _hongguoContentKey(spade);
                }

                // 从 definition 或 vheight/vwidth 提取真实清晰度数值 (对齐红果鉴)
                int qNum = 0;
                final defMatch = RegExp(r'(\d+)').firstMatch(defName);
                if (defMatch != null) {
                  qNum = int.tryParse(defMatch.group(1)!) ?? 0;
                }
                if (qNum == 0) {
                  final h = int.tryParse(meta['vheight']?.toString() ?? '') ?? 0;
                  final w = int.tryParse(meta['vwidth']?.toString() ?? '') ?? 0;
                  qNum = (w > 0 && (h == 0 || w < h)) ? w : h;
                }
                if (qNum == 0) qNum = 720;

                String rawUrl = opt['main_url']?.toString() ?? opt['backup_url']?.toString() ?? '';
                if (rawUrl.isNotEmpty) {
                  if (!rawUrl.startsWith('http')) {
                    try {
                      rawUrl = utf8.decode(base64.decode(rawUrl));
                    } catch (_) {}
                  }
                  if (rawUrl.startsWith('http')) {
                    qualitiesSet.add(qNum);
                    qualityToUrl[qNum] = rawUrl;
                    multiMap['${qNum}P'] = rawUrl;
                  }
                }
              }

              // 对可用清晰度列表进行降序排列 (例如 [1080, 720, 480])
              final sortedQualities = qualitiesSet.toList()..sort((a, b) => b.compareTo(a));
              if (sortedQualities.isEmpty) {
                sortedQualities.addAll([1080, 720, 480]);
              }

              String primaryUrl = '';
              int actualQuality = sortedQualities.first;

              if (quality > 0 && qualityToUrl.containsKey(quality)) {
                primaryUrl = qualityToUrl[quality]!;
                actualQuality = quality;
              } else {
                primaryUrl = qualityToUrl[actualQuality] ?? (multiMap.isNotEmpty ? multiMap.values.first : '');
              }

              if (primaryUrl.isNotEmpty) {
                // 补齐「自动」键
                multiMap['自动'] = primaryUrl;
                // 如果只解析到 1 档，通过 url 参数构造兜底档位
                if (multiMap.length <= 2) {
                  final fallbackUrls = buildMultiResolutionUrls(primaryUrl);
                  fallbackUrls.forEach((k, v) {
                    multiMap.putIfAbsent(k, () => v);
                  });
                }

                return DuanjuPlaybackPlan(
                  url: primaryUrl,
                  decryptionKey: cencKey,
                  headers: {
                    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1',
                    'Referer': 'https://novel.snssdk.com/',
                  },
                  multiMap: multiMap,
                  resolution: '${actualQuality}P',
                  quality: quality,
                  actualQuality: actualQuality,
                  qualities: sortedQualities,
                );
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] 官方App接口取流异常: $e');
      }
    }
    return null;
  }

  /// 字节跳动红果 App 请求签名计算 (X-Gorgon, X-Khronos, X-SS-STUB)
  static Map<String, String> _signHongguo(String queryString, Uint8List? body, DateTime now) {
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final queryHash = md5.convert(utf8.encode(queryString)).bytes;
    final payload = Uint8List(20);
    payload.setRange(0, 4, queryHash.sublist(0, 4));
    String bodyStub = '';
    if (body != null && body.isNotEmpty) {
      final bodyHash = md5.convert(body).bytes;
      payload.setRange(4, 8, bodyHash.sublist(0, 4));
      bodyStub = bodyHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
    }
    payload[12] = 0;
    payload[13] = 6;
    payload[14] = 11;
    payload[15] = 28;
    final bd = ByteData(4)..setUint32(0, timestamp, Endian.big);
    payload.setRange(16, 20, bd.buffer.asUint8List());

    final key = <int>[
      0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93,
      0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f
    ];
    for (int i = 0; i < 20; i++) {
      payload[i] ^= key[i];
    }
    for (int i = 0; i < 20; i++) {
      final cur = payload[i];
      final rot = ((cur << 4) | (cur >> 4)) & 0xff;
      final mixed = rot ^ payload[(i + 1) % 20];
      int rev = 0;
      int t = mixed;
      for (int b = 0; b < 8; b++) {
        rev = (rev << 1) | (t & 1);
        t >>= 1;
      }
      payload[i] = rev ^ 0xff ^ 20;
    }
    final prefix = <int>[0x84, 0x04, 0x40, 0x1c, 0, 0];
    final fullSig = [...prefix, ...payload];
    final gorgonHex = fullSig.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

    return {
      'X-Khronos': '$timestamp',
      'X-Gorgon': gorgonHex,
      'X-SS-Req-Ticket': '${now.millisecondsSinceEpoch}',
      if (bodyStub.isNotEmpty) 'X-SS-STUB': bodyStub,
    };
  }

  /// 红果 CENC 媒体密钥解密算法 (将 spade_a 解密为 16 字节 AES-128 密钥的 32 字符 Hex)
  static String _hongguoContentKey(String value) {
    try {
      final raw = base64.decode(value.trim());
      if (raw.length < 3) return '';
      final tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
      final contentLength = raw.length - tagLength - 1;
      if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
        return '';
      }
      final seed = raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
      final tagCodes = <int>[];
      for (int i = 0; i < tagLength; i++) {
        tagCodes.add(raw[raw.length - tagLength + i] ^ seed);
      }
      final tag = String.fromCharCodes(tagCodes);
      if (tag == 'app_v2' || tag == 'web_v2') {
        return '';
      }
      final decoded = Uint8List(contentLength);
      int prevEven = 250;
      int prevOdd = 85;
      for (int i = 0; i < contentLength; i++) {
        final cur = raw[1 + i];
        final prev = (i % 2 == 0) ? prevEven : prevOdd;
        if (i % 2 == 0) {
          prevEven = cur;
        } else {
          prevOdd = cur;
        }
        int bitsCount = 0;
        int temp = i;
        while (temp > 0) {
          bitsCount += (temp & 1);
          temp >>= 1;
        }
        decoded[i] = ((prev ^ cur) - 21 - bitsCount) & 0xff;
      }
      final hexKey = String.fromCharCodes(decoded.sublist(1, 33));
      return hexKey.trim();
    } catch (_) {
      return '';
    }
  }

  /// 保持旧接口签名兼容，底层统一调用具备 CENC 解密能力的 getPlaybackPlan
  Future<String?> resolvePlaybackUrl({
    required String dramaId,
    required int episode,
    String? rawUrl,
    int quality = 0,
  }) async {
    // 已经是完整网络音视频流且不是占位符数字，直接返回
    if (rawUrl != null &&
        rawUrl.startsWith('http') &&
        (rawUrl.contains('.m3u8') || rawUrl.contains('.mp4'))) {
      return rawUrl;
    }

    final plan = await getPlaybackPlan(dramaId: dramaId, episode: episode, quality: quality);
    return plan?.url;
  }

  /// 官方网页端单集直链解析通道兜底
  Future<String?> _resolveLegacyWebUrl(String cleanId, String vid, int episode, String cacheKey) async {
    if (vid.isEmpty) return null;
    try {
      final playerUri = Uri.parse('https://hongguoduanju.com/player/$cleanId/$vid');
      final resp = await http.get(playerUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true).firstMatch(resp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final loaderData = data['loaderData'];
          if (loaderData is Map) {
            dynamic pageData;
            for (final k in loaderData.keys) {
              final kStr = k.toString();
              if (kStr.contains('player_') && kStr.endsWith('/page')) {
                pageData = loaderData[k];
                break;
              }
            }
            pageData ??= loaderData['player_(series_id)/(vid)/page'] ?? loaderData['player_page'];
            if (pageData is Map) {
              final returnedVid = pageData['vid']?.toString() ?? '';
              if (returnedVid.isEmpty || returnedVid == vid) {
                final playInfo = pageData['video_player_info'];
                if (playInfo is Map) {
                  final mainUrl = (playInfo['main_url'] ??
                          playInfo['backup_url_1'] ??
                          playInfo['backup_url'])
                      ?.toString();
                  if (mainUrl != null && mainUrl.startsWith('http')) {
                    _playbackResolutionCache[cacheKey] = '1080P';
                    _playbackUrlCache[cacheKey] = mainUrl;
                    return mainUrl;
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 后台静默预加载下一集播放直链
  Future<void> _preloadNextEpisode(String dramaId, int nextEpisode, String vid) async {
    final nextCacheKey = '$dramaId-$nextEpisode';
    if (_playbackUrlCache.containsKey(nextCacheKey)) return;

    try {
      final playerUri =
          Uri.parse('https://hongguoduanju.com/player/$dramaId/$vid');
      final resp = await http.get(playerUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true)
            .firstMatch(resp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final loaderData = data['loaderData'];
          if (loaderData is Map) {
            dynamic pageData;
            for (final k in loaderData.keys) {
              final kStr = k.toString();
              if (kStr.contains('player_') && kStr.endsWith('/page')) {
                pageData = loaderData[k];
                break;
              }
            }
            pageData ??= loaderData['player_(series_id)/(vid)/page'] ??
                loaderData['player_page'];
            if (pageData is Map) {
              final returnedVid = pageData['vid']?.toString() ?? '';
              if (returnedVid.isNotEmpty && returnedVid != vid) {
                return; // 拦截冒充，不预缓存错误的第一集流
              }
              final playInfo = pageData['video_player_info'];
              if (playInfo is Map) {
                final mainUrl = playInfo['main_url']?.toString();
                if (mainUrl != null && mainUrl.startsWith('http')) {
                  final h =
                      int.tryParse(playInfo['height']?.toString() ?? '0') ?? 0;
                  String resLabel = '1080P';
                  if (h >= 1080) {
                    resLabel = '1080P';
                  } else if (h >= 720) {
                    resLabel = '720P';
                  } else if (h >= 480) {
                    resLabel = '480P';
                  }
                  _playbackResolutionCache[nextCacheKey] = resLabel;
                  _playbackUrlCache[nextCacheKey] = mainUrl;
                  _playbackMultiResCache[nextCacheKey] = buildMultiResolutionUrls(mainUrl);
                }
              }
            }
          }
        }
      }
    } catch (_) {}
  }
}
