import 'package:flutter/material.dart';

import '../models/user_profile.dart';
import '../models/runtime_config.dart';
import '../services/settings_service.dart';

class SetupPage extends StatefulWidget {
  final SettingsService settingsService;
  final UserProfile? existingProfile;
  final RuntimeConfig? existingConfig;

  const SetupPage({
    super.key,
    required this.settingsService,
    this.existingProfile,
    this.existingConfig,
  });

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _endpointController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _providerBaseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _cwdController;
  String _authMethod = 'ChatGPT';
  String _approvalPolicy = 'unlessTrusted';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.existingProfile?.name ?? '',
    );
    _endpointController = TextEditingController(
      text: widget.existingConfig?.endpoint ?? 'ws://127.0.0.1:60000',
    );
    _apiKeyController = TextEditingController(
      text: widget.existingConfig?.apiKey ?? '',
    );
    _providerBaseUrlController = TextEditingController(
      text: widget.existingConfig?.providerBaseUrl ?? '',
    );
    _modelController = TextEditingController(
      text: widget.existingConfig?.model ?? '',
    );
    _cwdController = TextEditingController(
      text: widget.existingConfig?.cwd ?? '',
    );
    _authMethod = widget.existingConfig?.authMethod ?? 'ChatGPT';
    _approvalPolicy = widget.existingConfig?.approvalPolicy ?? 'unlessTrusted';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _endpointController.dispose();
    _apiKeyController.dispose();
    _providerBaseUrlController.dispose();
    _modelController.dispose();
    _cwdController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your name')),
      );
      return;
    }
    if (_endpointController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter endpoint URL')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.settingsService.saveUserProfile(
        UserProfile(name: _nameController.text.trim()),
      );
      await widget.settingsService.saveRuntimeConfig(
        RuntimeConfig(
          provider: 'Codex',
          endpoint: _endpointController.text.trim(),
          authMethod: _authMethod,
          apiKey: _apiKeyController.text.trim().ifEmpty(null),
          providerBaseUrl: _providerBaseUrlController.text.trim().ifEmpty(null),
          model: _modelController.text.trim().ifEmpty(null),
          approvalPolicy: _approvalPolicy,
          cwd: _cwdController.text.trim().ifEmpty(null),
        ),
      );
      if (mounted) {
        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        } else {
          // On first setup, reload the app by restarting
          Navigator.pushReplacementNamed(context, '/');
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        title: const Text('Setup'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '小螃蟹 Workbench',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 32),
            Text(
              'User Profile',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Runtime Provider',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            const ListTile(
              title: Text('Provider'),
              trailing: Text('Codex'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _endpointController,
              decoration: const InputDecoration(
                labelText: 'Endpoint URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: 'Model (optional)',
                hintText: 'e.g. gpt-4, claude-3-opus',
                helperText: 'If set, overrides server default for turns you initiate.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cwdController,
              decoration: const InputDecoration(
                labelText: 'Workspace Path (optional)',
                hintText: 'e.g. /Users/you/myproject',
                helperText: 'Working directory passed to thread/start and turn/start.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _authMethod,
              decoration: const InputDecoration(
                labelText: 'Auth Method',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'ChatGPT', child: Text('ChatGPT')),
                DropdownMenuItem(value: 'API Key', child: Text('API Key')),
              ],
              onChanged: (v) => setState(() => _authMethod = v!),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _approvalPolicy,
              decoration: const InputDecoration(
                labelText: 'Approval Policy',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'unlessTrusted', child: Text('Unless Trusted (default)')),
                DropdownMenuItem(value: 'always', child: Text('Always')),
                DropdownMenuItem(value: 'never', child: Text('Never')),
              ],
              onChanged: (v) => setState(() => _approvalPolicy = v!),
            ),
            if (_authMethod == 'API Key') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  helperText: 'Written to config via config/batchWrite as experimental_bearer_token.',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _providerBaseUrlController,
                decoration: const InputDecoration(
                  labelText: 'LLM Provider Base URL (optional)',
                  hintText: 'e.g. https://api.siliconflow.cn/v1',
                  helperText: 'Written to model_providers.workbench_custom via config/batchWrite on connect.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String? ifEmpty(String? fallback) => isEmpty ? fallback : this;
}
