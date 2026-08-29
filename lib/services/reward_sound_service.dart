import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Soft coin-style SFX for monetization moments (e.g. ad reward).
abstract final class RewardSoundService {
  RewardSoundService._();

  static final AudioPlayer _player = AudioPlayer();

  static Future<void> playCoin() async {
    try {
      await _player.stop();
      await _player.play(
        AssetSource('sounds/reward_coin.wav'),
        volume: 0.38,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('RewardSoundService: $e\n$st');
      }
      await HapticFeedback.lightImpact();
    }
  }
}
