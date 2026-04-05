class RuntimeConfig {
  final String provider;
  final String endpoint;
  final String authMethod;
  final String? apiKey;

  /// LLM provider base URL override (e.g. for local Ollama or custom OpenAI-compatible endpoint).
  /// Stored locally; NOT yet passed to Codex app-server — pending upstream `initialize` support.
  final String? providerBaseUrl;

  /// LLM model to use (e.g. 'gpt-4', 'claude-3-opus').
  /// If set, overrides the server's default model for this turn.
  final String? model;

  /// Approval policy for turns (e.g. 'unlessTrusted', 'always').
  /// If not set, defaults to 'unlessTrusted'.
  final String? approvalPolicy;

  const RuntimeConfig({
    required this.provider,
    required this.endpoint,
    required this.authMethod,
    this.apiKey,
    this.providerBaseUrl,
    this.model,
    this.approvalPolicy,
  });

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'endpoint': endpoint,
        'authMethod': authMethod,
        'apiKey': apiKey,
        'providerBaseUrl': providerBaseUrl,
        'model': model,
        'approvalPolicy': approvalPolicy,
      };

  factory RuntimeConfig.fromJson(Map<String, dynamic> json) => RuntimeConfig(
        provider: json['provider'] as String,
        endpoint: json['endpoint'] as String,
        authMethod: json['authMethod'] as String,
        apiKey: json['apiKey'] as String?,
        providerBaseUrl: json['providerBaseUrl'] as String?,
        model: json['model'] as String?,
        approvalPolicy: json['approvalPolicy'] as String?,
      );
}
