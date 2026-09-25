// v2.1.33: LunaCacheManager — 自定义 [CacheManager] 注入 [LunaImageHttp]
//
// 背景:
//   - [cached_network_image] 3.4.1 删了 `httpClient` 参数 (v2.x 才有, 3.x
//     拿掉了). 注入自定义 http client 的方式变成 `cacheManager: CustomCacheManager()`
//   - [CacheManager] 接受 [Config], [Config] 可以指定 `fileService: HttpFileService(httpClient: ...)`
//   - [HttpFileService] 把文件下载请求转发给传入的 [http.Client]
//
// 关系链:
//   [CachedNetworkImage] → [ImageLoader] → [CacheManager.downloadFile]
//     → [FileService.get] (HttpFileService) → [LunaImageHttp.send]
//     → Android MethodChannel / dart:io fallback
//
// 配合 [ImageCacheManager] mixin 以支持 maxWidth / maxHeight 缩放缓存.

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:luna_tv/services/luna_image_http.dart';

class LunaCacheManager {
  // v2.1.33: 唯一 cache key — flutter_cache_manager 内部用 key 分数据库
  //   文件夹和 sqflite/json database name. 同 key 不能有多个实例, 否则互相覆盖.
  static const String _key = 'luna_image_cache';

  // v2.1.33: 单例 [CacheManager], 跨所有 [CachedNetworkImage] 共享
  static final CacheManager instance = CacheManager(
    Config(
      _key,
      // v2.1.33: 缓存 7 天. cached_network_image 默认是 30 天, image
      //   改动不频繁, 7 天足够
      stalePeriod: const Duration(days: 7),
      // v2.1.33: 最多 200 张图. 跟 flutter_cache_manager 默认一致
      maxNrOfCacheObjects: 200,
      // v2.1.33: 关键 — 把 [LunaImageHttp] 注入 [HttpFileService]
      //   所有图片下载请求都走 [LunaImageHttp] → Android MethodChannel
      fileService: HttpFileService(httpClient: LunaImageHttp()),
    ),
  );
}
