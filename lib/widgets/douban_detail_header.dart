import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/luna_cache_manager.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// 沉浸式影视大头部 (支持 TMDB 16:9 高清 Backdrop / 豆瓣剧照 + 高清立体海报)
class DoubanDetailHeader extends StatefulWidget {
  final String title;
  final String? year;
  final String cover;
  final String source;
  final String? sourceName;
  final String? coverUrl;
  final String? tmdbBackdropUrl;
  final String? rate;
  final String? summary;
  final Widget? castOverlay;
  final VoidCallback? onPlayPressed;

  const DoubanDetailHeader({
    super.key,
    required this.title,
    this.year,
    required this.cover,
    required this.source,
    this.sourceName,
    this.coverUrl,
    this.tmdbBackdropUrl,
    this.rate,
    this.summary,
    this.castOverlay,
    this.onPlayPressed,
  });

  @override
  State<DoubanDetailHeader> createState() => _DoubanDetailHeaderState();
}

class _DoubanDetailHeaderState extends State<DoubanDetailHeader> {
  bool _summaryExpanded = false;

  /// 背景 URL 优先级:
  /// 1) tmdbBackdropUrl (TMDB w1280 16:9 高清剧照, 精准匹配)
  /// 2) coverUrl (豆瓣 16:9 横版剧照 l_cover 1280x720)
  /// 3) cover (豆瓣 2:3 竖版海报兜底)
  Future<String> _backgroundUrl() async {
    if (widget.tmdbBackdropUrl != null && widget.tmdbBackdropUrl!.isNotEmpty) {
      return getImageUrl(widget.tmdbBackdropUrl!, 'tmdb');
    }
    if (widget.coverUrl != null && widget.coverUrl!.isNotEmpty) {
      return getDoubanCoverUrl(widget.coverUrl!);
    }
    return getImageUrl(widget.cover, widget.source);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    final isTablet = MediaQuery.of(context).size.width >= 600;

    if (widget.cover.isEmpty && widget.title.isEmpty) {
      return const SizedBox.shrink();
    }

    final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBgColor = isDark ? const Color(0xFF1E293B) : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 顶部全幅大背景 + 立体海报与影视主信息
        _buildHeroSection(isDark, isTablet, bgColor),

        // 2. 剧情简介 (优雅排版 + 展开收起)
        if (widget.summary != null && widget.summary!.trim().isNotEmpty)
          _buildSummarySection(isDark, cardBgColor),

        // 3. 演职员表 (TMDB 演员横滑列表)
        if (widget.castOverlay != null)
          _buildCastSection(isDark, cardBgColor),
      ],
    );
  }

  /// 顶部 Hero 沉浸大背景与前景卡片
  Widget _buildHeroSection(bool isDark, bool isTablet, Color bgColor) {
    final heroHeight = isTablet ? 340.0 : 280.0;
    final posterW = isTablet ? 145.0 : 120.0;
    final posterH = isTablet ? 215.0 : 175.0;

    return SizedBox(
      height: heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A. 背景剧照 (带平滑暗度消融渐变)
          FutureBuilder<String>(
            future: _backgroundUrl(),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? widget.cover;
              final headers = getImageRequestHeaders(imageUrl, widget.source);
              return CachedNetworkImage(
                imageUrl: imageUrl,
                cacheManager: LunaCacheManager.instance,
                fit: BoxFit.cover,
                httpHeaders: headers,
                placeholder: (c, u) => Container(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                errorWidget: (c, u, e) => Container(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
              );
            },
          ),

          // B. 多层质感渐变蒙版
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.40),
                  Colors.black.withOpacity(0.65),
                  bgColor.withOpacity(0.92),
                  bgColor,
                ],
                stops: const [0.0, 0.45, 0.85, 1.0],
              ),
            ),
          ),

          // C. 前景：高清立体海报 + 右侧核心信息
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 1) 左侧 3D 立体质感海报
                Container(
                  width: posterW,
                  height: posterH,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.25),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: FutureBuilder<String>(
                      future: getImageUrl(widget.cover, widget.source),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? widget.cover;
                        final headers = getImageRequestHeaders(imageUrl, widget.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          cacheManager: LunaCacheManager.instance,
                          fit: BoxFit.cover,
                          httpHeaders: headers,
                          memCacheWidth: (posterW * MediaQuery.of(context).devicePixelRatio).round(),
                          memCacheHeight: (posterH * MediaQuery.of(context).devicePixelRatio).round(),
                          placeholder: (c, u) => Container(
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                          ),
                          errorWidget: (c, u, e) => Container(
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                            child: const Icon(Icons.movie_outlined, color: Colors.grey, size: 44),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // 2) 右侧核心元数据 + 快捷播放按钮
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 主标题
                      Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1.25,
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 8, offset: Offset(0, 2)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // 标签矩阵 (评分 + 年份 + 默认源)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (widget.rate != null && widget.rate!.isNotEmpty)
                            _buildRatingBadge(widget.rate!),
                          if (widget.year != null && widget.year!.isNotEmpty)
                            _buildGlassTag(widget.year!),
                          if (widget.sourceName != null && widget.sourceName!.isNotEmpty)
                            _buildSourceTag(widget.sourceName!),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 快捷开播主按钮
                      if (widget.onPlayPressed != null)
                        InkWell(
                          onTap: widget.onPlayPressed,
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF10B981), Color(0xFF059669)],
                              ),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF10B981).withOpacity(0.35),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                                SizedBox(width: 4),
                                Text(
                                  '立即开播',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 金橙色评分胶囊
  Widget _buildRatingBadge(String rate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withOpacity(0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 13, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            rate,
            style: const TextStyle(
              fontSize: 11.5,
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// 磨砂玻璃质感年份标签
  Widget _buildGlassTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 默认源标签
  Widget _buildSourceTag(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_outlined, size: 12, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.9),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 剧情简介模块
  Widget _buildSummarySection(bool isDark, Color cardBgColor) {
    final summary = widget.summary!.trim();
    final isLong = summary.length > 90;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.2 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 3.5,
                  height: 13,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF059669)],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '剧情简介',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: isLong ? () => setState(() => _summaryExpanded = !_summaryExpanded) : null,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    maxLines: isLong && !_summaryExpanded ? 3 : null,
                    overflow: isLong && !_summaryExpanded ? TextOverflow.ellipsis : TextOverflow.visible,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: isDark ? Colors.white.withOpacity(0.8) : const Color(0xFF475569),
                    ),
                  ),
                  if (isLong) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _summaryExpanded ? '收起简介' : '展开全部',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF10B981),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Icon(
                          _summaryExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: const Color(0xFF10B981),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 演职员表模块
  Widget _buildCastSection(bool isDark, Color cardBgColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.2 : 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 3.5,
                  height: 13,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF059669)],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '演职员表',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            widget.castOverlay!,
          ],
        ),
      ),
    );
  }
}
