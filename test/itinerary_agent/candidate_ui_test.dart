import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/features/itinerary_agent/presentation/controllers/candidate_decision_controller.dart';
import 'package:gonow/features/itinerary_agent/presentation/models/candidate_preview_model.dart';
import 'package:gonow/features/itinerary_agent/presentation/widgets/candidate_preview_panel.dart';

void main() {
  test('typed Candidate rejects unknown prompt or reasoning fields', () {
    final Map<String, dynamic> payload = _candidateJson();
    payload['reasoning'] = 'not-renderable';

    expect(
      () => ItineraryCandidateView.fromJson(payload),
      throwsA(
        isA<CandidatePreviewException>().having(
          (CandidatePreviewException error) => error.code,
          'code',
          'candidate.unknown_field',
        ),
      ),
    );
  });

  test('diff exposes changed, removed, and added items', () {
    final CandidatePreviewModel preview = _preview();

    expect(
      preview.diff.map((CandidateDiffEntry entry) => entry.kind),
      containsAll(<CandidateDiffKind>[
        CandidateDiffKind.changed,
        CandidateDiffKind.removed,
        CandidateDiffKind.added,
      ]),
    );
    expect(preview.hasVersionConflict, isTrue);
  });

  testWidgets('preview renders itinerary, evidence, warnings, and all diffs', (
    WidgetTester tester,
  ) async {
    final _FakeAuditSink audit = _FakeAuditSink();
    await _pump(tester, _controller(audit));

    expect(find.text('候选行程预览'), findsOneWidget);
    expect(find.text('New plan'), findsOneWidget);
    await _scrollTo(tester, find.textContaining('items.item_old'));
    expect(find.textContaining('items.item_old'), findsOneWidget);
    await _scrollTo(tester, find.text('ev_hours'));
    expect(find.text('ev_hours'), findsOneWidget);
    await _scrollTo(tester, find.text('开放时间仍需确认'));
    expect(find.text('开放时间仍需确认'), findsOneWidget);
    await _scrollTo(tester, find.byKey(const Key('candidate-conflict-ack')));
    expect(find.byKey(const Key('candidate-conflict-ack')), findsOneWidget);
  });

  testWidgets('unapproved preview performs zero business writes', (
    WidgetTester tester,
  ) async {
    final _FakeAuditSink audit = _FakeAuditSink();
    int businessWriteCount = 0;
    await _pump(
      tester,
      _controller(audit),
      onDecision: (_) => businessWriteCount += 1,
    );
    await _scrollTo(
      tester,
      find.byKey(const Key('candidate-request-adoption')),
    );

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('candidate-request-adoption')),
          )
          .onPressed,
      isNull,
    );
    expect(audit.events, isEmpty);
    expect(businessWriteCount, 0);
  });

  testWidgets('version conflict cannot be hidden during approval', (
    WidgetTester tester,
  ) async {
    final _FakeAuditSink audit = _FakeAuditSink();
    await _pump(tester, _controller(audit));

    await _scrollTo(tester, find.byKey(const Key('candidate-review-ack')));
    await tester.tap(find.byKey(const Key('candidate-review-ack')));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('candidate-request-adoption')),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('不一致，我已看到冲突'), findsOneWidget);
  });

  testWidgets(
    'explicit confirmation emits audited request but no business write',
    (WidgetTester tester) async {
      final _FakeAuditSink audit = _FakeAuditSink();
      final List<CandidateDecisionReceipt> decisions =
          <CandidateDecisionReceipt>[];
      int businessWriteCount = 0;
      await _pump(tester, _controller(audit), onDecision: decisions.add);

      await _scrollTo(tester, find.byKey(const Key('candidate-conflict-ack')));
      await tester.tap(find.byKey(const Key('candidate-conflict-ack')));
      await _scrollTo(tester, find.byKey(const Key('candidate-review-ack')));
      await tester.tap(find.byKey(const Key('candidate-review-ack')));
      await tester.pump();
      await _scrollTo(
        tester,
        find.byKey(const Key('candidate-request-adoption')),
      );
      await tester.tap(find.byKey(const Key('candidate-request-adoption')));
      await tester.pump();

      expect(decisions.single.kind, CandidateDecisionKind.requestAdoption);
      expect(decisions.single.auditReceiptId, 'audit-candidate-1');
      expect(audit.events.single.conflictAcknowledged, isTrue);
      expect(businessWriteCount, 0);
    },
  );

  testWidgets('abandon is audited without an adoption request', (
    WidgetTester tester,
  ) async {
    final _FakeAuditSink audit = _FakeAuditSink();
    final List<CandidateDecisionReceipt> decisions =
        <CandidateDecisionReceipt>[];
    await _pump(tester, _controller(audit), onDecision: decisions.add);

    await _scrollTo(tester, find.byKey(const Key('candidate-abandon')));
    await tester.tap(find.byKey(const Key('candidate-abandon')));
    await tester.pump();

    expect(decisions.single.kind, CandidateDecisionKind.abandon);
    expect(audit.events.single.kind, CandidateDecisionKind.abandon);
  });

  testWidgets(
    'missing audit receipt shows safe error and keeps Candidate pending',
    (WidgetTester tester) async {
      final _FakeAuditSink audit = _FakeAuditSink(receipt: '');
      final CandidateDecisionController controller = _controller(audit);
      await _pump(tester, controller);

      await _scrollTo(tester, find.byKey(const Key('candidate-abandon')));
      await tester.tap(find.byKey(const Key('candidate-abandon')));
      await tester.pump();

      await _scrollTo(
        tester,
        find.byKey(const Key('candidate-decision-error')),
      );
      expect(find.byKey(const Key('candidate-decision-error')), findsOneWidget);
      expect(find.textContaining('候选未被采用'), findsOneWidget);
      expect(controller.state, CandidateDecisionState.pending);
    },
  );

  testWidgets('critical preview controls expose accessibility semantics', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await _pump(tester, _controller(_FakeAuditSink()));

      expect(
        find.bySemanticsLabel('Candidate itinerary preview'),
        findsOneWidget,
      );
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

      final Finder conflict = find.byKey(
        const Key('candidate-conflict-semantics'),
      );
      await _scrollTo(tester, conflict);
      expect(
        tester.getSemantics(conflict).label,
        contains('Version conflict requires acknowledgement'),
      );
    } finally {
      semantics.dispose();
    }
  });
}

CandidateDecisionController _controller(_FakeAuditSink audit) =>
    CandidateDecisionController(preview: _preview(), auditSink: audit);

CandidatePreviewModel _preview() => CandidatePreviewModel(
  candidate: ItineraryCandidateView.fromJson(_candidateJson()),
  current: const CurrentItinerarySnapshot(
    version: 4,
    title: 'Old plan',
    items: <CurrentItineraryItem>[
      CurrentItineraryItem(
        itemId: 'item_museum',
        title: 'Old museum',
        startMinute: 480,
        durationMinutes: 90,
      ),
      CurrentItineraryItem(
        itemId: 'item_old',
        title: 'Removed stop',
        startMinute: 700,
        durationMinutes: 30,
      ),
    ],
  ),
  expectedVersion: 3,
  warnings: const <CandidateWarning>[
    CandidateWarning(code: 'evidence.stale', message: '开放时间仍需确认'),
  ],
);

Map<String, dynamic> _candidateJson() => <String, dynamic>{
  'schema_version': '1.0',
  'candidate_id': 'cand_11111111111111111111111111111111',
  'run_id': '11111111-1111-4111-8111-111111111111',
  'behavior_digest': 'b' * 64,
  'input_digest': 'c' * 64,
  'title': 'New plan',
  'days': <Object>[
    <String, dynamic>{
      'day_number': 1,
      'items': <Object>[
        <String, dynamic>{
          'item_id': 'item_museum',
          'title': 'New museum',
          'start_minute': 540,
          'duration_minutes': 120,
          'claim_ids': <String>['claim_hours'],
        },
        <String, dynamic>{
          'item_id': 'item_new',
          'title': 'New stop',
          'start_minute': 780,
          'duration_minutes': 60,
          'claim_ids': <String>[],
        },
      ],
    },
  ],
  'citations': <Object>[
    <String, dynamic>{
      'claim_id': 'claim_hours',
      'evidence_id': 'ev_hours',
      'source_ref': 'evidence://poi/hours',
      'sha256': 'a' * 64,
    },
  ],
  'evidence_refs': <String>['evidence://poi/hours'],
  'status': 'candidate',
};

Future<void> _pump(
  WidgetTester tester,
  CandidateDecisionController controller, {
  ValueChanged<CandidateDecisionReceipt>? onDecision,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CandidatePreviewPanel(
          controller: controller,
          onDecision: onDecision,
        ),
      ),
    ),
  );
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

final class _FakeAuditSink implements CandidateDecisionAuditSink {
  _FakeAuditSink({this.receipt = 'audit-candidate-1'});

  final String receipt;
  final List<CandidateDecisionAuditEvent> events =
      <CandidateDecisionAuditEvent>[];

  @override
  Future<String> record(CandidateDecisionAuditEvent event) async {
    events.add(event);
    return receipt;
  }
}
