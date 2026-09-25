import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

class VersionService {
  static const String githubRepoUrl = 'https://github.com/djsevenx1/LunaTV-Mobile';
  static const String githubApiUrl = 'https://api.github.com/repos/djsevenx1/LunaTV-Mobile/releases/latest';
  static const String _dismissedVersionKey = 'dismissed_version';

  // 极速高可用 CDN 镜像源列表（国内免梯秒连）
  static const List<String> _cdnPubspecMirrors = [
    'https://fastly.jsdelivr.net/gh/djsevenx1/LunaTV-Mobile@main/pubspec.yaml',
    'https://testingcf.jsdelivr.net/gh/djsevenx1/LunaTV-Mobile@main/pubspec.yaml',
    'https://cdn.jsdelivr.net/gh/djsevenx1/LunaTV-Mobile@main/pubspec.yaml',
    'https://raw.githubusercontent.com/djsevenx1/LunaTV-Mobile/main/pubspec.yaml',
  ];

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
      final apiUrl = UserDataService.buildGithubApiUrl(githubApiUrl);
      final response = await http.get(
        Uri.parse(apiUrl),
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
          for (final asset in assets) {
            if (asset is Map<String, dynamic>) {
              final name = (asset['name'] as String?) ?? '';
              final url = (asset['browser_download_url'] as String?) ?? '';
              if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
                apkDownloadUrl = UserDataService.buildGithubReleaseAssetUrl(url);
                break;
              }
            }
          }
        }
        apkDownloadUrl ??= UserDataService.buildGithubReleaseAssetUrl(
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

  /// 通道 2：通过 jsDelivr 全球加速 CDN 读取最新版本号（国内直连毫秒级响应）
  static Future<VersionInfo?> _checkViaCdnMirrors(String currentVersion) async {
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
            final apkUrl = UserDataService.buildGithubReleaseAssetUrl(rawDownloadUrl);

            return VersionInfo(
              currentVersion: currentVersion,
              latestVersion: latestVersion,
              releaseNotes: '发现全新版本 v$latestVersion，点击下方按钮立即下载安装更新！',
              apkDownloadUrl: apkUrl,
              releasePageUrl: getReleaseUrl(latestVersion),
            );
          }
          // 如果解析成功且不需要更新，直接退出循环
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
