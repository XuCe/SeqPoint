import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

// 故意退出而不关闭连接，用真实崩溃遗留验证恢复协议。
void main(List<String> args) {
  final db = SeqDatabase.open(args.single);
  db.raw.execute('PRAGMA journal_mode = WAL');
  db.raw.execute('PRAGMA wal_autocheckpoint = 0');
  db.raw.execute('UPDATE notes SET raw_content=?', ['stale WAL']);
  final value = db.raw.select('SELECT raw_content FROM notes').single['raw_content'];
  exit(value == 'stale WAL' ? 0 : 1);
}
