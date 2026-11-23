# 执行与自测记录 (v2.7.85)

## 1. 代码修改实施
1. **清理选源详情页顶部爬虫图标**：
   - 目标文件：`lib/screens/player_screen.dart:5163-5170`
   - 移除 `_buildTopBar` 中右侧的 `IconButton(tooltip: '播放诊断与日记', icon: const Icon(Icons.bug_report_outlined...)...)`；
2. **清理选集旁浅蓝色日记胶囊**：
   - 目标文件：`lib/screens/player_screen.dart:5707-5730`
   - 移除 `_buildEpisodeSection` 中 `_buildSectionTitle('选集', isDark)` 右侧的 `InkWell(child: Container(... Icons.terminal_rounded ... '日记'))`；
3. **保留播放控件内部日记与诊断**：
   - 播放设置齿轮面板 `_showSettingsSheet` 中的“播放日志 / 诊断”（第 6810 行）；
   - 居中错误卡片上的“查看播放日记”与“一键复制日记”（第 4377、4398 行）；
   - 播放器内置覆盖层控件（第 8153 行）。
4. **版本号与更新日志对齐**：
   - `pubspec.yaml`：更新为 `2.7.85+20885`；
   - `.github/changelogs.json`：新增 `v2.7.85` 发版说明。

## 2. 验证与审查
- `git diff` 验证无多余修改或语法截断；
- 代码自检：所有控件层级与闭合括号完全一致，无语法与类型隐患。
