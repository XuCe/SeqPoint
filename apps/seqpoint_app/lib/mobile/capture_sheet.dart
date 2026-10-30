import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../features/voice/voice_input_page.dart';
import '../theme/seq_tokens.dart';
import 'quick_capture_page.dart';

/// ＋ 弹出的动作面板：快速记录 / 语音速记。
///
/// "开始会议"入口在 M6 之前不出现。
class CaptureSheet {
  /// 返回 true 表示确实创建了便签。
  static Future<bool?> show(BuildContext context) async {
    if (AppScope.of(context).restoring) return null;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: SeqTokens.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('快速记录'),
              subtitle: const Text('想到就写，不用填任何属性'),
              onTap: () => Navigator.of(sheetContext).pop('text'),
            ),
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('语音速记'),
              subtitle: const Text('识别后先预览确认，再保存'),
              onTap: () => Navigator.of(sheetContext).pop('voice'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted || AppScope.of(context).restoring) return null;
    if (selected == 'voice') {
      final text = await Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => const VoiceInputPage(), fullscreenDialog: true));
      if (!context.mounted || text == null || text.trim().isEmpty || AppScope.of(context).restoring) return null;
      return Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => QuickCapturePage(initialText: text), fullscreenDialog: true));
    }
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const QuickCapturePage(),
        fullscreenDialog: true,
      ),
    );
  }
}
