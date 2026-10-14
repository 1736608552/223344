// lib/models/skip_segment.dart
// 片头/片尾/前情回顾跳过片段数据模型

enum SkipSegmentType {
  intro,   // 片头
  recap,   // 前情回顾
  outro,   // 片尾
  credits, // 演职人员表
  preview, // 下集预告
}

class SkipSegment {
  final SkipSegmentType type;
  final int startMs;
  final int endMs;
  final double confidence;

  const SkipSegment({
    required this.type,
    required this.startMs,
    required this.endMs,
    this.confidence = 1.0,
  });

  String get label {
    switch (type) {
      case SkipSegmentType.intro:
        return '跳过片头';
      case SkipSegmentType.recap:
        return '跳过回顾';
      case SkipSegmentType.outro:
      case SkipSegmentType.credits:
        return '跳过片尾';
      case SkipSegmentType.preview:
        return '跳过预告';
    }
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'start_ms': startMs,
    'end_ms': endMs,
    'confidence': confidence,
  };

  factory SkipSegment.fromJson(Map<String, dynamic> json) {
    SkipSegmentType t = SkipSegmentType.intro;
    final typeStr = json['type']?.toString().toLowerCase() ?? 'intro';
    for (final v in SkipSegmentType.values) {
      if (v.name == typeStr) {
        t = v;
        break;
      }
    }
    return SkipSegment(
      type: t,
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }
}
