import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/auth_service.dart';
import 'data/qq_music_api.dart';
import 'player/music_handler.dart';

final apiProvider = Provider<QqMusicApi>(
  (ref) => throw StateError('API not initialized'),
);
final authProvider = ChangeNotifierProvider<AuthService>(
  (ref) => throw StateError('Auth not initialized'),
);
final playerProvider = Provider<MusicHandler>(
  (ref) => throw StateError('Player not initialized'),
);
