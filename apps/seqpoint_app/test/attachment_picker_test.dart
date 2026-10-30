import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/attachments/attachment_picker.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  test('取消选择返回空且不读取文件', () async {
    expect(await AttachmentPicker(select: () async => null).pick(), isNull);
  });
  test('选定文件复制字节，保留展示名', () async {
    final dir = await Directory.systemTemp.createTemp('seqpoint-picker-');
    addTearDown(() => dir.delete(recursive: true));
    final source = await File('${dir.path}/source.png').writeAsBytes([1, 2, 3]);
    final picker = AttachmentPicker(select: () async => FilePickerResult([
      PlatformFile(name: 'source.png', size: 3, path: source.path),
    ]));
    final image = await picker.pick();
    expect(image!.bytes, [1, 2, 3]);
    expect(image.name, 'source.png');
  });
  test('缺失本地路径、超限、权限拒绝均传播失败', () async {
    final unavailable = AttachmentPicker(select: () async => FilePickerResult([
      PlatformFile(name: 'x.png', size: 1),
    ]));
    await expectLater(unavailable.pick(), throwsStateError);
    final large = AttachmentPicker(select: () async => FilePickerResult([
      PlatformFile(name: 'x.png', size: AttachmentService.maxImageBytes + 1),
    ]));
    await expectLater(large.pick(), throwsArgumentError);
    final denied = AttachmentPicker(select: () async =>
      throw const FileSystemException('permission denied'));
    await expectLater(denied.pick(), throwsA(isA<FileSystemException>()));
  });
}
