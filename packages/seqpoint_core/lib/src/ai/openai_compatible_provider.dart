import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../util/result.dart';
import 'ai_provider.dart';

class OpenAiCompatibleProvider implements AiProvider {
  OpenAiCompatibleProvider({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  @override
  String get id => 'openaiCompatible';

  @override
  Future<Result<Map<String, Object?>>> complete({required String prompt,
    required String schemaHint, required String apiKey,
    ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async {
    final base = Uri.tryParse(config.baseUrl ?? '');
    if (config.id != id || base == null || base.scheme != 'https' || base.host.isEmpty ||
        base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment ||
        apiKey.contains(RegExp(r'[\r\n]')) ||
        config.model?.trim().isNotEmpty != true || apiKey.trim().isEmpty ||
        config.timeout <= Duration.zero) {
      return const Err('invalid_config');
    }
    if (utf8.encode(prompt).length > 65536) {
      return const Err('invalid_request');
    }
    http.Client? client;
    try {
      client = _clientFactory();
      final path = base.path.endsWith('/') ? base.path : '${base.path}/';
      final request = http.Request('POST', base.replace(path: '${path}chat/completions'))
        ..followRedirects = false
        ..headers.addAll({'authorization': 'Bearer $apiKey', 'content-type': 'application/json'})
        ..body = jsonEncode({'model': config.model!.trim(), 'stream': false,
          'response_format': {'type': 'json_object'}, 'messages': [
            {'role': 'system', 'content': 'Return only JSON matching this shape: $schemaHint'},
            {'role': 'user', 'content': prompt}]});
      final response = await _send(client, request).timeout(config.timeout);
      if (response.statusCode != 200) return const Err('request_failed');
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
        final choice = (body['choices'] as List).first as Map;
        final message = choice['message'] as Map;
        if (choice['finish_reason'] != 'stop' || message['refusal'] != null) {
          return const Err('invalid_response');
        }
        return Ok(Map<String, Object?>.from(jsonDecode(message['content'] as String) as Map));
      } catch (_) {
        return const Err('invalid_response');
      }
    } on TimeoutException {
      return const Err('request_timeout');
    } on FormatException {
      return const Err('invalid_response');
    } catch (_) {
      return const Err('request_failed');
    } finally { client?.close(); }
  }

  Future<http.Response> _send(http.Client client, http.Request request) async {
    final response = await client.send(request);
    if (response.statusCode != 200) return http.Response('', response.statusCode);
    const limit = 262144;
    if ((response.contentLength ?? 0) > limit) throw const FormatException();
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > limit) throw const FormatException();
      bytes.addAll(chunk);
    }
    return http.Response.bytes(bytes, response.statusCode);
  }

  @override
  Future<Result<void>> ping({required String apiKey,
    ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async {
    final result = await complete(prompt: 'Return JSON {}.', schemaHint: '{}', apiKey: apiKey, config: config);
    return result is Err<Map<String, Object?>> ? Err(result.code) : const Ok(null);
  }
}
