// lib/models/source_browser.dart
// v2.3.31: 源浏览器 model
//   SourceCategory - 源分类 (e.g. 电影/剧集/动漫/综艺)
//   SourceBrowserItem - 列表项 (海报+标题+年份+备注)
//   SourceBrowserDetail - 详情 (含简介+选集+演员+导演+地区)
//
// 字段命名沿用源 API AppleCMS 风格 (vod_id / vod_name / vod_pic / vod_year),
//   跟 DownstreamService / SearchService.parse 保持一致, 不强行 rename.
// 选集 vod_play_url 解析复用 SearchService.parsePlayUrl 那种 split + regex,
//   在 service 层做, model 只存解析后的 List<SourceBrowserEpisode>.

import 'package:flutter/foundation.dart';

/// 源分类 (e.g. 电影/剧集/动漫/综艺/纪录片/短剧)
/// 来自源 API `?ac=list` 返回的 class[].type_id / type_name.
@immutable
class SourceCategory {
  final int typeId;
  final String typeName;

  const SourceCategory({required this.typeId, required this.typeName});

  factory SourceCategory.fromJson(Map<String, dynamic> json) {
    // v2.4.1: 跟 web categories route 1:1, 兼容 3 种字段名
    //   web: c.type_id ?? c.typeid ?? c.id
    //   某些源返 typeid / id 而不是 type_id, 不读备用字段会拿到 0
    //   导致后续 ?ac=videolist&t=0 返回错的内容 (分类内容不匹配)
    final rawTypeId = json['type_id'] ?? json['typeid'] ?? json['id'];
    final rawTypeName = json['type_name'] ?? json['typename'] ?? json['name'];
    return SourceCategory(
      typeId: rawTypeId is int
          ? rawTypeId
          : int.tryParse(rawTypeId?.toString() ?? '') ?? 0,
      typeName: (rawTypeName?.toString() ?? '').trim(),
    );
  }

  @override
  String toString() => 'SourceCategory($typeId, $typeName)';
}

/// 源浏览器列表项 (来源 `?ac=videolist&t=X&pg=N` list[])
/// poster / year / type_name / remarks 都直接来自源 API, 不二次清洗.
@immutable
class SourceBrowserItem {
  final String id; // vod_id
  final String title; // vod_name
  final String poster; // vod_pic
  final String year; // vod_year
  final String typeName; // type_name (单条, 跟分类 type_name 一致但取自视频本身)
  final String remarks; // vod_remarks (e.g. "正片" / "更新至10集" / "HD")

  const SourceBrowserItem({
    required this.id,
    required this.title,
    required this.poster,
    required this.year,
    required this.typeName,
    required this.remarks,
  });

  factory SourceBrowserItem.fromJson(Map<String, dynamic> json) {
    return SourceBrowserItem(
      id: (json['vod_id'] ?? json['id'] ?? '').toString(),
      title: (json['vod_name'] ?? json['title'] ?? '').toString().trim(),
      poster: (json['vod_pic'] ?? json['poster'] ?? '').toString().trim(),
      year: (json['vod_year'] ?? json['year'] ?? '').toString().trim(),
      typeName:
          (json['type_name'] ?? json['typeName'] ?? '').toString().trim(),
      remarks:
          (json['vod_remarks'] ?? json['remarks'] ?? '').toString().trim(),
    );
  }
}

/// 选集 (从 vod_play_url 解析)
/// "第01集\$url#第02集\$url#..." → List<SourceBrowserEpisode>
@immutable
class SourceBrowserEpisode {
  final String name; // e.g. "第01集" / "01" / "HD"
  final String url; // 视频 URL (m3u8 / mp4)

  const SourceBrowserEpisode({required this.name, required this.url});

  @override
  String toString() => 'SourceBrowserEpisode($name, ${url.length} chars)';
}

/// 源浏览器详情 (来自 `?ac=videolist&ids=ID` list[0])
/// 比 SourceBrowserItem 多 vod_content (简介) + vod_play_url (选集 URL 串) +
///   vod_actor (演员) + vod_director (导演) + vod_area (地区) + vod_lang (语言).
@immutable
class SourceBrowserDetail {
  final String id;
  final String title;
  final String poster;
  final String year;
  final String typeName;
  final String remarks;
  final String content; // 简介
  final String actor; // 演员
  final String director; // 导演
  final String area; // 地区
  final String lang; // 语言
  final List<SourceBrowserEpisode> episodes; // 解析后的选集

  const SourceBrowserDetail({
    required this.id,
    required this.title,
    required this.poster,
    required this.year,
    required this.typeName,
    required this.remarks,
    required this.content,
    required this.actor,
    required this.director,
    required this.area,
    required this.lang,
    required this.episodes,
  });

  factory SourceBrowserDetail.fromJson(
    Map<String, dynamic> json,
    List<SourceBrowserEpisode> episodes,
  ) {
    return SourceBrowserDetail(
      id: (json['vod_id'] ?? json['id'] ?? '').toString(),
      title: (json['vod_name'] ?? json['title'] ?? '').toString().trim(),
      poster: (json['vod_pic'] ?? json['poster'] ?? '').toString().trim(),
      year: (json['vod_year'] ?? json['year'] ?? '').toString().trim(),
      typeName:
          (json['type_name'] ?? json['typeName'] ?? '').toString().trim(),
      remarks:
          (json['vod_remarks'] ?? json['remarks'] ?? '').toString().trim(),
      content:
          (json['vod_content'] ?? json['content'] ?? '').toString().trim(),
      actor: (json['vod_actor'] ?? json['actor'] ?? '').toString().trim(),
      director:
          (json['vod_director'] ?? json['director'] ?? '').toString().trim(),
      area: (json['vod_area'] ?? json['area'] ?? '').toString().trim(),
      lang: (json['vod_lang'] ?? json['lang'] ?? '').toString().trim(),
      episodes: episodes,
    );
  }
}

/// 列表分页元数据 (来自 list 响应的 page / pagecount / total / limit)
@immutable
class SourceBrowserPageMeta {
  final int page;
  final int pageCount;
  final int total;
  final int limit;

  const SourceBrowserPageMeta({
    required this.page,
    required this.pageCount,
    required this.total,
    required this.limit,
  });

  factory SourceBrowserPageMeta.fromJson(Map<String, dynamic> json) {
    return SourceBrowserPageMeta(
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageCount: (json['pagecount'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 20,
    );
  }

  bool get hasMore => page < pageCount;
}
