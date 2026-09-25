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
  Future<List<Map<String, dynamic>>> fetchCatalog({
    String category = 'hot',
    int page = 1,
    int size = 20,
  }) async {
    // 1. 尝试原生核心引擎解析
    if (_isNativeAvailable) {
      final nativeRes = await invokeNative('catalog', {
        'category': category,
        'page': page,
        'size': size,
      });
      if (nativeRes != null && nativeRes['list'] is List) {
        return List<Map<String, dynamic>>.from(nativeRes['list']);
      }
    }

    // 2. HTTP 协议直连降级
    try {
      final uri = Uri.parse(
          'https://api.hongguoduanju.com/api/app/playlet-tab/all?category=$category&page=$page&limit=$size');
      final resp = await http.get(uri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && data['data'] is List) {
          return List<Map<String, dynamic>>.from(data['data']);
        }
      }
    } catch (_) {}

    return [];
  }

  /// 搜索短剧
  Future<List<Map<String, dynamic>>> searchDramas(String query,
      {int page = 1}) async {
    if (_isNativeAvailable) {
      final nativeRes = await invokeNative('search', {
        'query': query,
        'page': page,
      });
      if (nativeRes != null && nativeRes['list'] is List) {
        return List<Map<String, dynamic>>.from(nativeRes['list']);
      }
    }

    try {
      final uri = Uri.parse(
          'https://api.hongguoduanju.com/api/app/playlet/home/tab/search?keyword=${Uri.encodeComponent(query)}&page=$page');
      final resp = await http.get(uri, headers: {
        'User-Agent': _defaultUserAgent,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && data['data'] is List) {
          return List<Map<String, dynamic>>.from(data['data']);
        }
      }
    } catch (_) {}

    return [];
  }

  /// 解析单集高清播放直链
  Future<String?> resolvePlaybackUrl({
    required String dramaId,
    required int episode,
    String? rawUrl,
  }) async {
    // 1. 如果已有有效直链且为 m3u8/mp4，直接返回
    if (rawUrl != null &&
        (rawUrl.contains('.m3u8') || rawUrl.contains('.mp4'))) {
      return rawUrl;
    }

    // 2. 原生引擎解析
    if (_isNativeAvailable) {
      final nativeRes = await invokeNative('resolve', {
        'drama_id': dramaId,
        'episode': episode,
      });
      if (nativeRes != null && nativeRes['url'] != null) {
        return nativeRes['url'].toString();
      }
    }

    // 3. 官方通道解析
    try {
      final uri = Uri.parse(
          'https://api.hongguoduanju.com/api/hongguo/play?drama_id=$dramaId&episode=$episode');
      final resp = await http.get(uri, headers: {
        'User-Agent': _defaultUserAgent,
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map && data['data'] != null) {
          final playUrl = data['data']['play_url'] ?? data['data']['video_url'];
          if (playUrl != null) return playUrl.toString();
        }
      }
    } catch (_) {}

    return null;
  }
}
