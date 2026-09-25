import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  /// 检查原生 Go 核心动态库是否就绪
  bool get isNativeAvailable => _isNativeAvailable;

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
      }
    } catch (e) {
      _isNativeAvailable = false;
      if (kDebugMode) {
        print('[DuanjuBridge] 原生库加载失败，已自动降级到 HTTP 协议直连: $e');
      }
    }
  }

  /// 通过原生 FFI 派发请求给 Go 核心引擎
  Future<Map<String, dynamic>?> invokeNative(
      String action, Map<String, dynamic> params) async {
    if (!_isNativeAvailable || _nativeRequest == null || _nativeFree == null) {
      return null;
    }

    return compute(_isolateCall, {
      'action': action,
      'params': params,
    });
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
    // 1. 尝试原生 Go 核心引擎解析 (若就绪)
    if (_isNativeAvailable) {
      try {
        final nativeRes = await invokeNative('catalog', {
          'category': category,
          'page': page,
          'size': size,
        });
        if (nativeRes != null && nativeRes['list'] is List && (nativeRes['list'] as List).isNotEmpty) {
          return List<Map<String, dynamic>>.from(nativeRes['list']);
        }
      } catch (_) {}
    }

    // 2. 官方真实 Web 协议 SSR 数据抓取通道
    final result = await _fetchOfficialHongguoCatalog(category: category, page: page, size: size);
    if (result.isNotEmpty) {
      return result;
    }

    return [];
  }

  /// 真实抓取红果官网 SSR 数据并智能解析分类
  Future<List<Map<String, dynamic>>> _fetchOfficialHongguoCatalog({
    required String category,
    required int page,
    required int size,
  }) async {
    try {
      final List<Map<String, dynamic>> allItems = [];

      // 1. 抓取分类页 (含 24 部高热度短剧与标签)
      final catUri = Uri.parse('https://hongguoduanju.com/category/');
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

      // 2. 补充抓取首页 (含热播、真人、漫剧、AI 4大 Tab)
      final homeUri = Uri.parse('https://hongguoduanju.com');
      final homeResp = await http.get(homeUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));

      if (homeResp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true).firstMatch(homeResp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final sections = data['loaderData']?['page']?['homeSections'];
          if (sections is List) {
            for (final sec in sections) {
              if (sec is Map<String, dynamic>) {
                final vList = sec['video_list'];
                final tabType = sec['tab_type']?.toString() ?? '';
                if (vList is List) {
                  for (final it in vList) {
                    if (it is Map<String, dynamic>) {
                      final formatted = _formatHongguoItem(it, extraTabType: tabType);
                      allItems.add(formatted);
                    }
                  }
                }
              }
            }
          }
        }
      }

      // 去重
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

      final list = uniqueMap.values.toList();

      // 智能根据 category 进行精细化分类筛选
      final filtered = _filterByCategory(list, category);
      return filtered.isNotEmpty ? filtered : list;
    } catch (e) {
      if (kDebugMode) {
        print('[DuanjuBridge] 官方通道抓取异常: $e');
      }
      return [];
    }
  }

  /// 格式化红果单部短剧数据
  Map<String, dynamic> _formatHongguoItem(Map<String, dynamic> it, {String? extraTabType}) {
    final idVal = it['series_id'] ?? it['id'] ?? it['book_id'] ?? 0;
    final title = (it['series_name'] ?? it['series_title'] ?? it['title'] ?? '').toString();
    final cover = (it['series_cover'] ?? it['cover'] ?? '').toString();
    final epCount = it['episode_cnt'] ?? it['total_episodes'] ?? it['episode_count'] ?? 80;
    final intro = (it['series_intro'] ?? it['intro'] ?? it['description'] ?? '').toString();
    
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

    return {
      'id': idVal is int ? idVal : (int.tryParse(idVal.toString()) ?? idVal.hashCode.abs()),
      'drama_id': idVal.toString(),
      'title': title,
      'cover': cover,
      'cover_url': cover,
      'episode_count': epCount is int ? epCount : (int.tryParse(epCount.toString()) ?? 80),
      'intro': intro,
      'description': intro,
      'tags': tags,
    };
  }

  /// 根据 category 标签进行精准匹配
  List<Map<String, dynamic>> _filterByCategory(List<Map<String, dynamic>> list, String category) {
    if (category == 'hot' || category == 'all') {
      return list;
    }

    return list.where((item) {
      final tags = (item['tags'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
      final title = (item['title'] ?? '').toString();
      final desc = (item['description'] ?? '').toString();
      final fullText = '$title $desc ${tags.join(' ')}';

      switch (category) {
        case 'ai':
          return tags.contains('ai') || tags.contains('comic') || fullText.contains('漫剧') || fullText.contains('AI') || fullText.contains('动漫');
        case 'shuangju':
          return fullText.contains('爽') || fullText.contains('逆袭') || fullText.contains('神豪') || fullText.contains('战神') || fullText.contains('反转') || fullText.contains('翻身') || fullText.contains('无敌');
        case 'dushi':
          return fullText.contains('都市') || fullText.contains('职场') || fullText.contains('生活') || fullText.contains('神医') || fullText.contains('日常');
        case 'zongcai':
          return fullText.contains('总裁') || fullText.contains('豪门') || fullText.contains('甜宠') || fullText.contains('言情') || fullText.contains('千金') || fullText.contains('夫人');
        case 'guzhuang':
          return fullText.contains('古装') || fullText.contains('仙侠') || fullText.contains('修仙') || fullText.contains('玄幻') || fullText.contains('穿越') || fullText.contains('王爷') || fullText.contains('皇后');
        case 'suspense':
          return fullText.contains('悬疑') || fullText.contains('脑洞') || fullText.contains('推理') || fullText.contains('重生') || fullText.contains('异能') || fullText.contains('惊悚');
        default:
          return true;
      }
    }).toList();
  }

  /// 搜索短剧
  Future<List<Map<String, dynamic>>> searchDramas(String query,
      {int page = 1}) async {
    if (_isNativeAvailable) {
      try {
        final nativeRes = await invokeNative('search', {
          'query': query,
          'page': page,
        });
        if (nativeRes != null && nativeRes['list'] is List && (nativeRes['list'] as List).isNotEmpty) {
          return List<Map<String, dynamic>>.from(nativeRes['list']);
        }
      } catch (_) {}
    }

    try {
      final all = await fetchCatalog(category: 'hot', page: 1, size: 60);
      final q = query.trim().toLowerCase();
      if (q.isEmpty) return all;
      return all.where((it) {
        final title = (it['title'] ?? '').toString().toLowerCase();
        final intro = (it['intro'] ?? '').toString().toLowerCase();
        return title.contains(q) || intro.contains(q);
      }).toList();
    } catch (_) {}

    return [];
  }

  /// 解析单集高清播放直链
  Future<String?> resolvePlaybackUrl({
    required String dramaId,
    required int episode,
    String? rawUrl,
  }) async {
    if (rawUrl != null &&
        (rawUrl.contains('.m3u8') || rawUrl.contains('.mp4'))) {
      return rawUrl;
    }

    if (_isNativeAvailable) {
      try {
        final nativeRes = await invokeNative('resolve', {
          'drama_id': dramaId,
          'episode': episode,
        });
        if (nativeRes != null && nativeRes['url'] != null && nativeRes['url'].toString().isNotEmpty) {
          return nativeRes['url'].toString();
        }
      } catch (_) {}
    }

    // 官方通道解析
    try {
      final detailUri = Uri.parse('https://hongguoduanju.com/detail?series_id=$dramaId');
      final resp = await http.get(detailUri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final m = RegExp(r'_ROUTER_DATA\s*=\s*(\{.*?\});', dotAll: true).firstMatch(resp.body);
        if (m != null) {
          final data = jsonDecode(m.group(1)!);
          final vList = data['loaderData']?['detail_page']?['seriesDetail']?['vid_list'];
          if (vList is List && vList.isNotEmpty) {
            final idx = (episode - 1).clamp(0, vList.length - 1);
            final vid = vList[idx]?.toString() ?? '';
            if (vid.isNotEmpty) {
              return 'https://novel.snssdk.com/api/novel/player/video_detail/v1/?item_id=$vid';
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }
}
