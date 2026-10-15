import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:luna_tv/danmaku/models/danmaku_comment.dart';
import 'package:luna_tv/danmaku/models/hongguo_danmaku_emojis.dart';

/// 短剧播放计划与CENC解密包模型 (100%对齐红果鉴)
class DuanjuPlaybackPlan {
  final String url;
  final String decryptionKey;
  final Map<String, String> keys;
  final Map<String, String> headers;
  final Map<String, String> multiMap;
  final String resolution;
  final int quality;
  final int actualQuality;
  final List<int> qualities;
  final String session;
  final String danmakuId;

  const DuanjuPlaybackPlan({
    required this.url,
    this.decryptionKey = '',
    this.keys = const {},
    this.headers = const {},
    this.multiMap = const {},
    this.resolution = '1080P',
    this.quality = 0,
    this.actualQuality = 1080,
    this.qualities = const [1080, 720, 480],
    this.session = '',
    this.danmakuId = '',
  });

  /// 获取指定清晰度标签或默认的解密 Key
  String getKeyForResolution(String? resLabel) {
    if (resLabel != null && keys.containsKey(resLabel)) {
      final k = keys[resLabel]!;
      if (k.isNotEmpty) return k;
    }
    return decryptionKey;
  }
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

  /// 统一清洗短剧剧集 ID（去除各类前缀并精准保留纯数字大 ID）
  static String cleanSeriesId(dynamic raw) {
    if (raw == null) return '';
    var s = raw.toString().trim();
    if (s.startsWith('hongguo:')) {
      s = s.substring('hongguo:'.length).trim();
    } else if (s.startsWith('hg-series-v1:')) {
      s = s.substring('hg-series-v1:'.length).trim();
    } else if (s.startsWith('shortdrama:')) {
      s = s.substring('shortdrama:'.length).trim();
    }
    // 若仍包含非纯数字符号（如复合ID），精准提取纯数字ID
    if (!RegExp(r'^\d+$').hasMatch(s)) {
      final match = RegExp(r'(\d{6,32})').firstMatch(s);
      if (match != null) {
        return match.group(1)!;
      }
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
    // 0. 若为榜单请求 (以 rank- 开头)，直通官方榜单页面抓取与解析通道
    if (category.startsWith('rank-')) {
      final rankList = await _fetchOfficialHongguoCatalog(category: category, page: page, size: size);
      if (rankList.isNotEmpty) {
        return rankList;
      }
    }

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

  /// 获取短剧全部选集 vid 列表与详情 (原生官方App通道优先/兜底 + 原生Go核心 + 官方Web双重解析 + 内存高速缓存 + In-Flight合并)
  Future<List<String>> fetchEpisodeVidList(String dramaId) async {
    final cleanId = cleanSeriesId(dramaId);
    if (cleanId.isEmpty) return [];

    // 双键检查高速缓存
    final cached = _vidListCache[cleanId] ?? _vidListCache[dramaId.trim()];
    if (cached != null && cached.isNotEmpty && cached.length > 1) {
      return cached;
    }

    if (_pendingVidRequests.containsKey(cleanId)) {
      return await _pendingVidRequests[cleanId]!;
    }

    final future = _doFetchEpisodeVidList(cleanId);
    _pendingVidRequests[cleanId] = future;
    try {
      final res = await future;
      if (res.isNotEmpty) {
        _vidListCache[cleanId] = res;
        _vidListCache['hongguo:$cleanId'] = res;
      }
      return res;
    } finally {
      _pendingVidRequests.remove(cleanId);
    }
  }

  /// 平衡括号状态机：100% 完整准确提取 HTML 中的 _ROUTER_DATA JSON (对齐 hongguoTV)
  static dynamic _extractRouterDataJson(String source, {String marker = '_ROUTER_DATA'}) {
    final start = source.indexOf(marker);
    if (start < 0) return null;
    final first = source.indexOf('{', start);
    if (first < 0) return null;
    int depth = 0;
    bool quote = false;
    bool escaped = false;
    for (int i = first; i < source.length; i++) {
      final ch = source[i];
      if (quote) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          quote = false;
        }
        continue;
      }
      if (ch == '"') {
        quote = true;
      } else if (ch == '{' || ch == '[') {
        depth++;
      } else if (ch == '}' || ch == ']') {
        depth--;
        if (depth == 0) {
          final jsonStr = source.substring(first, i + 1);
          try {
            return jsonDecode(jsonStr);
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  Future<List<String>> _doFetchEpisodeVidList(String cleanId) async {
    // 通道 0: Android 原生官方 App 接口 (走 /novel/player/video_detail/v1/，100% 官方返回，彻底杜绝 Web 404)
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.example.lunatv/hongguo_resolver');
        final rawList = await channel.invokeMethod<List<dynamic>>('fetchEpisodeVids', {
          'seriesId': cleanId,
        });
        if (rawList != null && rawList.isNotEmpty) {
          final list = rawList.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          if (list.isNotEmpty) {
            if (kDebugMode) {
              print('[DuanjuBridge] 原生 Android 官方 App 接口获取章节成功: 剧集=$cleanId, 共${list.length}集');
            }
            return list;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 原生 Android 获取章节异常: $e');
        }
      }
    }

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

    // 通道 2: 官方 Web 协议 SSR 数据提取 (基于平衡状态机提取 _ROUTER_DATA，对齐 hongguoTV)
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
        final data = _extractRouterDataJson(resp.body);
        if (data is Map) {
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
              final list = vList.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
              if (list.isNotEmpty) {
                return list;
              }
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
            return list;
          }
        }
      } else {
        if (kDebugMode) {
          print('[DuanjuBridge] Web 详情请求返回非 200 (状态码: ${resp.statusCode})，启动双轨兜底');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] fetchEpisodeVidList Web 提取异常: $e');
      }
    }

    // 通道 4: 终极原生兜底 (若前面通道受限且在 Android 环境，再次请求原生 App 接口)
    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.example.lunatv/hongguo_resolver');
        final rawList = await channel.invokeMethod<List<dynamic>>('fetchEpisodeVids', {
          'seriesId': cleanId,
        });
        if (rawList != null && rawList.isNotEmpty) {
          final list = rawList.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
          if (list.isNotEmpty) {
            return list;
          }
        }
      } catch (_) {}
    }

    return [];
  }

  final Map<String, DuanjuPlaybackPlan> _planCache = {};
  final Map<String, List<DanmakuComment>> _danmakuCache = {};
  final Map<String, List<DanmakuComment>> _episodeDanmakuCache = {};
  final Map<String, String> _danmakuSessionMap = {};
  final Map<String, String> _dramaTitleCache = {};
  static int _globalSequence = DateTime.now().microsecondsSinceEpoch;
  static int _nextSequence() => ++_globalSequence;
  final String _readOwner = 'luna-read-${DateTime.now().microsecondsSinceEpoch}';

  /// 注册短剧剧名缓存 (供弹幕智能情境生成和历史检索使用)
  void registerDramaTitle(String seriesId, String title) {
    final cleanId = cleanSeriesId(seriesId);
    if (cleanId.isNotEmpty && title.trim().isNotEmpty) {
      _dramaTitleCache[cleanId] = title.trim();
    }
  }

  /// 获取短剧剧名缓存
  String getDramaTitle(String seriesId) {
    return _dramaTitleCache[cleanSeriesId(seriesId)] ?? '';
  }

  /// 获取单集短剧的解密密钥 (供播放器注入底层解密参数，支持多清晰度Key检索与ID格式容错)
  String? getDecryptionKey(String dramaId, int episode, {String? resolution}) {
    final cleanId = cleanSeriesId(dramaId);
    final plan = _planCache['$cleanId-$episode'] ??
        _planCache['$dramaId-$episode'] ??
        _planCache['hongguo:$cleanId-$episode'];
    if (plan != null) {
      if (resolution != null) {
        final k = plan.getKeyForResolution(resolution);
        if (k.isNotEmpty) return k;
      }
      if (plan.decryptionKey.isNotEmpty) {
        return plan.decryptionKey;
      }
      if (plan.keys.isNotEmpty) {
        return plan.keys.values.firstWhere((k) => k.isNotEmpty, orElse: () => '');
      }
    }
    return null;
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
    } else if (RegExp(r'^\d{10,25}$').hasMatch(cleanId)) {
      vid = cleanId;
    }

    // 通道 1 (最高优先级): Android 原生层红果短剧签名与解密通道 (官方 preload/v1 超清直取，支持 1080P/720P/480P + CENC 解密)
    if (Platform.isAndroid && vid.isNotEmpty) {
      try {
        const channel = MethodChannel('com.example.lunatv/hongguo_resolver');
        final res = await channel.invokeMethod<Map<dynamic, dynamic>>('resolveStream', {
          'vid': vid,
          'maxQuality': quality > 0 ? quality : 1080,
        });
        if (res != null) {
          final streamUrl = res['url']?.toString() ?? '';
          final decKey = res['decryptionKey']?.toString() ?? '';
          final rawKeys = res['keys'];
          final keysMap = <String, String>{};
          if (rawKeys is Map) {
            for (final entry in rawKeys.entries) {
              keysMap[entry.key.toString()] = entry.value.toString();
            }
          }
          final rawQualities = res['qualities'];
          final qualities = (rawQualities is List)
              ? rawQualities.map((e) => int.tryParse(e.toString()) ?? 0).where((q) => q > 0).toList()
              : [1080, 720, 480];
          final actQ = int.tryParse(res['actualQuality']?.toString() ?? '') ?? (qualities.isNotEmpty ? qualities.first : 1080);
          final rawMulti = res['multiMap'];
          final multiMap = <String, String>{};
          if (rawMulti is Map) {
            for (final entry in rawMulti.entries) {
              multiMap[entry.key.toString()] = entry.value.toString();
            }
          }
          if (streamUrl.isNotEmpty && streamUrl.startsWith('http')) {
            final plan = DuanjuPlaybackPlan(
              url: streamUrl,
              decryptionKey: decKey,
              keys: keysMap,
              headers: {
                'User-Agent': 'Mozilla/5.0 (Linux; Android 16; 25053RT47C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36',
                'Referer': 'https://novel.snssdk.com/',
              },
              multiMap: multiMap,
              resolution: '${actQ}P',
              quality: quality,
              actualQuality: actQ,
              qualities: qualities,
            );
            _planCache[cacheKey] = plan;
            _planCache['$cleanId-$episode'] = plan;
            _planCache['hongguo:$cleanId-$episode'] = plan;
            _playbackUrlCache[cacheKey] = streamUrl;
            _playbackUrlCache['$cleanId-$episode'] = streamUrl;
            _playbackMultiResCache[cacheKey] = multiMap;
            _playbackMultiResCache['$cleanId-$episode'] = multiMap;
            _playbackResolutionCache[cacheKey] = '${actQ}P';
            _playbackResolutionCache['$cleanId-$episode'] = '${actQ}P';
            if (kDebugMode) {
              print('[DuanjuBridge] 原生 HongguoStreamResolver 极速取流解密成功: ep=$episode, vid=$vid, actQ=${actQ}P, decKey=$decKey, url=$streamUrl');
            }
            return plan;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 原生 HongguoStreamResolver 解析异常: $e');
        }
      }
    }

    // 通道 2: 官方 App 原生预加载接口（带 X-Gorgon 签名 + preload/v1 提取全分辨率与真实 CENC Key）
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

    // 通道 3: 原生 Go 核心引擎解析 (完全对齐鱼佬 guoapp 原生核心调度与解密推流)
    if (_isNativeAvailable && vid.isNotEmpty) {
      try {
        await ensureInitialized();
        // 步骤 A: 预热 detail，激活 Go 核心 client.details 缓存
        try {
          await invokeNative('detail', {
            'drama': {
              'id': 'hongguo:$cleanId',
              'source': 'hongguo',
              'title': '短剧',
            },
          });
        } catch (_) {}

        // 步骤 B: 独占调用 resolve 建立视频流播放与解密会话
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
          'sequence': _nextSequence(),
        });

        if (nativeRes != null && nativeRes['ok'] == true) {
          final data = nativeRes['data'];
          if (data is Map) {
            final nativeUrl = data['url']?.toString();
            final decKey = data['decryptionKey']?.toString() ?? data['key']?.toString() ?? '';
            final session = data['session']?.toString() ?? '';
            if (session.isNotEmpty) {
              _danmakuSessionMap['$cleanId-$episode'] = session;
            }
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

    // 通道 4: 官方网页解析通道兜底
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

    // 通道 5 (终极降级兜底): 官方公开直链 (仅在上述高清/App/Go核心/Web全部失败时降级兜底，杜绝黑屏死机)
    if (vid.isNotEmpty) {
      final directUrl = 'https://hongguoduanju.com/video/public/$vid/360p.mp4';
      bool isDirectAvailable = (episode <= 3);
      if (!isDirectAvailable) {
        try {
          final headRes = await http.head(
            Uri.parse(directUrl),
            headers: {
              'Referer': 'https://hongguoduanju.com/',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
            },
          ).timeout(const Duration(milliseconds: 1500));
          if (headRes.statusCode == 200) {
            isDirectAvailable = true;
          }
        } catch (_) {}
      }

      if (isDirectAvailable) {
        final multiMap = <String, String>{
          '360P': directUrl,
          '标清': directUrl,
          '自动': directUrl,
        };
        final plan = DuanjuPlaybackPlan(
          url: directUrl,
          decryptionKey: '',
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
            'Referer': 'https://hongguoduanju.com/',
          },
          multiMap: multiMap,
          resolution: '360P',
          quality: quality > 0 ? quality : 360,
          actualQuality: 360,
          qualities: const [360],
        );
        _planCache[cacheKey] = plan;
        _planCache['$cleanId-$episode'] = plan;
        _planCache['hongguo:$cleanId-$episode'] = plan;
        _playbackUrlCache[cacheKey] = directUrl;
        _playbackUrlCache['$cleanId-$episode'] = directUrl;
        _playbackMultiResCache[cacheKey] = multiMap;
        _playbackMultiResCache['$cleanId-$episode'] = multiMap;
        _playbackResolutionCache[cacheKey] = '360P';
        _playbackResolutionCache['$cleanId-$episode'] = '360P';
        if (kDebugMode) {
          print('[DuanjuBridge] 官方公开直链降级兜底成功: ep=$episode, vid=$vid, url=$directUrl');
        }
        return plan;
      }
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
        'biz_param': {
          'detail_page_version': 0,
          'device_level': 3,
          'disable_digg_stat': false,
          'need_all_video_definition': true,
          'need_mp4_align': false,
          'use_os_player': false,
          'use_server_dns': false,
          'video_platform': 1024,
        },
        'mixed_video_id_map': {
          '1004': [videoId],
        },
      };
      final bodyBytes = Uint8List.fromList(utf8.encode(jsonEncode(payloadMap)));
      final signHeaders = _signHongguo(queryStr, bodyBytes, now);

      final uri = Uri.parse('https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/preload/v1/?$queryStr');
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
        if (resJson is Map && (resJson['code'] == 0 || resJson['Code'] == 0)) {
          final data = resJson['data'];
          if (data is Map) {
            final entry = data[videoId] ?? (data.isNotEmpty ? data.values.first : null);
            dynamic vm = (entry is Map) ? entry['video_model'] : (data['video_model'] ?? data);
            if (vm is String) {
              try {
                vm = jsonDecode(vm);
              } catch (_) {}
            }
            if (vm is Map) {
              final vl = vm['video_list'];
              final List<dynamic> options = (vl is List) ? vl : (vl is Map ? vl.values.toList() : []);
              final multiMap = <String, String>{};
              final keysMap = <String, String>{};
              final qualityToUrl = <int, String>{};
              final qualitiesSet = <int>{};
              String primaryCencKey = '';

              for (final opt in options) {
                if (opt is! Map) continue;
                final meta = opt['video_meta'] is Map ? opt['video_meta'] as Map : {};
                final codec = (meta['codec_type'] ?? opt['codec_type'])?.toString().toLowerCase() ?? '';
                if (codec == 'bytevc2' || codec == 'bvc2') continue; // 跳过不支持的 H.266

                final defName = (meta['definition'] ?? meta['quality_desc'] ?? opt['quality_desc'])?.toString().toLowerCase() ?? '';
                final enc = opt['encrypt_info'] is Map ? opt['encrypt_info'] as Map : {};
                final spade = enc['spade_a']?.toString() ?? opt['spade_a']?.toString() ?? '';

                String itemKey = '';
                if (spade.isNotEmpty) {
                  itemKey = _hongguoContentKey(spade);
                  if (primaryCencKey.isEmpty && itemKey.isNotEmpty) {
                    primaryCencKey = itemKey;
                  }
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

                String rawUrl = opt['main_url']?.toString() ?? opt['backup_url_1']?.toString() ?? opt['backup_url']?.toString() ?? '';
                if (rawUrl.isNotEmpty) {
                  if (!rawUrl.startsWith('http')) {
                    try {
                      rawUrl = utf8.decode(base64.decode(rawUrl));
                    } catch (_) {}
                  }
                  if (rawUrl.startsWith('http')) {
                    final qLabel = '${qNum}P';
                    qualitiesSet.add(qNum);
                    qualityToUrl[qNum] = rawUrl;
                    multiMap[qLabel] = rawUrl;
                    if (itemKey.isNotEmpty) {
                      keysMap[qLabel] = itemKey;
                    }
                  }
                }
              }

              // 对可用清晰度列表进行降序排列 (例如 [1080, 720, 540, 480, 360])
              final sortedQualities = qualitiesSet.toList()..sort((a, b) => b.compareTo(a));
              if (sortedQualities.isNotEmpty && multiMap.isNotEmpty) {
                final targetQuality = (quality > 0 && qualityToUrl.containsKey(quality))
                    ? quality
                    : sortedQualities.first;
                final targetLabel = '${targetQuality}P';
                final primaryUrl = qualityToUrl[targetQuality] ?? multiMap.values.first;
                final activeKey = keysMap[targetLabel] ?? primaryCencKey;

                multiMap['自动'] = primaryUrl;

                return DuanjuPlaybackPlan(
                  url: primaryUrl,
                  decryptionKey: activeKey,
                  keys: keysMap,
                  headers: {
                    'User-Agent': 'Mozilla/5.0 (Linux; Android 16; 25053RT47C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Mobile Safari/537.36',
                    'Referer': 'https://novel.snssdk.com/',
                  },
                  multiMap: multiMap,
                  resolution: targetLabel,
                  quality: quality,
                  actualQuality: targetQuality,
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
    final clean = value.trim().replaceAll('-', '+').replaceAll('_', '/');
    if (clean.isEmpty) return '';
    final raw = tryBase64Decode(clean);
    if (raw == null || raw.length < 3) return '';

    // 算法 1: 官方标准派生 (对齐 MediaCrypto.kt 与 hongguo.cjs)
    try {
      int length = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47;
      if (length > raw.length - 1) length = raw.length - 1;
      if (length >= 33) {
        final work = Uint8List.fromList(raw.sublist(1, 1 + length));
        int a = 85;
        int b = 246;
        for (int i = 0; i < work.length; i++) {
          final old = work[i];
          final previous = (i & 1 != 0) ? a : b;
          if (i & 1 != 0) {
            a = old;
          } else {
            b = old;
          }
          int pop = 0;
          int t = i;
          while (t > 0) {
            pop += t & 1;
            t >>= 1;
          }
          work[i] = (-21 - pop + (previous ^ old)) & 0xff;
        }
        final hexStr = String.fromCharCodes(work.sublist(1, 33));
        if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hexStr)) {
          return hexStr.toLowerCase();
        }
      }
    } catch (_) {}

    // 算法 2: 变体派生兼容
    try {
      final tagLen = (raw[0] ^ raw[1] ^ raw[2]) - 48;
      final contentLen = raw.length - tagLen - 1;
      if (tagLen >= 1 && contentLen >= 33 && contentLen < raw.length) {
        final decoded = Uint8List(contentLen);
        int prevEven = 250;
        int prevOdd = 85;
        for (int i = 0; i < contentLen; i++) {
          final cur = raw[1 + i];
          final prev = (i % 2 == 0) ? prevEven : prevOdd;
          if (i % 2 == 0) {
            prevEven = cur;
          } else {
            prevOdd = cur;
          }
          int pop = 0;
          int t = i;
          while (t > 0) {
            pop += t & 1;
            t >>= 1;
          }
          decoded[i] = ((prev ^ cur) - 21 - pop) & 0xff;
        }
        final hexStr = String.fromCharCodes(decoded.sublist(1, 33));
        if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hexStr)) {
          return hexStr.toLowerCase();
        }
      }
    } catch (_) {}

    return '';
  }

  static Uint8List? tryBase64Decode(String s) {
    try {
      var normalized = s;
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      return base64.decode(normalized);
    } catch (_) {
      return null;
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
        final data = _extractRouterDataJson(resp.body);
        if (data is Map) {
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
                // 1. 优先提取公开 SEO 静态直链 (针对开放试看集)
                final seo = pageData['publicVideoSeo'];
                if (seo is Map && seo['available'] == true) {
                  final targetVid = seo['itemId']?.toString() ?? vid;
                  final directUrl = 'https://hongguoduanju.com/video/public/$targetVid/360p.mp4';
                  _playbackResolutionCache[cacheKey] = '360P';
                  _playbackUrlCache[cacheKey] = directUrl;
                  return directUrl;
                }

                // 2. 兼容提取传统 video_player_info 直链
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
        final data = _extractRouterDataJson(resp.body);
        if (data is Map) {
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

              final seo = pageData['publicVideoSeo'];
              if (seo is Map && seo['available'] == true) {
                final targetVid = seo['itemId']?.toString() ?? vid;
                final directUrl = 'https://hongguoduanju.com/video/public/$targetVid/360p.mp4';
                _playbackResolutionCache[nextCacheKey] = '360P';
                _playbackUrlCache[nextCacheKey] = directUrl;
                _playbackMultiResCache[nextCacheKey] = buildMultiResolutionUrls(directUrl);
                return;
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

  /// 常见超热门短剧全季精准直通索引库 (零延迟秒开，避免搜索与匹配歧义)
  static const Map<String, String> _knownDramaDirectMap = {
    '持械入宋:1': '7671966197985856536', // 持械入宋：第一季 (100集)
    '持械入宋:2': '7676706788724460568', // 持械入宋：第二季 (100集)
    '持械入宋:3': '7678620970638134334', // 持械入宋：第三季 (100集)
    '持械入宋:4': '7680845974494776345', // 持械入宋：第四季 (100集)
    '持械入宋:5': '7683455900727659545', // 持械入宋：第五季 (100集)
    '持械入宋:6': '7686430794469887001', // 持械入宋：第六季 (100集)
    '持械入宋:7': '7690112243203050521', // 持械入宋：第七季 (100集)
    '持械入宋:8': '7691615145977449496', // 持械入宋：第八季 (100集)
  };

  /// 根据剧名和季数在红果官方库中精确定位短剧信息 (返回真实的 seriesId 和完整 vidList)
  Future<({String seriesId, List<String> vidList})?> matchHongguoDramaInfo({
    required String title,
    int season = 1,
  }) async {
    final clean = cleanDramaSearchTitle(title);
    if (clean.isEmpty) return null;
    final baseTitle = extractBaseDramaTitle(title);
    final targetSeason = season > 0 ? season : (extractDramaSeason(title) ?? 1);

    // 1. 直通精选热门短剧字典
    final directKey = '$baseTitle:$targetSeason';
    if (_knownDramaDirectMap.containsKey(directKey)) {
      final directId = _knownDramaDirectMap[directKey]!;
      final vids = await fetchEpisodeVidList(directId);
      if (vids.isNotEmpty) {
        return (seriesId: directId, vidList: vids);
      }
    }

    // 2. 搜索红果短剧官方库
    try {
      var results = await searchDramas(clean);
      if (results.isEmpty && baseTitle.isNotEmpty && baseTitle != clean) {
        results = await searchDramas(baseTitle);
      }
      if (results.isEmpty) return null;

      Map<String, dynamic>? bestMatch;
      int bestScore = -1;

      for (final r in results) {
        final rTitle = (r['title'] ?? '').toString().trim();
        final rId = cleanSeriesId(r['drama_id'] ?? r['series_id'] ?? r['id']);
        if (rId.isEmpty) continue;

        final candSeason = extractDramaSeason(rTitle) ?? 1;
        final isSeasonMatch = candSeason == targetSeason;
        final candBase = extractBaseDramaTitle(rTitle);

        int score = 0;
        // 核心剧名完全吻合（如 "持械入宋" == "持械入宋"）
        if (candBase == baseTitle) {
          score += 2000;
        } else if (candBase.contains(baseTitle) || baseTitle.contains(candBase)) {
          score += 1000;
        } else {
          score += 100;
        }

        // 季数精准吻合
        if (isSeasonMatch) {
          score += 800;
          // 若候选剧名明确标出季数（如 "持械入宋：第一季"），相比没有季数标识的，针对季数明确查询有额外优先级
          if (rTitle.contains('第') || rTitle.contains('S') || rTitle.contains('季')) {
            score += 200;
          }
        } else {
          score -= 500; // 季数错配大幅扣分
        }

        if (score > bestScore) {
          bestScore = score;
          bestMatch = r;
        }
      }

      if (bestMatch != null && bestScore > 0) {
        final dramaId = cleanSeriesId(bestMatch['drama_id'] ?? bestMatch['series_id'] ?? bestMatch['id']);
        if (dramaId.isNotEmpty) {
          final vids = await fetchEpisodeVidList(dramaId);
          if (vids.isNotEmpty) {
            return (seriesId: dramaId, vidList: vids);
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 清洗短剧搜索标题，剔除非剧名噪声与集数尾缀
  static String cleanDramaSearchTitle(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'^(?:短剧|全网首播|热播|高清|4K|1080P)[：:\s]+', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[（\(](?:短剧|全集|大结局|合集|更新至.*?)[）\)]', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[【\[](?:短剧|全集|大结局|合集|更新至.*?)[】\]]', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[《》「」]'), '');
    // 剔除单集后缀（如 · 第31集、第31集、第31话、EP31、E31等）
    s = s.replaceAll(RegExp(r'[·•\-\s]+第\s*\d+\s*[集话回].*$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'第\s*\d+\s*[集话回].*$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[·•\-\s]+(?:EP|E)\s*\d+.*$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\b\d+\s*集\b.*$', caseSensitive: false), '');
    return s.trim();
  }

  /// 提取核心剧名（进一步剥离季数，例如 "持械入宋：第一季" -> "持械入宋"）
  static String extractBaseDramaTitle(String raw) {
    var s = cleanDramaSearchTitle(raw);
    s = s.replaceAll(RegExp(r'[:：\s]*第[一二三四五六七八九十\d]+[季部]', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[:：\s]*(?:S|Season)\s*\d+', caseSensitive: false), '');
    return s.trim();
  }

  /// 提取短剧季数 (第N季/第二部/Season N)
  static int? extractDramaSeason(String title) {
    const cnMap = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
      '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
    };
    final m1 = RegExp(r'第([一二三四五六七八九十\d]+)[季部]').firstMatch(title);
    if (m1 != null) {
      final g = m1.group(1)!;
      if (cnMap.containsKey(g)) return cnMap[g];
      return int.tryParse(g);
    }
    final m2 = RegExp(r'(?:S|Season)\s*(\d+)', caseSensitive: false).firstMatch(title);
    if (m2 != null) {
      return int.tryParse(m2.group(1)!);
    }
    return null;
  }

  /// 获取红果短剧指定时间窗的弹幕 (对齐红果鉴 30秒滑动时间窗 danmakuWindowMs = 30000)
  Future<List<DanmakuComment>> fetchHongguoDanmakuWindow({
    required String seriesId,
    required String vid,
    int episode = 1,
    int startMs = 0,
    int durationMs = 180000,
    String title = '',
  }) async {
    final cleanId = cleanSeriesId(seriesId);
    if (cleanId.isEmpty && vid.isEmpty) return const [];

    final actualTitle = title.trim().isNotEmpty
        ? title.trim()
        : getDramaTitle(cleanId);
    if (actualTitle.isNotEmpty) {
      registerDramaTitle(cleanId, actualTitle);
    }

    final actualVid = vid.isNotEmpty ? vid : '';
    final windowStart = (startMs ~/ 30000) * 30000;
    final windowEnd = windowStart + 30000;
    final epCacheKey = '$cleanId-$episode';
    final windowCacheKey = '$cleanId-$episode-$actualVid-$windowStart';

    // 0. 优先命中当前集已拉取的全集弹幕内存缓存
    if (_episodeDanmakuCache.containsKey(epCacheKey) && _episodeDanmakuCache[epCacheKey]!.isNotEmpty) {
      final all = _episodeDanmakuCache[epCacheKey]!;
      if (startMs == 0 && (durationMs <= 0 || durationMs >= 60000)) {
        return all;
      }
      final windowed = all.where((c) => c.timeMs >= windowStart && c.timeMs < windowEnd).toList();
      return windowed.isNotEmpty ? windowed : all;
    }

    if (_danmakuCache.containsKey(windowCacheKey) && _danmakuCache[windowCacheKey] != null && _danmakuCache[windowCacheKey]!.isNotEmpty) {
      return _danmakuCache[windowCacheKey]!;
    }

    String targetVid = actualVid;
    if (targetVid.isEmpty && cleanId.isNotEmpty) {
      final vids = await fetchEpisodeVidList(cleanId);
      if (vids.isNotEmpty) {
        final idx = (episode - 1).clamp(0, vids.length - 1);
        targetVid = vids[idx];
      }
    }

    // 通道 0: 官方 App 原生签名真实弹幕通道 (最高优先级，直接打通真实观众弹幕)
    if (Platform.isAndroid && targetVid.isNotEmpty) {
      try {
        const channel = MethodChannel('com.example.lunatv/hongguo_resolver');
        final totalDur = durationMs > (windowStart + 1000) ? durationMs : (windowStart + 180000);
        final res = await channel.invokeMethod<Map>('fetchDanmaku', {
          'seriesId': cleanId,
          'vid': targetVid,
          'startMs': windowStart,
          'durationMs': totalDur,
        });

        if (res != null && res['items'] is List) {
          final rows = res['items'] as List;
          if (rows.isNotEmpty) {
            final comments = <DanmakuComment>[];
            for (final row in rows) {
              if (row is! Map) continue;
              final text = (row['text'] ?? '').toString().trim();
              final timeMs = int.tryParse(row['timeMs']?.toString() ?? '') ?? 0;
              if (text.isEmpty) continue;
              comments.add(DanmakuComment(
                timeMs: timeMs,
                mode: 1,
                color: 0xFFFFFF,
                content: formatHongguoDanmakuText(text),
              ));
            }

            if (comments.isNotEmpty) {
              comments.sort((a, b) => a.timeMs.compareTo(b.timeMs));
              _danmakuCache[windowCacheKey] = comments;

              // 合并至单集全量缓存，严格按毫秒时间戳排序并去重
              final existing = _episodeDanmakuCache[epCacheKey] ?? [];
              final merged = <DanmakuComment>[...existing];
              final existingKeys = existing.map((c) => '${c.timeMs}-${c.content}').toSet();
              for (final c in comments) {
                final k = '${c.timeMs}-${c.content}';
                if (!existingKeys.contains(k)) {
                  merged.add(c);
                  existingKeys.add(k);
                }
              }
              merged.sort((a, b) => a.timeMs.compareTo(b.timeMs));
              _episodeDanmakuCache[epCacheKey] = merged;

              if (kDebugMode) {
                print('[DuanjuBridge] 成功拉取官方真实观众弹幕: ep=$episode, window=${windowStart}ms, 本窗${comments.length}条, 全集累计${merged.length}条, 首条="${comments.first.content}"');
              }

              // 若起播（startMs == 0），异步连续预拉取后续窗口，预热全集弹幕
              if (startMs == 0 && totalDur > 30000) {
                _preloadRemainingWindows(cleanId, targetVid, episode, totalDur);
              }

              return comments;
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('[DuanjuBridge] 官方 App 弹幕签名通道异常: $e');
        }
      }
    }

    // 通道 1: 原生 Go 引擎调度 (直接复用视频播放已建立的合法 session)
    if (_isNativeAvailable && targetVid.isNotEmpty) {
      try {
        await ensureInitialized();
        final session = _danmakuSessionMap[epCacheKey];
        if (session != null && session.isNotEmpty) {
          final totalDur = durationMs > (windowStart + 1000) ? durationMs : (windowStart + 180000);
          final res = await invokeNative('danmaku', {
            'session': '$_readOwner:danmaku',
            'sequence': _nextSequence(),
            'playbackSession': session,
            'startMs': 0, // 一次性拉取整集真实弹幕
            'durationMs': totalDur,
          });

          if (res != null && res['ok'] == true && res['data'] is Map) {
            final data = res['data'] as Map;
            final rows = data['items'];
            if (rows is List && rows.isNotEmpty) {
              final comments = <DanmakuComment>[];
              for (final row in rows) {
                if (row is! Map) continue;
                final text = (row['text'] ?? '').toString().trim();
                final timeMs = int.tryParse(row['timeMs']?.toString() ?? '') ?? 0;
                if (text.isEmpty) continue;
                comments.add(DanmakuComment(
                  timeMs: timeMs,
                  mode: 1,
                  color: 0xFFFFFF,
                  content: formatHongguoDanmakuText(text),
                ));
              }

              if (comments.isNotEmpty) {
                comments.sort((a, b) => a.timeMs.compareTo(b.timeMs));
                _episodeDanmakuCache[epCacheKey] = comments;
                _danmakuCache[windowCacheKey] = comments;

                if (kDebugMode) {
                  print('[DuanjuBridge] 成功拉取红果官方真实弹幕: ep=$episode, 共${comments.length}条, 首条="${comments.first.content}"');
                }

                // 起播或全集请求直接返回整集真实弹幕
                if (startMs == 0 && (durationMs <= 0 || durationMs >= 60000)) {
                  return comments;
                }
                final windowed = comments.where((c) => c.timeMs >= windowStart && c.timeMs < windowEnd).toList();
                return windowed.isNotEmpty ? windowed : comments;
              }
            }
          } else {
            // 若 session 失效，清空以允许下次重试
            _danmakuSessionMap.remove(epCacheKey);
            if (kDebugMode) {
              print('[DuanjuBridge] danmaku 请求失败: $res');
            }
          }
        }
      } catch (e) {
        _danmakuSessionMap.remove(epCacheKey);
        if (kDebugMode) {
          print('[DuanjuBridge] 原生短剧弹幕调度异常: $e');
        }
      }
    }

    // 通道 2: 官方网页端弹幕数据提取通道兜底
    if (targetVid.isNotEmpty) {
      try {
        final webComments = await _fetchHongguoDanmakuWebFallback(cleanId, targetVid, durationMs);
        if (webComments.isNotEmpty) {
          _episodeDanmakuCache[epCacheKey] = webComments;
          final windowed = webComments.where((c) => c.timeMs >= windowStart && c.timeMs < windowEnd).toList();
          return windowed.isNotEmpty ? windowed : webComments;
        }
      } catch (_) {}
    }

    // 严禁塞入胡编乱造的模板假弹幕，保持真实纯净空态
    return const [];
  }

  /// 异步预拉取当前集剩余时间窗口的官方弹幕
  void _preloadRemainingWindows(String seriesId, String vid, int episode, int durationMs) {
    Future.microtask(() async {
      try {
        const channel = MethodChannel('com.example.lunatv/hongguo_resolver');
        final epCacheKey = '$seriesId-$episode';
        for (int offset = 30000; offset < durationMs && offset <= 600000; offset += 30000) {
          final wCacheKey = '$seriesId-$episode-$vid-$offset';
          if (_danmakuCache.containsKey(wCacheKey) && _danmakuCache[wCacheKey]!.isNotEmpty) {
            continue;
          }
          final res = await channel.invokeMethod<Map>('fetchDanmaku', {
            'seriesId': seriesId,
            'vid': vid,
            'startMs': offset,
            'durationMs': durationMs,
          });
          if (res != null && res['items'] is List) {
            final rows = res['items'] as List;
            if (rows.isNotEmpty) {
              final comments = <DanmakuComment>[];
              for (final row in rows) {
                if (row is! Map) continue;
                final text = (row['text'] ?? '').toString().trim();
                final timeMs = int.tryParse(row['timeMs']?.toString() ?? '') ?? 0;
                if (text.isEmpty) continue;
                comments.add(DanmakuComment(
                  timeMs: timeMs,
                  mode: 1,
                  color: 0xFFFFFF,
                  content: formatHongguoDanmakuText(text),
                ));
              }
              if (comments.isNotEmpty) {
                comments.sort((a, b) => a.timeMs.compareTo(b.timeMs));
                _danmakuCache[wCacheKey] = comments;
                final existing = _episodeDanmakuCache[epCacheKey] ?? [];
                final merged = <DanmakuComment>[...existing];
                final existingKeys = existing.map((c) => '${c.timeMs}-${c.content}').toSet();
                for (final c in comments) {
                  final k = '${c.timeMs}-${c.content}';
                  if (!existingKeys.contains(k)) {
                    merged.add(c);
                    existingKeys.add(k);
                  }
                }
                merged.sort((a, b) => a.timeMs.compareTo(b.timeMs));
                _episodeDanmakuCache[epCacheKey] = merged;
              }
            }
          }
          // 适度防抖
          await Future.delayed(const Duration(milliseconds: 150));
        }
      } catch (_) {}
    });
  }

  /// 获取红果短剧单集全量弹幕 (对齐红果鉴)
  Future<List<DanmakuComment>> fetchHongguoDanmaku({
    required String seriesId,
    required String vid,
    int episode = 1,
    int durationMs = 180000,
    String title = '',
  }) async {
    final epCacheKey = '${cleanSeriesId(seriesId)}-$episode';
    if (_episodeDanmakuCache.containsKey(epCacheKey) && _episodeDanmakuCache[epCacheKey]!.isNotEmpty) {
      return _episodeDanmakuCache[epCacheKey]!;
    }
    return await fetchHongguoDanmakuWindow(
      seriesId: seriesId,
      vid: vid,
      episode: episode,
      startMs: 0,
      durationMs: durationMs,
      title: title,
    );
  }

  /// 官方网页端弹幕数据提取通道兜底
  Future<List<DanmakuComment>> _fetchHongguoDanmakuWebFallback(
    String cleanId,
    String vid,
    int durationMs,
  ) async {
    try {
      final uri = Uri.parse('https://hongguoduanju.com/player/$cleanId/$vid');
      final resp = await http.get(uri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      }).timeout(const Duration(seconds: 6));

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
              final commentsRaw = pageData['danmaku_list'] ?? pageData['comment_list'];
              if (commentsRaw is List && commentsRaw.isNotEmpty) {
                final comments = <DanmakuComment>[];
                for (final c in commentsRaw) {
                  if (c is! Map) continue;
                  final text = (c['text'] ?? c['content'] ?? '').toString().trim();
                  final timeMs = int.tryParse(c['time']?.toString() ?? c['offset_time']?.toString() ?? '') ?? 0;
                  if (text.isEmpty) continue;
                  comments.add(DanmakuComment(
                    timeMs: timeMs,
                    mode: 1,
                    color: 0xFFFFFF,
                    content: formatHongguoDanmakuText(text),
                  ));
                }
                if (comments.isNotEmpty) return comments;
              }
            }
          }
        }
      }
    } catch (_) {}
    return const [];
  }

  /// 短剧按 30 秒窗口生成的智能情境弹幕 (严格限定在当前窗口区间内，绝不提前剧透或集中刷屏)
  List<DanmakuComment> _generateShortDramaSmartDanmakuWindow({
    required String cleanId,
    required String vid,
    required String title,
    required int episode,
    required int windowStart,
    required int windowEnd,
    required int durationMs,
  }) {
    final all = _generateShortDramaSmartDanmaku(
      cleanId: cleanId,
      vid: vid,
      title: title,
      episode: episode,
      durationMs: durationMs,
    );
    final inWindow = all.where((c) => c.timeMs >= windowStart && c.timeMs < windowEnd).toList();
    if (inWindow.isNotEmpty) {
      if (inWindow.length > 3) {
        return inWindow.sublist(0, 3);
      }
      return inWindow;
    }
    final seed = (cleanId.hashCode ^ (episode * 7919) ^ windowStart).abs();
    final rng = _StableDanmakuRandom(seed);
    final fallbackTexts = [
      '这反转绝了！[赞]',
      '节奏真快，过瘾[赞]',
      '注意看主角眼神[机智]',
      '这剧情越看越上头[偷笑]',
      '反派要遭殃了[看]',
      '哈哈哈哈太搞笑了[笑哭]',
      '这一招请君入瓮真妙[灵机一动]',
    ];
    final text = fallbackTexts[rng.nextInt(fallbackTexts.length)];
    final timeMs = windowStart + 8000 + rng.nextInt(12000);
    return [
      DanmakuComment(
        timeMs: timeMs.clamp(windowStart + 1000, windowEnd - 1000),
        mode: 1,
        color: 0xFFFFFF,
        content: formatHongguoDanmakuText(text),
      ),
    ];
  }

  /// 短剧专属高可用智能情境弹幕生成引擎 (对齐红果鉴体验，彻底告别 0 条冷场)
  List<DanmakuComment> _generateShortDramaSmartDanmaku({
    required String cleanId,
    required String vid,
    required String title,
    required int episode,
    required int durationMs,
  }) {
    final displayTitle = title.trim().isNotEmpty ? title.trim() : '这部短剧';
    final dur = durationMs > 30000 ? durationMs : 150000;

    // 1. 题材特征识别
    final isHistoryCross = displayTitle.contains(RegExp(
        r'入宋|大宋|大明|大唐|秦|汉|穿越|皇帝|太子|锦衣卫|王爷|开局|武器|军工|神枪|科技|火枪|持械|带把|重工'));
    final isWarGodDragon = displayTitle.contains(RegExp(
        r'战神|龙王|至尊|狂龙|修仙|神医|赘婿|神豪|天尊|宗师|无敌|归来|退婚|天师'));
    final isSweetLove = displayTitle.contains(RegExp(
        r'夫人|总裁|千金|豪门|替嫁|闪婚|甜宠|萌宝|真假|爱|撩|嫁给|心动|少夫人'));
    final isRebornRevenge = displayTitle.contains(RegExp(
        r'重生|复仇|反杀|末日|末世|安全屋|囤积|异能|深渊|判官|绝地|复苏'));

    // 2. 特色弹幕库
    final specializedList = <String>[];
    if (isHistoryCross) {
      specializedList.addAll([
        '带着现代重火力回古代，简直降维打击[赞]',
        '大人，时代变了！[大笑]',
        '在古代掏出这玩意，对面全看傻了[笑哭]',
        '哈哈哈哈古人直呼神仙下凡[偷笑]',
        '现代科技狠活在大宋横推一切[灵机一动]',
        '物理超度最为致命，太解压了[看]',
        '皇帝当场给整不会了[捂脸]',
        '一人单挑千军万马，帅爆！[酷]',
        '这才是穿越剧的正确打开方式[赞]',
        '王爷吓得当场跪地求饶[打脸]',
        '哈哈哈哈现代工业结晶不讲武德[笑翻]',
        '在冷兵器时代掏出热武器，真爽剧！[机智]',
        '降维打击，全场起立[赞]',
      ]);
    } else if (isWarGodDragon) {
      specializedList.addAll([
        '三年之期已到，恭迎龙王回归！[赞]',
        '一声令下，十万将士奔赴而来[酷]',
        '有眼不识泰山，反派等死吧[打脸]',
        '战神之威，岂容尔等蝼蚁挑衅[机智]',
        '真正的巨佬往往伪装成新手[看]',
        '跪下叫爸爸！[偷笑]',
        '哈哈哈哈打脸来得太快就像龙卷风[笑哭]',
        '岳母一家马上就要肠子悔青了[偷笑]',
        '别忍了，直接动手灭了他们！[抓狂]',
        '全场肃静！龙王要发飙了[酷]',
        '主角眼神里杀气藏不住了[看]',
      ]);
    } else if (isSweetLove) {
      specializedList.addAll([
        '霸道总裁护妻狂魔正式上线[爱慕]',
        '男女主颜值好高啊，锁死！[比心]',
        '这眼神拉丝了，甜死我算了[喜欢]',
        '民政局我搬来了，请你们原地结婚[飞吻]',
        '敢动我的人，你配吗？[酷]',
        '反派绿茶又在作妖，坐等女主反杀[看]',
        '哈哈哈吃醋的样子太可爱了[可爱]',
        '全员助攻，男主终于开窍了[笑哭]',
        '太宠了吧，柠檬树下你和我[吃瓜]',
      ]);
    } else if (isRebornRevenge) {
      specializedList.addAll([
        '重活一世，失去的我都要拿回来！[酷]',
        '开局直接囤积百亿物资，安全感拉满[赞]',
        '这一世绝不再当冤大头！[打脸]',
        '全知全能，剧透流爽到飞起[机智]',
        '仇人名单已拉满，一个都别想跑[坏笑]',
        '前世害我的人，百倍奉还！[发怒]',
        '步步为营，这心机智商在线[灵机一动]',
      ]);
    }

    // 3. 通用短剧爽文节奏弹幕库 (分为片头、推进、高潮反转、结尾)
    final introList = [
      '第$episode集打卡！[爱心]',
      '第一排前排打卡！[看]',
      '热榜第一慕名而来[赞]',
      '熬夜追剧停不下来[灵机一动]',
      '冲着 $displayTitle 来的！[比心]',
      '开局高能，非战斗人员迅速撤离[酷]',
      '全员就位，好戏开场了[偷笑]',
      '一口气看到第$episode集，太上头了[赞]',
      '终于等到更新了！[互粉]',
    ];

    final buildUpList = [
      '这节奏飞快，毫不拖泥带水[赞]',
      '反派这嘴脸，看着就想揍[打脸]',
      '主角眼神里全是戏[看]',
      '哈哈哈哈这台词太搞笑了[笑哭]',
      '注意看右边群演的小表情[偷笑]',
      '伏笔回收了！原来在这里[灵机一动]',
      '前方高能预警，弹幕护体！[看]',
      '这个反派演员演技真到位[赞]',
      '主角：给你机会你不中用啊[坏笑]',
      '好家伙，一言不合就开大[吃瓜]',
      '这局势看得我屏住呼吸了[机智]',
      '别急，主角肯定留了后手[看]',
      '哈哈哈哈真把主角当软柿子了[偷笑]',
    ];

    final climaxList = [
      '卧槽卧槽反转了！！！[惊恐]',
      '哈哈哈哈哈当场打脸太爽了[打脸]',
      '全场起立！全体目光向我看齐[酷]',
      '主角终于亮底牌了！[机智]',
      '这波操作在大气层，服了[赞]',
      '反派直接看傻眼了[呆住]',
      '爽！就喜欢这种暴脾气主角[赞]',
      '笑得我手机差点砸脸[笑翻]',
      '帅呆了！这才是短剧该有的爽感[赞]',
      '战力天花板名不虚传！[酷]',
      '反派：小丑竟是我自己[捂脸]',
      '大快人心！看得我一身鸡皮疙瘩[赞]',
      '哈哈哈哈反转来得猝不及防[笑哭]',
      '绝杀！彻底没有悬念了[打脸]',
      '这一招叫请君入瓮[灵机一动]',
    ];

    final outroList = [
      '卡在这里是人干的事吗？！[抓狂]',
      '一集太短了根本不够看[泪奔]',
      '进度条你怎么这么不争气啊！[泪奔]',
      '下一集快端上来，求求了[可怜]',
      '急急急，谁有下一集剧透[偷笑]',
      '停在最精彩的地方，急死我了[发怒]',
      '火速切换第${episode + 1}集！[互粉]',
      '今晚不睡了，通宵也要刷完[赞]',
      '第${episode + 1}集见，兄弟们冲！[比心]',
      '高能预警，下一集要放大招了[看]',
    ];

    // 4. 采用稳定伪随机种子进行打乱与选取
    final seed = (cleanId.hashCode ^ (episode * 7919) ^ displayTitle.hashCode).abs();
    final rng = _StableDanmakuRandom(seed);

    final selected = <_DanmakuDraft>[];

    // 阶段 1: 片头 (0 ~ 15% 时长，精简打卡避免开播扎堆)
    final introCount = 1 + (seed % 2);
    for (int i = 0; i < introCount; i++) {
      final t = introList[rng.nextInt(introList.length)];
      final timeMs = (3500 + i * 5000 + rng.nextInt(2500)).clamp(2500, (dur * 0.15).toInt());
      selected.add(_DanmakuDraft(text: t, timeMs: timeMs));
    }

    // 阶段 2: 剧情铺垫与特色弹幕 (15% ~ 48% 时长)
    final pool2 = [...buildUpList, ...specializedList];
    final buildCount = 3 + (seed % 3);
    final p2Start = (dur * 0.15).toInt();
    final p2End = (dur * 0.48).toInt();
    for (int i = 0; i < buildCount; i++) {
      final t = pool2[rng.nextInt(pool2.length)];
      final timeMs = p2Start + ((p2End - p2Start) * ((i + 1) / (buildCount + 1))).toInt() + rng.nextInt(1500);
      selected.add(_DanmakuDraft(text: t, timeMs: timeMs.clamp(p2Start, p2End)));
    }

    // 阶段 3: 高潮打脸反转 (48% ~ 82% 时长)
    final pool3 = [...climaxList, ...specializedList];
    final climaxCount = 4 + (seed % 3);
    final p3Start = (dur * 0.48).toInt();
    final p3End = (dur * 0.82).toInt();
    for (int i = 0; i < climaxCount; i++) {
      final t = pool3[rng.nextInt(pool3.length)];
      final timeMs = p3Start + ((p3End - p3Start) * ((i + 1) / (climaxCount + 1))).toInt() + rng.nextInt(1500);
      int color = 0xFFFFFF;
      final cPick = rng.nextInt(10);
      if (cPick == 0) color = 0xFFE082;
      else if (cPick == 1) color = 0x81C784;
      else if (cPick == 2) color = 0x64B5F6;
      else if (cPick == 3) color = 0xFF8A80;
      selected.add(_DanmakuDraft(text: t, timeMs: timeMs.clamp(p3Start, p3End), color: color));
    }

    // 阶段 4: 悬念与催更 (82% ~ 98% 时长)
    final outroCount = 2 + (seed % 2);
    final p4Start = (dur * 0.82).toInt();
    final p4End = (dur * 0.98).toInt();
    for (int i = 0; i < outroCount; i++) {
      final t = outroList[rng.nextInt(outroList.length)];
      final timeMs = p4Start + ((p4End - p4Start) * ((i + 1) / (outroCount + 1))).toInt() + rng.nextInt(1500);
      selected.add(_DanmakuDraft(text: t, timeMs: timeMs.clamp(p4Start, p4End)));
    }

    // 5. 按时间升序排序并格式化
    selected.sort((a, b) => a.timeMs.compareTo(b.timeMs));

    final result = <DanmakuComment>[];
    for (final draft in selected) {
      result.add(DanmakuComment(
        timeMs: draft.timeMs,
        mode: 1,
        color: draft.color,
        content: formatHongguoDanmakuText(draft.text),
      ));
    }

    if (kDebugMode) {
      print('[DuanjuBridge] 激活短剧专属智能情境弹幕引擎: title=$displayTitle, ep=$episode, count=${result.length}');
    }
    return result;
  }
}

class _DanmakuDraft {
  final String text;
  final int timeMs;
  final int color;
  _DanmakuDraft({required this.text, required this.timeMs, this.color = 0xFFFFFF});
}

class _StableDanmakuRandom {
  int _state;
  _StableDanmakuRandom(int seed) : _state = seed == 0 ? 123456789 : seed;

  int nextInt(int max) {
    if (max <= 0) return 0;
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % max;
  }
}

