package org.moontechlab.selenetv.service

import android.content.Context
import android.os.Build
import android.util.Log
import kotlinx.serialization.json.Json
import okhttp3.Request
import org.moontechlab.selenetv.model.GithubRelease
import org.moontechlab.selenetv.model.UpdateInfo
import java.io.File

/**
 * 应用更新服务。阻塞方法，必须在 Dispatchers.IO 调用；失败抛 ApiException。
 * 复用 MediaHttp.httpClient（trust-all），与项目网络约定一致。
 */
object UpdateService {
    private const val TAG = "UpdateService"
    private const val LATEST_URL =
        "https://api.github.com/repos/1736608552/LunaTV-Release/releases/latest"

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** 下载专用客户端：APK 较大，放宽 readTimeout 防止慢速/卡顿网络中途超时。 */
    private val downloadClient by lazy {
        MediaHttp.httpClient.newBuilder()
            .readTimeout(5, java.util.concurrent.TimeUnit.MINUTES)
            .build()
    }

    /** 判断当前设备是否为海信电视/设备 */
    fun isHisenseDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER ?: ""
        val brand = Build.BRAND ?: ""
        val model = Build.MODEL ?: ""
        return manufacturer.contains("hisense", ignoreCase = true) ||
               brand.contains("hisense", ignoreCase = true) ||
               model.contains("hisense", ignoreCase = true)
    }

    /** 构造 GitHub API URL（支持 Worker 加速与直连） */
    fun buildGithubApiUrl(originalUrl: String): String {
        val mode = AppDataService.getGithubDataSourceSync()
        val worker = AppDataService.getWorkerProxyUrlSync()
        if (mode == AppDataService.GithubDataSource.WORKER && worker.isNotEmpty() && originalUrl.startsWith("https://api.github.com")) {
            return originalUrl.replaceFirst("https://api.github.com", "$worker/github")
        }
        return originalUrl
    }

    /** 构造 GitHub Release 资产下载 URL（支持 CDN 加速 / GitHub Worker 加速 / 直连） */
    fun buildGithubAssetUrl(originalUrl: String): String {
        if (originalUrl.isEmpty()) return originalUrl
        if (originalUrl.contains("ghfast.top") ||
            originalUrl.contains("ghproxy.net") ||
            originalUrl.contains("mirror.ghproxy.com")) {
            return originalUrl
        }
        val raw = if (originalUrl.contains("github.com/")) {
            "https://github.com/" + originalUrl.substringAfter("github.com/")
        } else {
            originalUrl
        }
        val mode = AppDataService.getGithubDataSourceSync()
        val worker = AppDataService.getWorkerProxyUrlSync()
        if (mode == AppDataService.GithubDataSource.WORKER && worker.isNotEmpty()) {
            val m = Regex("^https://github\\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^?#]+)$").find(raw)
            if (m != null) {
                val (owner, repo, tag, asset) = m.destructured
                return "$worker/github/asset/$owner/$repo/$tag/$asset"
            }
        }
        if (mode == AppDataService.GithubDataSource.DIRECT) {
            return raw
        }
        return "https://ghfast.top/$raw"
    }

    /** 当前 versionName（与 SettingsTab.VersionColophon 一致，不依赖 BuildConfig）。 */
    fun currentVersionName(context: Context): String =
        runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: ""

    /**
     * 检查更新。返回 UpdateInfo，或 null（无更新 / CI 构建中无资产 / 无匹配架构）。
     * 网络或解析失败抛 ApiException。
     */
    fun checkForUpdate(context: Context): UpdateInfo? {
        // 车机包只挑 LunaTV-Car-*，TV 包只挑 LunaTV-TV-*（跨渠道包名不同，装了也更新不到自己）
        val isCar = org.moontechlab.selenetv.BuildConfig.CAR_TOUCH
        val release = fetchLatestRelease(isCar)
        val current = currentVersionName(context)
        val abis = Build.SUPPORTED_ABIS?.toList() ?: emptyList()
        val isHisense = isHisenseDevice()
        val info = UpdateLogic.buildUpdateInfo(release, current, abis, isHisense, isCar) ?: return null
        val acceleratedUrl = buildGithubAssetUrl(info.apkUrl)
        return info.copy(apkUrl = acceleratedUrl)
    }

    private fun fetchLatestRelease(isCar: Boolean): GithubRelease {
        val targetUrl = buildGithubApiUrl(LATEST_URL)
        val request = Request.Builder()
            .url(targetUrl)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "LunaTV")
            .build()
        try {
            MediaHttp.httpClient.newCall(request).execute().use { resp ->
                if (resp.isSuccessful) {
                    val body = resp.body?.string() ?: ""
                    if (body.isNotEmpty()) {
                        return json.decodeFromString<GithubRelease>(body)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "GitHub API 直连检查更新失败，尝试 CDN 镜像容灾: ${e.message}")
        }

        // 通道 2：jsDelivr 全球高速 CDN 容灾读取 changelogs.json（国内直连秒级响应，永不阻断）
        val cdnUrls = listOf(
            "https://fastly.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json",
            "https://cdn.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json",
            "https://testingcf.jsdelivr.net/gh/1736608552/223344@main/.github/changelogs.json"
        )
        for (cdnUrl in cdnUrls) {
            try {
                val cdnReq = Request.Builder().url(cdnUrl).header("User-Agent", "LunaTV").build()
                MediaHttp.httpClient.newCall(cdnReq).execute().use { resp ->
                    if (resp.isSuccessful) {
                        val body = resp.body?.string() ?: ""
                        if (body.startsWith("{")) {
                            val map = org.json.JSONObject(body)
                            val keys = map.keys()
                            if (keys.hasNext()) {
                                val latestTag = keys.next()
                                val cleanTag = latestTag.removePrefix("v").removePrefix("V")
                                val bodyText = map.optString(latestTag, "全新版本 $latestTag 发布！")
                                val releaseRepo = "https://github.com/1736608552/LunaTV-Release"

                                // 兜底清单必须与「本包渠道」一致：车机包给 Car 资产，TV 包给 TV 资产。
                                // 以前这里写死 LunaTV-TV-*，车机包走 CDN 兜底时永远选不到包 → 判定「无更新」。
                                val family = if (isCar) "LunaTV-Car" else "LunaTV-TV"
                                val abiNames = if (isCar) {
                                    listOf("arm64-v8a", "armeabi-v7a")
                                } else {
                                    listOf("arm64-v8a", "armeabi-v7a", "hisense")
                                }
                                val simulatedAssets = buildList {
                                    abiNames.forEach { tag ->
                                        // 不带版本号的稳定名：LunaTV-TV-arm64-v8a.apk / LunaTV-TV-hisense.apk
                                        add(
                                            org.moontechlab.selenetv.model.GithubAsset(
                                                name = "$family-$tag.apk",
                                                browserDownloadUrl = "$releaseRepo/releases/download/$latestTag/$family-$tag.apk"
                                            )
                                        )
                                    }
                                    abiNames.forEach { tag ->
                                        // 带版本号的文件名：LunaTV-Car-v2.8.4-arm64-v8a.apk
                                        add(
                                            org.moontechlab.selenetv.model.GithubAsset(
                                                name = "$family-$cleanTag-$tag.apk",
                                                browserDownloadUrl = "$releaseRepo/releases/download/$latestTag/$family-$cleanTag-$tag.apk"
                                            )
                                        )
                                    }
                                }

                                return GithubRelease(
                                    tagName = latestTag,
                                    name = latestTag,
                                    body = bodyText,
                                    assets = simulatedAssets
                                )
                            }
                        }
                    }
                }
            } catch (ignored: Exception) {}
        }

        throw ApiException("检查更新失败：网络连接超时或无法访问更新服务器")
    }

    /**
     * 下载 APK 到 cacheDir/update/。下载前清空该目录。
     * 默认全走国内极速 CDN 加速，支持多 CDN 自动轮询容灾。
     */
    fun downloadApk(context: Context, info: UpdateInfo, onProgress: (Float) -> Unit): File {
        val dir = File(context.cacheDir, "update").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val prefix = if (org.moontechlab.selenetv.BuildConfig.CAR_TOUCH) "LunaTV-Car" else "LunaTV-TV"
        val outFile = File(dir, "$prefix-${info.version}-${info.abi}.apk")

        val rawUrl = if (info.apkUrl.contains("github.com/")) {
            "https://github.com/" + info.apkUrl.substringAfter("github.com/")
        } else {
            info.apkUrl
        }

        val candidates = mutableListOf<String>()
        if (rawUrl.startsWith("https://github.com/")) {
            candidates.add("https://ghfast.top/$rawUrl")
            candidates.add("https://ghproxy.net/$rawUrl")
            candidates.add("https://mirror.ghproxy.com/$rawUrl")
            candidates.add(rawUrl)
        } else {
            candidates.add(info.apkUrl)
        }

        var lastErr: Exception? = null
        for (currentUrl in candidates) {
            try {
                if (outFile.exists()) outFile.delete()
                val request = Request.Builder().url(currentUrl).header("User-Agent", "LunaTV").build()
                downloadClient.newCall(request).execute().use { resp ->
                    if (!resp.isSuccessful) throw ApiException("下载失败 (${resp.code})", resp.code)
                    val body = resp.body ?: throw ApiException("下载失败：空响应")
                    val total = body.contentLength()
                    body.byteStream().use { input ->
                        outFile.outputStream().use { output ->
                            val buf = ByteArray(8 * 1024)
                            var downloaded = 0L
                            var read = input.read(buf)
                            while (read != -1) {
                                output.write(buf, 0, read)
                                downloaded += read
                                onProgress(if (total > 0) downloaded.toFloat() / total else -1f)
                                read = input.read(buf)
                            }
                        }
                    }
                }
                if (outFile.exists() && outFile.length() > 1024 * 1024) {
                    return outFile
                }
            } catch (e: Exception) {
                lastErr = e
                Log.w(TAG, "通过 CDN $currentUrl 下载失败，尝试下一个候选源: ${e.message}")
            }
        }

        outFile.delete()
        throw ApiException("下载更新包失败：${lastErr?.message ?: "所有下载节点均超时"}")
    }
}
