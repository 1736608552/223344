// lib/services/short_drama_search_source.dart
//
// v2.7.97（对齐 TV 端 SearchService.searchShortDramaResource）：
//   把红果官方短剧检索并入「全部搜索」结果流，标记来源名「精品短剧」。
//
// 为什么单独抽一层：
//   search_screen 的 _searchResults 类型是 List<SearchResult>，短剧侧拿到的是
//   List<ShortDrama>（红果原生模型）。这里做一次模型映射，顺带把
//   - 集数列表（episodes / episodesTitles）补齐 —— 搜索页会过滤 episodes 为空
//     的结果，不补齐的话短剧卡片会被当成「0 集源」直接丢掉；
//   - source 固定为 'hongguo' —— player_screen 命中 hongguo/shortdrama 时
//     直接走红果官方原画直出，不再回落到普通影视站搜源；
//   - sourceName 固定为「精品短剧」—— 与 TV 端 SearchResult.isShortDrama 的
//     判定字符串保持一致，两端 UI 显示同一个标记。
//
// 失败策略：短剧源是「锦上添花」，任何异常都返回空列表，绝不影响主搜索。

import 'package:luna_tv/models/search_result.dart';
import 'package:luna_tv/models/short_drama.dart';
import 'package:luna_tv/services/short_drama_direct_service.dart';

class ShortDramaSearchSource {
  ShortDramaSearchSource._();

  /// 结果里 source 字段的取值（播放器按这个走红果直出）
  static const String sourceKey = 'hongguo';

  /// 结果里展示的源名（与 TV 端一致）
  static const String sourceLabel = '精品短剧';

  /// 集数未知时的兜底（红果短剧普遍 60~100 集，播放器另有总集数兜底）
  static const int _fallbackEpisodeCount = 80;

  /// 搜索短剧并转成 SearchResult
  static Future<List<SearchResult>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const <SearchResult>[];

    List<ShortDrama> dramas;
    try {
      dramas = await ShortDramaDirectService.searchDramas(q);
    } catch (_) {
      return const <SearchResult>[];
    }
    if (dramas.isEmpty) return const <SearchResult>[];

    final seen = <String>{};
    final results = <SearchResult>[];
    for (final drama in dramas) {
      final result = _toSearchResult(drama);
      if (result == null) continue;
      if (!seen.add(result.id)) continue;
      results.add(result);
    }
    return results;
  }

  /// ShortDrama → SearchResult
  static SearchResult? _toSearchResult(ShortDrama drama) {
    final title = drama.name.trim();
    if (title.isEmpty) return null;

    final id = drama.dramaId.isNotEmpty
        ? drama.dramaId
        : (drama.id > 0 ? drama.id.toString() : '');
    if (id.isEmpty) return null;

    final total = drama.episodeCount > 0
        ? drama.episodeCount
        : _fallbackEpisodeCount;

    return SearchResult(
      id: id,
      title: title,
      poster: drama.cover,
      episodes: List<String>.generate(total, (i) => '${i + 1}'),
      episodesTitles: List<String>.generate(total, (i) => '第${i + 1}集'),
      source: sourceKey,
      sourceName: sourceLabel,
      year: _extractYear(drama.updateTime),
      desc: drama.description.isNotEmpty ? drama.description : null,
      typeName: '短剧',
    );
  }

  /// 从 "2026-11-26 12:00:00" / "2026" 里取年份，取不到按当年兜底
  static String _extractYear(String updateTime) {
    final match = RegExp(r'(19|20)\d{2}').firstMatch(updateTime);
    if (match != null) return match.group(0)!;
    return DateTime.now().year.toString();
  }
}
