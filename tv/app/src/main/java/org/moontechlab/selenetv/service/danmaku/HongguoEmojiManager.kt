package org.moontechlab.selenetv.service.danmaku

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import org.moontechlab.selenetv.ui.danmaku.DanmakuSegment
import org.moontechlab.selenetv.ui.danmaku.TextMeasurer

/**
 * 红果短剧官方 53 张高清 WebP 弹幕表情管理器
 * 负责从 assets/emojis/hongguo/ 读取预置表情图，并为轻量级弹幕引擎提供秒级像素渲染与分段支持
 */
object HongguoEmojiManager {
    private const val TAG = "HongguoEmojiManager"
    private const val ASSETS_DIR = "emojis/hongguo"

    /**
     * 官方 53 个表情的标签代码/中文名称 -> 文件名完整映射表
     */
    val codeToFileMap: Map<String, String> = mapOf(
        "[微笑]" to "01_微笑.webp", "微笑" to "01_微笑.webp",
        "[偷笑]" to "02_偷笑.webp", "偷笑" to "02_偷笑.webp",
        "[笑]" to "03_笑.webp", "笑" to "03_笑.webp",
        "[什么]" to "04_什么.webp", "什么" to "04_什么.webp",
        "[害羞]" to "05_害羞.webp", "害羞" to "05_害羞.webp",
        "[爱慕]" to "06_爱慕.webp", "爱慕" to "06_爱慕.webp",
        "[飞吻]" to "07_飞吻.webp", "飞吻" to "07_飞吻.webp",
        "[奸笑]" to "08_奸笑.webp", "奸笑" to "08_奸笑.webp",
        "[尬笑]" to "09_尬笑.webp", "尬笑" to "09_尬笑.webp",
        "[思考]" to "10_思考.webp", "思考" to "10_思考.webp",
        "[撇嘴]" to "11_撇嘴.webp", "撇嘴" to "11_撇嘴.webp",
        "[做鬼脸]" to "12_做鬼脸.webp", "做鬼脸" to "12_做鬼脸.webp",
        "[酷]" to "13_酷.webp", "酷" to "13_酷.webp",
        "[翻白眼]" to "14_翻白眼.webp", "翻白眼" to "14_翻白眼.webp",
        "[惊呆]" to "15_惊呆.webp", "惊呆" to "15_惊呆.webp",
        "[震惊]" to "16_震惊.webp", "震惊" to "16_震惊.webp",
        "[送心]" to "17_送心.webp", "送心" to "17_送心.webp",
        "[委屈]" to "18_委屈.webp", "委屈" to "18_委屈.webp",
        "[快哭了]" to "19_快哭了.webp", "快哭了" to "19_快哭了.webp",
        "[笑哭]" to "20_笑哭.webp", "笑哭" to "20_笑哭.webp",
        "[哭]" to "21_哭.webp", "哭" to "21_哭.webp",
        "[大笑]" to "22_大笑.webp", "大笑" to "22_大笑.webp",
        "[舔屏]" to "23_舔屏.webp", "舔屏" to "23_舔屏.webp",
        "[怒]" to "24_怒.webp", "怒" to "24_怒.webp",
        "[捂脸]" to "25_捂脸.webp", "捂脸" to "25_捂脸.webp",
        "[吐]" to "26_吐.webp", "吐" to "26_吐.webp",
        "[恐惧]" to "27_恐惧.webp", "恐惧" to "27_恐惧.webp",
        "[抓狂]" to "28_抓狂.webp", "抓狂" to "28_抓狂.webp",
        "[敬礼]" to "29_敬礼.webp", "敬礼" to "29_敬礼.webp",
        "[石化]" to "30_石化.webp", "石化" to "30_石化.webp",
        "[OK]" to "31_OK.webp", "OK" to "31_OK.webp",
        "[赞]" to "32_赞.webp", "赞" to "32_赞.webp",
        "[爱心]" to "33_爱心.webp", "爱心" to "33_爱心.webp",
        "[伤心]" to "34_伤心.webp", "伤心" to "34_伤心.webp",
        "[KISS]" to "35_KISS.webp", "KISS" to "35_KISS.webp",
        "[懂了]" to "36_懂了.webp", "懂了" to "36_懂了.webp",
        "[探究]" to "37_探究.webp", "探究" to "37_探究.webp",
        "[重拳出击]" to "38_重拳出击.webp", "重拳出击" to "38_重拳出击.webp",
        "[吃瓜]" to "39_吃瓜.webp", "吃瓜" to "39_吃瓜.webp",
        "[盯]" to "40_盯.webp", "盯" to "40_盯.webp",
        "[你细品]" to "41_你细品.webp", "你细品" to "41_你细品.webp",
        "[赶稿中]" to "42_赶稿中.webp", "赶稿中" to "42_赶稿中.webp",
        "[注意]" to "43_注意.webp", "注意" to "43_注意.webp",
        "[饱了]" to "44_饱了.webp", "饱了" to "44_饱了.webp",
        "[码住]" to "45_码住.webp", "码住" to "45_码住.webp",
        "[学会了]" to "46_学会了.webp", "学会了" to "46_学会了.webp",
        "[顶帖]" to "47_顶帖.webp", "顶帖" to "47_顶帖.webp",
        "[求爆更]" to "48_求爆更.webp", "求爆更" to "48_求爆更.webp",
        "[求关注]" to "49_求关注.webp", "求关注" to "49_求关注.webp",
        "[爽]" to "50_爽.webp", "爽" to "50_爽.webp",
        "[鼓掌]" to "51_鼓掌.webp", "鼓掌" to "51_鼓掌.webp",
        "[没看够]" to "52_没看够.webp", "没看够" to "52_没看够.webp",
        "[送花]" to "53_送花.webp", "送花" to "53_送花.webp"
    )

    private val bitmapCache = ConcurrentHashMap<String, Bitmap>()
    @Volatile
    private var isInitialized = false

    private val EMOJI_PATTERN = Regex("(\\[|［)\\s*([^\\[\\]［］]{1,16}?)\\s*(\\]|］)")

    /**
     * 异步从 assets 加载全部 53 张 WebP 表情图进内存
     */
    fun init(context: Context) {
        if (isInitialized) return
        Thread {
            try {
                val assetManager = context.applicationContext.assets
                val files = assetManager.list(ASSETS_DIR) ?: emptyArray()
                for (fileName in files) {
                    if (!fileName.endsWith(".webp")) continue
                    try {
                        val input: InputStream = assetManager.open("$ASSETS_DIR/$fileName")
                        val bitmap = BitmapFactory.decodeStream(input)
                        input.close()
                        if (bitmap != null) {
                            bitmapCache[fileName] = bitmap
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "加载表情 $fileName 异常: ${e.message}")
                    }
                }
                isInitialized = true
                Log.d(TAG, "红果弹幕高清表情预热完成，共加载 ${bitmapCache.size} 张表情")
            } catch (e: Exception) {
                Log.e(TAG, "初始化红果表情管理器失败: ${e.message}")
            }
        }.start()
    }

    /**
     * 根据表情代码（如 [微笑]）或名称获取对应 Bitmap
     */
    fun getBitmap(codeOrName: String): Bitmap? {
        val fileName = codeToFileMap[codeOrName] ?: codeToFileMap["[$codeOrName]"] ?: return null
        return bitmapCache[fileName]
    }

    /**
     * 检测文本中是否包含已收录的 53 个红果官方表情
     */
    fun hasEmoji(text: String): Boolean {
        if (!text.contains('[') && !text.contains('［')) return false
        val matches = EMOJI_PATTERN.findAll(text)
        for (m in matches) {
            val name = m.groupValues[2].trim()
            if (codeToFileMap.containsKey(name) || codeToFileMap.containsKey("[$name]")) {
                return true
            }
        }
        return false
    }

    /**
     * 将弹幕文本解析为分段（包含 Text 与 Emoji），并计算各段宽度
     */
    fun parseSegments(text: String, measurer: TextMeasurer, textSizePx: Float): List<DanmakuSegment> {
        val segments = mutableListOf<DanmakuSegment>()
        var lastIdx = 0
        val emojiSize = textSizePx * 1.15f
        val matches = EMOJI_PATTERN.findAll(text)

        for (m in matches) {
            val start = m.range.first
            val end = m.range.last + 1
            val name = m.groupValues[2].trim()
            val fileName = codeToFileMap[name] ?: codeToFileMap["[$name]"]

            if (fileName != null) {
                // 先添加前面的纯文本段
                if (start > lastIdx) {
                    val sub = text.substring(lastIdx, start)
                    val w = measurer.measure(sub, textSizePx)
                    if (w > 0f) {
                        segments.add(DanmakuSegment.Text(sub, w))
                    }
                }
                val bmp = bitmapCache[fileName]
                segments.add(DanmakuSegment.Emoji("[$name]", bmp, emojiSize + 4f))
                lastIdx = end
            }
        }

        // 添加尾部剩余文本段
        if (lastIdx < text.length) {
            val sub = text.substring(lastIdx)
            val w = measurer.measure(sub, textSizePx)
            if (w > 0f) {
                segments.add(DanmakuSegment.Text(sub, w))
            }
        }

        return segments
    }
}
