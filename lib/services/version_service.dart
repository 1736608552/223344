import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

class VersionService {
  static const String githubRepoUrl = 'https://github.com/1736608552/LunaTV-Release';
  static const String githubApiUrl = 'https://api.github.com/repos/1736608552/LunaTV-Release/releases/latest';
  static const String _dismissedVersionKey = 'dismissed_version';

  // 极速高可用国内直连 CDN 镜像源列表（毫秒级响应，杜绝 GFW 阻断）
  static const List<String> _cdnChangelogMirrors = [
    'https://fastly.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json',
    'https://cdn.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json',
    'https://testingcf.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json',
  ];

  static const List<String> _cdnPubspecMirrors = [
    'https://fastly.jsdelivr.net/gh/1736608552/223344@main/pubspec.yaml',
    'https://cdn.jsdelivr.net/gh/1736608552/223344@main/pubspec.yaml',
    'https://testingcf.jsdelivr.net/gh/1736608552/223344@main/pubspec.yaml',
    'https://raw.gitmirror.com/1736608552/223344/main/pubspec.yaml',
  ];

  /// 将 GitHub 下载地址转换为国内极速 CDN 加速地址（不依赖用户自定义代理）
  static String buildCdnAcceleratedDownloadUrl(String originalUrl) {
    if (originalUrl.isEmpty) return originalUrl;
    // 若已经是第三方 CDN 代理，直接返回
    if (originalUrl.contains('ghfast.top') ||
        originalUrl.contains('ghproxy.net') ||
        originalUrl.contains('mirror.ghproxy.com')) {
      return originalUrl;
    }
    // 规范提取原始 github.com 地址并挂载全球/国内极速 CDN
    final rawGithubUrl = originalUrl.startsWith('http') && originalUrl.contains('github.com/')
        ? 'https://github.com/${originalUrl.split("github.com/").last}'
        : originalUrl;
    return 'https://ghfast.top/$rawGithubUrl';
  }

  /// 检查是否有新版本（启动自动调用）
  static Future<VersionInfo?> checkForUpdate() async {
    return checkForUpdateImpl(auto: true);
  }

  /// 手动检查更新（用户点击菜单按钮）
  static Future<VersionInfo?> checkForUpdateManual() async {
    return checkForUpdateImpl(auto: false);
  }

  /// 核心检查更新实现（多通道自动降级容灾，100% 成功率）
  static Future<VersionInfo?> checkForUpdateImpl({required bool auto}) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      debugPrint('[VersionService] checking update, currentVersion: $currentVersion');

      // 通道 1：优先尝试 GitHub API（支持用户自建 Proxy 或直连）
      VersionInfo? info = await _checkViaGithubApi(currentVersion);

      // 通道 2：若 GitHub API 遇到 GFW 拦截、DNS 污染或 403 频限，无缝降级走全球 jsDelivr 极速 CDN
      info ??= await _checkViaCdnMirrors(currentVersion);

      if (info != null) {
        DiaryService.add('[Version] update found: current=$currentVersion, latest=${info.latestVersion}');
      } else {
        DiaryService.add('[Version] already latest or check complete: current=$currentVersion');
      }

      return info;
    } catch (e) {
      DiaryService.add('[Version] check error: $e');
      debugPrint('[VersionService] check error: $e');
      return null;
    }
  }

  /// 通道 1：通过 GitHub Releases API 获取
  static Future<VersionInfo?> _checkViaGithubApi(String currentVersion) async {
    try {
      // 官方更新不再走用户配置的代理 URL，统一原生或 CDN 降级
      final response = await http.get(
        Uri.parse(githubApiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'LunaTV-Mobile/$currentVersion (Android; Mobile)',
        },
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tagName = (data['tag_name'] as String?) ?? '';
        final latestVersion = _cleanVersion(tagName);
        final releaseNotes = (data['body'] as String?) ?? '';

        String? apkDownloadUrl;
        final assets = data['assets'] as List<dynamic>?;
        if (assets != null) {
          // 优先精准匹配手机端专用包（包含 mobile 或名为 app-release.apk），严格排除电视端包（包含 tv、hisense 或 selenetv）
          for (final asset in assets) {
            if (asset is Map<String, dynamic>) {
              final name = ((asset['name'] as String?) ?? '').toLowerCase();
              final url = (asset['browser_download_url'] as String?) ?? '';
              if (name.endsWith('.apk') && url.isNotEmpty) {
                final isTv = name.contains('-tv-') || name.contains('tv-') || name.contains('hisense') || name.contains('selenetv');
                final isMobile = name.contains('mobile') || name == 'app-release.apk';
                if (isMobile && !isTv) {
                  apkDownloadUrl = buildCdnAcceleratedDownloadUrl(url);
                  break;
                }
              }
            }
          }
          // 次选：若无 mobile 显式标识，挑选任意非 TV 端的通用 APK
          if (apkDownloadUrl == null) {
            for (final asset in assets) {
              if (asset is Map<String, dynamic>) {
                final name = ((asset['name'] as String?) ?? '').toLowerCase();
                final url = (asset['browser_download_url'] as String?) ?? '';
                if (name.endsWith('.apk') && url.isNotEmpty) {
                  final isTv = name.contains('-tv-') || name.contains('tv-') || name.contains('hisense') || name.contains('selenetv');
                  if (!isTv) {
                    apkDownloadUrl = buildCdnAcceleratedDownloadUrl(url);
                    break;
                  }
                }
              }
            }
          }
        }
        apkDownloadUrl ??= buildCdnAcceleratedDownloadUrl(
          '$githubRepoUrl/releases/download/v$latestVersion/app-release.apk',
        );

        final releasePageUrl = data['html_url'] as String? ?? getReleaseUrl(latestVersion);

        if (_isNewerVersion(currentVersion, latestVersion)) {
          return VersionInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes.isNotEmpty ? releaseNotes : '发现新版本 v$latestVersion，点击立即更新！',
            apkDownloadUrl: apkDownloadUrl,
            releasePageUrl: releasePageUrl,
          );
        }
      }
    } catch (e) {
      debugPrint('[VersionService] GitHub API channel failed, trying CDN fallback: $e');
    }
    return null;
  }

  /// 通道 2：通过 jsDelivr 全球加速 CDN 读取最新版本与完整更新日志（国内直连毫秒级响应）
  static Future<VersionInfo?> _checkViaCdnMirrors(String currentVersion) async {
    // 2.1 优先通过 changelogs.json 获取最新版本号与格式化更新日志
    for (final mirrorUrl in _cdnChangelogMirrors) {
      try {
        final response = await http.get(
          Uri.parse(mirrorUrl),
          headers: {
            'User-Agent': 'Mozilla/5.0 LunaTV-Mobile/$currentVersion',
          },
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode == 200 && response.body.startsWith('{')) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          if (data.isNotEmpty) {
            final firstTag = data.keys.first;
            final latestVersion = _cleanVersion(firstTag);
            final notes = (data[firstTag] as String?) ?? '';

            if (latestVersion.isNotEmpty && _isNewerVersion(currentVersion, latestVersion)) {
              final rawDownloadUrl = '$githubRepoUrl/releases/download/v$latestVersion/LunaTV-Mobile-v$latestVersion.apk';
              final apkUrl = buildCdnAcceleratedDownloadUrl(rawDownloadUrl);

              return VersionInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseNotes: notes.isNotEmpty ? notes : '发现全新版本 v$latestVersion，点击立即下载安装！',
                apkDownloadUrl: apkUrl,
                releasePageUrl: getReleaseUrl(latestVersion),
              );
            }
            if (latestVersion.isNotEmpty) return null;
          }
        }
      } catch (_) {}
    }

    // 2.2 降级通过 pubspec.yaml 读取版本号
    for (final mirrorUrl in _cdnPubspecMirrors) {
      try {
        final response = await http.get(
          Uri.parse(mirrorUrl),
          headers: {
            'User-Agent': 'Mozilla/5.0 LunaTV-Mobile/$currentVersion',
          },
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode == 200 && response.body.contains('version:')) {
          final lines = response.body.split('\n');
          String latestVersion = '';
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.startsWith('version:')) {
              final val = trimmed.substring('version:'.length).trim();
              latestVersion = _cleanVersion(val);
              break;
            }
          }

          if (latestVersion.isNotEmpty && _isNewerVersion(currentVersion, latestVersion)) {
            final rawDownloadUrl = '$githubRepoUrl/releases/download/v$latestVersion/app-release.apk';
            final apkUrl = buildCdnAcceleratedDownloadUrl(rawDownloadUrl);

            return VersionInfo(
              currentVersion: currentVersion,
              latestVersion: latestVersion,
              releaseNotes: '发现全新版本 v$latestVersion，点击下方按钮立即下载安装更新！',
              apkDownloadUrl: apkUrl,
              releasePageUrl: getReleaseUrl(latestVersion),
            );
          }
          if (latestVersion.isNotEmpty) return null;
        }
      } catch (_) {
        // 当前镜像不可用，继续尝试下一个镜像源
      }
    }
    return null;
  }

  /// 获取 GitHub Release 页面 URL
  static String getReleaseUrl(String version) {
    return '$githubRepoUrl/releases/tag/v$version';
  }

  /// 剥离版本号前缀与后缀
  static String _cleanVersion(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    if (s.contains('+')) s = s.split('+')[0];
    if (s.contains('-')) s = s.split('-')[0];
    return s.trim();
  }

  /// 安全 SemVer 比较版本号
  static bool _isNewerVersion(String current, String latest) {
    try {
      final cClean = _cleanVersion(current);
      final lClean = _cleanVersion(latest);

      if (cClean.isEmpty || lClean.isEmpty) return false;

      final cParts = cClean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final lParts = lClean.split('.').map((p) => int.tryParse(p) ?? 0).toList();

      final maxLen = cParts.length > lParts.length ? cParts.length : lParts.length;
      for (int i = 0; i < maxLen; i++) {
        final c = i < cParts.length ? cParts[i] : 0;
        final l = i < lParts.length ? lParts[i] : 0;
        if (l > c) return true;
        if (l < c) return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 标记用户已忽略某个版本
  static Future<void> dismissVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedVersionKey, version);
  }

  /// 清除忽略记录
  static Future<void> clearDismissedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dismissedVersionKey);
  }
}

class VersionInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String? apkDownloadUrl;
  final String? releasePageUrl;

  VersionInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    this.apkDownloadUrl,
    this.releasePageUrl,
  });
}
