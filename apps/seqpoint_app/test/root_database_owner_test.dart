import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/seq_app.dart';

void main() {
  testWidgets('主Root销毁时关闭自己装配的当前数据库', (tester) async {
    final directory = Directory.systemTemp.createTempSync('seqpoint_owner_');
    final old = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _OwnerPaths(directory.path);
    addTearDown(() {
      PathProviderPlatform.instance = old;
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(const SeqApp());
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(AppScope).evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('Root未装配完成');
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    final database = tester.widget<AppScope>(find.byType(AppScope)).database!;
    addTearDown(database.close);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(() => database.raw.select('SELECT 1'), throwsStateError);
  });
}

class _OwnerPaths extends PathProviderPlatform {
  _OwnerPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
