import 'dart:collection';

typedef PublishedEntry = ({int size,List<int> Function() read});

/// Immutable metadata index; asking for one file never reads other payloads.
class PublishedFileView extends MapBase<String,List<int>> {
  PublishedFileView(Map<String,PublishedEntry> entries):_entries=Map.unmodifiable(entries);
  final Map<String,PublishedEntry> _entries;
  int? size(String path)=>_entries[path]?.size;
  @override Iterable<String> get keys=>_entries.keys;
  @override List<int>? operator [](Object? key)=>_entries[key]?.read();
  @override void operator []=(String key,List<int> value)=>throw UnsupportedError('Read-only publications');
  @override void clear()=>throw UnsupportedError('Read-only publications');
  @override List<int>? remove(Object? key)=>throw UnsupportedError('Read-only publications');
  static PublishedFileView combine(List<Map<String,List<int>>> sources) {
    final entries=<String,PublishedEntry>{};
    for(final source in sources) {
      if(source is PublishedFileView) {entries.addAll(source._entries);continue;}
      for(final key in source.keys) {
        final bytes=List<int>.unmodifiable(source[key]!);
        entries[key]=(size:bytes.length,read:()=>bytes);
      }
    }
    return PublishedFileView(entries);
  }
}
