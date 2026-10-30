import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../util/clock.dart';
import '../../util/ids.dart';
import '../operation.dart';
import 'segment.dart';
import 'vault_layout.dart';

typedef VerifiedSegment = ({Segment segment, List<Operation> operations, List<int> bytes});

/// Vault 目录的读写。
///
/// 单写者原则：本设备只写 `ops/<自己>/`、`acks/<自己>.json`，
/// 只读其他设备的目录。搬运方（网盘 / 局域网 / 节点）因此永远不会
/// 产生冲突文件——这是整个同步方案成立的前提。
class VaultStore {
  static const maxSegmentFileBytes = 12 * 1024 * 1024;
  VaultStore({
    required this.root,
    required this.deviceId,
    required this.codec,
    Future<void> Function(File, List<int>)? writeSegmentBytes,
    Future<void> Function(File, List<int>)? writeAckBytes,
    Clock clock = const SystemClock(),
  }) : _clock = clock,
       _writeSegmentBytes = writeSegmentBytes ?? _writeTemporary,
       _writeAckBytes = writeAckBytes ?? _writeTemporary {
    _checkDeviceId(deviceId);
  }

  static void _checkDeviceId(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      throw ArgumentError('设备标识格式错误');
    }
  }

  void _checkOpsPath(String ofDeviceId) {
    _checkDeviceId(ofDeviceId);
    for (final relative in [VaultLayout.opsDir, VaultLayout.opsDirOf(ofDeviceId)]) {
      if (FileSystemEntity.typeSync(p.join(root.path, relative),
          followLinks: false) == FileSystemEntityType.link) {
        throw StateError('同步目录不能是符号链接');
      }
    }
  }

  /// Vault 根目录。可以是本地目录、网盘同步目录或 NAS 挂载盘。
  final Directory root;

  /// 本设备 id。只有它名下的路径本设备才会写。
  final String deviceId;

  final SegmentCodec codec;
  final Clock _clock;
  final Future<void> Function(File, List<int>) _writeSegmentBytes;
  final Future<void> Function(File, List<int>) _writeAckBytes;

  static Future<void> _writeTemporary(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes, flush: true);
  }

  Directory get _selfOpsDir =>
      Directory(p.join(root.path, VaultLayout.opsDirOf(deviceId)));

  /// 初始化目录结构与 manifest。幂等。
  Future<VaultManifest> init({required String vaultPublicId}) async {
    await root.create(recursive: true);
    for (final dir in [
      VaultLayout.membersDir,
      VaultLayout.opsDir,
      VaultLayout.acksDir,
      VaultLayout.attachmentsDir,
      VaultLayout.snapshotsDir,
    ]) {
      await Directory(p.join(root.path, dir)).create(recursive: true);
    }
    await _selfOpsDir.create(recursive: true);

    final file = File(p.join(root.path, VaultLayout.manifestFile));
    if (file.existsSync()) return readManifest();

    final manifest = VaultManifest(
      formatVersion: VaultManifest.currentFormatVersion,
      vaultPublicId: vaultPublicId,
      keyEpoch: 1,
    );
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    return manifest;
  }

  VaultManifest readManifest() {
    final file = File(p.join(root.path, VaultLayout.manifestFile));
    if (!file.existsSync()) throw StateError('Vault 尚未初始化：缺少 manifest');
    return VaultManifest.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
  }

  // ---- 写：只写本设备名下 ----

  /// 只认DB已知的本机文件名；空段也不能静默忽略后重用序号。
  Set<String> checkSelfHistory(Set<String> knownFileNames) {
    _checkOpsPath(deviceId);
    if (!_selfOpsDir.existsSync()) return const {};
    final found = <String>{};
    final temporaryName = RegExp(r'^(.+\.log)\.tmp\.[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    for (final entry in _selfOpsDir.listSync(followLinks: false)) {
      if (entry is Link) throw StateError('同步段不能是符号链接');
      final name = p.basename(entry.path);
      final temporary = temporaryName.firstMatch(name);
      if (entry is File && temporary != null && temporary.end == name.length &&
          knownFileNames.contains(temporary[1])) {
        continue;
      }
      if (entry is! File || VaultLayout.looksLikeConflict(name) ||
          !knownFileNames.contains(name)) {
        throw StateError('本机目录含DB未知的同步历史');
      }
      found.add(name);
    }
    return found;
  }

  /// 认证/暂存在事务外；调用方在短同步事务内复核DB并替换，再标published。
  Future<void> writePrepared({required String fileName, required List<int> bytes,
    required Set<String> knownFileNames,
    required void Function(List<Operation>, void Function() replace) commit,
  }) async {
    if (bytes.length > maxSegmentFileBytes) throw StateError('同步段文件过大');
    final frozen = List<int>.unmodifiable(bytes);
    final segment = Segment.decode(frozen);
    if (segment.deviceId != deviceId || segment.seq < 1 || segment.keyEpoch < 1 ||
        !segment.createdAt.isUtc || segment.opCount < 1 || segment.opCount > Segment.maxOpsPerSegment ||
        fileName != VaultLayout.segmentName(segment.createdAt.year, segment.createdAt.month, segment.seq)) {
      throw StateError('prepared路径与作者不一致');
    }
    final operations = List<Operation>.unmodifiable(await codec.decode(segment));
    if (operations.length != segment.opCount) throw StateError('prepared内容不完整');
    checkSelfHistory(knownFileNames);
    final file = File(p.join(_selfOpsDir.path, fileName));
    final previous = _readPreparedFile(file);
    if (previous != null && !_sameBytes(previous, frozen)) {
      await _checkPreparedReplacement(previous, segment, operations);
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp.${newId()}');
    try {
      await _writeSegmentBytes(temporary, frozen);
      if (!_sameBytes(frozen, _readPreparedFile(temporary))) throw StateError('暂存段字节不完整');
      commit(operations, () {
        checkSelfHistory(knownFileNames);
        if (!_sameBytes(previous, _readPreparedFile(file))) throw StateError('暂存期间同步文件已改变');
        temporary.renameSync(file.path);
      });
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _checkPreparedReplacement(List<int> previous, Segment next,
      List<Operation> operations) async {
    final old = Segment.decode(previous);
    if (old.isSealed || old.deviceId != next.deviceId || old.seq != next.seq ||
        old.keyEpoch != next.keyEpoch || old.createdAt != next.createdAt ||
        !old.createdAt.isUtc || old.opCount < 1 || old.opCount > operations.length) {
      throw StateError('现有段不是可延续的开放前缀');
    }
    final prefix = await codec.decode(old);
    if (prefix.length != old.opCount || prefix.indexed.any((entry) =>
        jsonEncode(entry.$2.toJson()) != jsonEncode(operations[entry.$1].toJson()))) {
      throw StateError('现有段的认证前缀已改变');
    }
  }

  List<int>? _readPreparedFile(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || file.lengthSync() > maxSegmentFileBytes) {
      throw StateError('同步段路径或大小无效');
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length > maxSegmentFileBytes) throw StateError('同步段文件过大');
    return bytes;
  }
  bool _sameBytes(List<int>? a, List<int>? b) => a == null || b == null
      ? a == null && b == null
      : a.length == b.length && !a.indexed.any((entry) => entry.$2 != b[entry.$1]);

  /// 追加操作到本设备的当前段。写满自动封口另起新段。
  ///
  /// 返回本次写入涉及的段序号。
  Future<List<int>> append(List<Operation> ops) async {
    if (ops.isEmpty) return const [];
    _checkOpsPath(deviceId);
    await _selfOpsDir.create(recursive: true);

    final touched = <int>[];
    var remaining = List<Operation>.from(ops);

    while (remaining.isNotEmpty) {
      final current = await _openWritableSegment();
      final room = Segment.maxOpsPerSegment - current.$2.length;
      final take = remaining.take(room).toList();
      remaining = remaining.skip(room).toList();

      final merged = [...current.$2, ...take];
      await _writeSegment(seq: current.$1, ops: merged, createdAt: current.$3);
      touched.add(current.$1);
    }
    return touched;
  }

  /// 找到可继续写入的段：最后一个未写满的，或新建一个。
  /// 返回 (段序号, 该段已有的操作)。
  Future<(int, List<Operation>, DateTime)> _openWritableSegment() async {
    final segments = await listSegments(deviceId);
    final now = _clock.now().toUtc();
    if (segments.isEmpty) return (1, <Operation>[], now);

    final last = segments.last;
    final operations = await readOperations(deviceId, last.seq);
    if (operations.length != last.opCount) throw StateError('本机段尚未完整');
    if (last.isSealed) {
      return (last.seq + 1, <Operation>[], now);
    }
    if (last.createdAt.year != now.year || last.createdAt.month != now.month) {
      await _writeSegment(seq: last.seq, ops: operations,
          createdAt: last.createdAt, sealed: true);
      return (last.seq + 1, <Operation>[], now);
    }
    return (last.seq, operations, last.createdAt);
  }

  Future<void> _writeSegment({
    required int seq,
    required List<Operation> ops,
    required DateTime createdAt,
    bool sealed = false,
  }) async {
    final manifest = readManifest();
    final header = Segment(
      deviceId: deviceId,
      keyEpoch: manifest.keyEpoch,
      seq: seq,
      opCount: ops.length,
      createdAt: createdAt,
      sealed: sealed,
      payload: const [],
    );
    final segment = await codec.encode(header, ops);
    final file = File(p.join(root.path,
        _segmentPath(deviceId, seq, createdAt: header.createdAt)));
    await file.parent.create(recursive: true);
    final bytes = segment.encode();
    if (bytes.length > maxSegmentFileBytes) throw StateError('同步段文件过大');
    final temporary = File('${file.path}.tmp.${newId()}');
    try {
      await _writeSegmentBytes(temporary, bytes);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  // ---- 读：任意设备 ----

  /// 列出某设备的所有段头，按序号升序。
  Future<List<Segment>> listSegments(String ofDeviceId) async {
    _checkOpsPath(ofDeviceId);
    final dir = Directory(p.join(root.path, VaultLayout.opsDirOf(ofDeviceId)));
    if (!dir.existsSync()) return const [];

    final segments = <Segment>[];
    final sequences = <int>{};
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Link) throw StateError('同步段不能是符号链接');
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.log')) continue;
      if (VaultLayout.looksLikeConflict(name)) {
        // 单写者原则被破坏了。不静默吞掉——这是程序缺陷的信号。
        throw StateError('检测到冲突文件，单写者原则被破坏：${entity.path}');
      }
      final firstLine = _firstLineOf(entity);
      if (firstLine == null) continue;
      final segment = Segment.decodeHeader(firstLine);
      if (segment.deviceId != ofDeviceId || segment.seq < 1 ||
          name != p.basename(_segmentPath(ofDeviceId, segment.seq,
              createdAt: segment.createdAt)) || !sequences.add(segment.seq)) {
        throw StateError('段文件名与作者或序号不一致');
      }
      segments.add(segment);
    }
    segments.sort((a, b) => a.seq.compareTo(b.seq));
    return segments;
  }

  Future<List<Operation>> readOperations(String ofDeviceId, int seq) async =>
      (await readVerifiedSegment(ofDeviceId, seq))?.operations ?? const [];

  /// header、操作与原字节来自同一次读取/验签，不能混用扫描时的header。
  Future<VerifiedSegment?> readVerifiedSegment(String ofDeviceId, int seq) async {
    _checkDeviceId(ofDeviceId);
    if (seq < 1) throw ArgumentError('段序号格式错误');
    final matching = (await listSegments(ofDeviceId)).where((s) => s.seq == seq);
    if (matching.isEmpty) return null;
    final file = File(p.join(root.path,
        _segmentPath(ofDeviceId, seq, createdAt: matching.single.createdAt)));
    if (await file.length() > maxSegmentFileBytes) throw StateError('同步段文件过大');
    final bytes = await file.readAsBytes();
    if (bytes.length > maxSegmentFileBytes) throw StateError('同步段文件过大');
    final segment = Segment.decode(bytes);
    if (segment.deviceId != ofDeviceId || segment.seq != seq ||
        p.basename(file.path) != p.basename(_segmentPath(ofDeviceId, seq,
            createdAt: segment.createdAt))) {
      throw StateError('段路径与身份不一致');
    }
    final operations = await codec.decode(segment);
    if (operations.length != segment.opCount) throw StateError('同步段条数不一致');
    final frozen = segment.withPayload(List<int>.unmodifiable(segment.payload),
        signature: List<int>.unmodifiable(segment.signature));
    return (segment: frozen, operations: List<Operation>.unmodifiable(operations),
        bytes: List<int>.unmodifiable(bytes));
  }

  /// 目录中出现过的所有设备 id。
  Future<List<String>> knownDevices() async {
    final dir = Directory(p.join(root.path, VaultLayout.opsDir));
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
  }

  // ---- 水位 ----

  /// 生产接收器写连续封口前缀；历史内存测试入口使用最后观察段。
  Future<Map<String, int>> readAck(String ofDeviceId) async {
    final file = File(p.join(root.path, VaultLayout.ackPath(ofDeviceId)));
    if (!file.existsSync()) return const {};
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return json.map((k, v) => MapEntry(k, v as int));
  }

  Future<void> writeSelfAck(Map<String, int> watermarks) async {
    final bytes = utf8.encode(jsonEncode(watermarks));
    final file = File(p.join(root.path, VaultLayout.ackPath(deviceId)));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp.${newId()}');
    try {
      await _writeAckBytes(temporary, bytes);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// 全体成员的水位，用于判断某段能否回收。
  Future<Map<String, Map<String, int>>> readAllAcks() async {
    final dir = Directory(p.join(root.path, VaultLayout.acksDir));
    if (!dir.existsSync()) return const {};
    final result = <String, Map<String, int>>{};
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final owner = p.basenameWithoutExtension(entity.path);
      result[owner] = await readAck(owner);
    }
    return result;
  }

  // ---- 回收 ----

  /// 当前不回收段：尚无可验证的覆盖快照，ACK 或 TTL 都不足以安全删除。
  /// 保留参数兼容现有调用；实现 V1 的快照覆盖检查后才能启用回收。
  Future<int> reclaim({
    List<String>? members,
    Duration ttl = const Duration(days: 30),
  }) async {
    return 0;
  }

  // ---- 内部 ----

  /// V1月份+全局递增序号；跨月不得重用旧序号。
  String _segmentPath(String ofDeviceId, int seq, {required DateTime createdAt}) => p.join(
        VaultLayout.opsDirOf(ofDeviceId),
        VaultLayout.segmentName(createdAt.toUtc().year, createdAt.toUtc().month, seq),
      );

  String? _firstLineOf(File file) {
    if (file.lengthSync() > maxSegmentFileBytes) throw StateError('同步段文件过大');
    final content = file.readAsStringSync();
    final idx = content.indexOf('\n');
    if (idx < 0) return null;
    return content.substring(0, idx);
  }
}
