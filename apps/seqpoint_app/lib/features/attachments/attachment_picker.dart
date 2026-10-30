import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class SelectedImage {
  const SelectedImage(this.bytes, this.name);
  final Uint8List bytes;
  final String name;
}

class AttachmentPicker {
  AttachmentPicker({Future<FilePickerResult?> Function()? select})
    : _select = select ?? _open;
  final Future<FilePickerResult?> Function() _select;

  static Future<FilePickerResult?> _open() => FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
    allowMultiple: false,
    withData: false,
  );

  Future<SelectedImage?> pick() async {
    final result = await _select();
    if (result == null || result.files.isEmpty) return null;
    final selected = result.files.single;
    if (selected.size > AttachmentService.maxImageBytes) {
      throw ArgumentError('图片不能超过 20 MB');
    }
    final path = selected.path;
    if (path == null) throw StateError('无法读取所选图片，请换一张重试');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in File(path).openRead()) {
      if (bytes.length + chunk.length > AttachmentService.maxImageBytes) {
        throw ArgumentError('图片不能超过 20 MB');
      }
      bytes.add(chunk);
    }
    return SelectedImage(bytes.takeBytes(), selected.name);
  }
}
