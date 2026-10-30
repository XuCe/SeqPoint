import 'dart:convert';
import '../db/database.dart';
import '../search/search_service.dart';
import '../util/clock.dart';
import 'hlc.dart';
import 'operation.dart';
import 'tag_projection.dart';
import 'item_tag_projection.dart';

/// 从持久事实重新投影；上层在同一事务推进水位，提交后才可ACK。
class SyncProjector {
  SyncProjector(this._db);
  final SeqDatabase _db;

  int project() {
    try {
      return _project();
    } catch (_) {
      throw StateError('无法投影同步数据，未提交本批更改');
    }
  }

  int _project() => _db.transaction(() => _db.withoutSyncCapture(() {
    var pending = 0;
    final groups = <SyncObjectKey, Map<String, Object?>>{};
    final tagOps = <Operation>[];
    final markers = <SyncObjectKey, Map<String, Hlc>>{};
    final rows = _db.raw.select('''
      SELECT * FROM (
        SELECT op_id,object_type,object_id,field,value_json,hlc_millis,hlc_counter,device_id,
          ROW_NUMBER() OVER (PARTITION BY object_type,object_id,field
            ORDER BY hlc_millis DESC,hlc_counter DESC,device_id DESC) AS rank
        FROM sync_operations WHERE object_type IN ('note','item','tag','item_tag','attachment')
      ) WHERE rank=1
    ''');
    for (final row in rows) {
      final key = (type: row['object_type'] as String, id: row['object_id'] as String);
      if (key.type == 'tag' || key.type == 'item_tag') {
        tagOps.add(Operation(opId: row['op_id'] as String, deviceId: row['device_id'] as String,
            hlc: Hlc(millis: row['hlc_millis'] as int, counter: row['hlc_counter'] as int,
                deviceId: row['device_id'] as String), objectType: key.type, objectId: key.id,
            field: row['field'] as String, value: jsonDecode(row['value_json'] as String)));
        continue;
      }
      groups.putIfAbsent(key, () => {})[row['field'] as String] =
          jsonDecode(row['value_json'] as String);
      final field = row['field'] as String;
      if (field == Operation.tombstoneField || field == Operation.restoreField) {
        markers.putIfAbsent(key, () => {})[field] = Hlc(
            millis: row['hlc_millis'] as int, counter: row['hlc_counter'] as int,
            deviceId: row['device_id'] as String);
      }
    }
    for (final type in const ['note', 'item', 'attachment']) {
      final fields = Operation.syncFields[type]!.toList();
      final table = const {'note': 'notes', 'item': 'items', 'attachment': 'attachments'}[type]!;
      for (final entry in groups.entries.where((e) => e.key.type == type)) {
        final values = entry.value;
        if (!fields.every(values.containsKey)) { pending++; continue; }
        if (type == 'item' && values['note_id'] != null && _db.raw.select(
            'SELECT id FROM notes WHERE id=?', [values['note_id']]).isEmpty) {
          pending++; continue;
        }
        if (type == 'attachment') {
          if ((values['note_id'] == null) == (values['item_id'] == null) ||
              (values['media'] == 'image' && (values['byte_size'] as int) > 20 * 1024 * 1024)) {
            throw const FormatException('附件关联或大小无效');
          }
          final parent = values['note_id'] == null ? 'items' : 'notes';
          if (_db.raw.select('SELECT id FROM $parent WHERE id=?',
              [values['note_id'] ?? values['item_id']]).isEmpty) {
            pending++; continue;
          }
        }
        final tomb = markers[entry.key]?[Operation.tombstoneField];
        final restore = markers[entry.key]?[Operation.restoreField];
        final hidden = tomb != null && (restore == null || !(restore > tomb));
        values['deleted_at'] = hidden ? values['deleted_at'] ?? encodeTime(
            DateTime.fromMillisecondsSinceEpoch(tomb.millis, isUtc: true)) : null;
        final data = fields.map((field) {
          final value = values[field];
          return field.endsWith('_at') && value != null
              ? encodeTime(DateTime.parse(value as String)) : value;
        }).toList();
        final localColumn = type == 'attachment' ? ',sync' : '';
        final localValue = type == 'attachment' ? ",'trusted_devices'" : '';
        _db.raw.execute('INSERT INTO $table (id,${fields.join(',')}$localColumn) '
            'VALUES (?,${fields.map((_) => '?').join(',')}$localValue) ON CONFLICT(id) '
            'DO UPDATE SET ${fields.map((f) => '$f=excluded.$f').join(',')}',
            [entry.key.id, ...data]);
        if (type == 'attachment') continue;
        final search = SearchService(_db);
        if (values['deleted_at'] != null) {
          search.removeFromIndex(type, entry.key.id);
        } else if (type == 'note') {
          final title = values['title'] as String?;
          search.indexNote(entry.key.id, '${title == null || title.isEmpty ? '' : '$title\n'}${values['raw_content']}');
        } else {
          search.indexItem(entry.key.id, values['title'] as String);
        }
      }
    }
    final tagView = projectTags(_db, tagOps);
    if (tagOps.any((op) => op.objectType == 'item_tag')) {
      var linkPending = projectItemTags(_db, tagOps, tagView);
      projectTags(_db, tagOps); // 关联事实清理后，同事务收尾此前暂缓的标签墓碑。
      if (linkPending > 0) {
        linkPending = projectItemTags(_db, tagOps, tagView); // 补齐收尾后才可用的新目标。
      }
      pending += linkPending;
    }
    pending += pendingTagCount(_db, tagView);
    _db.raw.execute('UPDATE sync_local SET pending_count=? WHERE id=1 AND pending_count<>?',
        [pending, pending]);
    return pending;
  }));
}
