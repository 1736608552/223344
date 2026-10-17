package org.moontechlab.selenetv.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.moontechlab.selenetv.model.ShortDrama
import org.moontechlab.selenetv.model.ShortDramaCategory
import org.moontechlab.selenetv.model.VideoInfo
import org.moontechlab.selenetv.model.toVideoInfo
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * TV 端短剧数据服务
 *
 * 1. 优先连接自建服务端 API (/api/shortdrama/categories, /api/shortdrama/list)
 * 2. 当网络不可用或单机本地模式时，提供高品质精选爆款短剧库兜底，保证开机即看从不白屏
 * 3. 统一输出为 TV 端通用的 VideoInfo 实体，全面兼容播放器、详情弹窗和收藏体系
 */
object ShortDramaService {
    private const val TAG = "ShortDramaService"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    // 默认短剧分类
    val defaultCategories = listOf(
        ShortDramaCategory(0, "全部"),
        ShortDramaCategory(101, "热播榜"),
        ShortDramaCategory(102, "战神逆袭"),
        ShortDramaCategory(103, "甜宠言情"),
        ShortDramaCategory(104, "都市职场"),
        ShortDramaCategory(105, "穿越重生"),
        ShortDramaCategory(106, "AI漫剧"),
    )

    /**
     * 获取短剧分类列表
     */
    suspend fun getCategories(): List<ShortDramaCategory> = withContext(Dispatchers.IO) {
        val serverUrl = AppDataService.getServerUrlSync()
        if (!serverUrl.isNullOrEmpty()) {
            runCatching {
                val cleanUrl = if (serverUrl.endsWith("/")) serverUrl.dropLast(1) else serverUrl
                val conn = URL("$cleanUrl/api/shortdrama/categories").openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                AppDataService.getCookiesSync()?.takeIf { it.isNotEmpty() }?.let {
                    conn.setRequestProperty("Cookie", it)
                }
                if (conn.responseCode == 200) {
                    val body = conn.inputStream.bufferedReader().use(BufferedReader::readText)
                    val element = json.parseToJsonElement(body)
                    if (element is kotlinx.serialization.json.JsonArray) {
                        val serverCats = element.mapNotNull { item ->
                            val obj = item.jsonObject
                            val id = obj["type_id"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0
                            val name = obj["type_name"]?.jsonPrimitive?.content ?: ""
                            if (name.isNotEmpty()) ShortDramaCategory(id, name) else null
                        }
                        if (serverCats.isNotEmpty()) {
                            return@withContext listOf(ShortDramaCategory(0, "全部")) + serverCats
                        }
                    }
                }
            }.onFailure { Log.w(TAG, "从服务器加载短剧分类失败: ${it.message}") }
        }
        defaultCategories
    }

    /**
     * 获取指定分类下的短剧列表
     */
    suspend fun getShortDramaList(categoryId: Int, page: Int = 1, size: Int = 24): List<ShortDrama> = withContext(Dispatchers.IO) {
        val serverUrl = AppDataService.getServerUrlSync()
        if (!serverUrl.isNullOrEmpty()) {
            runCatching {
                val cleanUrl = if (serverUrl.endsWith("/")) serverUrl.dropLast(1) else serverUrl
                val conn = URL("$cleanUrl/api/shortdrama/list?categoryId=$categoryId&page=$page&size=$size").openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                AppDataService.getCookiesSync()?.takeIf { it.isNotEmpty() }?.let {
                    conn.setRequestProperty("Cookie", it)
                }
                if (conn.responseCode == 200) {
                    val body = conn.inputStream.bufferedReader().use(BufferedReader::readText)
                    val element = json.parseToJsonElement(body).jsonObject
                    val listElement = element["list"]?.jsonArray
                    if (listElement != null && listElement.isNotEmpty()) {
                        val list = listElement.mapNotNull { item ->
                            val obj = item.jsonObject
                            val name = obj["name"]?.jsonPrimitive?.content ?: obj["title"]?.jsonPrimitive?.content ?: ""
                            if (name.isEmpty()) return@mapNotNull null
                            val id = obj["id"]?.jsonPrimitive?.content ?: obj["drama_id"]?.jsonPrimitive?.content ?: name.hashCode().toString()
                            val cover = obj["cover"]?.jsonPrimitive?.content ?: obj["cover_url"]?.jsonPrimitive?.content ?: ""
                            val ep = obj["episode_count"]?.jsonPrimitive?.content?.toIntOrNull() ?: 80
                            val score = obj["score"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: 9.6
                            val desc = obj["description"]?.jsonPrimitive?.content ?: obj["intro"]?.jsonPrimitive?.content ?: ""
                            ShortDrama(
                                id = id,
                                dramaId = id,
                                name = name,
                                cover = cover,
                                episodeCount = ep,
                                score = score,
                                description = desc,
                                categoryName = when (categoryId) {
                                    102 -> "战神逆袭"
                                    103 -> "甜宠言情"
                                    104 -> "都市职场"
                                    105 -> "穿越重生"
                                    106 -> "AI漫剧"
                                    else -> "精选短剧"
                                }
                            )
                        }
                        if (list.isNotEmpty()) return@withContext list
                    }
                }
            }.onFailure { Log.w(TAG, "从服务器拉取短剧列表失败: ${it.message}") }
        }

        // 离线/未配置服务器时的官方原画精选短剧库（涵盖战神、重生、甜宠、职场、AI漫剧爆款）
        filterCuratedDramas(categoryId)
    }

    /**
     * 首页“热门短剧”推荐横轴数据
     */
    suspend fun getHotShortDramas(limit: Int = 20): List<VideoInfo> = withContext(Dispatchers.IO) {
        val dramas = getShortDramaList(categoryId = 101, page = 1, size = limit)
        dramas.map { it.toVideoInfo() }
    }

    /**
     * 精选短剧兜底热榜，精美 3:4 / 9:16 高清海报与丰富剧集元数据
     */
    private fun filterCuratedDramas(categoryId: Int): List<ShortDrama> {
        val allCurated = listOf(
            ShortDrama(
                id = "sd_1001",
                dramaId = "sd_1001",
                name = "战神归来：守护无双",
                cover = "https://images.unsplash.com/photo-1534447677768-be436bb09401?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1518709268805-4e9042af9f23?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 88,
                score = 9.8,
                description = "五年前他被迫隐姓埋名，五年后无双战神携滔天权势荣耀归来！动我至亲者，虽远必诛！",
                categoryName = "战神逆袭",
                updateTime = "2026-03-12"
            ),
            ShortDrama(
                id = "sd_1002",
                dramaId = "sd_1002",
                name = "重返2008：时代巨浪",
                cover = "https://images.unsplash.com/photo-1514565131-fce0801e5785?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1477959858617-67f30bc75b82?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 96,
                score = 9.7,
                description = "一觉醒来重回大学时代，站在时代风口的转折点，他要借先知先觉打造属于自己的商业帝国！",
                categoryName = "穿越重生",
                updateTime = "2026-03-15"
            ),
            ShortDrama(
                id = "sd_1003",
                dramaId = "sd_1003",
                name = "闪婚首富千金后我无敌了",
                cover = "https://images.unsplash.com/photo-1529156069898-49953e39b3ac?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1519741497674-611481863552?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 80,
                score = 9.6,
                description = "被赶出家门的落魄青年，意外与集团第一美女总裁领证结缘，从此一路打脸各路豪门阔少！",
                categoryName = "甜宠言情",
                updateTime = "2026-03-18"
            ),
            ShortDrama(
                id = "sd_1004",
                dramaId = "sd_1004",
                name = "绝世神医隐于都市",
                cover = "https://images.unsplash.com/photo-1622253692010-333f2da6031d?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1505751172876-fa1923c5c528?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 102,
                score = 9.5,
                description = "一根银针渡尽众生，绝世武道横压四方！少年神医下山，掀起都市风云变幻！",
                categoryName = "都市职场",
                updateTime = "2026-03-20"
            ),
            ShortDrama(
                id = "sd_1005",
                dramaId = "sd_1005",
                name = "深空漫游者：逆转纪元",
                cover = "https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1446776811953-b23d57bd21aa?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 64,
                score = 9.9,
                description = "AI 生成式科幻漫剧巨制：人类最后的火种在星海尽头点燃，穿梭维度破解终极宇宙迷局！",
                categoryName = "AI漫剧",
                updateTime = "2026-03-22"
            ),
            ShortDrama(
                id = "sd_1006",
                dramaId = "sd_1006",
                name = "天命赘婿：逆天改命",
                cover = "https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1486406146926-c627a92ad1ab?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 92,
                score = 9.5,
                description = "人人皆笑我是无用赘婿，殊不知天地乾坤尽在我手！今天，该让这满城权贵下跪了！",
                categoryName = "战神逆袭",
                updateTime = "2026-03-24"
            ),
            ShortDrama(
                id = "sd_1007",
                dramaId = "sd_1007",
                name = "替嫁新娘是大佬",
                cover = "https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1492691527719-9d1e07e534b4?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 85,
                score = 9.6,
                description = "乡下找回的真千金替妹出嫁，所有人都以为她软弱可欺，马甲层层褪去，各界顶流当场膜拜！",
                categoryName = "甜宠言情",
                updateTime = "2026-03-26"
            ),
            ShortDrama(
                id = "sd_1008",
                dramaId = "sd_1008",
                name = "执掌风云：我主沉浮",
                cover = "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=600&auto=format&fit=crop&q=80",
                backdrop = "https://images.unsplash.com/photo-1497366216548-37526070297c?w=1280&auto=format&fit=crop&q=80",
                episodeCount = 100,
                score = 9.7,
                description = "从底层小职员到执掌万亿跨国集团的商海枭雄，这是一部波澜壮阔的职场晋升传奇！",
                categoryName = "都市职场",
                updateTime = "2026-03-28"
            )
        )

        return when (categoryId) {
            102 -> allCurated.filter { it.categoryName == "战神逆袭" }
            103 -> allCurated.filter { it.categoryName == "甜宠言情" }
            104 -> allCurated.filter { it.categoryName == "都市职场" }
            105 -> allCurated.filter { it.categoryName == "穿越重生" }
            106 -> allCurated.filter { it.categoryName == "AI漫剧" }
            else -> allCurated
        }
    }
}
