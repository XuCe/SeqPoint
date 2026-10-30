/// 轻量结果类型，用于不应抛异常的边界（AI 调用、同步通道）。
sealed class Result<T> {
  const Result();

  bool get isOk => this is Ok<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.code, {this.message, this.cause});
  final String code;
  final String? message;
  final Object? cause;
}
