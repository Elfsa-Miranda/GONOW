class AiConfig {
  const AiConfig._();

  /// Release A never accepts a model-provider credential from the client.
  ///
  /// Both values are compile-time deployment inputs. The service validates
  /// that the URL host exactly matches [releaseAGatewayAllowedHost] before
  /// any request is created. Missing or mismatched values fail closed.
  static const bool releaseAGatewayEnabled = bool.fromEnvironment(
    'GONOW_RELEASE_A_GATEWAY_ENABLED',
    defaultValue: false,
  );
  static const String releaseAGatewayUrl = String.fromEnvironment(
    'GONOW_RELEASE_A_GATEWAY_URL',
  );
  static const String releaseAGatewayAllowedHost = String.fromEnvironment(
    'GONOW_RELEASE_A_GATEWAY_ALLOWED_HOST',
  );

  /// Compatibility tombstones for legacy feature paths.
  ///
  /// They intentionally contain no endpoint, model, or credential. Existing
  /// legacy callers therefore fail before a provider request can be sent.
  /// Never repopulate these values; migrate callers to a reviewed server API.
  @Deprecated('Client model-provider calls are permanently disabled.')
  static const String deepseekApiKey = '';
  @Deprecated('Client model-provider calls are permanently disabled.')
  static const String deepseekEndpoint = '';
  @Deprecated('Client model-provider calls are permanently disabled.')
  static const String deepseekModel = '';
}
