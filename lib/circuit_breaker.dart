/// A library for async retry, circuit breaker, request hedging, and adaptive throttling.
///
/// This package provides advanced resilience patterns to improve system performance
/// by addressing service failures and latency bottlenecks in distributed systems.
///
/// ## Key Features
///
/// - **Circuit Breaker**: Prevents cascading failures by failing fast when a service is struggling.
/// - **Retry with Backoff**: Automatically retries transient failures with exponential backoff and full jitter.
/// - **Request Hedging**: Mitigates tail latency by speculatively duplicating operations.
/// - **Adaptive Throttling**: Dynamically rejects requests based on rolling success rates to protect backends.
///
/// ## Usage
///
/// The main entry point is [ResilienceContext]. You can use it to execute operations
/// with configured policies for named resources.
///
/// {@example /example/main.dart}
library circuit_breaker;

export 'src/context.dart'
    show
        ResilienceContext,
        Resource,
        Operation,
        Criticality,
        ResourceConfig,
        CircuitBreakerConfig,
        RetryConfig,
        ThrottlingConfig,
        HedgingConfig;

export 'src/throttling.dart' show ThrottledException;
export 'src/exceptions.dart'
    show CircuitBreakerOpenException, ResilienceTimeoutException;
