// lib/services/hls_quality_selector.dart
// v2.7.83: 「所有源默认最高分辨率播放」—— HLS master playlist → 最高档变体
//
// 背景 / 为什么需要在 Dart 侧做:
//   - 手机端 Android 播放走 Flutter 官方 `video_player`（底层 ExoPlayer），
//     它的 DefaultTrackSelector 是自适应 ABR：起播先选低码率，网络抖一下就
//     往下掉档，观感上就是「明明有 1080P，却一直是糊的」。
//   - `video_player` 没有暴露 trackSelector / setMaxVideoSize 这类接口，
//     Dart 侧改不了选档参数。
//   - 所以唯一稳的做法：**在把地址交给播放器之前，把 master playlist 换写成
//     最高档 variant 的 URL**。播放器拿到的直接就是 1080P/4K 的 media
//     playlist，ABR 无从降档。
//
// 与 TV 端 `HlsBestVariant.kt` / `FastStreamProxy` 的选档规则保持完全一致：
//   先比 RESOLUTION 面积（宽×高），面积相同比 BANDWIDTH，都相同保留先出现的。
//   忽略 `#EXT-X-I-FRAME-STREAM-INF`（只含关键帧，不能播）。
//
// 安全性:
//   - 2.5s 总预算（含所有 hop），超时/失败一律**原样返回原 URL**，行为不变；
//   - 命中缓存直接返回，不增加切集时延；
//   - 直链 mp4/flv/mkv/ts 与本地回环地址直接跳过，一次网络都不发。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/http_shared.dart';

class HlsQualitySelector {
  HlsQualitySelector._();

  /// 整个选档流程的总预算。超过就放弃，用原地址（绝不拖慢起播）。
  static const Duration defaultBudget = Duration(milliseconds: 2500);

  /// master → variant → (variant 可能又是 master) 最多跟两层。
  static const int _maxHops = 2;

  static const int _cacheLimit = 128;

  static final Map<String, String> _cache = <String, String>{};
  static final List<String> _cacheOrder = <String>[];

  /// 明显是单体容器/分片，不用探测。
  static const List<String> _directMediaSuffixes = <String>[
    '.mp4',
    '.flv',
    '.mkv',
    '.mov',
    '.avi',
    '.ts',
    '.m4s',
    '.mp3',
    '.aac',
  ];

  static String? _cacheGet(String key) => _cache[key];

  static void _cachePut(String key, String value) {
    if (_cache.containsKey(key)) {
      _cache[key] = value;
      return;
    }
    _cache[key] = value;
    _cacheOrder.add(key);
    while (_cacheOrder.length > _cacheLimit) {
      final evict = _cacheOrder.removeAt(0);
      _cache.remove(evict);
    }
  }

  static bool _shouldSkip(String url) {
    if (url.isEmpty) return true;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return true;
    if (url.contains('127.0.0.1')) return true;
    final lower = url.toLowerCase();
    final path = lower.split('?').first;
    for (final suffix in _directMediaSuffixes) {
      if (path.endsWith(suffix)) return true;
    }
    // 只对「明确像 HLS」的地址探测，避免给网页播放页 / 未知地址白加一次请求
    // 拖慢起播。判定条件与 TV 端 FastStreamProxy.getProxyUrl 保持一致。
    if (lower.contains('m3u8')) return false;
    if (lower.contains('/hls/')) return false;
    if (lower.contains('live=1')) return false;
    return true;
  }

  /// 返回「最高分辨率」的播放地址；判断不出来或失败时返回 [url] 本身。
  static Future<String> highest(
    String url, {
    Map<String, String>? headers,
    Duration? budget,
  }) async {
    if (_shouldSkip(url)) return url;

    final cached = _cacheGet(url);
    if (cached != null) return cached;

    try {
      final picked = await _resolve(url, headers)
          .timeout(budget ?? defaultBudget);
      if (picked != null && picked.isNotEmpty && picked != url) {
        _cachePut(url, picked);
        DiaryService.add('[HlsQuality] 最高档 $url → $picked');
        return picked;
      }
    } catch (e) {
      // 超时 / 断网 / 非 HLS：保持原行为，不记错误日志噪音
      DiaryService.add('[HlsQuality] 选档放弃($e)，沿用原地址');
    }

    // 负缓存：同一个地址本次会话不再重复探测，避免每集都白等 2.5s。
    _cachePut(url, url);
    return url;
  }

  static Future<String?> _resolve(
    String url,
    Map<String, String>? headers,
  ) async {
    var current = url;
    var followedAny = false;

    for (var hop = 0; hop < _maxHops; hop++) {
      final body = await _fetch(current, headers);
      if (body == null) return followedAny ? current : null;

      final best = bestVariantUrl(body, current);
      if (best == null) {
        // 已经是 media playlist（没有 STREAM-INF）：跟过就返回当前档位
        return followedAny ? current : null;
      }
      if (best == current) return followedAny ? current : null;

      current = best;
      followedAny = true;
    }
    return followedAny ? current : null;
  }

  static Future<String?> _fetch(
    String url,
    Map<String, String>? headers,
  ) async {
    // 大小写不敏感地合并：调用方传的 Quark UA / Referer 必须覆盖默认值，
    // 否则同一请求里会出现两个 User-Agent（个别 CDN 直接 400）。
    final merged = <String, String>{};

    void put(String key, String value) {
      final duplicate = merged.keys
          .where((k) => k.toLowerCase() == key.toLowerCase())
          .toList();
      for (final k in duplicate) {
        merged.remove(k);
      }
      merged[key] = value;
    }

    put('User-Agent', HttpShared.userAgent);
    put('Accept', '*/*');
    if (headers != null) {
      for (final entry in headers.entries) {
        if (entry.value.isEmpty) continue;
        put(entry.key, entry.value);
      }
    }

    final resp = await http.get(Uri.parse(url), headers: merged);
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    if (resp.bodyBytes.isEmpty) return null;
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  /// 从 master playlist 里挑最高档变体，返回绝对 URL；不是 master 返回 null。
  static String? bestVariantUrl(String playlist, String baseUrl) {
    if (!playlist.contains('#EXT-X-STREAM-INF')) return null;

    final lines = const LineSplitter().convert(playlist);
    String? bestUri;
    var bestArea = -1;
    var bestHeight = -1;
    var bestBandwidth = -1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;

      final attrs = line.substring('#EXT-X-STREAM-INF:'.length);
      final resMatch = RegExp(
        r'RESOLUTION=(\d+)x(\d+)',
        caseSensitive: false,
      ).firstMatch(attrs);
      final width = resMatch == null ? 0 : (int.tryParse(resMatch.group(1)!) ?? 0);
      final height = resMatch == null ? 0 : (int.tryParse(resMatch.group(2)!) ?? 0);

      // 注意 `AVERAGE-BANDWIDTH=` 也含 `BANDWIDTH=`，用后顾断言排除掉。
      final bwMatch = RegExp(
        r'(?<![-A-Z])BANDWIDTH=(\d+)',
        caseSensitive: false,
      ).firstMatch(attrs);
      final bandwidth = bwMatch == null ? 0 : (int.tryParse(bwMatch.group(1)!) ?? 0);

      String? uri;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty) continue;
        if (candidate.startsWith('#')) continue;
        uri = candidate;
        break;
      }
      if (uri == null || uri.isEmpty) continue;

      final area = width * height;
      final better = area > bestArea ||
          (area == bestArea &&
              (height > bestHeight ||
                  (height == bestHeight && bandwidth > bestBandwidth)));
      if (!better) continue;

      bestArea = area;
      bestHeight = height;
      bestBandwidth = bandwidth;
      bestUri = uri;
    }

    if (bestUri == null) return null;
    return _absolutize(baseUrl, bestUri);
  }

  static String _absolutize(String baseUrl, String reference) {
    if (reference.startsWith('http://') || reference.startsWith('https://')) {
      return reference;
    }
    try {
      return Uri.parse(baseUrl).resolve(reference).toString();
    } catch (_) {
      return reference;
    }
  }
}
