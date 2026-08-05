import 'package:flutter/material.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/core/config/agent_service_config.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

final class AgentPlanningScreen extends StatefulWidget {
  const AgentPlanningScreen({required this.config, this.repository, super.key});

  final AgentServiceConfig config;
  final AgentRunRepository? repository;

  @override
  State<AgentPlanningScreen> createState() => _AgentPlanningScreenState();
}

final class _AgentPlanningScreenState extends State<AgentPlanningScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _origin = TextEditingController();
  final TextEditingController _destination = TextEditingController();
  final TextEditingController _days = TextEditingController(text: '3');
  final TextEditingController _budget = TextEditingController(text: '5000');
  final TextEditingController _constraints = TextEditingController();
  late final TextEditingController _startsOn;
  http.Client? _ownedHttpClient;
  AgentRunRepository? _repository;
  String? _configurationError;
  String _threadId = const Uuid().v4();
  String _idempotencyKey = 'plan-${const Uuid().v4()}';
  StartAgentRunReceipt? _run;
  ItineraryCandidateView? _candidate;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final DateTime tomorrow = DateTime.now().add(const Duration(days: 1));
    _startsOn = TextEditingController(text: _date(tomorrow));
    _repository = widget.repository;
    if (_repository == null) {
      final Uri? baseUri = widget.config.validatedBaseUri;
      if (baseUri == null) {
        _configurationError = 'Agent service is not safely configured.';
        return;
      }
      final http.Client client = http.Client();
      _ownedHttpClient = client;
      _repository = DefaultAgentRunRepository(
        gateway: GeneratedAgentRunGateway(
          AgentApiClient(
            baseUri: baseUri,
            httpClient: client,
            accessTokenProvider: _accessToken,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _origin.dispose();
    _destination.dispose();
    _days.dispose();
    _budget.dispose();
    _constraints.dispose();
    _startsOn.dispose();
    _ownedHttpClient?.close();
    super.dispose();
  }

  Future<String> _accessToken() async {
    final String? token =
        Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.trim().isEmpty) {
      throw const AgentApiTransportException('authentication_required');
    }
    return token;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Agent itinerary planning')),
      body: _configurationError == null
          ? _body()
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _configurationError!,
                  key: const Key('agent-configuration-error'),
                ),
              ),
            ),
    );
  }

  Widget _body() {
    final ItineraryCandidateView? candidate = _candidate;
    if (candidate != null) {
      return _candidateView(candidate);
    }
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _field(_origin, 'Origin', key: const Key('agent-origin')),
          _field(
            _destination,
            'Destination',
            key: const Key('agent-destination'),
          ),
          _field(
            _startsOn,
            'Start date (YYYY-MM-DD)',
            key: const Key('agent-start-date'),
          ),
          _field(
            _days,
            'Days (1-31)',
            key: const Key('agent-days'),
            keyboardType: TextInputType.number,
          ),
          _field(
            _budget,
            'Budget in CNY',
            key: const Key('agent-budget'),
            keyboardType: TextInputType.number,
          ),
          TextFormField(
            key: const Key('agent-constraints'),
            controller: _constraints,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Hard constraints (one per line)',
            ),
          ),
          const SizedBox(height: 16),
          if (_run != null) ...<Widget>[
            Text('Run: ${_run!.runId}', key: const Key('agent-run-id')),
            const Text('Queued. Refresh when the Candidate is ready.'),
            const SizedBox(height: 12),
          ],
          if (_message != null)
            Text(_message!, key: const Key('agent-planning-message')),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('agent-start-run'),
            onPressed: _busy || _run != null ? null : _start,
            child: Text(_busy ? 'Working…' : 'Start planning'),
          ),
          if (_run != null) ...<Widget>[
            OutlinedButton(
              key: const Key('agent-refresh-candidate'),
              onPressed: _busy ? null : _loadCandidate,
              child: const Text('Refresh Candidate'),
            ),
            TextButton(
              key: const Key('agent-cancel-run'),
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel Run'),
            ),
          ],
        ],
      ),
    );
  }

  TextFormField _field(
    TextEditingController controller,
    String label, {
    required Key key,
    TextInputType? keyboardType,
  }) => TextFormField(
    key: key,
    controller: controller,
    keyboardType: keyboardType,
    decoration: InputDecoration(labelText: label),
    validator: (String? value) => value == null || value.trim().isEmpty
        ? 'This field is required.'
        : null,
  );

  Future<void> _start() async {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    final int? days = int.tryParse(_days.text.trim());
    final num? budget = num.tryParse(_budget.text.trim());
    if (days == null || budget == null || budget < 0) {
      setState(() => _message = 'Days or budget is invalid.');
      return;
    }
    await _runBusy(() async {
      final AgentRunResult<AgentApiContractReceipt> contract =
          await _repository!.verifyContract();
      if (contract case AgentRunRejected<AgentApiContractReceipt>(
        :final failure,
      )) {
        _message = failure.safeMessage;
        return;
      }
      final AgentRunResult<StartAgentRunReceipt> result = await _repository!
          .startRun(
            StartAgentRunCommand(
              idempotencyKey: _idempotencyKey,
              threadId: _threadId,
              origin: _origin.text,
              destination: _destination.text,
              startsOn: _startsOn.text.trim(),
              days: days,
              budgetMinor: (budget * 100).round(),
              currency: 'CNY',
              locale: 'zh-CN',
              timezone: 'Asia/Shanghai',
              hardConstraints: _constraints.text
                  .split('\n')
                  .map((String value) => value.trim())
                  .where((String value) => value.isNotEmpty)
                  .toList(growable: false),
            ),
          );
      switch (result) {
        case AgentRunSuccess<StartAgentRunReceipt>(:final value):
          _run = value;
          _message = null;
        case AgentRunRejected<StartAgentRunReceipt>(:final failure):
          _message = failure.safeMessage;
      }
    });
  }

  Future<void> _loadCandidate() async {
    final StartAgentRunReceipt? run = _run;
    if (run == null) return;
    await _runBusy(() async {
      final AgentRunResult<AgentRunCandidateReceipt> result = await _repository!
          .getCandidate(run.runId);
      switch (result) {
        case AgentRunSuccess<AgentRunCandidateReceipt>(:final value):
          try {
            _candidate = ItineraryCandidateView.fromJson(value.payload);
            _message = null;
          } on CandidatePreviewException {
            _message = 'The Candidate response is invalid.';
          }
        case AgentRunRejected<AgentRunCandidateReceipt>(:final failure):
          _message = failure.kind.name == 'forbidden'
              ? 'Candidate is not ready or is not accessible.'
              : failure.safeMessage;
      }
    });
  }

  Future<void> _cancel() async {
    final StartAgentRunReceipt? run = _run;
    if (run == null) return;
    await _runBusy(() async {
      final AgentRunResult<CancelAgentRunReceipt> result = await _repository!
          .cancelRun(
            CancelAgentRunCommand(
              runId: run.runId,
              expectedVersion: run.version,
            ),
          );
      switch (result) {
        case AgentRunSuccess<CancelAgentRunReceipt>(:final value):
          _message = 'Run ${value.status}.';
        case AgentRunRejected<CancelAgentRunReceipt>(:final failure):
          _message = failure.safeMessage;
      }
    });
  }

  Future<void> _runBusy(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    await operation();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Widget _candidateView(ItineraryCandidateView candidate) => ListView(
    key: const Key('agent-candidate-preview'),
    padding: const EdgeInsets.all(16),
    children: <Widget>[
      Text(candidate.title, style: Theme.of(context).textTheme.headlineSmall),
      const Text(
        'Candidate only. Review it before a separately authorized adoption.',
      ),
      for (final CandidateDayView day in candidate.days) ...<Widget>[
        const Divider(),
        Text('Day ${day.dayNumber}'),
        for (final CandidateItemView item in day.items)
          ListTile(
            title: Text(item.title),
            subtitle: Text('${item.startLabel} · ${item.durationMinutes} min'),
          ),
      ],
      OutlinedButton(
        key: const Key('agent-new-plan'),
        onPressed: _reset,
        child: const Text('Plan another trip'),
      ),
    ],
  );

  void _reset() {
    setState(() {
      _threadId = const Uuid().v4();
      _idempotencyKey = 'plan-${const Uuid().v4()}';
      _run = null;
      _candidate = null;
      _message = null;
    });
  }

  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
