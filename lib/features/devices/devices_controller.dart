import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/models/models.dart';
import '../auth/auth_controller.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Same wording as the web devices page.
String lastActiveText(DateTime lastActive, DateTime now) {
  final diff = now.difference(lastActive);
  final min = diff.isNegative ? 0 : diff.inMinutes;
  if (min < 2) return 'Active now';
  if (min < 60) return 'Active $min minutes ago';
  final h = min ~/ 60;
  if (h < 24) return 'Active $h hour${h == 1 ? '' : 's'} ago';
  final d = lastActive.toLocal();
  return 'Last active ${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// This device first, then Android before web (same order as the web page).
List<Device> sortDevices(Iterable<Device> devices) => [...devices]
  ..sort((a, b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    return a.type.name.compareTo(b.type.name);
  });

/// The account's signed-in devices, while the Linked devices screen is open.
class DevicesController extends AsyncNotifier<List<Device>> {
  ApiClient get _api => ref.read(apiClientProvider);

  @override
  Future<List<Device>> build() async => sortDevices(await _api.listDevices());

  /// Reloads in the background. A failure keeps the list already shown.
  Future<void> refresh() async {
    try {
      final list = sortDevices(await _api.listDevices());
      if (ref.mounted) state = AsyncData(list);
    } on ApiError catch (e, st) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    }
  }

  /// Loads again from scratch, showing the spinner (after an error).
  void retry() => ref.invalidateSelf();

  /// Signs [device] out. For this device it signs out locally too (the router then shows
  /// sign-in). Throws [ApiError] when the server refused; a device that is already gone
  /// ([ApiErrorCode.deviceNotFound]) is removed from the list before rethrowing.
  Future<void> revoke(Device device) async {
    if (device.current) {
      await ref.read(authControllerProvider.notifier).signOut();
      return;
    }
    try {
      await _api.revokeDevice(device.id);
      _remove(device.id);
    } on ApiError catch (e) {
      if (e.code == ApiErrorCode.deviceNotFound) _remove(device.id);
      rethrow;
    }
  }

  void _remove(String id) {
    final list = state.value;
    if (!ref.mounted || list == null) return;
    state = AsyncData(list.where((d) => d.id != id).toList());
  }
}

final devicesProvider =
    AsyncNotifierProvider.autoDispose<DevicesController, List<Device>>(
  DevicesController.new,
  // The screen shows the error with a Retry button (and polls), so no automatic retries.
  retry: (_, _) => null,
);
