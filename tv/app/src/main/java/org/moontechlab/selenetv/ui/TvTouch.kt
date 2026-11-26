package org.moontechlab.selenetv.ui

import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.tv.material3.ClickableSurfaceBorder
import androidx.tv.material3.ClickableSurfaceColors
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ClickableSurfaceScale
import androidx.tv.material3.ClickableSurfaceShape
import androidx.tv.material3.Surface as TvMaterialSurface
import org.moontechlab.selenetv.BuildConfig

/**
 * v2.8.0：车机触摸屏支持（触摸 / 遥控 双通路并存）
 *
 * 为什么需要这一层：tv-material 1.1.0-alpha01 的 `Surface(onClick)` 内部只挂了
 * `handleDPadEnter` + `focusable`（见库内 `SurfaceClickableUtils.tvClickable`），
 * 整个组件没有任何 pointerInput —— 于是遥控器 OK 能点，手指点上去毫无反应。
 *
 * 设计红线：**只加触摸，绝不动遥控器**。
 * - 这里只往 Modifier 链上追加一个 pointerInput；按键事件（KeyEvent）永远不会进入
 *   pointerInput，也不经过 detectTapGestures，所以遥控器/网络遥控的按键通路
 *   （handleDPadEnter、focusable、onKeyEvent、focusProperties、焦点顺序）一行未改。
 * - 不调用 `clickable`（它会额外注册 focusable + 按键点击，与 handleDPadEnter 抢 OK 键）。
 * - 触摸不 requestFocus：手指点完，焦点仍在原处，遥控器接着用时的落点与之前完全一致。
 *
 * 触摸侧还会顺带满足列表拖动：detectTapGestures 只在「按下→抬起且未移动」时判定点击，
 * 手指一滑就退出识别，纵向滚动/横向翻行仍由父级 scrollable 接管。
 */
@Composable
fun Modifier.tvTouchTap(
    enabled: Boolean = true,
    onLongPress: (() -> Unit)? = null,
    onClick: () -> Unit,
): Modifier {
    val latestOnClick = rememberUpdatedState(onClick)
    val latestOnLongPress = rememberUpdatedState(onLongPress)
    // 车机包才挂 pointerInput；TV 包的 Modifier 链与加触摸之前完全一致（零成本、零行为差异）。
    if (!BuildConfig.CAR_TOUCH || !enabled) return this
    return this.pointerInput(enabled) {
        detectTapGestures(
            onTap = { latestOnClick.value() },
            onLongPress = { latestOnLongPress.value?.invoke() },
        )
    }
}

/**
 * 带命中坐标的触摸点击：给「容器自己按坐标判断点到哪个子项」的场景用
 * （TabSwitcher 的兜底就是用它在标签条上做 x 轴命中，见 TabSwitcher.kt）。
 * 同样只在车机包启用，TV 包直接原样返回。
 */
@Composable
fun Modifier.tvTouchTapAt(
    enabled: Boolean = true,
    onTap: (androidx.compose.ui.geometry.Offset) -> Unit,
): Modifier {
    val latestOnTap = rememberUpdatedState(onTap)
    if (!BuildConfig.CAR_TOUCH || !enabled) return this
    return this.pointerInput(enabled) {
        detectTapGestures(onTap = { pos -> latestOnTap.value(pos) })
    }
}

/**
 * 车机包才挂的 pointerInput。
 *
 * 播放页的「点画面播放/暂停」「进度条拖动」这类底层手势是直接写的 pointerInput，
 * 这里统一收口：TV 包直接返回原 Modifier —— 连指针节点都不创建，与加触摸之前的
 * 版本完全一致；车机包才真正注册。
 */
fun Modifier.tvPointerInput(
    key: Any? = Unit,
    block: suspend androidx.compose.ui.input.pointer.PointerInputScope.() -> Unit,
): Modifier = if (!BuildConfig.CAR_TOUCH) this else this.pointerInput(key, block)

/**
 * 控制条淡出后仍在组合中（`graphicsLayer { alpha = 0f }` 只改透明度，照样能命中），
 * 手指落在这一层时会点到那些「看不见的胶囊按钮」。本修饰符在控制条隐藏期间把这一层的
 * 指针事件全部吞掉，并只当成一次「唤起控制条」——按键事件不进 pointerInput，
 * 遥控器在控制条隐藏时的行为（任意键只唤起控制条）完全不变。
 *
 * @param hidden 控制条当前是否处于隐藏态（alpha≈0）
 * @param onTouch 手指落在隐藏控制条上时的动作（通常是 wake()）
 */
@Composable
fun Modifier.tvHiddenControlsShield(hidden: Boolean, onTouch: () -> Unit): Modifier {
    val latestHidden = rememberUpdatedState(hidden)
    val latestOnTouch = rememberUpdatedState(onTouch)
    if (!BuildConfig.CAR_TOUCH) return this
    return this.pointerInput(Unit) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (!latestHidden.value) continue
                val first = event.changes.firstOrNull() ?: continue
                val freshDown = first.pressed && !first.previousPressed
                event.changes.forEach { it.consume() }
                if (freshDown) latestOnTouch.value()
            }
        }
    }
}

/**
 * tv-material3 `Surface(onClick)` 的触摸补丁版：签名与库内完全一致，只在转调前
 * 补一层 [tvTouchTap]。调用方把 `import androidx.tv.material3.Surface` 换成
 * `import org.moontechlab.selenetv.ui.Surface` 即可，其余代码零改动。
 *
 * 触摸点击 / 长按走 pointerInput，遥控器 OK / 长按仍走库内 handleDPadEnter，
 * 两条通路互不可见，互不干扰。
 */
@Composable
fun Surface(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    shape: ClickableSurfaceShape = ClickableSurfaceDefaults.shape(),
    colors: ClickableSurfaceColors = ClickableSurfaceDefaults.colors(),
    scale: ClickableSurfaceScale = ClickableSurfaceDefaults.scale(),
    border: ClickableSurfaceBorder = ClickableSurfaceDefaults.border(),
    content: @Composable BoxScope.() -> Unit,
) {
    TvMaterialSurface(
        onClick = onClick,
        modifier = modifier.tvTouchTap(
            enabled = enabled,
            onLongPress = onLongClick,
            onClick = onClick,
        ),
        onLongClick = onLongClick,
        enabled = enabled,
        shape = shape,
        colors = colors,
        scale = scale,
        border = border,
        content = content,
    )
}

/**
 * 触摸态标志：只有「设备声明了触摸屏」或「用户真的用手指点过」时才为 true。
 *
 * 只用来决定是否绘制触摸专用按钮（播放页右上角的「选集 / 频道 / 退出」）。
 * 纯电视用户永远是 false → 这些按钮根本不进组合树，画面与旧版逐像素一致，
 * 焦点链里也不存在它们（它们本来就没挂 focusable）。
 */
object TouchMode {
    private val state = mutableStateOf(false)

    /**
     * 车机包（`device=car`）且设备确实摸得到屏幕时才为 true。
     * TV 包里恒为 false —— 触摸专用按钮（播放页「选集/频道/退出」、登录页触摸按钮等）
     * 在 TV 包的组合树里根本不存在，与加触摸之前逐像素一致。
     */
    val active: Boolean
        get() = BuildConfig.CAR_TOUCH && state.value

    /** 收到第一根手指按下时置位（MainActivity.dispatchTouchEvent 里只观察、不拦截）。 */
    fun markTouched() {
        if (!BuildConfig.CAR_TOUCH) return
        if (!state.value) state.value = true
    }

    /** 车机通常直接声明触摸屏：开机即进入触摸态，不必先盲点一下。 */
    fun seedFromSystem(context: Context) {
        if (!BuildConfig.CAR_TOUCH) return
        if (state.value) return
        val pm = context.packageManager
        val hasTouch = pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
            pm.hasSystemFeature(PackageManager.FEATURE_FAKETOUCH)
        if (hasTouch) state.value = true
    }
}
