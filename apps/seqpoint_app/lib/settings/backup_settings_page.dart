import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import 'settings_scaffold.dart';

/// 备份与导出：四层备份的开关与恢复入口。
class BackupSettingsPage extends StatefulWidget {
  const BackupSettingsPage({super.key});
  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  bool _busy = false;
  Future<Directory> _snapshotDirectory() async {
    final directory = await getApplicationSupportDirectory();
    return Directory('${directory.path}/snapshots');
  }
  Future<List<Snapshot>>? _snapshotList;
  SeqDatabase? _snapshotDatabase;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final database = AppScope.of(context).database;
    if (database != _snapshotDatabase) {
      _snapshotDatabase = database;
      _snapshotList = database == null ? null :
          _snapshotDirectory().then(SnapshotService(database).list);
    }
  }
  bool get _mobile => defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> _backup() async {
    final database = AppScope.of(context).database;
    if (_busy || database == null) return;
    setState(() => _busy = true);
    String message;
    try {
      final directory = await _snapshotDirectory();
      final service = SnapshotService(database);
      final snapshot = await service.createManual(directory);
      final all = await service.list(directory);
      if (mounted) {
        setState(() { _snapshotList = Future.value(all); });
      }
      message = '已生成未加密本机快照：${snapshot.file.path}';
    } catch (error) {
      message = '备份失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context)..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _pickRestore() async {
    if (_busy || AppScope.of(context).restoring) return;
    File? source;
    setState(() => _busy = true);
    try {
      final selected = await FilePicker.pickFiles(dialogTitle: '选择本机快照');
      if (selected == null || selected.files.isEmpty) return;
      final path = selected.files.single.path;
      if (path == null) throw StateError('无法读取所选快照文件');
      source = File(path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text('选择快照失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (source != null && mounted) await _confirmRestore(source);
  }

  Future<void> _confirmRestore(File source) async {
    final scope = AppScope.of(context);
    final restore = scope.restoreSnapshot;
    if (_busy || scope.restoring || restore == null) return;
    try {
      final version = SnapshotService.validate(source);
      final confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: const Text('确认恢复本机快照'),
        content: SingleChildScrollView(child: Text('${source.path}\n'
            '${(source.lengthSync() / 1024).toStringAsFixed(1)} KB · 格式 v$version · 校验通过\n'
            '文件修改时间：${source.lastModifiedSync().toLocal()}\n\n'
            '将替换当前数据库。恢复前先保留一份未加密保护快照。'
            '支持便签、事项和标签，不恢复系统安全存储凭据或外部附件。'
            '恢复将断开同步；如需同步，请重新配对。')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('确认恢复')),
        ],
      ));
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      await restore(source);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text('恢复失败，当前数据已保留：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(bool markdown) async {
    final database = AppScope.of(context).database;
    if (_busy || database == null) return;
    setState(() => _busy = true);
    String message;
    try {
      if (_mobile) {
        message = await _saveMobile(database, markdown);
      } else {
        final path = await FilePicker.getDirectoryPath(dialogTitle: '选择导出位置');
        if (path == null) {
          message = '未选择或无法访问导出位置';
        } else {
          final Exporter exporter = markdown ? MarkdownExporter(database) : JsonExporter(database);
          final result = await exporter.export(Directory(path));
          message = '已导出至 ${markdown ? result.parent.path : result.path}';
        }
      }
    } catch (error) {
      message = '导出失败：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context)..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<String> _saveMobile(SeqDatabase database, bool markdown) async {
    final archive = Archive();
    if (markdown) {
      for (final entry in MarkdownExporter(database).build().entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
    }
    final bytes = Uint8List.fromList(markdown ? ZipEncoder().encode(archive) :
        utf8.encode(const JsonEncoder.withIndent('  ').convert(JsonExporter(database).build())));
    final name = 'seqpoint-export-${newId()}.${markdown ? 'zip' : 'json'}';
    final copy = defaultTargetPlatform == TargetPlatform.iOS
        ? File('${(await getApplicationDocumentsDirectory()).path}/$name') : null;
    if (copy != null && await copy.exists()) throw StateError('导出副本已存在');
    try {
      final result = await FilePicker.saveFile(fileName: name, bytes: bytes);
      return result == null ? '未选择或未完成系统保存' : '已交由系统保存，请在文件应用中确认';
    } finally {
      if (copy != null && await copy.exists()) await copy.delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final enabled = scope.database != null && !scope.restoring;
    final canRestore = enabled && scope.restoreSnapshot != null;
    return SettingsScaffold(
      title: '备份与导出',
      footnote: 'JSON / Markdown 为未加密的可读导出，含未删除便签（含归档）、'
          '事项及关联标签，不含密钥，不能用于快照恢复。'
          '本机快照不包含系统安全存储中的可用凭据及外部附件。',
      children: [
        if (_busy) const LinearProgressIndicator(),
        SettingsGroup(
          label: '未加密本机快照',
          children: [
            ListTile(title: const Text('立即备份'),
              subtitle: const Text('保留独立副本，不覆盖或自动删除手动快照'),
              trailing: const Icon(Icons.save_outlined, size: 18),
              onTap: _busy || !enabled ? null : _backup),
            ListTile(title: const Text('从本机快照恢复'),
              subtitle: const Text('需确认替换当前数据；JSON和Markdown不能用于恢复'),
              trailing: const Icon(Icons.folder_open_outlined, size: 18),
              onTap: _busy || !canRestore ? null : _pickRestore),
            FutureBuilder<List<Snapshot>>(
              future: _snapshotList,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ListTile(title: const Text('无法读取本机快照'),
                      subtitle: Text('${snapshot.error}'));
                }
                final all = snapshot.data;
                if (all == null) return ListTile(title: Text(enabled ? '正在读取本机快照' : '本机数据未就绪'));
                if (all.isEmpty) return const ListTile(title: Text('尚无本机快照'));
                return Column(children: [for (final entry in all) ListTile(
                  title: Text('${entry.createdAt.toLocal()}'),
                  subtitle: Text('SQLite · 未校验（恢复前校验）\n'
                      '${(entry.bytes / 1024).toStringAsFixed(1)} KB\n${entry.file.path}'),
                  trailing: canRestore ? const Icon(Icons.restore, size: 18) : null,
                  onTap: _busy || !canRestore ? null : () => _confirmRestore(entry.file),
                )]);
              },
            ),
          ],
        ),
        SettingsGroup(
          label: '明文导出',
          children: [
            ListTile(
              title: Text('导出为 JSON'),
              subtitle: Text('未加密的可读数据，包含归档'),
              trailing: Icon(Icons.chevron_right, size: 18),
              onTap: _busy || !enabled ? null : () => _export(false),
            ),
            ListTile(
              title: Text('导出为 Markdown'),
              subtitle: Text(_mobile ? 'ZIP压缩包，内含便签和独立事项的Markdown文件'
                  : '一张便签一个文件，别的笔记软件也能读'),
              trailing: Icon(Icons.chevron_right, size: 18),
              onTap: _busy || !enabled ? null : () => _export(true),
            ),
          ],
        ),
      ],
    );
  }
}
