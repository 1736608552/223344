package org.moontechlab.selenetv.ui

import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.view.View
import android.view.ViewParent
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import org.moontechlab.selenetv.BuildConfig

/**
 * 车机包专用：把承载播放页的 Dialog 窗口本身铺成「整屏 + 不透明黑 + 沉浸式」。
 *
 * 背景：播放页是独立 Dialog 窗口（为了焦点隔离）。Dialog 默认 `decorFitsSystemWindows = true`，
 * 窗口尺寸又是 WRAP_CONTENT —— DecorView 先按系统栏 inset 收缩，内容再按收缩后的上限铺满，
 * 于是播放页窗口只有「屏高 − 上栏 − 下栏」，居中摆放后上下各露一条，缝里直通下层窗口。
 * 竖屏短剧左右本来就是黑边（pillarbox），所以现象恰好是「两边黑正常，上下露底」。
 *
 * 这里从窗口层修：窗口强制 MATCH_PARENT、DecorView 不再消费 inset、窗口背景置纯黑兜底、
 * 再收一次系统栏。Compose 侧布局一行不动。
 *
 * TV 包 [BuildConfig.CAR_TOUCH] = false，本函数立刻返回，Dialog 窗口与旧版完全一致。
 */
@Composable
fun CarDialogFullscreen() {
    if (!BuildConfig.CAR_TOUCH) return
    val view = LocalView.current
    DisposableEffect(view) {
        val window = view.dialogWindow()
        val controller = window?.let { applyCarDialogWindow(it) }
        val focusListener = if (controller == null) {
            null
        } else {
            ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
                // 弹窗自己拿到焦点时系统栏可能复原，再收一次（只作用于本窗口）
                if (hasFocus) controller.hide(WindowInsetsCompat.Type.systemBars())
            }.also { view.viewTreeObserver.addOnWindowFocusChangeListener(it) }
        }
        onDispose {
            focusListener?.let { view.viewTreeObserver.removeOnWindowFocusChangeListener(it) }
        }
    }
    // Compose 的 DialogWrapper 在 onStart 里还会再写一次窗口参数，稳妥起见等第一帧后再压一次尺寸。
    LaunchedEffect(view) {
        withFrameNanos { }
        view.dialogWindow()?.setLayout(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
        )
    }
}

/** 应用车机播放弹窗的窗口属性，返回该窗口的 insets 控制器（供焦点变化时再收系统栏）。 */
private fun applyCarDialogWindow(window: Window): WindowInsetsControllerCompat {
    window.setBackgroundDrawable(ColorDrawable(0xFF000000.toInt()))
    // 关键：Dialog 窗口默认 WRAP_CONTENT，内容填满也只能填到「测量上限」，
    // 窗口本身不会因此变大。显式 MATCH_PARENT 才能真正铺满整屏。
    window.setLayout(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.MATCH_PARENT,
    )
    WindowCompat.setDecorFitsSystemWindows(window, false)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        // 与 Activity 侧保持一致：不主动画进 cutout，避免顶到车机的半透明 HUD 条底下
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
        }
    }
    return WindowInsetsControllerCompat(window, window.decorView).apply {
        systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        hide(WindowInsetsCompat.Type.systemBars())
    }
}

/** 从 Dialog 内容视图向上找到承载它的窗口（Compose 的 Dialog 根容器实现了 DialogWindowProvider）。 */
private fun View.dialogWindow(): Window? {
    var p: ViewParent? = parent
    while (p != null) {
        if (p is DialogWindowProvider) return p.window
        p = p.parent
    }
    return null
}
