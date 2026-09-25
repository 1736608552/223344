/// v2.5.3: TVBox 协议 (`vod_id` / `vod_name` / `vod_pic` / ...) 短剧原始 model.
///
/// 之前 [ShortDrama] 走的是后端 `/api/shortdrama/*` 二次加工后的字段名
/// (`id` / `name` / `cover` / ...). 直连 TVBox 源拿到的 JSON 字段是
/// `vod_id` / `vod_name` / `vod_pic` / ..., 字段名 / 类型不通用, 单独 model
/// 解耦, 不污染老的 [ShortDrama] 逻辑.
///
/// 不包含 `episodes` / `episodes_titles` (即不含 m3u8 集数列表),
/// 因为按用户要求:
/// - 写死源 = 只提供 数据 + 图片 + 分类
/// - 播放 = 仍走 ShortDramaService.parseEpisode() 走后端解析
class RawShortDrama {
  final int vodId;
  final String vodName;
  final String vodPic;
  final String vodPicSlide;
  final String vodTime;
  final double vodScore;
  final int vodRemarksEpisodeCount;
  final String vodContent;
  final String vodBlurb;
  final String vodActor;
  final int typeId;
  final String typeName;

  const RawShortDrama({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodPicSlide,
    required this.vodTime,
    required this.vodScore,
    required this.vodRemarksEpisodeCount,
    required this.vodContent,
    required this.vodBlurb,
    required this.vodActor,
    required this.typeId,
    required this.typeName,
  });

  /// 清洗短剧标题 (去除采集站垃圾标记、括号集数说明、完结/高清后缀等)
  static String cleanVodName(String raw) {
    if (raw.isEmpty) return '';
    var s = raw.trim();
    // 1. 去除常见的带括号标签，如：【全集】、[全80集]、(80集全)、（完结）
    s = s.replaceAll(RegExp(r'[【\[\(（][^】\]\)）]*[】\]\)）]'), '');
    // 2. 去除常见状态和集数标记: 全80集, 80集全, 第1-80集, 完结, HD, 1080P, 超清, 未删减等
    s = s.replaceAll(
      RegExp(
        r'(?:第?\s*\d+[-~至到]\d+\s*[集话]|全\s*\d+\s*[集话]|\d+\s*[集话]全|全集|完结|更新至\s*\d+\s*[集话]|超清|高清|未删减|无删减|中字|国语|1080[pP]|4[kK]|HD|BD)+',
        caseSensitive: false,
      ),
      '',
    );
    // 3. 去除首尾多余标点和空白
    s = s.trim().replaceAll(RegExp(r'^[-_—:：\s]+|[-_—:：\s]+$'), '');
    return s.isNotEmpty ? s : raw.trim();
  }

  /// 规范化图片地址 (修复协议、去除空格)
  static String cleanVodPic(String raw) {
    var p = raw.trim();
    if (p.startsWith('//')) {
      p = 'https:$p';
    }
    return p;
  }

  /// 从 TVBox JSON (`?ac=detail&t=...`) 的一条 `list[]` 项解析.
  factory RawShortDrama.fromVodJson(Map<String, dynamic> json) {
    // 跟 src/lib/shortdrama.server.ts L62-66 字段映射 1:1, 复用后端解析逻辑.
    final remarks = json['vod_remarks']?.toString() ?? '';
    final epCount = int.tryParse(remarks.replaceAll(RegExp(r'[^\d]'), '')) ?? 1;
    final score =
        double.tryParse(json['vod_score']?.toString() ?? '') ?? 0.0;
    final rawName = json['vod_name']?.toString() ?? '';
    final rawPic = json['vod_pic']?.toString() ?? '';
    final rawSlide = json['vod_pic_slide']?.toString() ?? '';
    return RawShortDrama(
      vodId: json['vod_id'] is int
          ? json['vod_id']
          : int.tryParse(json['vod_id']?.toString() ?? '0') ?? 0,
      vodName: cleanVodName(rawName),
      vodPic: cleanVodPic(rawPic),
      vodPicSlide: cleanVodPic(rawSlide),
      vodTime: json['vod_time']?.toString() ?? '',
      vodScore: score,
      vodRemarksEpisodeCount: epCount,
      vodContent: json['vod_content']?.toString() ?? '',
      vodBlurb: json['vod_blurb']?.toString() ?? '',
      vodActor: json['vod_actor']?.toString() ?? '',
      typeId: json['type_id'] is int
          ? json['type_id']
          : int.tryParse(json['type_id']?.toString() ?? '0') ?? 0,
      typeName: json['type_name']?.toString() ?? '',
    );
  }
}

/// v2.5.3: TVBox 协议 (`?ac=list` 返的 `class[]`) 短剧原始分类.
class RawShortDramaCategory {
  final int typeId;
  final String typeName;

  const RawShortDramaCategory({
    required this.typeId,
    required this.typeName,
  });

  factory RawShortDramaCategory.fromVodJson(Map<String, dynamic> json) {
    return RawShortDramaCategory(
      typeId: json['type_id'] is int
          ? json['type_id']
          : int.tryParse(json['type_id']?.toString() ?? '0') ?? 0,
      typeName: json['type_name']?.toString() ?? '',
    );
  }
}
