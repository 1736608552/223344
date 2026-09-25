import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2.0.99.2: 应用内「日记」服务 — 维护一个内存 List<String> 日志, 失败 / 关键事件
///   都打进去, 用户菜单「日记」行跳到 DiaryScreen 看到全流程. 跟 adb logcat
///   互补: adb logcat 是开发者视角, 日记是普通用户视角 (不用接电脑). 跟
///   v2.0.91 删的「log UI」区别: 那个是开发者 log 实时浮层 ([VideoProxy] xxx 一直
///   滚), 这次是独立日记页面 (按时间序, 用户主动点开, 不打扰).
///
/// v2.1.22: 加 3 个可配项 (用户在「设置」里调):
///   - 退出 app 自动清空 (默认 true, 跟 v2.0.99.2 行为一致)
///   - 容量上限 (默认 500, 范围 100/500/1000/2000)
///   - 持久化 (默认 false, 不跨会话; 开启后写到 SharedPreferences, 跨会话保留)
///
/// 用法 (调用方):
///   - `DiaryService.add('[TMDB] search: title="X" year=2025')` — 成功路径
///   - `DiaryService.add('[TMDB] error: $e')` — 失败路径
///   - `DiaryService.add('[Network] timeout after 6s')` — 网络错
///   - `DiaryService.onAppExit()` — App 生命周期 onExit 时调, 按 _clearOnExit 决定清不清
///
/// 设计取舍:
///   - **单例 + 内存 List<String>**: 简单, 默认不存盘 (失败排查是会话内的事, 退出 app
///     清空合理). 持久化开关打开后才写 SharedPreferences, 跟 v2.0.93 TMDB 缓存命名空间一致
///   - **容量可配 100/500/1000/2000**: 100 给内存紧的设备, 2000 给排查复杂问题的用户
///   - **持久化默认 false**: TMDB search title 是用户私人观影记录, 默认不跨会话保留
///   - **格式 '[分类] 描述'**: 跟 v2.0.95 debugPrint `[TMDB] xxx` 风格一致, 日记
///     里直接看, 不用前端加分类列
///   - **同时打 debugPrint**: 跟 v2.0.95 行为一致, adb logcat 仍能看到全流程
class DiaryService {
  static final List<String> _entries = <String>[];
  static const int _defaultMaxEntries = 500;
  static const int _maxMaxEntries = 2000;
  static const int _minMaxEntries = 100;

  // v2.1.22: 可配项 (从 SharedPreferences 读, 启动时 loadConfig 加载)
  static int _maxEntries = _defaultMaxEntries;
  static bool _clearOnExit = true;
  static bool _persist = false;
  static bool _loaded = false;

  static const String _kMaxEntries = 'diary_max_entries';
  static const String _kClearOnExit = 'diary_clear_on_exit';
  static const String _kPersist = 'diary_persist';
  static const String _kEntries = 'diary_entries_v1';

  /// v2.1.22: 启动时调一次, 从 SharedPreferences 加载配置 + 可选加载历史日记.
  /// 在 main.dart 的 WidgetsFlutterBinding.ensureInitialized() 之后调.
  static Future<void> loadConfig() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _maxEntries = (prefs.getInt(_kMaxEntries) ?? _defaultMaxEntries)
        .clamp(_minMaxEntries, _maxMaxEntries);
    _clearOnExit = prefs.getBool(_kClearOnExit) ?? true;
    _persist = prefs.getBool(_kPersist) ?? false;
    if (_persist) {
      final raw = prefs.getStringList(_kEntries) ?? <String>[];
      _entries.clear();
      _entries.addAll(raw);
      // 加载后按当前容量上限截断
      if (_entries.length > _maxEntries) {
        _entries.removeRange(0, _entries.length - _maxEntries);
      }
    }
    _loaded = true;
  }

  /// 加一条日记, 自动 prepend 时间戳, FIFO 容量限制.
  /// 调用方写 `[分类] 描述` (e.g. `[TMDB] search: title="X" year=2025`).
  static Future<void> add(String message) async {
    final ts = DateTime.now().toIso8601String().substring(11, 19); // HH:mm:ss
    final entry = '[$ts] $message';
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // 跟 v2.0.95 行为一致, debugPrint 保留给 adb 开发者
    debugPrint('[Diary] $message');
    if (_persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kEntries, _entries);
    }
  }

  /// 清空日记 (UI 上有「清空」按钮调这个).
  static Future<void> clear() async {
    _entries.clear();
    if (_persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kEntries);
    }
  }

  /// v2.1.22: 单条删除 (UI 上长按菜单调). 按文本精确匹配删第一条.
  static Future<void> removeEntry(String entry) async {
    final idx = _entries.indexOf(entry);
    if (idx >= 0) {
      _entries.removeAt(idx);
      if (_persist) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_kEntries, _entries);
      }
    }
  }

  /// v2.1.22: App 退出时调 (e.g. main.dart 监听 AppLifecycleState.detached),
  /// 根据 _clearOnExit 决定清不清. 持久化开启时 _clearOnExit 仍生效 (清内存, 写
  /// 盘会保留之前的, 但 next start 加载时清空).
  static Future<void> onAppExit() async {
    if (_clearOnExit) {
      _entries.clear();
      if (_persist) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kEntries);
      }
    }
  }

  /// 拿全部日记 (UI 上 ListView 显示).
  /// 返回 copy, 调用方不能改内部 List.
  static List<String> getAll() {
    return List<String>.from(_entries);
  }

  /// 当前条数 (UI 顶部显示「共 N 条」).
  static int get length => _entries.length;
  static int get maxEntries => _maxEntries;
  static bool get clearOnExit => _clearOnExit;
  static bool get persist => _persist;

  /// v2.1.22: 设置容量上限 (100/500/1000/2000). 立即 truncate 超量部分.
  static Future<void> setMaxEntries(int value) async {
    _maxEntries = value.clamp(_minMaxEntries, _maxMaxEntries);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxEntries, _maxEntries);
    if (_persist) {
      await prefs.setStringList(_kEntries, _entries);
    }
  }

  /// v2.1.22: 设置「退出 app 自动清空」开关.
  static Future<void> setClearOnExit(bool value) async {
    _clearOnExit = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kClearOnExit, value);
  }

  /// v2.1.22: 设置「持久化」开关. 打开时立即把当前 _entries 写到 SharedPreferences.
  /// 关闭时清 SharedPreferences 里存的日记.
  static Future<void> setPersist(bool value) async {
    _persist = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPersist, value);
    if (value) {
      await prefs.setStringList(_kEntries, _entries);
    } else {
      await prefs.remove(_kEntries);
    }
  }
}
