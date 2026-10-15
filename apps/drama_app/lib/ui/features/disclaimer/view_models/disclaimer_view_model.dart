import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/appearance_controller.dart';

/// 免责声明是否已确认（首次启动引导用，PRD Q13 措辞定稿前先用占位）。
///
/// 三处落地之一：首次启动引导页；另外两处为「关于」页与设置页内文案。
final disclaimerAcknowledgedProvider =
    NotifierProvider<DisclaimerController, bool>(DisclaimerController.new);

class DisclaimerController extends Notifier<bool> {
  static const String _key = 'legal.disclaimerAcknowledged';

  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(_key) ?? false;

  Future<void> acknowledge() async {
    state = true;
    await ref.read(sharedPreferencesProvider).setBool(_key, true);
  }
}
