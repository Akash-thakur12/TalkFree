import 'package:flutter/material.dart';

import '../services/assign_number_service.dart';
import '../services/available_numbers_service.dart';
import '../utils/user_facing_service_error.dart';
import 'pick_available_number_sheet.dart';

/// Loads inventory, optionally auto-picks the first number (premium), else shows picker,
/// then POST `/assign-number` with the chosen E.164.
Future<void> runAssignUsNumberFlow(
  BuildContext context, {
  String planType = 'monthly',
  /// Premium: skip the sheet and assign the first inventory number immediately.
  bool autoPickFirstNumber = false,
  /// Matches server POST `/assign-number` (`vip` | `premium`).
  String numberTier = 'vip',
  required void Function(AssignNumberResult r) onSuccess,
  required void Function(String message) onError,
}) async {
  try {
    final list = await AvailableNumbersService.instance.fetch();
    if (!context.mounted) return;
    if (list.isEmpty) {
      onError('No numbers available right now. Try again later.');
      return;
    }
    final String? phone = autoPickFirstNumber
        ? list.first.phoneNumber
        : await showPickAvailableNumberSheet(
            context,
            candidates: list,
          );
    if (!context.mounted || phone == null) return;
    final r = await AssignNumberService.instance.requestAssignNumber(
      phoneNumber: phone,
      planType: planType,
      numberTier: numberTier,
    );
    if (!context.mounted) return;
    onSuccess(r);
  } on AssignNumberException catch (e) {
    onError(userFacingServiceError(e.message));
  } catch (e) {
    onError(userFacingServiceError(e.toString()));
  }
}
