import 'package:flutter/foundation.dart';

import 'device.dart';
import 'user.dart';

/// `RequestCodeResponse` in the contract.
@immutable
class RequestCodeResponse {
  const RequestCodeResponse({required this.expiresIn, required this.resendAfter});

  /// Seconds until the code expires.
  final int expiresIn;

  /// Seconds until another code may be requested.
  final int resendAfter;

  factory RequestCodeResponse.fromJson(Map<String, dynamic> json) =>
      RequestCodeResponse(
        expiresIn: json['expiresIn'] as int,
        resendAfter: json['resendAfter'] as int,
      );
}

/// `TokenPair` in the contract. Android always receives [refreshToken].
@immutable
class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.expiresIn,
    this.refreshToken,
  });

  final String accessToken;

  /// Seconds until [accessToken] expires.
  final int expiresIn;
  final String? refreshToken;

  factory TokenPair.fromJson(Map<String, dynamic> json) => TokenPair(
        accessToken: json['accessToken'] as String,
        expiresIn: json['expiresIn'] as int,
        refreshToken: json['refreshToken'] as String?,
      );
}

/// `AuthResult` in the contract: the response of `POST /auth/verify`.
@immutable
class AuthResult extends TokenPair {
  const AuthResult({
    required super.accessToken,
    required super.expiresIn,
    super.refreshToken,
    required this.isNewAccount,
    required this.device,
    required this.user,
  });

  final bool isNewAccount;
  final Device device;
  final Me user;

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    final tokens = TokenPair.fromJson(json);
    return AuthResult(
      accessToken: tokens.accessToken,
      expiresIn: tokens.expiresIn,
      refreshToken: tokens.refreshToken,
      isNewAccount: json['isNewAccount'] as bool,
      device: Device.fromJson(json['device'] as Map<String, dynamic>),
      user: Me.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
