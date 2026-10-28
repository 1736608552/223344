package org.moontechlab.selenetv.ui.danmaku

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RectF
import org.moontechlab.selenetv.service.danmaku.HongguoEmojiManager

/**
 * 把引擎活跃集画到一块硬件 Canvas 上。每条 drawText 自带 alpha（颜色折入不透明度）——
 * 绝不调 saveLayer*。复用同一个 Paint 与 RectF，零每帧分配。
 * 支持红果短剧 53 张官方原版 WebP 高清表情行内精准混排渲染。
 */
object DanmakuRenderer {
    private val emojiRect = RectF()

    fun draw(canvas: Canvas, paint: Paint, engine: DanmakuEngine) {
        canvas.drawColor(0, PorterDuff.Mode.CLEAR)  // 整屏透明清空
        val cfg = engine.config
        if (!cfg.visible) return
        paint.textSize = cfg.textSizePx
        val alpha = (cfg.opacity.coerceIn(0f, 1f) * 255f).toInt()
        val emojiSize = cfg.textSizePx * 1.15f

        // 下标遍历，避免 for-in 对 List 每帧分配 Iterator（低内存机 GC 抖动→滚动卡顿主因）。
        val list = engine.renderActive
        for (i in 0 until list.size) {
            val d = list[i]
            paint.color = (alpha shl 24) or (d.colorRgb and 0xFFFFFF)
            val segs = d.segments

            if (segs == null) {
                // 纯文本常规弹幕，单次 drawText 直出
                canvas.drawText(d.text, d.x, d.y, paint)
            } else {
                // 图文混排弹幕：逐段绘制文本与表情 Bitmap
                var curX = d.x
                for (j in 0 until segs.size) {
                    when (val s = segs[j]) {
                        is DanmakuSegment.Text -> {
                            canvas.drawText(s.text, curX, d.y, paint)
                            curX += s.width
                        }
                        is DanmakuSegment.Emoji -> {
                            val bmp = s.bitmap ?: HongguoEmojiManager.getBitmap(s.code)
                            if (bmp != null) {
                                val top = d.y - emojiSize + 4f
                                emojiRect.set(curX + 2f, top, curX + 2f + emojiSize, top + emojiSize)
                                canvas.drawBitmap(bmp, null, emojiRect, paint)
                            }
                            curX += s.width
                        }
                    }
                }
            }
        }
    }
}
