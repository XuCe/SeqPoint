import 'package:seqpoint_core/src/ai/organize_proposal.dart';
import 'package:test/test.dart';

void main() {
  test('提案绑定原文，部分选择与字段编辑保持候选身份和来源行', () {
    const first = ProposedItem(id: 'candidate-a', title: '事项一', lineIndex: 0);
    const second = ProposedItem(id: 'candidate-b', title: '事项二', lineIndex: 1);
    const proposal = OrganizeProposal(noteId: 'note', sourceContent: '原文一\n原文二',
        items: [first, second]);
    final edited = first.copyWith(title: '用户改标题', accepted: false, important: true);
    expect(proposal.sourceContent, '原文一\n原文二');
    expect(edited.id, first.id); expect(edited.lineIndex, 0);
    expect(edited.title, '用户改标题'); expect(edited.accepted, isFalse);
    expect(edited.important, isTrue); expect(second.accepted, isTrue);
    expect(proposal.items.first.title, '事项一');
  });
  test('清除期限保留身份和原对象', () {
    final due = DateTime.utc(2026, 11, 1);
    final item = ProposedItem(id: 'candidate', title: '事项', lineIndex: 0, dueAt: due);
    final edited = item.copyWith(clearDueAt: true);
    expect(edited.id, item.id); expect(edited.dueAt, isNull);
    expect(item.dueAt, due);
  });
}
