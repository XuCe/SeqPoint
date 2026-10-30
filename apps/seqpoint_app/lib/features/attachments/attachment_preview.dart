import 'dart:io';

import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({
    super.key,
    required this.image,
    required this.service,
    this.onRemove,
  });
  final Attachment image;
  final AttachmentService service;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8, top: 8),
    child: SizedBox(
      width: 160,
      child: Column(
        children: [
          FutureBuilder<File>(
            future: service.file(image.id),
            builder: (context, value) {
              final file = value.data;
              return SizedBox(
                height: 120,
                width: 160,
                child: file == null || !file.existsSync()
                    ? Center(child: Text(image.isShared?'等待原文件同步':'图片不可用'))
                    : InkWell(
                        onTap: () => _preview(context, file),
                        child: Semantics(
                          button: true,
                          label: '预览 ${image.fileName ?? '图片'}',
                          child: Image.file(
                            file,
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            errorBuilder: (_, _, _) =>
                                const Center(child: Text('图片不可用')),
                          ),
                        ),
                      ),
              );
            },
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  image.fileName ?? '图片',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: '删除图片',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  void _preview(BuildContext context, File file) => showDialog<void>(
    context: context,
    builder: (dialog) => Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(image.fileName ?? '图片'),
          ),
          Flexible(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('图片不可用，文件可能已损坏或被移除'),
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
