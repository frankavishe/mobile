import 'models/models.dart';

/// Same wording as `web/src/lib/errors.ts`, so both clients say the same thing.
const _messages = <ApiErrorCode, String>{
  ApiErrorCode.invalidPhone: "That phone number isn't valid.",
  ApiErrorCode.invalidCode: "That code isn't right. Check it and try again.",
  ApiErrorCode.codeExpired: 'That code has expired. Request a new one.',
  ApiErrorCode.tooManyAttempts: 'Too many attempts. Request a new code.',
  ApiErrorCode.accountNotFound:
      "There's no account for this number yet. Create your account on the Android app first, then sign in here.",
  ApiErrorCode.userNotFound: "This number isn't on Chat App.",
  ApiErrorCode.deviceNotFound: 'That device is no longer signed in.',
  ApiErrorCode.sessionRevoked: 'This phone was signed out.',
  ApiErrorCode.unauthorized: 'Your session has ended. Sign in again.',
  ApiErrorCode.fileTooLarge: 'That photo is too large. The limit is 5 MB.',
  ApiErrorCode.unsupportedMediaType: 'Use a JPEG, PNG or WebP photo.',
  ApiErrorCode.network: "Can't reach the server. Check your connection.",
};

const _fallback = 'Something went wrong. Try again.';

String waitText(int seconds) {
  if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
  final minutes = (seconds / 60).ceil();
  return '$minutes minute${minutes == 1 ? '' : 's'}';
}

/// A sentence to show the user for any error thrown by [ApiClient] calls.
String errorMessage(Object error) {
  if (error is! ApiError) return _fallback;
  switch (error.code) {
    case ApiErrorCode.rateLimited:
      final s = error.retryAfter;
      return s != null && s > 0
          ? 'Too many requests. Try again in ${waitText(s)}.'
          : 'Too many requests. Try again later.';
    case ApiErrorCode.validationFailed:
      return error.message.isNotEmpty ? error.message : 'Check what you entered.';
    default:
      return _messages[error.code] ?? _fallback;
  }
}
