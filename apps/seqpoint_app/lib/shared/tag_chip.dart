import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

/// 标签胶囊。项目标签用琥珀色，类型标签用中性色。
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.name, required this.kind});

  final String name;
  final TagKind kind;

  @override
  Widget build(BuildContext context) {
    // TODO(M1)
    return const SizedBox.shrink();
  }
}
