import 'package:gonow/core/constants/ai_config.dart';

@Deprecated('Use AiConfig instead.')
class ApiKeys {
  const ApiKeys._();

  static const String deepseekApiKey = AiConfig.deepseekApiKey;
  static const String deepseekEndpoint = AiConfig.deepseekEndpoint;
  static const String deepseekModel = AiConfig.deepseekModel;
}
