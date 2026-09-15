/// HTTP resilience for `package:circuit_breaker`.
///
/// Rather than wrapping [http.BaseClient], this package attaches resilience at
/// the *operation* boundary. That distinction matters: `Client.send` completes
/// as soon as response headers arrive, so a client wrapper records success for
/// a request whose body later dies mid-stream, and cannot replay a
/// [http.BaseRequest] that has already been finalized.
///
/// Instead, [ResiliencePolicyHttp.executeHttp] takes a *factory* — a fresh
/// request per attempt — and reads the body to completion inside the protected
/// operation, so a connection dropped at byte 10 of 100 is a failure the
/// circuit breaker sees and retry can act on.
///
/// Start from [httpPolicy] or [httpResourceConfig]; both pre-wire
/// [HttpClassifier.isFailure] so client mistakes never trip a breaker.
///
/// This library is platform-agnostic and works on native, web and wasm.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' as http_parser;

/// Thrown when an HTTP request completes with a status code that fails
/// validation.
///
/// > [!NOTE]
/// > This deliberately sits outside the sealed [ResilienceException]
/// > hierarchy — Dart does not permit a sealed type to be implemented from
/// > another library. An exhaustive `switch` over [ResilienceException] will
/// > not cover HTTP status failures; match [HttpResponseException] separately.
final class HttpResponseException implements Exception {
  /// The response whose status failed validation, including its body.
  final http.Response response;

  /// The name of the resource the request targeted, if known.
  final String? resourceName;

  /// A human-readable description of the failure.
  ///
  /// Never contains the response body; read [body] for that.
  final String message;

  /// Wraps [response] as a failure.
  HttpResponseException(this.response, {String? message, this.resourceName})
    : message =
          message ??
          'HTTP ${response.statusCode} for '
              '${response.request?.url ?? 'unknown URL'}';

  /// The status code returned by the server.
  int get statusCode => response.statusCode;

  /// The response headers, with lower-case keys.
  Map<String, String> get headers => response.headers;

  /// The response body decoded as a string.
  String get body => response.body;

  /// The `Retry-After` header as a [Duration], or `null` when the header is
  /// absent or malformed.
  ///
  /// For an HTTP-date the value is relative to [clock] at the moment of the
  /// call, so it shrinks as time passes.
  Duration? get retryAfter => RetryAfterParser.parse(headers['retry-after']);

  @override
  String toString() => 'HttpResponseException: $message';
}

/// Parses the HTTP `Retry-After` header.
///
/// Accepts both forms defined by RFC 9110 §10.2.3: delta-seconds (`120`) and
/// an HTTP-date (`Wed, 21 Oct 2026 07:28:00 GMT`).
final class RetryAfterParser {
  RetryAfterParser._();

  /// Parses [headerValue] into a [Duration] to wait.
  ///
  /// Returns `null` when [headerValue] is `null`, blank, or matches neither
  /// permitted form — callers should then fall back to their own backoff.
  /// A delay already in the past, or a negative delta, yields [Duration.zero].
  ///
  /// [now] overrides the reference point for HTTP-date values; it defaults to
  /// [clock], so `withClock` applies.
  static Duration? parse(String? headerValue, {DateTime? now}) {
    if (headerValue == null) return null;
    final trimmed = headerValue.trim();
    if (trimmed.isEmpty) return null;

    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
    }

    try {
      final date = http_parser.parseHttpDate(trimmed);
      final diff = date.difference(now ?? clock.now());
      return diff.isNegative ? Duration.zero : diff;
    } on FormatException {
      return null;
    }
  }
}

/// Decides which HTTP outcomes count as backend failures and which are worth
/// retrying.
///
/// The two questions are distinct and answered by two predicates:
///
/// - [isFailure] — *does this count against the backend?* Drives the circuit
///   breaker and adaptive throttling. A `404` is a perfectly healthy response
///   to a bad URL, so it must not open a breaker.
/// - [isTransient] — *is another attempt likely to fare better?* Drives retry.
///   Strictly narrower: a `500` is a genuine backend failure, yet replaying a
///   non-idempotent request against it is rarely the right call.
final class HttpClassifier {
  HttpClassifier._();

  /// Whether [statusCode] is a 5xx Server Error.
  static bool isServerError(int statusCode) =>
      statusCode >= 500 && statusCode < 600;

  /// Whether [statusCode] is a 4xx Client Error.
  static bool isClientError(int statusCode) =>
      statusCode >= 400 && statusCode < 500;

  /// Whether [statusCode] denotes a condition that typically clears on its own.
  ///
  /// Covers `408` Request Timeout, `425` Too Early, `429` Too Many Requests,
  /// `502` Bad Gateway, `503` Service Unavailable and `504` Gateway Timeout.
  static bool isTransientStatus(int statusCode) =>
      const {408, 425, 429, 502, 503, 504}.contains(statusCode);

  /// Whether [error] should count against the backend's health.
  ///
  /// Server errors (5xx), rate limiting (`429`) and transport failures count.
  /// Other client errors (4xx) and programmer errors do not: they say nothing
  /// about backend health, and letting them accumulate would open the circuit
  /// for every caller because one caller sent a bad request or an expired
  /// token.
  ///
  /// Pass to [ResourceConfig.failureClassifier]; [httpResourceConfig] and
  /// [httpPolicy] do so by default.
  static bool isFailure(Object error) {
    if (error is HttpResponseException) {
      return !isClientError(error.statusCode) || error.statusCode == 429;
    }
    if (error is ArgumentError ||
        error is TypeError ||
        error is FormatException ||
        error is AssertionError ||
        error is RangeError) {
      return false;
    }
    return true;
  }

  /// Whether [error] is worth another attempt.
  ///
  /// True for the statuses in [isTransientStatus] and for transport failures
  /// ([http.ClientException], [TimeoutException]). False for everything else,
  /// including 5xx statuses other than `502`/`503`/`504` — a bare `500` means
  /// the server has already processed something and gone wrong, so retrying a
  /// non-idempotent request risks duplicating it.
  ///
  /// Widen this per call via `executeHttp`'s `retryOn` when the request is
  /// known to be idempotent.
  static bool isTransient(Object error) {
    if (error is HttpResponseException) {
      return isTransientStatus(error.statusCode);
    }
    if (error is ArgumentError ||
        error is TypeError ||
        error is FormatException ||
        error is AssertionError ||
        error is RangeError) {
      return false;
    }
    return error is http.ClientException || error is TimeoutException;
  }

  /// A [RetryDelaySuggestion] honouring the server's `Retry-After` header.
  ///
  /// Yields the parsed header when [error] is an [HttpResponseException]
  /// carrying a well-formed `Retry-After`, and `null` otherwise, leaving the
  /// configured exponential backoff in charge. The core caps the result at
  /// [RetryConfig.maxDelay], so a server cannot stall a call indefinitely.
  ///
  /// ```dart
  /// RetryConfig(
  ///   maxDelay: const Duration(seconds: 30),
  ///   suggestedDelay: HttpClassifier.retryAfterDelay,
  /// )
  /// ```
  static Duration? retryAfterDelay(int attempt, Object error) =>
      error is HttpResponseException ? error.retryAfter : null;
}

/// Builds a [ResourceConfig] with HTTP-aware failure classification.
///
/// Identical to constructing [ResourceConfig] directly except that
/// [failureClassifier] defaults to [HttpClassifier.isFailure] rather than the
/// core's generic classifier. Without that substitution every `404` and `401`
/// counts as a backend failure and will eventually open the circuit — prefer
/// this over a hand-rolled [ResourceConfig] for anything speaking HTTP.
///
/// Use with a named [Resource]:
///
/// ```dart
/// final api = Resource('users-api', config: httpResourceConfig(
///   circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
/// ));
/// ```
ResourceConfig httpResourceConfig({
  CircuitBreakerConfig? circuitBreaker,
  RetryConfig? retry,
  ThrottlingConfig? throttling,
  HedgingConfig? hedging,
  Duration? timeout,
  bool Function(Object)? failureClassifier,
}) {
  return ResourceConfig(
    circuitBreaker: circuitBreaker,
    retry: retry ?? RetryConfig(suggestedDelay: HttpClassifier.retryAfterDelay),
    throttling: throttling,
    hedging: hedging,
    timeout: timeout,
    failureClassifier: failureClassifier ?? HttpClassifier.isFailure,
  );
}

/// Builds a standalone [ResiliencePolicy] with HTTP-aware defaults.
///
/// Like [httpResourceConfig], but self-contained: no [ResilienceContext] or
/// named [Resource] required. [failureClassifier] defaults to
/// [HttpClassifier.isFailure], and an unspecified [retry] honours
/// `Retry-After` via [HttpClassifier.retryAfterDelay].
///
/// ```dart
/// final policy = httpPolicy(
///   circuitBreaker: CircuitBreakerConfig(consecutiveFailuresThreshold: 5),
/// );
/// final response = await policy.executeHttp(client, () => request);
/// ```
ResiliencePolicy httpPolicy({
  CircuitBreakerConfig? circuitBreaker,
  RetryConfig? retry,
  ThrottlingConfig? throttling,
  HedgingConfig? hedging,
  Duration? timeout,
  bool Function(Object)? failureClassifier,
}) {
  return ResiliencePolicy(
    circuitBreaker: circuitBreaker,
    retry: retry ?? RetryConfig(suggestedDelay: HttpClassifier.retryAfterDelay),
    throttling: throttling,
    hedging: hedging,
    timeout: timeout,
    failureClassifier: failureClassifier ?? HttpClassifier.isFailure,
  );
}

/// Issues one attempt: build a fresh request, send it, and read the body to
/// completion under [cancelCompleter].
Future<http.Response> _attempt({
  required http.Client client,
  required FutureOr<http.BaseRequest> Function() requestFactory,
  required Completer<void> cancelCompleter,
  required bool Function(http.Response response)? validateStatus,
  required String? resourceName,
}) async {
  final request = await requestFactory();
  final streamed = await client.send(request);
  final response = await _readBody(streamed, cancelCompleter);

  final accepted = validateStatus?.call(response) ?? response.statusCode < 400;
  if (!accepted) {
    throw HttpResponseException(response, resourceName: resourceName);
  }
  return response;
}

/// Drains [streamed] into a buffered [http.Response], aborting the connection
/// if [cancelCompleter] completes first.
///
/// Cancelling the subscription is what actually releases the socket; without
/// it a losing hedge or a timed-out request keeps draining bytes nobody will
/// read, and the hedge concurrency slot is never returned.
Future<http.Response> _readBody(
  http.StreamedResponse streamed,
  Completer<void> cancelCompleter,
) {
  final completer = Completer<http.Response>();
  final buffer = BytesBuilder(copy: false);

  final subscription = streamed.stream.listen(
    buffer.add,
    cancelOnError: true,
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
    onDone: () {
      if (completer.isCompleted) return;
      completer.complete(
        http.Response.bytes(
          buffer.takeBytes(),
          streamed.statusCode,
          request: streamed.request,
          headers: streamed.headers,
          isRedirect: streamed.isRedirect,
          persistentConnection: streamed.persistentConnection,
          reasonPhrase: streamed.reasonPhrase,
        ),
      );
    },
  );

  unawaited(
    cancelCompleter.future
        .then((_) async {
          if (completer.isCompleted) return;
          await subscription.cancel();
          if (!completer.isCompleted) {
            completer.completeError(
              const OperationCancelledException(
                'HTTP request aborted before the response body was received',
              ),
            );
          }
        })
        .catchError((_) {}),
  );

  return completer.future;
}

/// Adds HTTP execution to [ResiliencePolicy].
extension ResiliencePolicyHttp on ResiliencePolicy {
  /// Sends the request built by [requestFactory] under this policy.
  ///
  /// [requestFactory] is invoked once per attempt, so retries and hedges each
  /// get a fresh [http.BaseRequest]; a finalized request cannot be replayed.
  /// It may return any [http.BaseRequest], including [http.MultipartRequest].
  ///
  /// The response body is read to completion before the attempt is considered
  /// successful, so a mid-stream disconnect is recorded as the failure it is.
  /// If the surrounding policy cancels the attempt — a lost hedge, or an
  /// expired deadline — the connection is aborted rather than left draining.
  ///
  /// By default any status below 400 is accepted, which includes a surfaced
  /// 3xx (relevant only when redirects are disabled); supply [validateStatus]
  /// for anything stricter. A rejected status throws [HttpResponseException].
  ///
  /// [retryOn] defaults to [HttpClassifier.isTransient], which is intentionally
  /// narrower than the policy's failure classifier: an error can count against
  /// the breaker without being safe to replay. Widen it for idempotent
  /// requests.
  ///
  /// Throws [HttpResponseException] if the status is rejected,
  /// [CircuitBreakerOpenException] if the circuit is open, [ThrottledException]
  /// if shed by adaptive throttling, [ResilienceTimeoutException] on deadline
  /// expiry, and [OperationCancelledException] if cancelled via [cancelToken].
  Future<http.Response> executeHttp(
    http.Client client,
    FutureOr<http.BaseRequest> Function() requestFactory, {
    Duration? timeout,
    Criticality criticality = Criticality.critical,
    bool Function(http.Response response)? validateStatus,
    bool Function(Object error)? retryOn,
    CancellationToken? cancelToken,
  }) {
    return executeCancelable(
      (cancelCompleter) => _attempt(
        client: client,
        requestFactory: requestFactory,
        cancelCompleter: cancelCompleter,
        validateStatus: validateStatus,
        resourceName: resource.name,
      ),
      retryOn: retryOn ?? HttpClassifier.isTransient,
      criticality: criticality,
      timeout: timeout,
      cancellationToken: cancelToken,
    );
  }
}

/// Adds HTTP execution to [ResilienceContext].
extension ResilienceContextHttp on ResilienceContext {
  /// Sends the request built by [requestFactory] under the policies of
  /// [target].
  ///
  /// [target] accepts any [ResilienceTarget]: a [Resource] for defaults, or an
  /// [Operation] to attach a [Criticality] and per-call overrides — which is
  /// how a `sheddable` bulk sync is shed ahead of `criticalPlus` checkout
  /// traffic against the same host.
  ///
  /// [requestFactory] is invoked once per attempt, so retries and hedges each
  /// get a fresh [http.BaseRequest]; a finalized request cannot be replayed.
  /// It may return any [http.BaseRequest], including [http.MultipartRequest].
  ///
  /// The response body is read to completion before the attempt is considered
  /// successful, so a mid-stream disconnect is recorded as the failure it is.
  /// If the surrounding policy cancels the attempt — a lost hedge, or an
  /// expired deadline — the connection is aborted rather than left draining.
  ///
  /// By default any status below 400 is accepted, which includes a surfaced
  /// 3xx (relevant only when redirects are disabled); supply [validateStatus]
  /// for anything stricter. A rejected status throws [HttpResponseException].
  ///
  /// [retryOn] defaults to [HttpClassifier.isTransient], which is intentionally
  /// narrower than the resource's failure classifier: an error can count
  /// against the breaker without being safe to replay. Widen it for idempotent
  /// requests.
  ///
  /// Throws [HttpResponseException] if the status is rejected,
  /// [CircuitBreakerOpenException] if the circuit is open, [ThrottledException]
  /// if shed by adaptive throttling, [ResilienceTimeoutException] on deadline
  /// expiry, and [OperationCancelledException] if cancelled via [cancelToken].
  Future<http.Response> executeHttp(
    ResilienceTarget target,
    http.Client client,
    FutureOr<http.BaseRequest> Function() requestFactory, {
    Duration? timeout,
    bool Function(http.Response response)? validateStatus,
    bool Function(Object error)? retryOn,
    CancellationToken? cancelToken,
  }) {
    return executeCancelable(
      target,
      (cancelCompleter) => _attempt(
        client: client,
        requestFactory: requestFactory,
        cancelCompleter: cancelCompleter,
        validateStatus: validateStatus,
        resourceName: target.resource.name,
      ),
      retryOn: retryOn ?? HttpClassifier.isTransient,
      timeout: timeout,
      cancellationToken: cancelToken,
    );
  }
}
