/// HTTP client resilience extensions and utilities for package:circuit_breaker.
///
/// Provides HTTP status code classification, `Retry-After` header parsing,
/// typed HTTP exceptions, and factory-based execution helpers that respect
/// full request/response lifecycles.
library;

import 'dart:async';
import 'dart:io';

import 'package:circuit_breaker/circuit_breaker.dart';
import 'package:http/http.dart' as http;

/// Exception thrown when an HTTP request completes with an error status code.
final class HttpResponseException implements Exception {
  /// The underlying HTTP response.
  final http.Response response;

  /// The name of the resource that failed, if known.
  final String? resourceName;

  /// The error message.
  final String message;

  /// Creates a new [HttpResponseException] wrapping the given [response].
  HttpResponseException(this.response, {String? message, this.resourceName})
    : message =
          message ??
          'HTTP ${response.statusCode} for ${response.request?.url ?? 'unknown URL'}';

  /// The HTTP status code returned by the server.
  int get statusCode => response.statusCode;

  /// The headers returned by the server.
  Map<String, String> get headers => response.headers;

  /// The response body as a string.
  String get body => response.body;

  /// The parsed duration from the `Retry-After` header, or `null` if not present
  /// or unparseable.
  Duration? get retryAfter => RetryAfterParser.parse(headers['retry-after']);

  @override
  String toString() => 'HttpResponseException: $message';
}

/// Utility for parsing HTTP `Retry-After` headers.
///
/// Supports both integer seconds (RFC 9110 §10.2.3) and HTTP-date formats
/// (RFC 9110 §5.6.7).
final class RetryAfterParser {
  RetryAfterParser._();

  /// Parses the given [headerValue] into a [Duration].
  ///
  /// Returns `null` if [headerValue] is `null`, empty, or cannot be parsed.
  /// If the parsed date is in the past, returns [Duration.zero].
  static Duration? parse(String? headerValue, {DateTime? now}) {
    if (headerValue == null) return null;
    final trimmed = headerValue.trim();
    if (trimmed.isEmpty) return null;

    // 1. Delta-seconds
    final seconds = int.tryParse(trimmed);
    if (seconds != null) {
      return seconds < 0 ? Duration.zero : Duration(seconds: seconds);
    }

    // 2. HTTP-date
    try {
      final date = HttpDate.parse(trimmed);
      final referenceTime = now ?? DateTime.now();
      final diff = date.difference(referenceTime);
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }
}

/// HTTP failure and retry classification helpers.
final class HttpClassifier {
  HttpClassifier._();

  /// Returns `true` if [statusCode] represents a 5xx Server Error.
  static bool isServerError(int statusCode) =>
      statusCode >= 500 && statusCode < 600;

  /// Returns `true` if [statusCode] represents a 4xx Client Error.
  static bool isClientError(int statusCode) =>
      statusCode >= 400 && statusCode < 500;

  /// Returns `true` if [statusCode] is typically transient and safe to retry
  /// (429 Too Many Requests, 502 Bad Gateway, 503 Service Unavailable, 504 Gateway Timeout).
  static bool isTransientStatus(int statusCode) {
    return statusCode == 429 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  /// Default failure classifier for HTTP operations.
  ///
  /// Classifies 5xx server errors and network/transport failures as failures.
  /// Client errors (4xx except 429) are classified as non-failures so they do
  /// not trip the circuit breaker.
  static bool defaultFailureClassifier(Object error, [StackTrace? stackTrace]) {
    if (error is HttpResponseException) {
      final status = error.statusCode;
      if (isClientError(status) && status != 429) {
        return false;
      }
      return true;
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

  /// Predicate determining whether an error is transient and should be retried.
  ///
  /// Returns `true` for transient HTTP status codes (429, 502, 503, 504) and
  /// transport exceptions ([SocketException], [http.ClientException], [TimeoutException]).
  /// Returns `false` for programmer errors and non-transient client errors (4xx).
  static bool isTransient(Object error, [StackTrace? stackTrace]) {
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
    if (error is SocketException ||
        error is http.ClientException ||
        error is HttpException ||
        error is TlsException ||
        error is TimeoutException) {
      return true;
    }
    return false;
  }

  /// A [RetryDelaySuggestion] that honours the server's `Retry-After` header.
  ///
  /// Returns the parsed header value when [error] is an [HttpResponseException]
  /// carrying a well-formed `Retry-After`, and `null` otherwise — in which case
  /// the configured exponential backoff applies as usual. The core clamps the
  /// returned value to [RetryConfig.maxDelay], so a server cannot stall a call
  /// indefinitely by asking for an absurd delay.
  ///
  /// Wire it into a [RetryConfig]:
  ///
  /// ```dart
  /// RetryConfig(
  ///   maxAttempts: 4,
  ///   maxDelay: const Duration(seconds: 30),
  ///   suggestedDelay: HttpClassifier.retryAfterDelay,
  /// )
  /// ```
  static Duration? retryAfterDelay(int attempt, Object error) {
    if (error is HttpResponseException) return error.retryAfter;
    return null;
  }
}

/// Extension providing HTTP execution methods on [ResiliencePolicy].
extension ResilientPolicyHttpExtension on ResiliencePolicy {
  /// Executes an HTTP request created by [requestFactory] through this policy.
  ///
  /// Every attempt calls [requestFactory] to produce a fresh [http.Request],
  /// avoiding the single-use limitation of finalized requests during retries or hedging.
  ///
  /// Awaits the full response stream via [http.Response.fromStream] before declaring
  /// the attempt complete. If [validateStatus] is omitted, any response with
  /// status code >= 400 throws an [HttpResponseException].
  ///
  /// It is an error if [requestFactory] returns a request whose body cannot be read.
  ///
  /// Throws [HttpResponseException] if the response fails status validation.
  /// Throws [ResilienceException] if circuit breaker is open, request is throttled,
  /// or execution times out.
  Future<http.Response> executeHttp(
    http.Client client,
    FutureOr<http.Request> Function() requestFactory, {
    Duration? timeout,
    Criticality criticality = Criticality.critical,
    bool Function(http.Response response)? validateStatus,
    bool Function(Object error)? retryOn,
  }) {
    return execute(
      () async {
        final request = await requestFactory();
        final streamedResponse = await client.send(request);
        final response = await http.Response.fromStream(streamedResponse);

        final isValid = validateStatus != null
            ? validateStatus(response)
            : response.statusCode < 400;

        if (!isValid) {
          throw HttpResponseException(response);
        }

        return response;
      },
      retryOn: retryOn ?? HttpClassifier.isTransient,
      criticality: criticality,
      timeout: timeout,
    );
  }
}

/// Extension providing HTTP execution methods on [ResilienceContext].
extension ResilientContextHttpExtension on ResilienceContext {
  /// Executes an HTTP request created by [requestFactory] through this context for [resource].
  ///
  /// Every attempt calls [requestFactory] to produce a fresh [http.Request],
  /// avoiding the single-use limitation of finalized requests during retries or hedging.
  ///
  /// Awaits the full response stream via [http.Response.fromStream] before declaring
  /// the attempt complete. If [validateStatus] is omitted, any response with
  /// status code >= 400 throws an [HttpResponseException].
  ///
  /// It is an error if [requestFactory] returns a request whose body cannot be read.
  ///
  /// Throws [HttpResponseException] if the response fails status validation.
  /// Throws [ResilienceException] if circuit breaker is open, request is throttled,
  /// or execution times out.
  Future<http.Response> executeHttp(
    Resource resource,
    http.Client client,
    FutureOr<http.Request> Function() requestFactory, {
    Duration? timeout,
    bool Function(http.Response response)? validateStatus,
    bool Function(Object error)? retryOn,
  }) {
    return execute(
      resource,
      () async {
        final request = await requestFactory();
        final streamedResponse = await client.send(request);
        final response = await http.Response.fromStream(streamedResponse);

        final isValid = validateStatus != null
            ? validateStatus(response)
            : response.statusCode < 400;

        if (!isValid) {
          throw HttpResponseException(response, resourceName: resource.name);
        }

        return response;
      },
      retryOn: retryOn ?? HttpClassifier.isTransient,
      timeout: timeout,
    );
  }
}
