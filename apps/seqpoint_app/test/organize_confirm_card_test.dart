import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_app/shared/organize_confirm_card.dart';

void main() {
  testWidgets('展示可保存字段，逐项选择保持原文和候选身份，未采纳前不回调', (tester) async {
    final proposal = OrganizeProposal(noteId: 'note', sourceContent: '原文一\n原文二',
        noteTitle: '未开放标题建议', items: [
      ProposedItem(id: 'a', title: '回复报价', lineIndex: 0, important: true,
          dueAt: DateTime(2026, 11, 1, 9), typeTagName: '沟通', projectTagName: '项目A',
          recurrence: '未开放循环', reminderHint: '未开放提醒'),
      const ProposedItem(id: 'b', title: '文档', lineIndex: 1),
    ]);
    OrganizeProposal? accepted;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(
        proposal: proposal, onAccept: (value) async { accepted = value; }, onCancel: () {}))));
    expect(find.text('回复报价'), findsOneWidget); expect(find.text('文档'), findsOneWidget);
    expect(find.textContaining('重要'), findsOneWidget);
    expect(find.textContaining('项目A'), findsOneWidget); expect(find.textContaining('沟通'), findsOneWidget);
    expect(find.textContaining('09:00'), findsOneWidget); expect(accepted, isNull);
    expect(find.textContaining('未开放'), findsNothing);
    await tester.tap(find.widgetWithText(CheckboxListTile, '文档')); await tester.pump();
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(accepted!.sourceContent, proposal.sourceContent); expect(accepted!.noteId, 'note');
    expect(accepted!.items.map((item) => item.id), ['a', 'b']);
    expect(accepted!.items.last.accepted, isFalse); expect(proposal.items.last.accepted, isTrue);
  });
  testWidgets('采纳等待期间冻结选择与取消，重复点击只回调一次', (tester) async {
    const proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
    final done = Completer<void>(); var calls = 0, cancels = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (_) async { calls++; await done.future; }, onCancel: () { cancels++; }))));
    await tester.tap(find.text('采纳勾选项')); await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '取消')).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('采纳勾选项')); await tester.tap(find.text('取消')); await tester.pump();
    expect(calls, 1); expect(cancels, 0);
    done.complete(); await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
  testWidgets('采纳失败显示原因，保留选择并允许重试', (tester) async {
    const proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (_) async { calls++; if (calls == 1) throw StateError('便签已变化，请重新整理'); }, onCancel: () {}))));
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(find.text('便签已变化，请重新整理'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(calls, 2); expect(find.text('便签已变化，请重新整理'), findsNothing);
  });
  testWidgets('全部取消勾选不能采纳，取消不调用采纳器', (tester) async {
    const proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
    var calls = 0, cancels = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (_) async { calls++; }, onCancel: () { cancels++; }))));
    await tester.tap(find.byType(CheckboxListTile)); await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('取消')); await tester.pump();
    expect(calls, 0); expect(cancels, 1);
  });
  testWidgets('空提案明确提示，不提供可执行采纳动作', (tester) async {
    const proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: []);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (_) async => fail('不应采纳空提案'), onCancel: () {}))));
    expect(find.text('没有可采纳的新事项'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
  testWidgets('窄屏长列表可选末项，滚动不丢勾选或身份', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: [
      for (var i = 0; i < 30; i++) ProposedItem(id: 'item-$i', title: '第$i项较长建议标题，确认时应能完整阅读',
          lineIndex: i, projectTagName: '项目标签', important: true)]);
    OrganizeProposal? accepted;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (value) async { accepted = value; }, onCancel: () {}))));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('item-29')), 400);
    await tester.tap(find.byKey(const ValueKey('item-29'))); await tester.pump();
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(accepted!.items.last.accepted, isFalse); expect(accepted!.items.first.accepted, isTrue);
    expect(accepted!.items.map((e) => e.id).toSet(), hasLength(30)); expect(tester.takeException(), isNull);
  });
  testWidgets('采纳等待中卸载，迟到完成不会setState或报错', (tester) async {
    const proposal = OrganizeProposal(noteId: 'n', sourceContent: '原文', items: [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
    final done = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OrganizeConfirmCard(proposal: proposal,
        onAccept: (_) => done.future, onCancel: () {}))));
    await tester.tap(find.text('采纳勾选项')); await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    done.complete(); await tester.pumpAndSettle(); expect(tester.takeException(), isNull);
  });
}
