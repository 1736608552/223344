# 紧急修复 Android 与 TV 端 CI 构建语法错误实施方案

## 一、故障定位（Source-first 铁证）
1. **Signer.kt 双引号逃逸语法错误**：
   - 报错位置：`android/.../Signer.kt:179` 与 `tv/.../Signer.kt:179`；
   - 错误表现：`f(24, "{"cmr":...}")` 内部 JSON 双引号未转义，导致 Kotlin 编译器误将其识别为 `do-while` 循环语法，报 `Syntax error: Expecting 'while'` / `Unresolved reference 'tk'`；
   - 修复方案：采用 Kotlin 原生三引号 `"""{"cmr":...}"""` 彻底消除转义歧义。

2. **DeviceRegister.kt 非法非内联 return 错误**：
   - 报错位置：`android/.../DeviceRegister.kt:158` 与 `tv/.../DeviceRegister.kt:158`；
   - 错误表现：在非内联泛型高阶函数 `RequestScope.execute` 的 lambda 参数内使用 `return Registered(...)`，报 `'return' is prohibited here` 错误；
   - 修复方案：解耦为局部结果表达式解耦赋值 `val registered = RequestScope.execute(...) { ... }`，若非空再在函数体顶层返回。

## 二、修复清单与发布规划
1. 修复移动端与 TV 端 `Signer.kt`；
2. 修复移动端与 TV 端 `DeviceRegister.kt`；
3. 更新 `pubspec.yaml`、`FIXLOG.md`、`.github/changelogs.json` 为 `v2.7.60+20860`；
4. 提交并推送 Tag `v2.7.60`，触发全平台 CI 构建自动发布至 Release 仓库。
