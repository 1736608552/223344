import 'package:http/http.dart' as http;
import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/downstream_service.dart';
import 'package:luna_tv/services/http_shared.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';

/// 搜索服务
class SearchService {
  // 内存缓存
  static List<SearchResource>? _cachedResources;
  static bool _isRefreshing = false;

  /// 获取搜索资源列表（带缓存）
  /// 本地模式直接返回，服务器模式先返回缓存数据然后异步刷新
  static Future<List<SearchResource>> _getSearchResourcesWithCache() async {
    final isLocalMode = await UserDataService.getIsLocalMode();

    // 本地模式不使用缓存，直接返回
    if (isLocalMode) {
      return await LocalModeStorageService.getSearchSources();
    }

    // 服务器模式使用缓存
    // 如果有缓存，立即返回缓存数据
    if (_cachedResources != null) {
      // 异步刷新缓存（不等待）
      if (!_isRefreshing) {
        _refreshCache();
      }
      return _cachedResources!;
    }

    // 如果没有缓存，同步获取并缓存
    return await _refreshCache();
  }

  /// 刷新缓存（仅用于服务器模式）
  ///
  /// v2.4.8: 失败 (拿到空 list) **不更新 cache**, 让下次重试.
  ///   之前 ApiService.getSearchResources 在 HTTP 失败/异常时返 [],
  ///   _refreshCache 把 [] 当成有效结果缓存进 _cachedResources →
  ///   后续 _getSearchResourcesWithCache 直接返空 cache →
  ///   UI 显示「暂无可用源」, 直到进程重启. 网络抖动一次就显示「没源」
  ///   体验极差. 修: 拿到空 list 时不更新 cache, 仍返旧 cache (或 []),
  ///   下次再试.
  static Future<List<SearchResource>> _refreshCache() async {
    if (_isRefreshing) {
      // 如果正在刷新，等待当前刷新完成
      while (_isRefreshing) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _cachedResources ?? [];
    }

    _isRefreshing = true;
    try {
      final resources = await ApiService.getSearchResources();
      // v2.4.8: 空 list 视为失败, 不更新 cache (避免网络抖动把空 list 缓存住)
      if (resources.isNotEmpty) {
        _cachedResources = resources;
      }
      return _cachedResources ?? resources;
    } catch (e) {
      return _cachedResources ?? [];
    } finally {
      _isRefreshing = false;
    }
  }

  /// 清除缓存（在需要强制刷新时调用）
  static void clearCache() {
    _cachedResources = null;
  }

  /// v2.3.31: 取当前激活的源列表 (公开版 _getSearchResourcesWithCache).
  ///   给源浏览器 (settings/源浏览器) 用, 拿所有未 disable 的 SearchResource.
  ///   跟 [searchSync] / [getDetailSync] 用同一份内存缓存, 不另起链路.
  ///   返回顺序 = server 推过来 / 本地 模式 读 LocalModeStorageService 的顺序.
  ///
  /// v2.4.5: 同时过滤空 api (跟 web sites/route.ts:17
  ///   `.filter((s) => Boolean(s.api?.trim()))` 1:1). 之前空 api 源会出现在
  ///   UI 列表里但点进去 _buildUrl 返 '' → _getJson 返 null → 「加载失败」,
  ///   silent failure 极难排查.
  static Future<List<SearchResource>> getActiveResources() async {
    final all = await _getSearchResourcesWithCache();
    return all.where((r) => !r.disabled && r.api.trim().isNotEmpty).toList();
  }

  /// 搜索推荐（只搜索第一个资源）
  /// 用于快速获取搜索建议
  static Future<List<String>> searchRecommand(String query) async {
    try {
      // 获取搜索资源列表（使用缓存）
      final allResources = await _getSearchResourcesWithCache();

      // 过滤掉被禁用的资源
      final resources =
          allResources.where((resource) => !resource.disabled).toList();

      if (resources.isEmpty) {
        return [];
      }

      // 只搜索第一个资源，设置 5 秒超时
      final firstResource = resources.first;
      final results =
          await DownstreamService.searchFromApi(firstResource, query)
              .timeout(const Duration(seconds: 5))
              .catchError((error) {
        // 捕获错误，返回空列表
        return <SearchResult>[];
      });

      // 提取标题列表并去重
      final titles = results.map((result) => result.title).toSet().toList();
      return titles;
    } catch (e) {
      return [];
    }
  }

  /// 同步搜索（本地搜索）
  /// 并发调用所有资源的搜索，返回所有结果
  static Future<List<SearchResult>> searchSync(String query) async {
    try {
      // 获取搜索资源列表（使用缓存）
      final allResources = await _getSearchResourcesWithCache();

      // 过滤掉被禁用的资源
      final resources =
          allResources.where((resource) => !resource.disabled).toList();

      if (resources.isEmpty) {
        return [];
      }

      // 并发调用所有资源的搜索，每个调用增加 20 秒超时
      final searchFutures = resources.map((resource) {
        return DownstreamService.searchFromApi(resource, query)
            .timeout(const Duration(seconds: 20))
            .catchError((error) {
          // 捕获错误，返回空列表
          return <SearchResult>[];
        });
      }).toList();

      // 等待所有搜索完成
      final allResults = await Future.wait(searchFutures);

      // 按照 resources 的顺序合并结果（allResults 的顺序与 resources 一致）
      final results = <SearchResult>[];
      for (int i = 0; i < allResults.length; i++) {
        if (allResults[i].isNotEmpty) {
          results.addAll(allResults[i]);
        }
      }

      return results;
    } catch (e) {
      return [];
    }
  }

  /// 获取视频详情（本地直接调用下游API）
  ///
  /// v2.4.6: 服务器模式走服务端代理 `/api/detail?source=K&id=ID`
  ///   (跟 web detail/route.ts 1:1). 本地模式 / 服务端代理失败 → fallback 直连.
  ///   mobile 直连源 API 在中国大陆常失败, 服务端代理能正常访问.
  ///   web `/api/detail` 返回格式跟 SearchResult.fromJson 完全匹配
  ///   (id/title/poster/episodes/episodes_titles/source/source_name/class/
  ///    year/desc/type_name/douban_id), 直接解析.
  static Future<List<SearchResult>> getDetailSync(
      String source, String id) async {
    try {
      // v2.4.6: 服务器模式优先走服务端代理
      if (await HttpShared.isServerMode()) {
        final data = await HttpShared.getViaServer(
            '/api/detail?source=${Uri.encodeComponent(source)}&id=${Uri.encodeComponent(id)}',
            timeout: HttpShared.timeoutDefault);
        if (data != null) {
          // web /api/detail 返回 SearchResult 对象 (不是 list),
          // 直接用 SearchResult.fromJson 解析.
          // 失败 (404 / 500) 时 data == null, fallback 直连.
          final result = SearchResult.fromJson(data);
          if (result.id.isNotEmpty || result.title.isNotEmpty) {
            return [result];
          }
        }
        // 服务端代理失败 → fallback 直连源 API
      }

      // 获取搜索资源列表（使用缓存）
      final allResources = await _getSearchResourcesWithCache();

      // 找到对应 source 的资源
      final apiSite = allResources.firstWhere(
        (resource) => resource.key == source,
        orElse: () => throw Exception('未找到对应的源: $source'),
      );

      // 如果 detail 不为空，使用特殊源处理
      if (apiSite.detail.isNotEmpty) {
        final result = await _handleSpecialSourceDetail(id, apiSite);
        return [result];
      }

      // 构建详情请求 URL
      // v2.4.5: 用 HttpShared.buildUrl 检查 api 是否已带 `?`.
      final detailUrl = HttpShared.buildUrl(apiSite.api, 'ac=videolist&ids=$id');

      // v2.4.5: UA Chrome 122 → 147 (HttpShared.jsonHeaders),
      //   timeout 10s → 8s (HttpShared.timeoutDefault, 跟 SourceBrowser.getDetail 1:1)
      final response = await http.get(
        Uri.parse(detailUrl),
        headers: HttpShared.jsonHeaders(),
      ).timeout(HttpShared.timeoutDefault);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('详情请求失败: ${response.statusCode}');
      }

      // v2.4.5: 解码 + JSON 解析改用 HttpShared (charset 检测 + GBK/UTF-8 自动 + 失败 fallback).
      //   之前直接 response.body (Latin-1 解码), GBK 源拿到乱码 json.decode 抛异常.
      final data = HttpShared.parseJson(HttpShared.decodeBody(response));

      if (data == null ||
          data['list'] == null ||
          data['list'] is! List ||
          (data['list'] as List).isEmpty) {
        throw Exception('获取到的详情内容无效');
      }

      final videoDetail = data['list'][0];
      List<String> episodes = [];
      List<String> titles = [];

      // v2.4.5: vod_play_url 解析改用 HttpShared.parseVodPlayUrl (startsWith('http')),
      //   跟 SourceBrowser.getDetail / DownstreamService.searchPage 一致.
      //   之前 .endsWith('.m3u8') 把 .mp4 直链 / .m3u8?token=xxx 全部过滤掉了.
      if (videoDetail['vod_play_url'] != null) {
        final vodPlayUrlArray =
            (videoDetail['vod_play_url'] as String).split(r'$$$');

        for (final url in vodPlayUrlArray) {
          final parsed = HttpShared.parseVodPlayUrl(url);
          if (parsed.length > episodes.length) {
            episodes = parsed.map((e) => e.url).toList();
            titles = parsed.map((e) => e.name).toList();
          }
        }
      }

      // 如果播放源为空，则尝试从内容中解析 m3u8
      if (episodes.isEmpty && videoDetail['vod_content'] != null) {
        final m3u8Pattern = RegExp(r'https?://[^\s<>"]+\.m3u8');
        final matches =
            m3u8Pattern.allMatches(videoDetail['vod_content'] as String);
        episodes = matches.map((match) => match.group(0)!).toList();
      }

      // 解析年份
      String year = 'unknown';
      if (videoDetail['vod_year'] != null && videoDetail['vod_year'] != '') {
        final yearMatch =
            RegExp(r'\d{4}').firstMatch(videoDetail['vod_year'] as String);
        if (yearMatch != null) {
          year = yearMatch.group(0)!;
        }
      }

      final result = SearchResult(
        id: id,
        title: videoDetail['vod_name'] ?? '',
        poster: videoDetail['vod_pic'] ?? '',
        episodes: episodes,
        episodesTitles: titles,
        source: apiSite.key,
        sourceName: apiSite.name,
        class_: videoDetail['vod_class'],
        year: year,
        desc: _cleanHtmlTags(videoDetail['vod_content'] ?? ''),
        typeName: videoDetail['type_name'],
        doubanId: videoDetail['vod_douban_id'],
      );

      return [result];
    } catch (e) {
      return [];
    }
  }

  /// 处理特殊源的详情（通过 HTML 页面解析）
  ///
  /// v2.4.5: UA Chrome 122 → 147 (HttpShared.htmlHeaders), apiSite 类型 dynamic
  ///   改成 SearchResource. detail 字段去掉末尾斜杠避免双斜杠.
  static Future<SearchResult> _handleSpecialSourceDetail(
      String id, SearchResource apiSite) async {
    final detailBase = apiSite.detail.trim().replaceAll(RegExp(r'/+$'), '');
    final detailUrl = '$detailBase/index.php/vod/detail/id/$id.html';

    // v2.4.5: UA Chrome 122 → 147 (HttpShared.htmlHeaders), timeout 10s → 8s
    final response = await http.get(
      Uri.parse(detailUrl),
      headers: HttpShared.htmlHeaders(),
    ).timeout(HttpShared.timeoutDefault);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('详情页请求失败: ${response.statusCode}');
    }

    final html = HttpShared.decodeBody(response);
    List<String> matches = [];

    // 如果是 ffzy 源，使用特殊的正则表达式
    if (apiSite.key == 'ffzy') {
      final ffzyPattern =
          RegExp(r'\$(https?://[^"\x27\s]+?/\d{8}/\d+_[a-f0-9]+/index\.m3u8)');
      matches =
          ffzyPattern.allMatches(html).map((match) => match.group(0)!).toList();
    }

    // 如果没有匹配到，使用通用的正则表达式
    if (matches.isEmpty) {
      final generalPattern = RegExp(r'\$(https?://[^"\x27\s]+?\.m3u8)');
      matches = generalPattern
          .allMatches(html)
          .map((match) => match.group(0)!)
          .toList();
    }

    // 去重并清理链接前缀
    final uniqueMatches = matches.toSet().toList();
    final episodes = uniqueMatches.map((link) {
      // 去掉开头的 $
      link = link.substring(1);
      // 去掉可能的括号后缀
      final parenIndex = link.indexOf('(');
      return parenIndex > 0 ? link.substring(0, parenIndex) : link;
    }).toList();

    // 根据 episodes 数量生成剧集标题
    final episodesTitles =
        List.generate(episodes.length, (i) => (i + 1).toString());

    // 提取标题
    final titleMatch = RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html);
    final titleText = titleMatch != null ? titleMatch.group(1)!.trim() : '';

    // 提取描述
    final descMatch =
        RegExp(r'<div[^>]*class=["\x27]sketch["\x27][^>]*>([\s\S]*?)</div>')
            .firstMatch(html);
    final descText =
        descMatch != null ? _cleanHtmlTags(descMatch.group(1)!) : '';

    // 提取封面
    final coverMatches =
        RegExp(r'(https?://[^"\x27\s]+?\.jpg)').allMatches(html);
    final coverUrl =
        coverMatches.isNotEmpty ? coverMatches.first.group(0)!.trim() : '';

    // 提取年份
    final yearMatch = RegExp(r'>(\d{4})<').firstMatch(html);
    final yearText = yearMatch != null ? yearMatch.group(1)! : 'unknown';

    return SearchResult(
      id: id,
      title: titleText,
      poster: coverUrl,
      episodes: episodes,
      episodesTitles: episodesTitles,
      source: apiSite.key,
      sourceName: apiSite.name,
      class_: '',
      year: yearText,
      desc: descText,
      typeName: '',
      doubanId: 0,
    );
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
}
