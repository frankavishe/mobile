/// Build-time configuration, set with `--dart-define`.
abstract final class AppConfig {
  /// Origin of the API, without the `/v1` prefix.
  /// The default reaches the host machine from the Android emulator.
  static const String apiOrigin = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://10.0.2.2:3000',
  );

  /// Base URL for REST calls.
  static String get apiBaseUrl => '${_trimSlash(apiOrigin)}/v1';

  /// Socket.IO namespace URL.
  static String get realtimeUrl => '${_trimSlash(apiOrigin)}/rt';

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}
