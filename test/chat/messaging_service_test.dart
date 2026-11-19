import 'package:chat_app/core/api/models/models.dart';
import 'package:chat_app/core/db/app_database.dart';
import 'package:chat_app/features/chat/payload.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

const aliceId = 'aaaaaaaa-0000-4000-8000-000000000001';
const bobId = 'bbbbbbbb-0000-4000-8000-000000000002';
const alicePhone = 'aaaaaaaa-1111-4000-8000-00000000000a';
const aliceTablet = 'aaaaaaaa-2222-4000-8000-00000000000b';
const bobPhone = 'bbbbbbbb-1111-4000-8000-00000000000c';

const bobUser = PublicUser(
  id: bobId,
  phone: '+255700000002',
  displayName: 'Bob',
  about: '',
  avatarUrl: null,
);

void main() {
  late FakeServer server;
  late TestDevice alice;
  late TestDevice bob;
  final extra = <TestDevice>[];

  setUp(() async {
    server = FakeServer();
    alice = TestDevice(server, aliceId, alicePhone);
    bob = TestDevice(server, bobId, bobPhone);
    await alice.boot();
    await bob.boot();
  });
  tearDown(() async {
    await alice.close();
    await bob.close();
    for (final d in extra) {
      await d.close();
    }
    extra.clear();
  });

  Future<MessageStatus> statusOn(TestDevice d, String conversationId, String id) async =>
      (await d.messages(conversationId)).firstWhere((m) => m.id == id).status;

  test('first message starts a session, the reply goes back, ticks reach read', () async {
    final cid = await alice.service.startDirect(bobUser);
    final m1 = await alice.service.sendText(cid, 'hi bob');

    await eventually(() async {
      final got = await bob.messages(cid);
      expect(got.map((m) => m.body), ['hi bob']);
      expect(got.single.senderUserId, aliceId);
      expect(got.single.status, MessageStatus.delivered);
    });
    // Bob's device sent `delivered` back.
    await eventually(() async => expect(await statusOn(alice, cid, m1), MessageStatus.delivered));
    // The first envelope was a prekey message; Bob's chat is unread.
    expect(server.sent.first.envelopes.single.type, EnvelopeType.prekey);
    expect((await bob.db.conversationById(cid))!.unreadCount, 1);

    await bob.service.openConversation(cid);
    await eventually(() async => expect(await statusOn(alice, cid, m1), MessageStatus.read));
    expect((await bob.db.conversationById(cid))!.unreadCount, 0);

    final reply = await bob.service.sendText(cid, 'hi alice');
    await eventually(() async {
      expect((await alice.messages(cid)).map((m) => m.body), ['hi bob', 'hi alice']);
    });
    await eventually(
        () async => expect(await statusOn(bob, cid, reply), MessageStatus.delivered));
    // Every envelope reached its device and was acked.
    await eventually(() => expect(server.queues.values.expand((q) => q), isEmpty));
  });

  test('messages for an open conversation are read at once', () async {
    final cid = await alice.service.startDirect(bobUser);
    await bob.service.sync(); // Bob learns the conversation.
    await bob.service.openConversation(cid);

    final id = await alice.service.sendText(cid, 'seen?');
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.read));
    expect((await bob.db.conversationById(cid))!.unreadCount, 0);
  });

  test("a new device of the peer is found through 409 and gets the next message", () async {
    final cid = await alice.service.startDirect(bobUser);
    await alice.service.sendText(cid, 'one');
    await eventually(() async => expect(await bob.messages(cid), hasLength(1)));

    final bobTablet = TestDevice(server, bobId, 'bbbbbbbb-3333-4000-8000-00000000000d');
    extra.add(bobTablet);
    await bobTablet.boot();

    await alice.service.sendText(cid, 'two');
    await eventually(() async {
      expect((await bobTablet.messages(cid)).map((m) => m.body), ['two']);
      expect((await bob.messages(cid)).map((m) => m.body), ['one', 'two']);
    });
    // Alice's second batch covered both of Bob's devices.
    expect(
      server.sent.map((b) => b.envelopes.map((e) => e.deviceId).toSet()),
      contains(equals({bobPhone, bobTablet.deviceId})),
    );
  });

  test('a revoked device is dropped after 409 and no longer receives', () async {
    final bobTablet = TestDevice(server, bobId, 'bbbbbbbb-4444-4000-8000-00000000000e');
    extra.add(bobTablet);
    await bobTablet.boot();
    final cid = await alice.service.startDirect(bobUser);
    await alice.service.sendText(cid, 'to both');
    await eventually(() async => expect(await bobTablet.messages(cid), hasLength(1)));

    server.revoke(bobTablet.deviceId);
    await alice.service.sendText(cid, 'phone only');
    await eventually(() async => expect(await bob.messages(cid), hasLength(2)));
    expect(await alice.db.devicesOf(bobId), [bobPhone]);
    expect(await bobTablet.messages(cid), hasLength(1));
  });

  test("own other devices get sync copies and follow the read state", () async {
    final tablet = TestDevice(server, aliceId, aliceTablet);
    extra.add(tablet);
    await tablet.boot();

    final cid = await alice.service.startDirect(bobUser);
    final id = await alice.service.sendText(cid, 'from my phone');
    await eventually(() async {
      final copy = (await tablet.messages(cid)).single;
      expect(copy.id, id);
      expect(copy.senderUserId, aliceId);
      expect(copy.body, 'from my phone');
    });
    // Bob's receipts reach the tablet too.
    await eventually(() async => expect(await statusOn(tablet, cid, id), MessageStatus.delivered));
    expect((await tablet.db.conversationById(cid))!.unreadCount, 0);

    // Bob replies; reading it on the phone clears it on the tablet.
    final reply = await bob.service.sendText(cid, 'hey');
    await eventually(() async {
      expect((await tablet.db.conversationById(cid))!.unreadCount, 1);
      expect(await alice.messages(cid), hasLength(2));
    });
    await alice.service.openConversation(cid);
    await eventually(() async {
      expect((await tablet.db.conversationById(cid))!.unreadCount, 0);
      expect(await statusOn(tablet, cid, reply), MessageStatus.read);
    });
  });

  test('sending offline stays pending and goes out on reconnect', () async {
    final cid = await alice.service.startDirect(bobUser);
    alice.goOffline();
    final id = await alice.service.sendText(cid, 'later');
    await alice.service.flush();
    expect(await statusOn(alice, cid, id), MessageStatus.pending);
    expect((await alice.db.dueOutbox(alice.clock.add(const Duration(hours: 1)))).single.attempts,
        1);

    alice.goOnline();
    await eventually(() async => expect((await bob.messages(cid)).single.body, 'later'));
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.delivered));
  });

  test('a device that was offline fetches its envelopes on reconnect', () async {
    final cid = await alice.service.startDirect(bobUser);
    bob.goOffline();
    await alice.service.sendText(cid, 'one');
    await alice.service.sendText(cid, 'two');
    await alice.service.flush();
    expect(server.queues[bobPhone], hasLength(2));

    bob.goOnline();
    await eventually(
        () async => expect((await bob.messages(cid)).map((m) => m.body), ['one', 'two']));
    await eventually(() => expect(server.queues[bobPhone], isEmpty));
  });

  test('a duplicate envelope is ignored and acked', () async {
    final cid = await alice.service.startDirect(bobUser);
    bob.goOffline(); // No push: the envelope stays queued.
    await alice.service.sendText(cid, 'once');
    await alice.service.flush();
    final env = server.queues[bobPhone]!.single;

    bob.goOnline();
    await eventually(() async => expect(await bob.messages(cid), hasLength(1)));
    // The same envelope arrives again (e.g. the ack was lost).
    server.queues[bobPhone]!.add(env);
    bob.socket.envelopes.add(env);
    await eventually(() => expect(server.queues[bobPhone], isEmpty));
    expect(await bob.messages(cid), hasLength(1));
  });

  test('an envelope that cannot be decrypted is acked and shown as such', () async {
    final cid = await alice.service.startDirect(bobUser);
    await bob.service.sync();
    final bogus = Envelope(
      id: 'e-bogus',
      conversationId: cid,
      senderUserId: aliceId,
      senderDeviceId: alicePhone,
      type: EnvelopeType.whisper,
      ciphertext: 'AAAA',
      serverTimestamp: DateTime.utc(2026, 11, 19),
    );
    server.queues[bobPhone] = [bogus];
    bob.socket.envelopes.add(bogus);

    await eventually(() async {
      final m = (await bob.messages(cid)).single;
      expect(m.kind, MessageKind.system);
    });
    await eventually(() => expect(server.queues[bobPhone], isEmpty));
  });

  test('typing: start is throttled, stop follows clear and send; incoming is tracked', () async {
    final cid = await alice.service.startDirect(bobUser);
    alice.service.composerChanged(cid, 'h');
    alice.service.composerChanged(cid, 'he');
    alice.clock = alice.clock.add(const Duration(seconds: 3));
    alice.service.composerChanged(cid, 'hel');
    alice.service.composerChanged(cid, '');
    expect(alice.socket.typingSent, [
      (cid, TypingState.start),
      (cid, TypingState.start),
      (cid, TypingState.stop),
    ]);

    alice.service.composerChanged(cid, 'x');
    await alice.service.sendText(cid, 'x');
    expect(alice.socket.typingSent.last, (cid, TypingState.stop));

    final states = <Set<String>>[];
    final sub = bob.service.typingUsers(cid).listen(states.add);
    bob.socket.typingIn.add(TypingEvent(conversationId: cid, userId: aliceId, state: TypingState.start));
    await eventually(() => expect(states.last, {aliceId}));
    bob.socket.typingIn.add(TypingEvent(conversationId: cid, userId: aliceId, state: TypingState.stop));
    await eventually(() => expect(states.last, isEmpty));
    await sub.cancel();
  });

  test('a send that cannot succeed is marked failed and can be retried', () async {
    final cid = await alice.service.startDirect(bobUser);
    final saved = server.conversations.remove(cid)!; // The server answers 404.

    final id = await alice.service.sendText(cid, 'lost');
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.failed));

    server.conversations[cid] = saved;
    await alice.service.retry(id);
    await eventually(() async => expect(await statusOn(alice, cid, id), MessageStatus.delivered));
  });

  test('payload round-trips and unknown kinds are dropped', () {
    final p = Payload.receipt(
      messageId: 'm',
      conversationId: 'c',
      sentAt: DateTime.utc(2026),
      receiptType: ReceiptType.read,
      receiptIds: const ['a', 'b'],
    );
    final back = Payload.tryParse(p.encode())!;
    expect(back.kind, PayloadKind.receipt);
    expect(back.receiptType, ReceiptType.read);
    expect(back.receiptIds, ['a', 'b']);
    expect(Payload.tryParse('{"v":1,"kind":"group_update","messageId":"m"}'), isNull);
    expect(Payload.tryParse('{"v":2,"kind":"text"}'), isNull);
    expect(Payload.tryParse('not json'), isNull);
  });
}
