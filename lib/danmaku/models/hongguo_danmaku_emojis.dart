// lib/danmaku/models/hongguo_danmaku_emojis.dart
// 红果短剧官方表情与弹幕标签解析器 (包含53张官方原版WebP高清表情图与150+种Emoji备用映射)

import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// 53 个官方原版高清 WebP 表情代码/名称到文件名完整映射表
const Map<String, String> hongguoDanmakuImageMap = {
  '[微笑]': '01_微笑.webp', '微笑': '01_微笑.webp',
  '[偷笑]': '02_偷笑.webp', '偷笑': '02_偷笑.webp',
  '[笑]': '03_笑.webp', '笑': '03_笑.webp',
  '[什么]': '04_什么.webp', '什么': '04_什么.webp',
  '[害羞]': '05_害羞.webp', '害羞': '05_害羞.webp',
  '[爱慕]': '06_爱慕.webp', '爱慕': '06_爱慕.webp',
  '[飞吻]': '07_飞吻.webp', '飞吻': '07_飞吻.webp',
  '[奸笑]': '08_奸笑.webp', '奸笑': '08_奸笑.webp',
  '[尬笑]': '09_尬笑.webp', '尬笑': '09_尬笑.webp',
  '[思考]': '10_思考.webp', '思考': '10_思考.webp',
  '[撇嘴]': '11_撇嘴.webp', '撇嘴': '11_撇嘴.webp',
  '[做鬼脸]': '12_做鬼脸.webp', '做鬼脸': '12_做鬼脸.webp',
  '[酷]': '13_酷.webp', '酷': '13_酷.webp',
  '[翻白眼]': '14_翻白眼.webp', '翻白眼': '14_翻白眼.webp',
  '[惊呆]': '15_惊呆.webp', '惊呆': '15_惊呆.webp',
  '[震惊]': '16_震惊.webp', '震惊': '16_震惊.webp',
  '[送心]': '17_送心.webp', '送心': '17_送心.webp',
  '[委屈]': '18_委屈.webp', '委屈': '18_委屈.webp',
  '[快哭了]': '19_快哭了.webp', '快哭了': '19_快哭了.webp',
  '[笑哭]': '20_笑哭.webp', '笑哭': '20_笑哭.webp',
  '[哭]': '21_哭.webp', '哭': '21_哭.webp',
  '[大笑]': '22_大笑.webp', '大笑': '22_大笑.webp',
  '[舔屏]': '23_舔屏.webp', '舔屏': '23_舔屏.webp',
  '[怒]': '24_怒.webp', '怒': '24_怒.webp',
  '[捂脸]': '25_捂脸.webp', '捂脸': '25_捂脸.webp',
  '[吐]': '26_吐.webp', '吐': '26_吐.webp',
  '[恐惧]': '27_恐惧.webp', '恐惧': '27_恐惧.webp',
  '[抓狂]': '28_抓狂.webp', '抓狂': '28_抓狂.webp',
  '[敬礼]': '29_敬礼.webp', '敬礼': '29_敬礼.webp',
  '[石化]': '30_石化.webp', '石化': '30_石化.webp',
  '[OK]': '31_OK.webp', 'OK': '31_OK.webp',
  '[赞]': '32_赞.webp', '赞': '32_赞.webp',
  '[爱心]': '33_爱心.webp', '爱心': '33_爱心.webp',
  '[伤心]': '34_伤心.webp', '伤心': '34_伤心.webp',
  '[KISS]': '35_KISS.webp', 'KISS': '35_KISS.webp',
  '[懂了]': '36_懂了.webp', '懂了': '36_懂了.webp',
  '[探究]': '37_探究.webp', '探究': '37_探究.webp',
  '[重拳出击]': '38_重拳出击.webp', '重拳出击': '38_重拳出击.webp',
  '[吃瓜]': '39_吃瓜.webp', '吃瓜': '39_吃瓜.webp',
  '[盯]': '40_盯.webp', '盯': '40_盯.webp',
  '[你细品]': '41_你细品.webp', '你细品': '41_你细品.webp',
  '[赶稿中]': '42_赶稿中.webp', '赶稿中': '42_赶稿中.webp',
  '[注意]': '43_注意.webp', '注意': '43_注意.webp',
  '[饱了]': '44_饱了.webp', '饱了': '44_饱了.webp',
  '[码住]': '45_码住.webp', '码住': '45_码住.webp',
  '[学会了]': '46_学会了.webp', '学会了': '46_学会了.webp',
  '[顶帖]': '47_顶帖.webp', '顶帖': '47_顶帖.webp',
  '[求爆更]': '48_求爆更.webp', '求爆更': '48_求爆更.webp',
  '[求关注]': '49_求关注.webp', '求关注': '49_求关注.webp',
  '[爽]': '50_爽.webp', '爽': '50_爽.webp',
  '[鼓掌]': '51_鼓掌.webp', '鼓掌': '51_鼓掌.webp',
  '[没看够]': '52_没看够.webp', '没看够': '52_没看够.webp',
  '[送花]': '53_送花.webp', '送花': '53_送花.webp',
};

const Map<String, String> hongguoDanmakuEmojiMap = {
  // 喜爱 / 心动 / 爱慕 / 恋爱
  '爱慕': '😍',
  '色': '😍',
  '花痴': '😍',
  '心动': '💓',
  '喜欢': '🥰',
  '心': '❤️',
  '爱心': '❤️',
  '红心': '❤️',
  '比心': '🫰',
  '比个心': '🫰',
  '送心': '💖',
  '飞吻': '😘',
  '亲亲': '😚',
  '吻': '💋',
  '害羞': '😳',
  '脸红': '😳',
  '可爱': '🥺',
  '可怜': '🥺',
  '爱了爱了': '🥰',

  // 开心 / 大笑 / 幽默
  '大笑': '😄',
  '笑': '😊',
  '哈哈': '😄',
  '笑哭': '😂',
  '笑翻': '🤣',
  '笑cry': '😂',
  '偷笑': '🤭',
  '奸笑': '😏',
  '坏笑': '😈',
  '得意': '😎',
  '酷': '😎',
  '机智': '🤓',
  '聪明': '🤓',
  '捂脸': '🤦',
  '打脸': '😣',
  '尬笑': '😅',
  '调皮': '😜',
  '憨笑': '😄',
  '愉快': '😊',
  '开心': '😃',

  // 悲伤 / 感动 / 哭泣
  '流泪': '😭',
  '泪奔': '😭',
  '泣不成声': '😭',
  '哭': '😭',
  '快哭了': '🥲',
  '泪': '😢',
  '难过': '🥺',
  '委屈': '🥺',
  '绝望': '😩',
  '吐血': '🩸',
  '心碎': '💔',
  '感动': '🥹',
  '逞强落泪': '🥲',

  // 震惊 / 惊讶 / 无语
  '震惊': '😱',
  '惊恐': '😱',
  '惊呆': '😲',
  '惊讶': '😲',
  '发呆': '😳',
  '翻白眼': '🙄',
  '白眼': '🙄',
  '无语': '😑',
  '汗': '😅',
  '冷汗': '😅',
  '尴尬': '😅',
  '抓狂': '😫',
  '黑线': '😓',
  '石化': '🗿',
  '晕': '😵',
  '撇嘴': '😒',
  '鄙视': '😒',
  '呆住': '😶',

  // 赞同 / 互动 / 点赞
  '赞': '👍',
  '点赞': '👍',
  '强': '👍',
  '棒': '👍',
  '真棒': '👍',
  '太棒了': '👏',
  '给力': '💪',
  '加油': '💪',
  '踩': '👎',
  '弱': '👎',
  '鼓掌': '👏',
  '掌声': '👏',
  '握手': '🤝',
  '抱拳': '🤜🤛',
  '拥抱': '🤗',
  '抱抱': '🤗',
  '抱抱你': '🤗',
  '祈祷': '🙏',
  '保佑': '🙏',
  '拜托': '🙏',
  '求求了': '🙏',
  '双手合十': '🙏',
  '击掌': '🙌',
  'OK': '👌',
  'ok': '👌',
  '好的': '👌',
  '耶': '✌️',
  '胜利': '✌️',
  '666': '🤙',
  '双击666': '🤙',
  '6': '🤙',
  '牛': '🐂',
  '牛逼': '🐂',
  '100': '💯',
  '100分': '💯',
  '秀儿': '🎭',
  '还得是你': '🤝',
  '打call': '📣',
  '加鸡腿': '🍗',

  // 思考 / 吃瓜 / 状态
  '看': '👀',
  '观察': '👀',
  '瞅瞅': '👀',
  '暗中观察': '🕵️',
  '吃瓜': '🍉',
  '吃瓜群众': '🍉',
  '思考': '🤔',
  '想': '🤔',
  '嘘': '🤫',
  '困': '🥱',
  '打哈欠': '🥱',
  '哈欠': '🥱',
  '睡': '😴',
  '睡觉': '😴',
  '打瞌睡': '😴',
  '闭嘴': '🤐',
  '再见': '👋',
  '拜拜': '👋',
  '互关': '🤝',
  '互粉': '🤝',
  '关注我': '🔔',

  // 愤怒 / 情绪
  '愤怒': '😡',
  '生气': '😡',
  '发怒': '😡',
  '怒': '💢',
  '傲慢': '😤',
  '哼': '😤',
  '左哼哼': '😤',
  '右哼哼': '😤',
  '别发癫了': '🙄',
  '别说了': '🤫',

  // 物品 / 符号 / 趣味
  '火': '🔥',
  '点火': '🔥',
  '续火花': '✨',
  '礼物': '🎁',
  '玫瑰': '🌹',
  '送花': '🌹',
  '鲜花': '💐',
  '干杯': '🍻',
  '啤酒': '🍺',
  '咖啡': '☕',
  '蛋糕': '🎂',
  '太阳': '☀️',
  '月亮': '🌙',
  '钱': '💰',
  '发财': '💰',
  '爱钱': '💰',
  '锦鲤': '🐟',
  '便便': '💩',
  '炸弹': '💣',
  '烟花': '🎆',
  '庆祝': '🎉',
  '狗头': '🐶',
  '菜狗': '🐶',
  '猪头': '🐷',
  '柠檬': '🍋',
  '酸': '🍋',
  '我酸了': '🍋',
  '疑问': '❓',
  '感叹': '❗️',
  '问号': '❓',
  '叹号': '❗️',
  'What': '❓',
  '红包': '🧧',
  '贴贴': '🫂',
  '裂开': '💔',
  '绝了': '💯',
};

/// 将包含 [爱慕]、［666］、[点赞] 等表情标签的短剧弹幕文本规范化处理
/// 53 个官方原版高清 WebP 表情规范保留为标准标签供 Canvas 绘制 Bitmap，其余收录标签转为原生 Unicode Emoji
String formatHongguoDanmakuText(String input) {
  if (input.isEmpty) return input;

  // 1. 清理控制字符与换行
  final cleaned = input
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
      .trim();

  // 2. 匹配中英文方括号内的标签
  return cleaned.replaceAllMapped(
    RegExp(r'(\[|［)\s*([^\[\]［］]{1,16}?)\s*(\]|］)'),
    (match) {
      final key = match.group(2)!.trim();
      // 过滤异常占位符
      if (key == r'$key' || key == 'key' || key.isEmpty) {
        return '';
      }
      if (hongguoDanmakuImageMap.containsKey(key) ||
          hongguoDanmakuImageMap.containsKey('[$key]')) {
        return '[$key]';
      }
      final emoji = hongguoDanmakuEmojiMap[key];
      if (emoji != null) {
        return emoji;
      }
      // 未收录标签保留用户原始内容
      return match.group(0)!;
    },
  );
}

/// 弹幕图文混排抽象段
abstract class DanmakuSegment {
  double get width;
  void dispose();
}

/// 文本段
class TextDanmakuSegment extends DanmakuSegment {
  final TextPainter painter;
  @override
  final double width;

  TextDanmakuSegment({required this.painter, required this.width});

  @override
  void dispose() {
    painter.dispose();
  }
}

/// 官方高清表情图片段
class ImageDanmakuSegment extends DanmakuSegment {
  final String code;
  final ui.Image? image;
  final double size;
  @override
  double get width => size + 4.0;

  ImageDanmakuSegment({
    required this.code,
    required this.image,
    required this.size,
  });

  @override
  void dispose() {}
}

/// 红果短剧官方 53 张高清 WebP 弹幕表情管理器
class HongguoEmojiLoader {
  static final Map<String, ui.Image> _cache = {};
  static bool _isInitialized = false;
  static bool get isInitialized => _isInitialized;
  static Completer<void>? _loadingCompleter;

  static final RegExp _emojiRegex =
      RegExp(r'(\[|［)\s*([^\[\]［］]{1,16}?)\s*(\]|］)');

  /// 异步预加载全部 53 张 WebP 表情进 GPU 显存
  static Future<void> preloadAll() async {
    if (_isInitialized) return;
    if (_loadingCompleter != null) return _loadingCompleter!.future;
    final completer = Completer<void>();
    _loadingCompleter = completer;

    try {
      final uniqueFiles = hongguoDanmakuImageMap.values.toSet();
      for (final filename in uniqueFiles) {
        try {
          final data =
              await rootBundle.load('assets/emojis/hongguo/$filename');
          final codec =
              await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          _cache[filename] = frame.image;
        } catch (e) {
          debugPrint('加载红果表情失败: $filename: $e');
        }
      }
      _isInitialized = true;
      debugPrint('红果弹幕高清表情预热完成，共加载 ${_cache.length} 张表情');
    } catch (e) {
      debugPrint('预加载红果表情异常: $e');
    } finally {
      completer.complete();
      _loadingCompleter = null;
    }
  }

  /// 获取表情图片
  static ui.Image? getImage(String codeOrName) {
    final fileName = hongguoDanmakuImageMap[codeOrName] ??
        hongguoDanmakuImageMap['[$codeOrName]'];
    if (fileName == null) return null;
    return _cache[fileName];
  }

  /// 检测文本中是否包含 53 个官方表情之一
  static bool hasEmoji(String text) {
    if (!text.contains('[') && !text.contains('［')) return false;
    final matches = _emojiRegex.allMatches(text);
    for (final m in matches) {
      final name = m.group(2)!.trim();
      if (hongguoDanmakuImageMap.containsKey(name) ||
          hongguoDanmakuImageMap.containsKey('[$name]')) {
        return true;
      }
    }
    return false;
  }

  /// 解析图文分段
  static List<DanmakuSegment> parseSegments({
    required String text,
    required TextStyle style,
    required double fontSize,
  }) {
    final segments = <DanmakuSegment>[];
    if (!hasEmoji(text)) {
      final p = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      segments.add(TextDanmakuSegment(painter: p, width: p.width));
      return segments;
    }

    final emojiSize = fontSize * 1.15;
    int lastIdx = 0;
    final matches = _emojiRegex.allMatches(text);

    for (final m in matches) {
      final start = m.start;
      final end = m.end;
      final name = m.group(2)!.trim();
      final fileName =
          hongguoDanmakuImageMap[name] ?? hongguoDanmakuImageMap['[$name]'];

      if (fileName != null) {
        if (start > lastIdx) {
          final sub = text.substring(lastIdx, start);
          final p = TextPainter(
            text: TextSpan(text: sub, style: style),
            textDirection: TextDirection.ltr,
          )..layout();
          if (p.width > 0) {
            segments.add(TextDanmakuSegment(painter: p, width: p.width));
          } else {
            p.dispose();
          }
        }
        final img = _cache[fileName];
        segments.add(ImageDanmakuSegment(
          code: '[$name]',
          image: img,
          size: emojiSize,
        ));
        lastIdx = end;
      }
    }

    if (lastIdx < text.length) {
      final sub = text.substring(lastIdx);
      final p = TextPainter(
        text: TextSpan(text: sub, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      if (p.width > 0) {
        segments.add(TextDanmakuSegment(painter: p, width: p.width));
      } else {
        p.dispose();
      }
    }

    return segments;
  }
}
