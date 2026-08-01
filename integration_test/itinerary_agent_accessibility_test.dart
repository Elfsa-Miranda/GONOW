import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/features/itinerary_agent/presentation/controllers/candidate_decision_controller.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';
import 'package:gonow/features/itinerary_agent/presentation/widgets/candidate_preview_panel.dart';

void main() {
  testWidgets('Candidate itinerary preview exposes evidence and warning labels', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _controller(_AuditSink()));
      expect(find.bySemanticsLabel('Candidate itinerary preview'), findsOneWidget);
      final Finder evidence = find.byKey(
        const ValueKey<String>('candidate-evidence-ev_hours'),
      );
      await _scrollTo(tester, evidence);
      expect(
        tester.getSemantics(evidence).label,
        contains('Verified evidence ev_hours'),
      );
      final Finder warning = find.byKey(
        const ValueKey<String>('candidate-warning-evidence.stale'),
      );
      await _scrollTo(tester, warning);
      expect(
        tester.getSemantics(warning).label,
        contains('Candidate warning evidence.stale'),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Candidate decision error is announced and remains safe', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _controller(_AuditSink(receipt: '')));
      final Finder abandon = find.byKey(const Key('candidate-abandon'));
      await _scrollTo(tester, abandon);
      await tester.tap(abandon);
      await tester.pump();
      final Finder error = find.byKey(const Key('candidate-decision-error'));
      await _scrollTo(tester, error);
      expect(tester.getSemantics(error).label, contains('Candidate decision error'));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Version conflict requires acknowledgement before adoption', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _controller(_AuditSink()));
      final Finder conflict = find.byKey(
        const Key('candidate-conflict-semantics'),
      );
      await _scrollTo(tester, conflict);
      expect(
        tester.getSemantics(conflict).label,
        contains('Version conflict requires acknowledgement'),
      );
      final Finder adoption = find.byKey(
        const Key('candidate-request-adoption'),
      );
      await _scrollTo(tester, adoption);
      expect(tester.widget<FilledButton>(adoption).onPressed, isNull);
    } finally {
      semantics.dispose();
    }
  });
}

CandidateDecisionController _controller(_AuditSink audit) =>
    CandidateDecisionController(
      preview: CandidatePreviewModel(
        candidate: ItineraryCandidateView.fromJson(_candidateJson()),
        current: const CurrentItinerarySnapshot(
          version: 2,
          title: 'Existing plan',
          items: <CurrentItineraryItem>[],
        ),
        expectedVersion: 1,
        warnings: const <CandidateWarning>[
          CandidateWarning(
            code: 'evidence.stale',
            message: 'Synthetic evidence needs confirmation.',
          ),
        ],
      ),
      auditSink: audit,
    );

Map<String, dynamic> _candidateJson() => <String, dynamic>{
  'schema_version': '1.0',
  'candidate_id': 'cand_11111111111111111111111111111111',
  'run_id': '11111111-1111-4111-8111-111111111111',
  'behavior_digest': 'b' * 64,
  'input_digest': 'c' * 64,
  'title': 'Candidate plan',
  'days': <Object>[
    <String, dynamic>{
      'day_number': 1,
      'items': <Object>[
        <String, dynamic>{
          'item_id': 'item_arrival',
          'title': 'Arrival',
          'start_minute': 540,
          'duration_minutes': 60,
          'claim_ids': <String>['claim_hours'],
        },
      ],
    },
  ],
  'citations': <Object>[
    <String, dynamic>{
      'claim_id': 'claim_hours',
      'evidence_id': 'ev_hours',
      'source_ref': 'evidence://synthetic/hours',
      'sha256': 'a' * 64,
    },
  ],
  'evidence_refs': <String>['evidence://synthetic/hours'],
  'status': 'candidate',
};

Future<void> _pump(
  WidgetTester tester,
  CandidateDecisionController controller,
) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: CandidatePreviewPanel(controller: controller)),
  ),
);

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

final class _AuditSink implements CandidateDecisionAuditSink {
  _AuditSink({this.receipt = 'synthetic-audit-receipt'});

  final String receipt;

  @override
  Future<String> record(CandidateDecisionAuditEvent event) async => receipt;
}
