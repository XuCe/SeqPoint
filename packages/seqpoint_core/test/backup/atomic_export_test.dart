import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late Directory dir;
  late NoteService service;
  final clock = FakeClock(DateTime.utc(2026, 10, 25));
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    dir = Directory.systemTemp.createTempSync('seqpoint_atomic_export_');
    service = NoteService(db: db, notes: NoteRepository(db),
        items: ItemRepository(db), activities: ActivityRepository(db));
    service.capture('第一份内容');
  });
  tearDown(() { db.close(); dir.deleteSync(recursive: true); });

  test('Markdown写文件期间新增写入不会混入本次导出', () async {
    service.capture('第二份原内容');
    var changed = false;
    final parent = Zone.current;
    final index = await IOOverrides.runZoned(() => MarkdownExporter(db).export(dir),
        createFile: (path) {
          final real = parent.run(() => File(path));
          return _HookFile(real, () {
            if (changed) return;
            changed = true;
            db.raw.execute('UPDATE notes SET raw_content = ?', ['新写入内容']);
          });
        });
    final content = index.parent.listSync().whereType<File>()
        .map((f) => f.readAsStringSync()).join('\n');
    expect(changed, isTrue);
    expect(content, contains('第二份原内容'));
    expect(content, contains('第一份内容'));
    expect(content, isNot(contains('新写入内容')));
    expect(NoteRepository(db).active().every((n) => n.rawContent == '新写入内容'), isTrue);
  });

  for (final markdown in [false, true]) {
    Exporter exporter() => markdown ? MarkdownExporter(db, clock: clock)
        : JsonExporter(db, clock: clock);
    test('${markdown ? 'Markdown' : 'JSON'} 同时刻重复导出保留旧件与目标文件', () async {
      final sentinel = File('${dir.path}/README.md')..writeAsStringSync('原有文件');
      final first = await exporter().export(dir);
      final bytes = first.readAsBytesSync();
      service.capture('后来添加的内容');
      final second = await exporter().export(dir);
      expect(first.path, isNot(second.path));
      expect(first.readAsBytesSync(), bytes);
      expect(sentinel.readAsStringSync(), '原有文件');
      expect(second.readAsStringSync(), contains('后来添加的内容'));
    });
    test('${markdown ? 'Markdown' : 'JSON'} 写到一半失败不发布残件或覆盖旧导出', () async {
      final first = await exporter().export(dir);
      final bytes = first.readAsBytesSync();
      final paths = dir.listSync().map((e) => e.path).toSet();
      service.capture('失败这次的新内容');
      final parent = Zone.current;
      await expectLater(IOOverrides.runZoned(() => exporter().export(dir),
          createFile: (path) {
            final real = parent.run(() => File(path));
            return path.endsWith('.json') || path.endsWith('README.md')
                ? _PartialFile(real) : real;
          }), throwsA(isA<FileSystemException>()));
      expect(first.readAsBytesSync(), bytes);
      expect(dir.listSync().map((e) => e.path).toSet(), paths);
    });
  }
}

class _PartialFile implements File {
  _PartialFile(this.real);
  final File real;
  @override
  Future<File> writeAsString(String contents, {FileMode mode = FileMode.write,
      Encoding encoding = utf8, bool flush = false}) async {
    await real.writeAsString('partial');
    throw FileSystemException('injected partial write', real.path);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HookFile implements File {
  _HookFile(this.real, this.beforeWrite);
  final File real;
  final void Function() beforeWrite;
  @override
  Directory get parent => real.parent;
  @override
  Future<File> writeAsString(String contents, {FileMode mode = FileMode.write,
      Encoding encoding = utf8, bool flush = false}) {
    beforeWrite();
    return real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
