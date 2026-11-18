import 'package:flutter/foundation.dart';

/// `PublicUser` in the contract: what other users can see about an account.
@immutable
class PublicUser {
  const PublicUser({
    required this.id,
    required this.phone,
    required this.displayName,
    required this.about,
    required this.avatarUrl,
    this.avatarThumbUrl,
  });

  final String id;

  /// E.164, e.g. `+255712345678`.
  final String phone;
  final String? displayName;
  final String about;
  final String? avatarUrl;
  final String? avatarThumbUrl;

  /// Name to show in lists: the display name, or the phone number before setup.
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : phone;

  factory PublicUser.fromJson(Map<String, dynamic> json) => PublicUser(
        id: json['id'] as String,
        phone: json['phone'] as String,
        displayName: json['displayName'] as String?,
        about: json['about'] as String,
        avatarUrl: json['avatarUrl'] as String?,
        avatarThumbUrl: json['avatarThumbUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'phone': phone,
        'displayName': displayName,
        'about': about,
        'avatarUrl': avatarUrl,
        'avatarThumbUrl': avatarThumbUrl,
      };
}

/// `Me` in the contract: the signed-in user's own profile.
@immutable
class Me extends PublicUser {
  const Me({
    required super.id,
    required super.phone,
    required super.displayName,
    required super.about,
    required super.avatarUrl,
    super.avatarThumbUrl,
    required this.profileComplete,
  });

  /// False until a display name has been set (shows the profile setup screen).
  final bool profileComplete;

  factory Me.fromJson(Map<String, dynamic> json) {
    final u = PublicUser.fromJson(json);
    return Me(
      id: u.id,
      phone: u.phone,
      displayName: u.displayName,
      about: u.about,
      avatarUrl: u.avatarUrl,
      avatarThumbUrl: u.avatarThumbUrl,
      profileComplete: json['profileComplete'] as bool,
    );
  }

  @override
  Map<String, dynamic> toJson() =>
      {...super.toJson(), 'profileComplete': profileComplete};

  Me copyWith({
    String? displayName,
    String? about,
    String? Function()? avatarUrl,
    String? Function()? avatarThumbUrl,
  }) {
    final name = displayName ?? this.displayName;
    return Me(
      id: id,
      phone: phone,
      displayName: name,
      about: about ?? this.about,
      avatarUrl: avatarUrl != null ? avatarUrl() : this.avatarUrl,
      avatarThumbUrl:
          avatarThumbUrl != null ? avatarThumbUrl() : this.avatarThumbUrl,
      profileComplete: name != null && name.isNotEmpty,
    );
  }
}
