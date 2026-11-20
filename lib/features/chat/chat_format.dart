import 'package:flutter/material.dart';

import '../../core/db/app_database.dart';
import '../../core/phone.dart';

/// Title of a chat: the peer's name, else their number, else the group name.
String chatTitle(LocalConversation c, CachedUser? peer) {
  final name = peer?.displayName;
  if (name != null && name.isNotEmpty) return name;
  final phone = peer?.phone;
  if (phone != null && phone.isNotEmpty) return formatPhone(phone);
  final group = c.name;
  if (group != null && group.isNotEmpty) return group;
  return c.kind == ConversationKind.group ? 'Group' : 'Unknown';
}

/// A user's name for lists and notes: the display name, else the number, else "Unknown".
String userLabel(CachedUser? u) {
  final name = u?.displayName;
  if (name != null && name.isNotEmpty) return name;
  final phone = u?.phone;
  if (phone != null && phone.isNotEmpty) return formatPhone(phone);
  return 'Unknown';
}

/// Longest group name accepted by the app (it travels encrypted; the server never checks).
const groupNameMax = 50;

/// A stable color per user for sender names in group bubbles.
Color senderColor(String userId, ColorScheme scheme) {
  const hues = [8.0, 32.0, 140.0, 175.0, 205.0, 230.0, 275.0, 310.0, 340.0];
  final hue = hues[userId.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) % hues.length];
  final dark = scheme.brightness == Brightness.dark;
  return HSLColor.fromAHSL(1, hue, 0.6, dark ? 0.72 : 0.38).toColor();
}

/// The round icon used for groups (groups have no picture).
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, this.radius = 24});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: Icon(Icons.group, size: radius),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String clockTime(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// Chat list time: `14:05` today, `Yesterday`, a weekday within a week, else `19/11/26`.
String listTime(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final today = _day(now ?? DateTime.now());
  final days = today.difference(_day(l)).inDays;
  if (days <= 0) return clockTime(l);
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[l.weekday - 1];
  return '${_two(l.day)}/${_two(l.month)}/${_two(l.year % 100)}';
}

/// Separator above the first message of a day: `Today`, `Yesterday`, or `19/11/2026`.
String dayLabel(DateTime t, {DateTime? now}) {
  final l = t.toLocal();
  final days = _day(now ?? DateTime.now()).difference(_day(l)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[l.weekday - 1];
  return '${_two(l.day)}/${_two(l.month)}/${l.year}';
}

bool sameDay(DateTime a, DateTime b) => _day(a.toLocal()) == _day(b.toLocal());

/// Delivery ticks for an outgoing message: clock, ✓, ✓✓, blue ✓✓, or a red mark for failed.
class MessageTicks extends StatelessWidget {
  const MessageTicks({super.key, required this.status, this.size = 16});

  final MessageStatus status;
  final double size;

  /// The blue of read ticks.
  static const readColor = Color(0xFF34B7F1);

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final (icon, color, label) = switch (status) {
      MessageStatus.pending => (Icons.schedule, muted, 'Sending'),
      MessageStatus.sent => (Icons.check, muted, 'Sent'),
      MessageStatus.delivered => (Icons.done_all, muted, 'Delivered'),
      MessageStatus.read => (Icons.done_all, readColor, 'Read'),
      MessageStatus.failed =>
        (Icons.error_outline, Theme.of(context).colorScheme.error, 'Not sent'),
    };
    return Icon(
      icon,
      key: Key('tick-${status.name}'),
      size: size,
      color: color,
      semanticLabel: label,
    );
  }
}
