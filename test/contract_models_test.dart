// Keeps the Dart models in lib/core/api/models/ in sync with the API contract.
//
// Reads the canonical contract from the api repo checked out next to this one
// (`../api/contracts/`). Override with CONTRACT_DIR=/path/to/contracts.
import 'dart:convert';
import 'dart:io';

import 'package:chat_app/core/api/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

final _contractDir =
    Platform.environment['CONTRACT_DIR'] ?? '../api/contracts';

/// YAML → plain JSON-like Dart values (`Map<String, dynamic>`, `List<dynamic>`).
dynamic _plain(dynamic yaml) => jsonDecode(jsonEncode(yaml));

void main() {
  late Map<String, dynamic> openapi;
  late Map<String, dynamic> ws;

  setUpAll(() {
    final yamlFile = File('$_contractDir/openapi.yaml');
    final wsFile = File('$_contractDir/ws-events.schema.json');
    if (!yamlFile.existsSync() || !wsFile.existsSync()) {
      fail('Contract not found in $_contractDir. Check out the api repo next to '
          'mobile/, or set CONTRACT_DIR.');
    }
    openapi = _plain(loadYaml(yamlFile.readAsStringSync())) as Map<String, dynamic>;
    ws = jsonDecode(wsFile.readAsStringSync()) as Map<String, dynamic>;
  });

  Map<String, dynamic> schema(String name) =>
      openapi['components']['schemas'][name] as Map<String, dynamic>;

  /// Required properties of a schema, following `allOf` and `$ref`.
  Set<String> requiredOf(String name) {
    final s = schema(name);
    final out = <String>{...(s['required'] as List? ?? []).cast<String>()};
    for (final part in (s['allOf'] as List? ?? [])) {
      final p = part as Map<String, dynamic>;
      if (p[r'$ref'] is String) {
        out.addAll(requiredOf((p[r'$ref'] as String).split('/').last));
      } else {
        out.addAll((p['required'] as List? ?? []).cast<String>());
      }
    }
    return out;
  }

  Map<String, dynamic> responseExample(String path, String method, String status) =>
      openapi['paths'][path][method]['responses'][status]['content']
          ['application/json']['example'] as Map<String, dynamic>;

  group('OpenAPI examples decode', () {
    test('POST /auth/request-code 202 → RequestCodeResponse', () {
      final r = RequestCodeResponse.fromJson(
          responseExample('/auth/request-code', 'post', '202'));
      expect(r.expiresIn, 300);
      expect(r.resendAfter, 60);
    });

    test('POST /auth/verify 200 → AuthResult', () {
      final r = AuthResult.fromJson(responseExample('/auth/verify', 'post', '200'));
      expect(r.accessToken, isNotEmpty);
      expect(r.refreshToken, isNotNull);
      expect(r.isNewAccount, isTrue);
      expect(r.device.type, DeviceType.android);
      expect(r.device.current, isTrue);
      expect(r.user.phone, '+255712345678');
      expect(r.user.displayName, isNull);
      expect(r.user.profileComplete, isFalse);
    });

    test('POST /auth/refresh 200 → TokenPair', () {
      final r = TokenPair.fromJson(responseExample('/auth/refresh', 'post', '200'));
      expect(r.expiresIn, 900);
      expect(r.refreshToken, isNotNull);
    });
  });

  group('models write every required contract field', () {
    final example = <String, dynamic>{
      'id': '0192f8a0-0000-7000-8000-000000000001',
      'phone': '+255712345678',
      'displayName': 'Frank',
      'about': 'Available',
      'avatarUrl': null,
      'avatarThumbUrl': null,
      'profileComplete': true,
      'type': 'web',
      'name': 'Chrome on Windows',
      'createdAt': '2026-11-17T10:00:00.000Z',
      'lastActiveAt': '2026-11-17T10:00:00.000Z',
      'current': false,
    };

    test('Device', () {
      expect(Device.fromJson(example).toJson().keys, containsAll(requiredOf('Device')));
    });
    test('PublicUser', () {
      expect(PublicUser.fromJson(example).toJson().keys,
          containsAll(requiredOf('PublicUser')));
    });
    test('Me', () {
      expect(Me.fromJson(example).toJson().keys, containsAll(requiredOf('Me')));
    });
  });

  test('DeviceType matches the contract enum', () {
    expect(DeviceType.values.map((t) => t.toJson()).toSet(),
        (schema('DeviceType')['enum'] as List).toSet());
  });

  test('ApiErrorCode matches the contract Error.code enum exactly', () {
    final contract =
        (schema('Error')['properties']['code']['enum'] as List).cast<String>().toSet();
    expect(ApiErrorCode.contractCodes.map((c) => c.wire).toSet(), contract);
  });

  test('ApiError decodes an error body with Retry-After', () {
    final e = ApiError.fromJson(
      429,
      {'code': 'RATE_LIMITED', 'message': 'Slow down'},
      retryAfter: 42,
    );
    expect(e.code, ApiErrorCode.rateLimited);
    expect(e.retryAfter, 42);
    expect(ApiError.fromJson(500, {'code': 'SOMETHING_NEW'}).code,
        ApiErrorCode.unknown);
  });

  group('feature 002 models', () {
    const u1 = '0192f8a0-0000-7000-8000-000000000001';
    const u2 = '0192f8a0-0000-7000-8000-000000000002';
    final key = 'B${'A' * 43}';
    final sig = '${'A' * 86}==';
    final signed = {'keyId': 1, 'publicKey': key, 'signature': sig};

    Set<String> enumOf(String name) => (schema(name)['enum'] as List).cast<String>().toSet();

    test('enums match the contract', () {
      expect(ConversationType.values.map((t) => t.toJson()).toSet(),
          enumOf('ConversationType'));
      expect(MemberRole.values.map((t) => t.toJson()).toSet(), enumOf('MemberRole'));
      expect(EnvelopeType.values.map((t) => t.toJson()).toSet(), enumOf('EnvelopeType'));
    });

    test('key models write every required field', () {
      expect(SignedPreKey.fromJson(signed).toJson().keys,
          containsAll(requiredOf('SignedPreKey')));
      expect(PublicPreKey.fromJson({'keyId': 2, 'publicKey': key}).toJson().keys,
          containsAll(requiredOf('PublicPreKey')));
      final bundle = {
        'deviceId': u1,
        'registrationId': 42,
        'identityKey': key,
        'signedPreKey': signed,
        'preKey': null,
      };
      final b = DeviceBundle.fromJson(bundle);
      expect(b.preKey, isNull);
      expect(b.toJson().keys, containsAll(requiredOf('DeviceBundle')));
      final keys = UserKeys.fromJson({'userId': u2, 'devices': [bundle]});
      expect(keys.devices.single.registrationId, 42);
      expect(keys.toJson().keys, containsAll(requiredOf('UserKeys')));
    });

    test('UploadKeysBody writes required fields and omits signedPreKey when absent', () {
      final body = UploadKeysBody(
        registrationId: 7,
        identityKey: key,
        preKeys: [PublicPreKey(keyId: 1, publicKey: key)],
      ).toJson();
      expect(body.keys, containsAll(requiredOf('UploadKeysBody')));
      expect(body.containsKey('signedPreKey'), isFalse);
      final props = (schema('UploadKeysBody')['properties'] as Map).keys;
      expect(props, containsAll(body.keys));
    });

    test('Conversation round-trips', () {
      final json = {
        'id': u1,
        'type': 'group',
        'createdAt': '2026-11-19T10:00:00.000Z',
        'members': [
          {'userId': u2, 'role': 'admin', 'joinedAt': '2026-11-19T10:00:00.000Z'},
        ],
      };
      final c = Conversation.fromJson(json);
      expect(c.members.single.role, MemberRole.admin);
      expect(c.toJson(), json);
      expect(c.toJson().keys, containsAll(requiredOf('Conversation')));
      expect(c.members.single.toJson().keys,
          containsAll(requiredOf('ConversationMember')));
    });

    test('CreateConversationBody variants match the contract', () {
      final direct = const CreateConversationBody.direct(u2).toJson();
      final group = const CreateConversationBody.group([u1, u2]).toJson();
      expect(direct.keys.toSet(), requiredOf('CreateDirectConversationBody'));
      expect(group.keys.toSet(), requiredOf('CreateGroupConversationBody'));
    });

    test('send and receive models write every required field', () {
      final body = SendMessageBody(conversationId: u1, envelopes: [
        OutgoingEnvelope(deviceId: u2, type: EnvelopeType.prekey, ciphertext: 'AAAA'),
      ]).toJson();
      expect(body.keys, containsAll(requiredOf('SendMessageBody')));
      expect((body['envelopes'] as List).single.keys,
          containsAll(requiredOf('OutgoingEnvelope')));

      final env = Envelope.fromJson({
        'id': u1,
        'conversationId': u2,
        'senderUserId': u1,
        'senderDeviceId': u2,
        'type': 'whisper',
        'ciphertext': 'AAAA',
        'serverTimestamp': '2026-11-19T10:00:00.000Z',
      });
      expect(env.type, EnvelopeType.whisper);
      expect(env.toJson().keys, containsAll(requiredOf('Envelope')));
    });

    test('DeviceMismatch decodes from a 409 error body', () {
      final err = ApiError.fromJson(409, {
        'code': 'DEVICE_MISMATCH',
        'message': 'Device list changed',
        'details': {
          'missingDevices': [
            {'userId': u1, 'deviceId': u2},
          ],
          'staleDevices': <dynamic>[],
        },
      });
      expect(err.code, ApiErrorCode.deviceMismatch);
      final m = DeviceMismatch.fromJson(err.details!);
      expect(m.missingDevices.single, const DeviceRef(userId: u1, deviceId: u2));
      expect(m.toJson().keys, containsAll(requiredOf('DeviceMismatch')));
    });
  });

  group('realtime events', () {
    Map<String, dynamic> event(String name) =>
        ws[r'$defs']['server-to-client']['properties'][name] as Map<String, dynamic>;
    Map<String, dynamic> wsDef(String name) =>
        ws[r'$defs'][name] as Map<String, dynamic>;

    test('envelope:new matches Envelope in both contracts', () {
      final wsRequired = (wsDef('envelope')['required'] as List).cast<String>().toSet();
      expect(wsRequired, requiredOf('Envelope'));
      expect(event('envelope:new')[r'$ref'], r'#/$defs/envelope');
    });

    test('conversation:updated decodes both shapes', () {
      final full = ConversationUpdatedEvent.fromJson({
        'id': 'c1',
        'type': 'direct',
        'createdAt': '2026-11-19T10:00:00.000Z',
        'members': <dynamic>[],
      });
      expect(full.removed, isFalse);
      expect(full.conversation!.type, ConversationType.direct);
      final removed = ConversationUpdatedEvent.fromJson({'id': 'c1', 'removed': true});
      expect(removed.removed, isTrue);
      expect(removed.conversation, isNull);
    });

    test('typing states match in both directions', () {
      final inbound = (event('typing')['properties']['state']['enum'] as List).toSet();
      final outbound = (ws[r'$defs']['client-to-server']['properties']['typing']
              ['properties']['state']['enum'] as List)
          .toSet();
      expect(TypingState.values.map((s) => s.toJson()).toSet(), inbound);
      expect(outbound, inbound);
      final e = TypingEvent.fromJson(
          {'conversationId': 'c1', 'userId': 'u1', 'state': 'start'});
      expect(e.state, TypingState.start);
    });

    test('prekeys:low decodes', () {
      expect(event('prekeys:low')['required'], ['count']);
      expect(PrekeysLowEvent.fromJson({'count': 3}).count, 3);
    });

    test('device:revoked reasons match', () {
      final reasons =
          (event('device:revoked')['properties']['reason']['enum'] as List).toSet();
      expect(DeviceRevokedReason.values.map((r) => r.wire).toSet(), reasons);
      for (final r in reasons) {
        final e = DeviceRevokedEvent.fromJson({'deviceId': 'd1', 'reason': r});
        expect(e.reason.wire, r);
      }
    });

    test('profile:updated decodes with only its required fields', () {
      final required = (event('profile:updated')['required'] as List).cast<String>();
      final sample = {
        for (final k in required)
          k: switch (k) {
            'id' => 'u1',
            'about' => 'Hi',
            _ => null,
          },
      };
      final e = ProfileUpdatedEvent.fromJson(sample);
      expect(e.id, 'u1');
      expect(e.displayName, isNull);
      expect(e.avatarThumbUrl, isNull);
    });
  });
}
