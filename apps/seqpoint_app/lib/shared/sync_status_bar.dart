import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

/// 同步状态条。诚实语义：没有可达副本时绝不显示"已同步"。
///
/// 文案：仅本机 / 已同步到 N 台设备 / 待中转 / 上次同步 时间。
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({super.key, required this.status});

  final TransportStatus status;

  @override
  Widget build(BuildContext context) {
    // TODO(M4)
    return const SizedBox.shrink();
  }
}
