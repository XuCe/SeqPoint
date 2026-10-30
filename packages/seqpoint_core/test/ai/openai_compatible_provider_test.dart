import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  const config = ProviderConfig(id: 'openaiCompatible',
      baseUrl: 'https://example.test/v1/', model: 'configured-model');
  test('单次JSON请求只发送明确原文，禁止重定向并解析对象', () async {
    var calls = 0;
    final provider = OpenAiCompatibleProvider(clientFactory: () => MockClient((request) async {
      calls++;
      expect(request.url.toString(), 'https://example.test/v1/chat/completions');
      expect(request.headers['authorization'], 'Bearer test-key');
      expect(request.followRedirects, isFalse);
      final body = jsonDecode(request.body) as Map;
      expect(body['model'], 'configured-model');
      expect(body['response_format'], {'type': 'json_object'});
      expect((body['messages'] as List).last, {'role': 'user', 'content': '仅此便签'});
      expect(body['stream'], isFalse);
      return http.Response(jsonEncode({'choices': [{'finish_reason': 'stop',
        'message': {'content': '{"items":[]}'}}]}), 200);
    }));
    final result = await provider.complete(prompt: '仅此便签', schemaHint: '{items: []}',
        apiKey: 'test-key', config: config);
    expect(result.valueOrNull, {'items': []});
    expect(calls, 1);
  });
  for (final url in ['http://example.test/v1', 'https://user:pass@example.test/v1',
      'https://example.test/v1?token=private', 'https://example.test/v1#private']) {
    test('不向无效地址发送密钥：$url', () async {
      var clients = 0;
      final provider = OpenAiCompatibleProvider(clientFactory: () {
        clients++; return MockClient((_) async => http.Response('{}', 400));
      });
      final result = await provider.complete(prompt: 'private text', schemaHint: '{}',
          apiKey: 'private key', config: ProviderConfig(id: 'openaiCompatible', baseUrl: url, model: 'm'));
      expect(result, isA<Err<Map<String, Object?>>>());
      expect(clients, 0);
    });
  }
  test('坏提供方标识、模型、超时和多行密钥在创建客户端前拒绝', () async {
    var clients = 0;
    final provider = OpenAiCompatibleProvider(clientFactory: () {
      clients++; return MockClient((_) async => http.Response('{}', 400));
    });
    for (final invalid in [
      const ProviderConfig(id: 'other', baseUrl: 'https://example.test', model: 'm'),
      const ProviderConfig(id: 'openaiCompatible', baseUrl: 'https://example.test', model: ' '),
      const ProviderConfig(id: 'openaiCompatible', baseUrl: 'https://example.test', model: 'm', timeout: Duration.zero),
    ]) {
      expect(await provider.complete(prompt: 'private text', schemaHint: '{}', apiKey: 'secret',
          config: invalid), isA<Err<Map<String, Object?>>>());
    }
    expect(await provider.complete(prompt: 'private text', schemaHint: '{}', apiKey: 'secret\nkey',
        config: config), isA<Err<Map<String, Object?>>>());
    expect(clients, 0);
  });
  for (final payload in ['not JSON', '{}', '[]', '{"choices":[]}',
    jsonEncode({'choices': [{'finish_reason': 'stop', 'message': {'content': '[]'}}]}),
    jsonEncode({'choices': [{'finish_reason': 'length', 'message': {'content': '{}'}}]}),
    jsonEncode({'choices': [{'finish_reason': 'stop', 'message': {'content': '{}', 'refusal': 'private'}}]}),
  ]) {
    test('坏响应明确拒绝且不暴露原始内容：${payload.length}', () async {
      final provider = OpenAiCompatibleProvider(clientFactory: () =>
          MockClient((_) async => http.Response(payload, 200)));
      final result = await provider.complete(prompt: 'private text', schemaHint: '{}',
          apiKey: 'secret', config: config);
      expect(result, isA<Err<Map<String, Object?>>>());
      final error = result as Err<Map<String, Object?>>;
      expect(error.code, 'invalid_response');
      expect(error.message, isNull); expect(error.cause, isNull);
    });
  }
  test('超时只请求一次，关闭客户端且不返回请求正文', () async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final client = _CloseClient((_) { calls++; return pending.future; });
    final provider = OpenAiCompatibleProvider(clientFactory: () => client);
    final result = await provider.complete(prompt: 'private text', schemaHint: '{}', apiKey: 'secret',
        config: const ProviderConfig(id: 'openaiCompatible', baseUrl: 'https://example.test',
            model: 'm', timeout: Duration(milliseconds: 2)));
    expect((result as Err<Map<String, Object?>>).code, 'request_timeout');
    expect(client.closed, isTrue); expect(calls, 1);
    pending.complete(http.Response('{}', 200));
  });
  test('过大原文在网络前拒绝，按UTF8字节而非字符计数', () async {
    var clients = 0;
    final provider = OpenAiCompatibleProvider(clientFactory: () {
      clients++; return MockClient((_) async => http.Response('{}', 400));
    });
    final result = await provider.complete(prompt: '中' * 22000, schemaHint: '{}',
        apiKey: 'secret', config: config);
    expect((result as Err<Map<String, Object?>>).code, 'invalid_request');
    expect(clients, 0);
  });
  test('超大响应在第二块越限时停止读取并关闭客户端', () async {
    var readTail = false;
    Stream<List<int>> chunks() async* {
      yield List.filled(262144, 32);
      yield [32];
      readTail = true;
      yield utf8.encode('private response');
    }
    final client = _StreamClient((_) async => http.StreamedResponse(chunks(), 200));
    final provider = OpenAiCompatibleProvider(clientFactory: () => client);
    final result = await provider.complete(prompt: 'text', schemaHint: '{}', apiKey: 'secret', config: config);
    expect((result as Err<Map<String, Object?>>).code, 'invalid_response');
    expect(readTail, isFalse); expect(client.closed, isTrue);
  });
  for (final status in [302, 401, 429, 500]) {
    test('HTTP $status 不重试不回传响应正文并关闭客户端', () async {
      var calls = 0;
      final client = _CloseClient((_) async {
        calls++; return http.Response('secret private text', status);
      });
      final provider = OpenAiCompatibleProvider(clientFactory: () => client);
      final result = await provider.complete(prompt: 'private text', schemaHint: '{}',
          apiKey: 'secret', config: config) as Err<Map<String, Object?>>;
      expect(result.code, 'request_failed');
      expect(result.message, isNull); expect(result.cause, isNull);
      expect(calls, 1); expect(client.closed, isTrue);
    });
  }
  test('创建客户端失败也返回脱敏Result', () async {
    final provider = OpenAiCompatibleProvider(clientFactory: () => throw StateError('secret private text'));
    final result = await provider.complete(prompt: 'private text', schemaHint: '{}',
        apiKey: 'secret', config: config) as Err<Map<String, Object?>>;
    expect(result.code, 'request_failed'); expect(result.cause, isNull);
  });
  test('网络错误不泄露异常，UTF8成功响应正确解码且关闭客户端', () async {
    for (final fails in [true, false]) {
      final client = _CloseClient((_) async {
        if (fails) throw http.ClientException('secret private text');
        return http.Response.bytes(utf8.encode(jsonEncode({'choices': [{'finish_reason': 'stop',
          'message': {'content': '{"title":"事项"}'}}]})), 200);
      });
      final result = await OpenAiCompatibleProvider(clientFactory: () => client).complete(
          prompt: 'text', schemaHint: '{}', apiKey: 'secret', config: config);
      if (fails) {
        expect((result as Err<Map<String, Object?>>).cause, isNull);
      } else {
        expect(result.valueOrNull, {'title': '事项'});
      }
      expect(client.closed, isTrue);
    }
  });
}

class _CloseClient extends MockClient {
  _CloseClient(super.handler);
  bool closed = false;
  @override
  void close() { closed = true; super.close(); }
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() { closed = true; }
}
