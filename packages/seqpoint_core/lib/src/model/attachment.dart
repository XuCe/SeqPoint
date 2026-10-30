/// 原文件保留在当前设备的受管目录，数据库不记录外部文件路径。
class Attachment {
  const Attachment({required this.id, required this.mime,
    required this.byteSize, required this.sha256, required this.createdAt,
    this.noteId, this.itemId, this.fileName, this.media = 'image',this.syncPolicy='local_only'});

  final String id;
  final String? noteId;
  final String? itemId;
  final String? fileName;
  final String media;
  final String syncPolicy;
  bool get isShared=>syncPolicy!='local_only';
  final String mime;
  final int byteSize;
  final String sha256;
  final DateTime createdAt;

  factory Attachment.fromRow(Map<String, Object?> row) => Attachment(
    id: row['id'] as String,
    noteId: row['note_id'] as String?,
    itemId: row['item_id'] as String?,
    fileName: row['file_name'] as String?,
    media: row['media'] as String,
    syncPolicy:row['sync'] as String? ?? 'local_only',
    mime: row['mime'] as String? ?? 'application/octet-stream',
    byteSize: row['byte_size'] as int,
    sha256: row['sha256'] as String? ?? '',
    createdAt: DateTime.parse(row['created_at'] as String),
  );
}
