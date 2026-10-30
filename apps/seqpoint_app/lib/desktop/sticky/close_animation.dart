import 'package:flutter/material.dart';

/// "揭走"动画：便签像被从桌面撕下来一样离开。
///
/// 这是产品的情绪终点，对应把物理便签从显示器边上撕下扔掉的那一下轻松感。
/// 时长控制在 400ms 内，尊重系统的"减弱动态效果"设置。
class CloseAnimation extends StatelessWidget {
  const CloseAnimation({
    super.key,
    required this.child,
    required this.onCompleted,
  });

  final Widget child;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    // TODO(M1): 旋转 + 上移 + 淡出；respect MediaQuery.disableAnimations
    return child;
  }
}
