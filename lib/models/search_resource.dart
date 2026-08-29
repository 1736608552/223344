/// 搜索资源模型
class SearchResource {
  final String key;
  final String name;
  final String api;
  final String detail;
  final String from;
  final bool disabled;

  SearchResource({
    required this.key,
    required this.name,
    required this.api,
    required this.detail,
    required this.from,
    required this.disabled,
  });

  factory SearchResource.fromJson(Map<String, dynamic> json) {
    return SearchResource(
      // v2.4.5: 全字段 trim, 之前只 trim api. detail 字段若有空格,
      //   search_service._handleSpecialSourceDetail 拼 detail URL 会带空格,
      //   URL 破损. name/key/from 顺手 trim 一致.
      key: (json['key'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      api: (json['api'] as String? ?? '').trim(),
      detail: (json['detail'] as String? ?? '').trim(),
      from: (json['from'] as String? ?? '').trim(),
      disabled: json['disabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'api': api,
      'detail': detail,
      'from': from,
      'disabled': disabled,
    };
  }
}
