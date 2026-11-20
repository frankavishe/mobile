import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/features/chat/payload.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

const aliceId = 'aaaaaaaa-0000-4000-8000-000000000001';
const bobId = 'bbbbbbbb-0000-4000-8000-000000000002';
const carolId = 'cccccccc-0000-4000-8000-000000000003';
const daveId = 'dddddddd-0000-4000-8000-000000000004';
const alicePhone = 'aaaaaaaa-1111-4000-8000-00000000000a';
const aliceTablet = 'aaaaaaaa-2222-4000-8000-00000000000b';
const bobPhone = 'bbbbbbbb-1111-4000-8000-00000000000c';
const carolPhone = 'cccccccc-1111-4000-8000-00000000000d';
const davePhone = 'dddddddd-1111-4000-8000-00000000000e';

PublicUser user(String id, String name, int n) => PublicUser(
      id: id,
      phone: '+25570000000$n',
      displayName: name,
      about: '',
      avatarUrl: null,
    );

final aliceUser = user(aliceId, 'Alice', 1);
final bobUser = user(bobId, 'Bob', 2);
final carolUser = user(carolId, 'Carol', 3);
final daveUser = user(daveId, 'Dave', 4);

void main() {
  late FakeServer server;
  late TestDevice alice;
  late TestDevice bob;
  late TestDevice carol;
  final extra = <TestDevice>[];

  setUp(() async {
    server = FakeServer();
    for (final u in [aliceUser, bobUser, carolUser, daveUser]) {
      server.profiles[u.id] = u;
    }
    alice = TestDevice(server, aliceId, alicePhone);
    bob = TestDevice(server, bobId, bobPhone);
    carol = TestDevice(server, carolId, carolPhone);
    for (final d in [alice, bob, carol]) {
      await d.boot();
    }
  });
  tearDown(() async {
    for (final d in [alice, bob, carol, ...extra]) {
      await d.close();
    }
    extra.clear();
  });

  Future<TestDevice> device(String userId, String deviceId) async {
    final d = TestDevice(server, userId, deviceId);
    extra.add(d);
    await d.boot();
    return d;
  }

  Future<LocalConversation?> conv(TestDevice d, String id) => d.db.conversationById(id);

  Future<List<String>> notes(TestDevice d, String id) async => [
        for (final m in await d.messages(id))
          if (m.kind == MessageKind.system) m.body!,
      ];

  Future<List<String>> texts(TestDevice d, String id) async => [
        for (final m in await d.messages(id))
          if (m.kind == MessageKind.text) m.body!,
      ];

  Future<MessageStatus> statusOn(TestDevice d, String cid, String id) async =>
      (await d.messages(cid)).firstWhere((m) => m.id == id).status;

  /// Alice's group with Bob and Carol, named "Trip" everywhere.
  Future<String> trip() async {
    final cid = await alice.service.createGroup('Trip', [bobUser, carolUser]);
    for (final d in [bob, carol]) {
      await eventually(() async => expect((await conv(d, cid))?.name, 'Trip'));
    }
    return cid;
  }

  test('a new group reaches every device with its encrypted name and fans out', () async {
    final tablet = await device(aliceId, aliceTablet);
    final cid = await trip();

    expect((await conv(alice, cid))!.kind, ConversationKind.group);
    expect(await notes(alice, cid), ["You created group 'Trip'"]);
    // Learning the first name is not a rename.
    expect(await notes(bob, cid), isEmpty);
    // Alice's other device gets the name from the sync copy.
    await eventually(() async => expect((await conv(tablet, cid))?.name, 'Trip'));
    // Bob learns Carol's name from GET /users although she isn't his contact.
    await eventually(() async => expect((await bob.db.cachedUser(carolId))?.displayName, 'Carol'));

    final before = server.sent.length;
    final id = await alice.service.sendText(cid, 'hello all');
    await alice.service.flush();
    final batch = server.sent[before];
    expect({for (final e in batch.envelopes) e.deviceId}, {bobPhone, carolPhone, aliceTablet});
    for (final d in [bob, carol, tablet]) {
      await eventually(() async => expect(await texts(d, cid), ['hello all']));
    }
    // The group_update was encrypted like any message: the server saw no name.
    expect(server.sent.first.envelopes.every((e) => !e.ciphertext.contains('Trip')), isTrue);
    expect((await bob.messages(cid)).last.senderUserId, aliceId);
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.delivered));
  });

  test('ticks move only when every member has delivered, then read', () async {
    final cid = await trip();
    carol.goOffline();
    final id = await alice.service.sendText(cid, 'are you there?');

    await eventually(() async => expect(await texts(bob, cid), ['are you there?']));
    await eventually(() async {
      final receipts = await alice.db.receiptsFor(id);
      expect(receipts.map((r) => (r.userId, r.status)), [(bobId, MessageStatus.delivered)]);
    });
    expect(await statusOn(alice, cid, id), MessageStatus.sent);

    carol.goOnline();
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.delivered));

    await bob.service.openConversation(cid);
    await eventually(() async {
      final r = await alice.db.receiptsFor(id);
      expect(r.firstWhere((x) => x.userId == bobId).status, MessageStatus.read);
    });
    expect(await statusOn(alice, cid, id), MessageStatus.delivered);

    await carol.service.openConversation(cid);
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.read));
  });

  test('an admin rename reaches everyone; a member rename is ignored', () async {
    final cid = await trip();
    alice.clock = alice.clock.add(const Duration(minutes: 1));
    await alice.service.renameGroup(cid, 'Trip 2026');
    await eventually(() async => expect((await conv(bob, cid))?.name, 'Trip 2026'));
    expect(await notes(bob, cid), ["Alice changed the group name to 'Trip 2026'"]);
    expect(await notes(alice, cid), ["You created group 'Trip'", "You changed the group name to 'Trip 2026'"]);

    bob.clock = bob.clock.add(const Duration(minutes: 2));
    await bob.service.renameGroup(cid, 'Bob rules');
    await bob.service.flush();
    // Carol decrypted it (no envelopes left) but Bob isn't an admin.
    await eventually(() async => expect(server.queues[carolPhone], isEmpty));
    expect((await conv(carol, cid))?.name, 'Trip 2026');
  });

  test('an added member gets the name and later messages; others see a note', () async {
    final cid = await trip();
    final dave = await device(daveId, davePhone);

    await alice.service.addMembers(cid, [daveUser]);
    await eventually(() async => expect((await conv(dave, cid))?.name, 'Trip'));
    await eventually(() async => expect(await notes(bob, cid), ['Dave joined']));
    expect(await notes(alice, cid), ["You created group 'Trip'", 'Dave joined']);

    await bob.service.sendText(cid, 'welcome dave');
    await eventually(() async => expect(await texts(dave, cid), ['welcome dave']));
  });

  test('a removed member keeps the history read-only and stops receiving', () async {
    final cid = await trip();
    await alice.service.sendText(cid, 'before');
    await eventually(() async => expect(await texts(carol, cid), ['before']));

    await alice.service.removeMember(cid, carolId);
    await eventually(() async => expect((await conv(carol, cid))?.active, isFalse));
    expect(await notes(carol, cid), ['You were removed']);
    expect(await texts(carol, cid), ['before']);
    await eventually(() async => expect(await notes(bob, cid), ['Carol left']));

    await alice.service.flush();
    final before = server.sent.length;
    await alice.service.sendText(cid, 'after');
    await alice.service.flush();
    expect(server.sent[before].envelopes.map((e) => e.deviceId), [bobPhone]);
    await eventually(() async => expect(await texts(bob, cid), ['before', 'after']));
    expect(await texts(carol, cid), ['before']);

    // Carol can't send any more.
    final id = await carol.service.sendText(cid, 'hello?');
    await carol.service.flush();
    expect(await statusOn(carol, cid, id), MessageStatus.failed);
  });

  test('leaving adds one note here and a "left" note for the others', () async {
    final cid = await trip();
    final id = await alice.service.sendText(cid, 'hi');
    await eventually(() async => expect(await texts(bob, cid), ['hi']));
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.delivered));

    // Carol never reads it; once she leaves, Bob's read is enough.
    await bob.service.openConversation(cid);
    await eventually(() async {
      final r = await alice.db.receiptsFor(id);
      expect(r.firstWhere((x) => x.userId == bobId).status, MessageStatus.read);
    });
    await carol.service.leaveGroup(cid);
    // The server's own `removed` event must not add a second note.
    await eventually(() async => expect(await notes(alice, cid), contains('Carol left')));
    expect(await notes(carol, cid), ['You left']);
    expect((await conv(carol, cid))!.active, isFalse);
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.read));
  });

  test('a removal while offline is noticed on the next sync', () async {
    final cid = await trip();
    carol.goOffline();
    await alice.service.removeMember(cid, carolId);
    expect((await conv(carol, cid))!.active, isTrue);

    carol.goOnline();
    await eventually(() async => expect((await conv(carol, cid))?.active, isFalse));
    expect(await notes(carol, cid), ['You were removed']);
  });

  test('group_update payload round-trips', () {
    final p = Payload.groupUpdate(
      messageId: 'm',
      conversationId: 'c',
      sentAt: DateTime.utc(2026, 11, 20),
      groupName: 'Trip',
      groupMemberIds: const ['a', 'b'],
    );
    final json = p.toJson();
    expect(json['kind'], 'group_update');
    expect(json['group'], {'name': 'Trip', 'memberIds': ['a', 'b']});
    final back = Payload.tryParse(p.encode())!;
    expect(back.kind, PayloadKind.groupUpdate);
    expect(back.groupName, 'Trip');
    expect(back.groupMemberIds, ['a', 'b']);
    // A group_update without a name is dropped.
    expect(
      Payload.tryParse('{"v":1,"kind":"group_update","messageId":"m","conversationId":"c",'
          '"sentAt":"2026-11-20T00:00:00Z","group":{"memberIds":[]}}'),
      isNull,
    );
  });
}
