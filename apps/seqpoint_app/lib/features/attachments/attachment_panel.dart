import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'attachment_picker.dart';
import 'attachment_preview.dart';
import '../../app/app_scope.dart';

class AttachmentPanel extends StatefulWidget {
  const AttachmentPanel({
    super.key,
    required this.database,
    this.noteId,
    this.itemId,
    this.enabled = true,
    this.service,
    this.picker,
  }) : assert((noteId == null) != (itemId == null));
  final SeqDatabase database;
  final String? noteId;
  final String? itemId;
  final bool enabled;
  final AttachmentService? service;
  final AttachmentPicker? picker;

  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  AttachmentService? _service;
  List<Attachment> _images = [];
  String? _error;
  bool _busy = false;
  int _generation = 0;
  int? _syncRevision;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision=context.dependOnInheritedWidgetOfExactType<AppScope>()?.syncRevision;
    if(_syncRevision!=null && revision!=_syncRevision && _service!=null) {
      _images=_service!.list(noteId:widget.noteId,itemId:widget.itemId);
    }
    _syncRevision=revision;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AttachmentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.database != widget.database ||
        oldWidget.noteId != widget.noteId ||
        oldWidget.itemId != widget.itemId) {
      _load();
    }
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    _service = null;
    _images = [];
    _busy = false;
    _error = null;
    try {
      final service =
          widget.service ??
          AttachmentService(
            db: widget.database,
            directory: Directory(
              '${(await getApplicationSupportDirectory()).path}/attachments',
            ),
          );
      if (!_current(generation)) return;
      setState(() {
        _service = service;
        _images = service.list(noteId: widget.noteId, itemId: widget.itemId);
      });
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法读取本机图片，请重试');
    }
  }

  Future<void> _add() async {
    final service = _service;
    if (_busy || !widget.enabled || service == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selected = await (widget.picker ?? AttachmentPicker()).pick();
      if (!_current(generation) || !widget.enabled || selected == null) return;
      await service.addImage(
        selected.bytes,
        name: selected.name,
        noteId: widget.noteId,
        itemId: widget.itemId,
      );
      if (_current(generation)) {
        setState(() {
          _images = service.list(noteId: widget.noteId, itemId: widget.itemId);
        });
      }
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = '无法添加图片，请检查读取权限或文件格式（最大 20 MB）');
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Attachment image) async {
    final generation = _generation;
    final service = _service;
    if (service == null || _busy || !widget.enabled) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await service.remove(image.id);
    } catch (_) {
      if (_current(generation)) setState(() => _error = '无法清理图片文件，请重试');
    } finally {
      if (_current(generation)) {
        setState(() {
          _busy = false;
          _images = service.list(noteId: widget.noteId, itemId: widget.itemId);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _busy || !widget.enabled || _service == null
                  ? null
                  : _add,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('添加图片'),
            ),
            Text(
              AttachmentSyncPolicy(widget.database).enabled?'原文件可同步 · 最大 20 MB':'本机保存 · 最大 20 MB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        if (_error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (_service == null)
                TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        if (_images.isNotEmpty && _service != null)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _images
                  .map(
                    (image) => AttachmentPreview(
                      key:ValueKey('${image.id}:$_syncRevision'),
                      image: image,
                      service: _service!,
                      onRemove: _busy || !widget.enabled
                          ? null
                          : () => _remove(image),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    ),
  );
}
