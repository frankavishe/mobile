/// `Error.code` in the contract, plus two client-side codes.
enum ApiErrorCode {
  validationFailed('VALIDATION_FAILED'),
  invalidPhone('INVALID_PHONE'),
  invalidCode('INVALID_CODE'),
  codeExpired('CODE_EXPIRED'),
  tooManyAttempts('TOO_MANY_ATTEMPTS'),
  accountNotFound('ACCOUNT_NOT_FOUND'),
  userNotFound('USER_NOT_FOUND'),
  deviceNotFound('DEVICE_NOT_FOUND'),
  sessionRevoked('SESSION_REVOKED'),
  unauthorized('UNAUTHORIZED'),
  rateLimited('RATE_LIMITED'),
  fileTooLarge('FILE_TOO_LARGE'),
  unsupportedMediaType('UNSUPPORTED_MEDIA_TYPE'),
  internal('INTERNAL'),

  /// Client only: the server could not be reached.
  network('NETWORK'),

  /// Client only: a code this app version does not know.
  unknown('UNKNOWN');

  const ApiErrorCode(this.wire);

  /// The value used on the wire.
  final String wire;

  /// Codes defined by the contract (excludes the client-only ones).
  static List<ApiErrorCode> get contractCodes =>
      values.where((c) => c != network && c != unknown).toList();

  static ApiErrorCode fromWire(String? value) => values.firstWhere(
        (c) => c.wire == value,
        orElse: () => unknown,
      );
}

/// A failed API call: the contract `Error` body, or a network failure.
class ApiError implements Exception {
  const ApiError({
    required this.status,
    required this.code,
    required this.message,
    this.retryAfter,
    this.details,
  });

  /// HTTP status, or 0 when the server could not be reached.
  final int status;
  final ApiErrorCode code;
  final String message;

  /// Seconds from the `Retry-After` header (429 responses).
  final int? retryAfter;
  final Map<String, dynamic>? details;

  const ApiError.network()
      : status = 0,
        code = ApiErrorCode.network,
        message = "Can't reach the server. Check your connection.",
        retryAfter = null,
        details = null;

  factory ApiError.fromJson(
    int status,
    Map<String, dynamic> json, {
    int? retryAfter,
  }) =>
      ApiError(
        status: status,
        code: ApiErrorCode.fromWire(json['code'] as String?),
        message: (json['message'] as String?) ?? 'Request failed ($status)',
        retryAfter: retryAfter,
        details: json['details'] as Map<String, dynamic>?,
      );

  @override
  String toString() => 'ApiError($status, ${code.wire}): $message';
}
