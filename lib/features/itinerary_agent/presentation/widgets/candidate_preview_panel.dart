import 'package:flutter/material.dart';
import 'package:gonow/features/itinerary_agent/presentation/controllers/candidate_decision_controller.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';

final class CandidatePreviewPanel extends StatefulWidget {
  const CandidatePreviewPanel({
    required this.controller,
    this.onDecision,
    super.key,
  });

  final CandidateDecisionController controller;
  final ValueChanged<CandidateDecisionReceipt>? onDecision;

  @override
  State<CandidatePreviewPanel> createState() => _CandidatePreviewPanelState();
}

final class _CandidatePreviewPanelState extends State<CandidatePreviewPanel> {
  String? _errorCode;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? child) {
        final CandidatePreviewModel preview = widget.controller.preview;
        return Semantics(
          label: 'Candidate itinerary preview',
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text('候选行程预览', style: Theme.of(context).textTheme.headlineSmall),
              Text(preview.candidate.title),
              const SizedBox(height: 12),
              ...preview.candidate.days.map(_day),
              const Divider(),
              Semantics(header: true, child: const Text('变更对比')),
              if (preview.diff.isEmpty) const Text('与当前行程无差异'),
              ...preview.diff.map(_diff),
              const Divider(),
              Semantics(header: true, child: const Text('证据')),
              ...preview.candidate.citations.map(
                (CandidateCitationView citation) => Semantics(
                  key: ValueKey<String>(
                    'candidate-evidence-${citation.evidenceId}',
                  ),
                  label: 'Verified evidence ${citation.evidenceId}',
                  child: ListTile(
                    leading: const Icon(Icons.verified_outlined),
                    title: Text(citation.evidenceId),
                    subtitle: Text('支持 ${citation.claimId}'),
                  ),
                ),
              ),
              ...preview.warnings.map(
                (CandidateWarning warning) => Semantics(
                  key: ValueKey<String>('candidate-warning-${warning.code}'),
                  liveRegion: true,
                  label: 'Candidate warning ${warning.code}',
                  child: MaterialBanner(
                    content: Text(warning.message),
                    actions: const <Widget>[SizedBox.shrink()],
                  ),
                ),
              ),
              if (preview.hasVersionConflict)
                Semantics(
                  key: const Key('candidate-conflict-semantics'),
                  liveRegion: true,
                  label: 'Version conflict requires acknowledgement',
                  child: CheckboxListTile(
                    key: const Key('candidate-conflict-ack'),
                    value: widget.controller.conflictAcknowledged,
                    onChanged: (bool? value) => widget.controller
                        .setConflictAcknowledged(value ?? false),
                    title: Text(
                      '当前行程版本 ${preview.current.version} 与预期版本 '
                      '${preview.expectedVersion} 不一致，我已看到冲突',
                    ),
                  ),
                ),
              CheckboxListTile(
                key: const Key('candidate-review-ack'),
                value: widget.controller.reviewAcknowledged,
                onChanged: (bool? value) =>
                    widget.controller.setReviewAcknowledged(value ?? false),
                title: const Text('我已查看预览、证据和全部差异'),
              ),
              if (_errorCode != null)
                Semantics(
                  liveRegion: true,
                  label: 'Candidate decision error',
                  child: Text(
                    _messageFor(_errorCode!),
                    key: const Key('candidate-decision-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('candidate-abandon'),
                      onPressed: widget.controller.busy ? null : _abandon,
                      child: const Text('放弃候选'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('candidate-request-adoption'),
                      onPressed: widget.controller.canRequestAdoption
                          ? _requestAdoption
                          : null,
                      child: const Text('确认并请求采用'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _day(CandidateDayView day) => Semantics(
    label: 'Candidate day ${day.dayNumber}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('第 ${day.dayNumber} 天'),
        ...day.items.map(
          (CandidateItemView item) => ListTile(
            title: Text(item.title),
            subtitle: Text('${item.startLabel} · ${item.durationMinutes} 分钟'),
          ),
        ),
      ],
    ),
  );

  Widget _diff(CandidateDiffEntry entry) => Semantics(
    label: 'Candidate diff ${entry.path} ${entry.kind.name}',
    child: ListTile(
      dense: true,
      title: Text(entry.path),
      subtitle: Text('${entry.before ?? '无'} → ${entry.after ?? '无'}'),
    ),
  );

  Future<void> _requestAdoption() async {
    await _run(widget.controller.requestAdoption);
  }

  Future<void> _abandon() async {
    await _run(widget.controller.abandon);
  }

  Future<void> _run(Future<CandidateDecisionReceipt> Function() action) async {
    setState(() => _errorCode = null);
    try {
      final CandidateDecisionReceipt receipt = await action();
      widget.onDecision?.call(receipt);
    } on CandidateDecisionException catch (error) {
      if (mounted) {
        setState(() => _errorCode = error.code);
      }
    } on Object {
      if (mounted) {
        setState(() => _errorCode = 'candidate.decision_failed');
      }
    }
  }

  String _messageFor(String code) => switch (code) {
    'candidate.audit_receipt_missing' => '操作记录失败，候选未被采用，请稍后重试。',
    'candidate.approval_required' => '请先查看并确认全部差异。',
    _ => '无法完成候选操作，请稍后重试。',
  };
}
