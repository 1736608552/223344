import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:luna_tv/services/duanju_media_kit_backend.dart';

/// 短剧专属 MediaKit 画面渲染组件
class DuanjuMediaKitView extends StatelessWidget {
  final DuanjuMediaKitBackend backend;

  const DuanjuMediaKitView({super.key, required this.backend});

  @override
  Widget build(BuildContext context) {
    final controller = backend.videoController;
    if (controller == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Center(
      child: Video(
        controller: controller,
        fit: BoxFit.contain,
        controls: NoVideoControls,
      ),
    );
  }
}
