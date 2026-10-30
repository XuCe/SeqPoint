import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// 生成业务对象 id。全库统一 UUID v4 字符串。
String newId() => _uuid.v4();
