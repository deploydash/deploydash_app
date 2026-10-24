import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppEnvironmentVariableRevisionNotifier
    extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void markProjectUpdated(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    state = {
      ...state,
      normalizedProjectId: (state[normalizedProjectId] ?? 0) + 1,
    };
  }
}

final appEnvironmentVariableRevisionProvider =
    NotifierProvider<AppEnvironmentVariableRevisionNotifier, Map<String, int>>(
      AppEnvironmentVariableRevisionNotifier.new,
    );
