/// 序点 SeqPoint 核心层。
///
/// 纯 Dart，不依赖 Flutter，可在主机上直接跑单元测试。
/// 分层：model（数据） → repo（存取） → service（业务规则）；
/// 另有 ai（整理管线）、reminder（提醒决策）、sync（同步引擎）三个横向能力。
library;

// 数据模型
export 'src/model/activity.dart';
export 'src/model/attachment.dart';
export 'src/model/enums.dart';
export 'src/model/item.dart';
export 'src/model/note.dart';
export 'src/model/reminder.dart';
export 'src/model/secret.dart';
export 'src/model/tag.dart';

// 数据库
export 'src/db/database.dart';
export 'src/db/migrations.dart';

// 仓储
export 'src/repo/activity_repository.dart';
export 'src/repo/item_repository.dart';
export 'src/repo/note_repository.dart';
export 'src/repo/notification_plan_repository.dart';
export 'src/repo/reminder_repository.dart';
export 'src/repo/tag_repository.dart';

// 业务服务
export 'src/service/note_service.dart';
export 'src/service/attachment_service.dart';
export 'src/service/meeting_transcript_service.dart';

// AI 整理
export 'src/ai/ai_provider.dart';
export 'src/ai/openai_compatible_provider.dart';
export 'src/ai/organize_applier.dart';
export 'src/ai/organize_proposal.dart';
export 'src/ai/organize_service.dart';
export 'src/ai/rules/syntax_parser.dart';
export 'src/ai/rules/time_parser.dart';

// 提醒
export 'src/reminder/reminder_engine.dart';
export 'src/reminder/reminder_policy.dart';

// 搜索、备份、导出
export 'src/backup/snapshot_service.dart';
export 'src/backup/restore_session.dart';
export 'src/export/exporters.dart';
export 'src/search/search_service.dart';

// 同步
export 'src/sync/field_merge.dart';
export 'src/sync/hlc.dart';
export 'src/sync/op_log.dart';
export 'src/sync/operation.dart';
export 'src/sync/operation_validation.dart';
export 'src/sync/sync_engine.dart';
export 'src/sync/sync_inbox.dart';
export 'src/sync/sync_outbox.dart';
export 'src/sync/sync_baseline.dart';
export 'src/sync/sync_publisher.dart';
export 'src/sync/membership_sync_policy.dart';
export 'src/sync/sync_publication_catalog.dart';
export 'src/sync/lan_sync_runtime.dart';
export 'src/sync/sync_projector.dart';
export 'src/sync/segment_receiver.dart';
export 'src/sync/transport/folder_transport.dart';
export 'src/sync/transport/lan_transport.dart';
export 'src/sync/transport/lan_https_server.dart';
export 'src/sync/transport/lan_protocol.dart' show LanAuthorization;
export 'src/sync/transport/lan_file_source.dart' show LanPublishedFiles;
export 'src/sync/transport/relay_transport.dart';
export 'src/sync/transport/vault_transport.dart';
export 'src/sync/vault/encrypted_segment_codec.dart';
export 'src/sync/vault/segment.dart';
export 'src/sync/vault/vault_layout.dart';
export 'src/sync/vault/vault_store.dart';

// 加密与身份
export 'src/crypto/crypto_primitives.dart';
export 'src/crypto/lan_tls_identity.dart';
export 'src/crypto/ed25519_signer.dart';
export 'src/crypto/vault_key.dart';
export 'src/crypto/xchacha20_aead.dart';
export 'src/identity/device_identity.dart' hide MembershipEvent, MembershipEventType;
export 'src/identity/device_keys.dart';
export 'src/identity/member_keys.dart';
export 'src/identity/membership_state.dart';
export 'src/identity/membership_file.dart';
export 'src/identity/member_epoch_envelope.dart';
export 'src/identity/pairing.dart';
export 'src/identity/pairing_handshake.dart';
export 'src/identity/pairing_invitation.dart';
export 'src/identity/pairing_response.dart';
export 'src/identity/pairing_transcript.dart' show PairingTranscript, PairingParticipant;

// 工具
export 'src/util/clock.dart';
export 'src/util/ids.dart';
export 'src/util/result.dart';
export 'src/sync/auto_sync_scheduler.dart';
export 'src/sync/attachment_sync_policy.dart';

/// 核心层版本，与 pubspec.yaml 保持同步。
const String coreVersion = '0.1.0';
