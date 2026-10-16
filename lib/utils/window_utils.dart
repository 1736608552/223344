import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面端（Windows/macOS）原生窗口控制工具
class WindowUtils {
  static const MethodChannel _channel =
      MethodChannel('org.moontechlab.lunatv/window');

  static bool _isFullscreen = false;

  /// 当前是否处于全屏状态
  static bool get isFullscreen => _isFullscreen;

  /// 设置全屏状态（Windows 原生真无边框沉浸全屏）
  static Future<bool> setFullScreen(bool fullScreen) async {
    if (!Platform.isWindows) {
      _isFullscreen = fullScreen;
      return fullScreen;
    }

    try {
      final bool? result = await _channel.invokeMethod<bool>(
        'setFullScreen',
        <String, dynamic>{'fullScreen': fullScreen},
      );
      _isFullscreen = result ?? fullScreen;
      return _isFullscreen;
    } catch (e) {
      debugPrint('[WindowUtils] setFullScreen error: $e');
      _isFullscreen = fullScreen;
      return fullScreen;
    }
  }

  /// 检查原生窗口是否为全屏状态
  static Future<bool> checkNativeFullScreen() async {
    if (!Platform.isWindows) {
      return _isFullscreen;
    }

    try {
      final bool? result = await _channel.invokeMethod<bool>('isFullScreen');
      _isFullscreen = result ?? false;
      return _isFullscreen;
    } catch (e) {
      debugPrint('[WindowUtils] checkNativeFullScreen error: $e');
      return _isFullscreen;
    }
  }
}
