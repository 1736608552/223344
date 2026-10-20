import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'package:luna_tv/services/http_shared.dart';
import 'package:luna_tv/services/local_search_cache_service.dart';

/// 分页搜索结果
class SearchPageResult {
  final List<SearchResult> results;
  final int pageCount;

  SearchPageResult({
    required this.results,
    required this.pageCount,
  });
}

/// 下游搜索服务
///
/// v2.4.5: 改用 HttpShared 公共 helper (UA Chrome 147 / 15s timeout / buildUrl /
///   decodeBody / parseVodPlayUrl). 之前是 Chrome 122 + 8s + 直接拼 URL +
///   .endsWith('.m3u8') 过滤, 跟 SourceBrowserService 配置分叉, 导致同一个源
///   「源浏览器能开但全局搜索搜不到」「点开视频没集数」.
class DownstreamService {
  /// 咕噜咕噜官方专线映射表 (对齐 Web 端 downstream.ts 与官方 GuluGuluTV 架构)
  /// 将代理解析接口（如 1ljx.com/?url=、jx.playerjy.com/?url=、jx.xmflv.com/?url= 等）
  /// 自动映射为对应高可用直连秒播切片 CMS 接口
  static String resolveEffectiveApi(SearchResource resource) {
    final rawApi = resource.api.trim();
    final key = resource.key.toLowerCase();
    final name = resource.name.toLowerCase();
    final apiLower = rawApi.toLowerCase();

    // 01_glgl_live: 咕噜直连切片代理 / glgl.tv (Live M3U8) -> 光速专线 (高并发节点)
    if (apiLower.contains('glgl.tv') ||
        key.contains('glgl') ||
        name.contains('咕噜专线代理解析') ||
        name.contains('咕噜直连切片')) {
      return 'https://api.guangsuapi.com/api.php/provide/vod/';
    }
    // 02_1ljx_main & 03_1ljx_api: 咕噜1号官方专线 / 1ljx.com 主力解析及 API 直连 -> 量子专线 (秒播切片 / 新咕噜4K)
    if (apiLower.contains('1ljx.com') ||
        key.contains('1ljx') ||
        name.contains('1号线路') ||
        name.contains('咕噜1号')) {
      return 'https://cj.lziapi.com/api.php/provide/vod/';
    }
    // 04_xmflv_jx: 虾米极速秒播解析 / xmflv.com -> 红牛资源 (超清综合 / 鲸宝4K)
    if (apiLower.contains('xmflv.com') ||
        key.contains('xmflv') ||
        name.contains('虾米') ||
        name.contains('极速秒播解析')) {
      return 'https://www.hongniuzy2.com/api.php/provide/vod/';
    }
    // 05_playerjy_jx: 金鹰蓝光大片解析 / playerjy.com -> 金鹰影视 (蓝光大片 / VIP4K)
    if (apiLower.contains('playerjy.com') ||
        key.contains('playerjy') ||
        name.contains('金鹰') ||
        name.contains('优质蓝光解析')) {
      return 'https://jyzyapi.com/api.php/provide/vod/';
    }
    // UC影音加速专线 / ucyy.cn -> 暴风专线 (高速秒播)
    if (apiLower.contains('ucyy.cn') ||
        key.contains('ucyy') ||
        name.contains('uc影音') ||
        name.contains('uc_speed')) {
      return 'https://bfzyapi.com/api.php/provide/vod/';
    }
    return rawApi;
  }

  /// 从指定的搜索资源API搜索
  static Future<List<SearchResult>> searchFromApi(
    SearchResource resource,
    String query,
  ) async {
    try {
      final apiBaseUrl = resolveEffectiveApi(resource);
      // v2.4.5: 用 HttpShared.buildUrl 检查 api 是否已带 `?`.
      final apiUrl = HttpShared.buildUrl(
          apiBaseUrl, 'ac=videolist&wd=${Uri.encodeComponent(query)}');

      final firstPageResult = await searchPage(
        resource: resource,
        query: query,
        page: 1,
        url: apiUrl,
      );

      final results = firstPageResult.results;
      final pageCountFromFirst = firstPageResult.pageCount;

      const maxSearchPages = 5;

      final pageCount = pageCountFromFirst;

      final pagesToFetch = (pageCount - 1) < (maxSearchPages - 1)
          ? pageCount - 1
          : maxSearchPages - 1;

      if (pagesToFetch > 0) {
        final additionalPageFutures = <Future<List<SearchResult>>>[];

        for (int page = 2; page <= pagesToFetch + 1; page++) {
          final pageUrl = HttpShared.buildUrl(apiBaseUrl,
              'ac=videolist&wd=${Uri.encodeComponent(query)}&pg=$page');

          final pageFuture = searchPage(
            resource: resource,
            query: query,
            page: page,
            url: pageUrl,
          ).then((pageResult) => pageResult.results);

          additionalPageFutures.add(pageFuture);
        }

        final additionalResults = await Future.wait(additionalPageFutures);

        for (final pageResults in additionalResults) {
          if (pageResults.isNotEmpty) {
            results.addAll(pageResults);
          }
        }
      }

      // 过滤包含黄色关键词的结果
      final filteredResults = results.where((result) {
        return !ContentFilterService.shouldFilter(result.typeName);
      }).toList();

      return filteredResults;
    } catch (error) {
      return [];
    }
  }

  /// 清理 HTML 标签
  static String _cleanHtmlTags(String text) {
    if (text.isEmpty) return '';

    String cleanedText = text
        .replaceAll(RegExp(r'<[^>]+>'), '\n')
        .replaceAll(RegExp(r'\n+'), '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'^\n+|\n+$'), '')
        .trim();

    return _decodeHtmlEntities(cleanedText);
  }

  /// 解码 HTML 实体
  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  /// 分页搜索
  static Future<SearchPageResult> searchPage({
    required SearchResource resource,
    required String query,
    required int page,
    required String url,
  }) async {
    // 先查缓存
    final cache = LocalSearchCacheService();
    final cached = cache.getCachedSearchPage(resource.key, query, page);

    if (cached != null) {
      if (cached.status == CachedPageStatus.ok) {
        return SearchPageResult(
          results: cached.data.cast<SearchResult>(),
          pageCount: cached.pageCount ?? 1,
        );
      } else {
        return SearchPageResult(results: [], pageCount: 1);
      }
    }

    try {
      // v2.4.5: UA Chrome 122 → 147 (HttpShared.userAgent), timeout 8s → 15s
      //   (HttpShared.timeoutList, 跟 web list route 1:1, 解决中等速度源超时)
      final response = await http.get(
        Uri.parse(url),
        headers: HttpShared.jsonHeaders(),
      ).timeout(HttpShared.timeoutList);

      // 检查 403 状态码，缓存 forbidden
      if (response.statusCode == 403) {
        cache.setCachedSearchPage(
          resource.key,
          query,
          page,
          CachedPageStatus.forbidden,
          [],
        );
        return SearchPageResult(results: [], pageCount: 1);
      }

      if (!response.statusCode.toString().startsWith('2')) {
        return SearchPageResult(results: [], pageCount: 1);
      }

      // v2.4.5: 解码 + JSON 解析改用 HttpShared (charset 检测 + GBK/UTF-8 自动 + 失败 fallback)
      final responseBody = HttpShared.decodeBody(response);
      final data = HttpShared.parseJson(responseBody);

      if (data == null ||
          data['list'] == null ||
          data['list'] is! List ||
          (data['list'] as List).isEmpty) {
        return SearchPageResult(results: [], pageCount: 1);
      }

      final list = data['list'] as List;

      final allResults = list.map((item) {
        // v2.4.5: vod_play_url 解析改用 HttpShared.parseVodPlayUrl (startsWith('http')),
        //   跟 source_browser_service.dart 一致. 之前 .endsWith('.m3u8') 把
        //   .mp4 直链 / .m3u8?token=xxx 带鉴权参数的 URL 全部过滤掉了.
        List<String> episodes = [];
        List<String> titles = [];

        if (item['vod_play_url'] != null) {
          final vodPlayUrlArray =
              (item['vod_play_url'] as String).split(r'$$$');

          for (final url in vodPlayUrlArray) {
            final parsed = HttpShared.parseVodPlayUrl(url);
            if (parsed.length > episodes.length) {
              episodes = parsed.map((e) => e.url).toList();
              titles = parsed.map((e) => e.name).toList();
            }
          }
        }

        String year = 'unknown';
        if (item['vod_year'] != null && item['vod_year'] != '') {
          final yearMatch =
              RegExp(r'\d{4}').firstMatch(item['vod_year'] as String);
          if (yearMatch != null) {
            year = yearMatch.group(0)!;
          }
        }

        return {
          'id': item['vod_id'].toString(),
          'title': (item['vod_name'] as String)
              .trim()
              .replaceAll(RegExp(r'\s+'), ' '),
          'poster': item['vod_pic'],
          'episodes': episodes,
          'episodes_titles': titles,
          'source': resource.key,
          'source_name': resource.name,
          'class': item['vod_class'],
          'year': year,
          'desc': _cleanHtmlTags(item['vod_content'] ?? ''),
          'type_name': item['type_name'],
          'douban_id': item['vod_douban_id'],
        };
      }).toList();

      final results = allResults
          .where((result) => (result['episodes'] as List).isNotEmpty)
          .map((result) => SearchResult.fromJson(result))
          .toList();

      final pageCount = page == 1 ? (data['pagecount'] as int? ?? 1) : 1;

      // 缓存成功的搜索结果
      cache.setCachedSearchPage(
        resource.key,
        query,
        page,
        CachedPageStatus.ok,
        results,
        pageCount: page == 1 ? pageCount : null,
      );

      return SearchPageResult(results: results, pageCount: pageCount);
    } on TimeoutException {
      // 只有超时才缓存 timeout 状态
      cache.setCachedSearchPage(
        resource.key,
        query,
        page,
        CachedPageStatus.timeout,
        [],
      );

      return SearchPageResult(results: [], pageCount: 1);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Downstream] searchPage err resource=${resource.key} e=$e');
      }
      // 其他异常不缓存，直接返回空结果
      return SearchPageResult(results: [], pageCount: 1);
    }
  }
}
