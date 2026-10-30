import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../mobile/note_detail_page.dart';
import 'item_editor_page.dart';

Future<void> openNoteSearch(BuildContext context) async {
  final scope = AppScope.of(context);
  final hit = await showSearch<SearchHit?>(
    context: context,
    delegate: NoteSearchDelegate(scope.search),
  );
  if (hit == null || !context.mounted) return;
  try {
    if (!hit.isNote) {
      await ItemEditorPage.open(context, hit.objectId);
    } else if (scope.windows case final windows?) {
      await windows.openSticky(hit.objectId);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: hit.objectId)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('打开搜索结果失败，请重试。')));
    }
  }
}

class NoteSearchDelegate extends SearchDelegate<SearchHit?> {
  NoteSearchDelegate(this.search) : super(searchFieldLabel: '搜索便签和事项');
  final SearchService search;

  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(
      tooltip: '清空',
      icon: const Icon(Icons.clear),
      onPressed: () => query = '',
    ),
  ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: '返回',
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, null),
  );
  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) return const Center(child: Text('输入关键词搜索便签和事项'));
    return FutureBuilder<List<SearchHit>>(
      future: search.query(query),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('搜索失败，请重新输入关键词。'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final hits = snapshot.data!;
        if (hits.isEmpty) return const Center(child: Text('没有找到相关便签或事项'));
        return ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, index) {
            final hit = hits[index];
            return ListTile(
              leading: Icon(
                hit.isNote ? Icons.note_outlined : Icons.check_circle_outline,
              ),
              title: Text(
                hit.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${hit.isNote ? '便签' : '事项'}${hit.archived ? ' · 已归档/完成' : ''}',
              ),
              onTap: () => close(context, hit),
            );
          },
        );
      },
    );
  }
}
