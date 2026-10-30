import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';

void main() {
  test('Bootstrap销毁关闭数据库，重复销毁安全', () async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    expect(boot.notes.active(), isEmpty);
    boot.dispose();
    expect(boot.notes.active, throwsStateError);
    expect(boot.dispose, returnsNormally);
  });
}
