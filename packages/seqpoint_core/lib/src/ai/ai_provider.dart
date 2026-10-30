import '../util/result.dart';

/// 隐私档位。默认"仅本地规则"，云端需用户显式开启并告知去向。
enum AiMode { off, localRulesOnly, cloud }

/// 模型服务商配置。密钥不在此对象中，使用时从安全存储读取。
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    this.baseUrl,
    this.model,
    this.timeout = const Duration(seconds: 30),
  });

  /// 'claude' | 'openaiCompatible' | 'local'
  final String id;

  /// 自定义 Base URL，国内访问必需。
  final String? baseUrl;
  final String? model;
  final Duration timeout;
}

/// 模型调用抽象。实现按服务商分文件，核心层只依赖这个接口。
abstract interface class AiProvider {
  String get id;

  /// 单轮结构化调用。[schemaHint] 描述期望的 JSON 形状。
  Future<Result<Map<String, Object?>>> complete({
    required String prompt,
    required String schemaHint,
    required String apiKey,
    ProviderConfig config,
  });

  /// 连通性测试，设置页的"测试连接"按钮用。
  Future<Result<void>> ping({required String apiKey, ProviderConfig config});
}
