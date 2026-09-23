import 'package:flutter_test/flutter_test.dart';

import 'package:fleet_driver_app/models/local_models.dart';
import 'package:fleet_driver_app/services/sync_service.dart';

SyncOperation op({required String state, required int attempts, required DateTime updatedAt}) => SyncOperation(
      id: 'op-1',
      operationType: 'SYNC_INSPECTION',
      entityId: 'draft-1',
      state: state,
      attempts: attempts,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

void main() {
  final now = DateTime.utc(2026, 1, 1, 12, 0, 0);

  test('a PENDING művelet mindig esedékes', () {
    expect(syncOperationDue(op(state: 'PENDING', attempts: 0, updatedAt: now), now), isTrue);
  });

  test('a hibázott művelet a backoff letelte előtt nem esedékes', () {
    // attempts = 3 -> 8 másodperc backoff
    final failed = op(state: 'ERROR', attempts: 3, updatedAt: now);
    expect(syncOperationDue(failed, now.add(const Duration(seconds: 7))), isFalse);
    expect(syncOperationDue(failed, now.add(const Duration(seconds: 8))), isTrue);
  });

  test('a backoff 5 percnél megáll, nem nő a végtelenségig', () {
    final failed = op(state: 'ERROR', attempts: 8, updatedAt: now);
    expect(syncOperationDue(failed, now.add(const Duration(minutes: 5))), isTrue);
  });
}
