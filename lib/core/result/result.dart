/// Typed success/failure container for bloc and repository layers.
///
/// Replaces ad-hoc `try`/`catch` + string-formatted error states with a
/// uniform `Result<T, E>` returned from repositories/services and unpacked
/// in blocs.
///
/// Use [Result.guard] to lift a throwing callback into a `Result<T, AppFailure>`
/// without losing the stack trace.
library;

import 'app_failure.dart';

sealed class Result<T, E extends Object> {
  const Result();

  const factory Result.success(T value) = ResultSuccess<T, E>;

  const factory Result.failure(E error, [StackTrace? stackTrace]) =
      ResultFailure<T, E>;

  bool get isSuccess => this is ResultSuccess<T, E>;

  bool get isFailure => this is ResultFailure<T, E>;

  /// Returns the success value or `null` if this is a failure. Use when the
  /// caller has already decided how to react to the failure case.
  T? get valueOrNull => switch (this) {
    ResultSuccess<T, E>(:final value) => value,
    ResultFailure<T, E>() => null,
  };

  /// Returns the error or `null` if this is a success.
  E? get errorOrNull => switch (this) {
    ResultSuccess<T, E>() => null,
    ResultFailure<T, E>(:final error) => error,
  };

  /// Pattern-match helper. Prefer Dart 3 `switch` expressions at call sites;
  /// this is a convenience for places where a tiny inline branch is cleaner.
  R when<R>({
    required R Function(T value) success,
    required R Function(E error, StackTrace? stackTrace) failure,
  }) => switch (this) {
    ResultSuccess<T, E>(:final value) => success(value),
    ResultFailure<T, E>(:final error, :final stackTrace) => failure(
      error,
      stackTrace,
    ),
  };

  Result<U, E> map<U>(U Function(T value) transform) => switch (this) {
    ResultSuccess<T, E>(:final value) => ResultSuccess<U, E>(transform(value)),
    ResultFailure<T, E>(:final error, :final stackTrace) => ResultFailure<U, E>(
      error,
      stackTrace,
    ),
  };

  Result<T, F> mapError<F extends Object>(F Function(E error) transform) =>
      switch (this) {
        ResultSuccess<T, E>(:final value) => ResultSuccess<T, F>(value),
        ResultFailure<T, E>(:final error, :final stackTrace) =>
          ResultFailure<T, F>(transform(error), stackTrace),
      };

  /// Runs [block] and converts any thrown error into an [AppFailure].
  ///
  /// Preserves [TransactionAuthCancelledException] semantics by mapping it
  /// to [AppFailure.cancelled] so blocs can quietly drop the cancellation
  /// rather than rendering it as a hard error.
  static Future<Result<T, AppFailure>> guard<T>(
    Future<T> Function() block,
  ) async {
    try {
      return ResultSuccess<T, AppFailure>(await block());
    } catch (error, stackTrace) {
      return ResultFailure<T, AppFailure>(AppFailure.from(error), stackTrace);
    }
  }
}

final class ResultSuccess<T, E extends Object> extends Result<T, E> {
  const ResultSuccess(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResultSuccess<T, E> && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Result.success($value)';
}

final class ResultFailure<T, E extends Object> extends Result<T, E> {
  const ResultFailure(this.error, [this.stackTrace]);

  final E error;
  final StackTrace? stackTrace;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResultFailure<T, E> && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'Result.failure($error)';
}
