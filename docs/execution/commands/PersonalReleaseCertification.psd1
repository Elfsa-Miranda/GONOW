@{
  SchemaVersion = '1.0'
  ConfigVersion = '1.1.1'
  ActiveGovernanceProfile = 'personal_automated'
  Profiles = @{
    ReleaseBDeep = @{
      TaskId = 'TASK-P10-009'
      OrderedGates = @('C1','C2','C3','C4','C5')
      MaximumWallClockSeconds = 64800
      MinimumRealSoakSeconds = 14400
      ProductionObservationRequired = $false
      AutomatedGateAcceptance = $true
      EvidenceType = 'personal_compressed_release_certification'
      ResidualRisk = 'not_validated_against_31_day_real_user_and_infrastructure_drift'
      Reports = @{
        C1 = 'c1-correctness.json'
        C2 = 'c2-security-performance-cost.json'
        C3 = 'c3-quality-slices.json'
        C4 = 'c4-recovery-time-soak.json'
        C5 = 'c5-rollback-operations.json'
      }
      SupportingReports = @{
        C1 = @('regression-report.json','state-space-report.json','c1-e0-expanded.json')
        C2 = @('security-matrix.json','performance-cost-report.json','c2-postgresql-load.json','deepseek-v2/live-provider-receipts.json','deepseek-v2/pricing-snapshot.json')
        C3 = @('quality-slice-report.json')
        C4 = @('fault-injection-report.json','virtual-time-report.json','soak-report.json','soak-samples.json','c4-judge-calibration.json')
        C5 = @('rollback-operations-report.json')
      }
      Thresholds = @{
        C1 = @{
          minimum_e0_cases = 200
          minimum_state_sequences = 50000
          minimum_success_rate_lower_95 = 0.90
        }
        C2 = @{
          minimum_generated_security_attempts = 100000
          minimum_local_complete_runs = 10000
          minimum_live_calls_per_route = 200
          minimum_critical_mutation_kill_rate = 1.0
          minimum_changed_mutation_kill_rate = 0.90
          maximum_api_p95_upper_ms = 800
          maximum_cost_to_budget_ratio = 1.20
          maximum_p95_cost_increase_upper = 0.15
        }
        C3 = @{
          minimum_e1_cases = 1000
          minimum_cases_per_critical_slice = 200
          maximum_noninferiority_regression_upper = 0.01
        }
        C4 = @{
          minimum_schedules_per_killpoint_outcome = 20
          minimum_virtual_days = 90
          minimum_fake_provider_lifecycles = 100000
          minimum_real_soak_seconds = 14400
          minimum_real_soak_samples = 480
          minimum_soak_slope_samples = 360
          minimum_judge_annotations = 400
          minimum_judge_primary_slice_annotations = 50
          maximum_judge_mechanical_gap_pp = 5
        }
        C5 = @{
          minimum_fault_classes = 20
          maximum_kill_switch_seconds = 30
        }
      }
    }
  }
}
