import 'agent_run_failure.dart';

sealed class AgentRunResult<T> {
  const AgentRunResult();

  R fold<R>({
    required R Function(T value) success,
    required R Function(AgentRunFailure failure) failure,
  }) {
    return switch (this) {
      AgentRunSuccess<T>(:final value) => success(value),
      AgentRunRejected<T>(failure: final reason) => failure(reason),
    };
  }
}

final class AgentRunSuccess<T> extends AgentRunResult<T> {
  const AgentRunSuccess(this.value);

  final T value;
}

final class AgentRunRejected<T> extends AgentRunResult<T> {
  const AgentRunRejected(this.failure);

  final AgentRunFailure failure;
}
