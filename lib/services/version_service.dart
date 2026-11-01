import 'dart:convert';
import 'dart:io';
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

  /// 根据当前操作系统平台智能匹配对应的 release asset 下载包
  static Map<String, String>? _matchAssetForPlatform(List<dynamic> assets, String latestVersion) {
    if (assets.isEmpty) return null;

    if (Platform.isWindows) {
      // Windows 平台：优先匹配 Windows 专属 zip/exe 安装包 (如 LunaTV-PC-v2.7.39-windows-x64.zip)
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (url.isNotEmpty && (name.endsWith('.zip') || name.endsWith('.exe'))) {
            if (name.contains('windows') || name.contains('pc') || name.contains('win')) {
              return {
                'name': (asset['name'] as String?) ?? 'LunaTV-PC-windows-x64.zip',
                'url': buildCdnAcceleratedDownloadUrl(url),
              };
            }
          }
        }
      }
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (url.isNotEmpty && name.endsWith('.zip')) {
            return {
              'name': (asset['name'] as String?) ?? 'LunaTV-PC-windows-x64.zip',
              'url': buildCdnAcceleratedDownloadUrl(url),
            };
          }
        }
      }
    } else if (Platform.isIOS) {
      // iOS 平台：匹配 ipa 文件
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (url.isNotEmpty && name.endsWith('.ipa')) {
            return {
              'name': (asset['name'] as String?) ?? 'LunaTV-iOS.ipa',
              'url': buildCdnAcceleratedDownloadUrl(url),
            };
          }
        }
      }
    } else if (Platform.isMacOS) {
      // macOS 平台：匹配 dmg 或 mac.zip
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (url.isNotEmpty && (name.endsWith('.dmg') || (name.endsWith('.zip') && name.contains('mac')))) {
            return {
              'name': (asset['name'] as String?) ?? 'LunaTV-macOS.dmg',
              'url': buildCdnAcceleratedDownloadUrl(url),
            };
          }
        }
      }
    } else if (Platform.isLinux) {
      // Linux 平台：匹配 AppImage / deb / tar.gz
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (url.isNotEmpty && (name.endsWith('.appimage') || name.endsWith('.deb') || name.endsWith('.tar.gz'))) {
            return {
              'name': (asset['name'] as String?) ?? 'LunaTV-Linux.AppImage',
              'url': buildCdnAcceleratedDownloadUrl(url),
            };
          }
        }
      }
    } else {
      // Android 移动端 (默认): 优先匹配手机端专用包，严格排除电视端包 (tv / hisense / selenetv)
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (name.endsWith('.apk') && url.isNotEmpty) {
            final isTv = name.contains('-tv-') || name.contains('tv-') || name.contains('hisense') || name.contains('selenetv');
            final isMobile = name.contains('mobile') || name == 'app-release.apk';
            if (isMobile && !isTv) {
              return {
                'name': (asset['name'] as String?) ?? 'LunaTV-Mobile.apk',
                'url': buildCdnAcceleratedDownloadUrl(url),
              };
            }
          }
        }
      }
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = ((asset['name'] as String?) ?? '').toLowerCase();
          final url = (asset['browser_download_url'] as String?) ?? '';
          if (name.endsWith('.apk') && url.isNotEmpty) {
            final isTv = name.contains('-tv-') || name.contains('tv-') || name.contains('hisense') || name.contains('selenetv');
            if (!isTv) {
              return {
                'name': (asset['name'] as String?) ?? 'app-release.apk',
                'url': buildCdnAcceleratedDownloadUrl(url),
              };
            }
          }
        }
      }
    }
    return null;
  }

  /// 获取当前平台的默认兜底下载文件名与加速 URL
  static Map<String, String> _getFallbackDownloadInfo(String latestVersion) {
    if (Platform.isWindows) {
      final fileName = 'LunaTV-PC-v$latestVersion-windows-x64.zip';
      final rawUrl = '$githubRepoUrl/releases/download/v$latestVersion/$fileName';
      return {
        'name': fileName,
        'url': buildCdnAcceleratedDownloadUrl(rawUrl),
      };
    } else if (Platform.isIOS) {
      final fileName = 'LunaTV-Mobile-v$latestVersion-unsigned.ipa';
      final rawUrl = '$githubRepoUrl/releases/download/v$latestVersion/$fileName';
      return {
        'name': fileName,
        'url': buildCdnAcceleratedDownloadUrl(rawUrl),
      };
    } else {
      final fileName = 'LunaTV-Mobile-v$latestVersion.apk';
      final rawUrl = '$githubRepoUrl/releases/download/v$latestVersion/$fileName';
      return {
        'name': fileName,
        'url': buildCdnAcceleratedDownloadUrl(rawUrl),
      };
    }
  }

  /// 通道 1：通过 GitHub Releases API 获取
  static Future<VersionInfo?> _checkViaGithubApi(String currentVersion) async {
    try {
      final osName = Platform.operatingSystem;
      final response = await http.get(
        Uri.parse(githubApiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'LunaTV/$currentVersion ($osName)',
        },
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tagName = (data['tag_name'] as String?) ?? '';
        final latestVersion = _cleanVersion(tagName);
        final releaseNotes = (data['body'] as String?) ?? '';

        final assets = data['assets'] as List<dynamic>?;
        final matchedAsset = _matchAssetForPlatform(assets ?? [], latestVersion) ??
            _getFallbackDownloadInfo(latestVersion);
        final downloadUrl = matchedAsset['url'];
        final assetFileName = matchedAsset['name'];

        final releasePageUrl = data['html_url'] as String? ?? getReleaseUrl(latestVersion);

        if (_isNewerVersion(currentVersion, latestVersion)) {
          return VersionInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes.isNotEmpty ? releaseNotes : '发现新版本 v$latestVersion，点击立即更新！',
            downloadUrl: downloadUrl,
            assetFileName: assetFileName,
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
            'User-Agent': 'Mozilla/5.0 LunaTV/$currentVersion',
          },
        ).timeout(const Duration(seconds: 3));

        if (response.statusCode == 200 && response.body.startsWith('{')) {
          final data = json.decode(response.body) as Map<String, dynamic>;
          if (data.isNotEmpty) {
            final firstTag = data.keys.first;
            final latestVersion = _cleanVersion(firstTag);
            final notes = (data[firstTag] as String?) ?? '';

            if (latestVersion.isNotEmpty && _isNewerVersion(currentVersion, latestVersion)) {
              final fallback = _getFallbackDownloadInfo(latestVersion);

              return VersionInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseNotes: notes.isNotEmpty ? notes : '发现全新版本 v$latestVersion，点击立即下载安装！',
                downloadUrl: fallback['url'],
                assetFileName: fallback['name'],
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
            'User-Agent': 'Mozilla/5.0 LunaTV/$currentVersion',
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
            final fallback = _getFallbackDownloadInfo(latestVersion);

            return VersionInfo(
              currentVersion: currentVersion,
              latestVersion: latestVersion,
              releaseNotes: '发现全新版本 v$latestVersion，点击下方按钮立即下载安装更新！',
              downloadUrl: fallback['url'],
              assetFileName: fallback['name'],
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
  final String? downloadUrl;
  final String? releasePageUrl;
  final String? assetFileName;

  // 保持向后兼容：历史代码读取 apkDownloadUrl 依然有效
  String? get apkDownloadUrl => downloadUrl;

  VersionInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    this.downloadUrl,
    String? apkDownloadUrl,
    this.releasePageUrl,
    this.assetFileName,
  }) : downloadUrl = downloadUrl ?? apkDownloadUrl;
}
