import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/app_state.dart';
import '../../../drivers/router_models.dart';
import '../data/usage_repository.dart';
import '../domain/usage_calculator_service.dart';
import '../domain/usage_models.dart';

class UsageState {
  const UsageState({
    required this.ledger,
    required this.quota,
    required this.stats,
    this.lastEvent,
  });

  final UsageLedger ledger;
  final QuotaSettings quota;
  final UsageStats stats;
  final IngestEvent? lastEvent;

  bool get isCalibrated =>
      ledger.calibrationCycleKey == stats.cycle.key && ledger.calibrationAdjustBytes != 0;
}

final usageServiceProvider = Provider<UsageCalculatorService>((ref) => UsageCalculatorService());

class UsageController extends Notifier<UsageState> {
  late UsageRepository _repo;
  UsageCalculatorService get _svc => ref.read(usageServiceProvider);

  @override
  UsageState build() {
    final demo = ref.watch(appSettingsProvider.select((s) => s.demoMode));
    _repo = UsageRepository(ref.watch(sharedPrefsProvider), demo: demo);
    final ledger = _repo.loadLedger();
    if (demo && ledger.daily.isEmpty) {
      UsageCalculatorService.seedDemoHistory(ledger, DateTime.now());
      _repo.saveLedger(ledger);
    }
    final quota = _repo.loadQuota();
    return UsageState(ledger: ledger, quota: quota, stats: _svc.stats(ledger, quota, DateTime.now()));
  }

  void _emit(UsageLedger ledger, {QuotaSettings? quota, IngestEvent? event}) {
    final q = quota ?? state.quota;
    state = UsageState(
      ledger: ledger,
      quota: q,
      stats: _svc.stats(ledger, q, DateTime.now()),
      lastEvent: event ?? state.lastEvent,
    );
  }

  void ingest(TrafficCounters counters) {
    final ledger = state.ledger.clone();
    final event = _svc.ingest(ledger, counters);
    _repo.saveLedger(ledger);
    _emit(ledger, event: event);
  }

  Future<void> setQuota(QuotaSettings q) async {
    await _repo.saveQuota(q);
    _emit(state.ledger, quota: q);
  }

  Future<void> calibrate(double usedGb) async {
    final ledger = state.ledger.clone();
    _svc.calibrate(ledger, state.quota, usedGb, DateTime.now());
    await _repo.saveLedger(ledger);
    _emit(ledger);
  }

  Future<void> clearCalibration() async {
    final ledger = state.ledger.clone();
    _svc.clearCalibration(ledger);
    await _repo.saveLedger(ledger);
    _emit(ledger);
  }

  Future<void> resetHistory() async {
    await _repo.resetLedger();
    // Keep the current raw counters as baseline so we don't re-count them.
    final fresh = UsageLedger(
      lastRawRx: state.ledger.lastRawRx,
      lastRawTx: state.ledger.lastRawTx,
      lastSampleAt: state.ledger.lastSampleAt,
    );
    await _repo.saveLedger(fresh);
    _emit(fresh);
  }

  List<DailyPoint> series(int days) => _svc.dailySeries(state.ledger, days, DateTime.now());
}

final usageControllerProvider =
    NotifierProvider<UsageController, UsageState>(UsageController.new);
