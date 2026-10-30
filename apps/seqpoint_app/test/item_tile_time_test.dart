import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  testWidgets('UTC存储的截止瞬时显示本地日期与钟点', (tester) async {
    final local = DateTime(2001, 11, 1, 23, 30);
    final item = Item(id: 'i', title: '本地截止', status: ItemStatus.todo,
        priority: Priority.p4, source: ItemSource.manual,
        dueAt: local.toUtc(), createdAt: local, updatedAt: local);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ItemTile(item: item))));
    expect(find.text('11/1 23:30'), findsOneWidget);
  });
}
