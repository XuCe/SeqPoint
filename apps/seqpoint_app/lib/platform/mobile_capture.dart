import 'dart:async';


import 'package:home_widget/home_widget.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

/// 桌面 / 锁屏小组件：显示今日剩余数量，点击直达快速记录。
class MobileWidgetService implements WidgetService {
  const MobileWidgetService();

  static const _androidProvider = 'TodayWidgetProvider';
  static const _iosKind = 'SeqPointTodayWidget';

  @override
  Future<void> updateTodayCount(int count) async {
    await HomeWidget.saveWidgetData<int>('today_count', count);
    await HomeWidget.updateWidget(
      androidName: _androidProvider,
      iOSName: _iosKind,
    );
  }

  @override
  Future<bool> isAdded() async {
    // 各平台都没有可靠的"是否已添加"查询，只能按未添加处理。
    return false;
  }
}

/// 系统分享接入："发送到序点"。
class MobileShareIntake implements ShareIntake {
  MobileShareIntake();

  final _texts = StreamController<String>.broadcast();
  final _images = StreamController<List<String>>.broadcast();
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  Stream<String> get texts => _texts.stream;

  @override
  Stream<List<String>> get imagePaths => _images.stream;

  Future<void> init() async {
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(_emit);
    // 冷启动时的首条分享。
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) {
      _emit(initial);
      unawaited(ReceiveSharingIntent.instance.reset());
    }
  }

  void _emit(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final images = <String>[];
    for (final f in files) {
      if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
        _texts.add(f.path);
      } else if (f.type == SharedMediaType.image) {
        images.add(f.path);
      }
    }
    if (images.isNotEmpty) _images.add(images);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _texts.close();
    await _images.close();
  }
}

/// 长按 App 图标的快捷动作。
class MobileQuickActionsService implements QuickActionsService {
  MobileQuickActionsService();

  final _selections = StreamController<QuickActionType>.broadcast();
  final _actions = const QuickActions();

  @override
  Stream<QuickActionType> get selections => _selections.stream;

  @override
  Future<void> register() async {
    // initialize 注册回调后立即返回，不需要等待。
    unawaited(_actions.initialize((type) {
      final action = switch (type) {
        'quick_note' => QuickActionType.quickNote,
        'voice_note' => QuickActionType.voiceNote,
        _ => null,
      };
      if (action != null) _selections.add(action);
    }));
    await _actions.setShortcutItems(const [
      ShortcutItem(type: 'quick_note', localizedTitle: '快速记录'),
      ShortcutItem(type: 'voice_note', localizedTitle: '语音速记'),
    ]);
  }

  Future<void> dispose() => _selections.close();
}
