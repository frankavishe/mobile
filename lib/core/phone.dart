import 'package:flutter/widgets.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

const _fallbackCountry = IsoCode.TZ;

/// Country from the device locale (e.g. `sw_TZ`), else Tanzania (same rule as the web app).
IsoCode defaultCountry([String? region]) {
  final code = (region ?? WidgetsBinding.instance.platformDispatcher.locale.countryCode)?.toUpperCase();
  return IsoCode.values.asNameMap()[code] ?? _fallbackCountry;
}

/// `+255` for [IsoCode.TZ].
String dialCode(IsoCode iso) => '+${PhoneNumber(isoCode: iso, nsn: '').countryCode}';

/// Regional indicator flag, e.g. 🇹🇿.
String flagOf(IsoCode iso) => String.fromCharCodes(
      iso.name.codeUnits.map((c) => 0x1F1E6 + c - 0x41),
    );

/// The E.164 form of [national] in [country], or null when it is not a valid number.
String? toE164(IsoCode country, String national) {
  final digits = national.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  try {
    final n = PhoneNumber.parse(digits, destinationCountry: country);
    return n.isoCode == country && n.isValid() ? n.international : null;
  } catch (_) {
    return null;
  }
}

/// `+255 712 345 678` for display.
String formatPhone(String e164) {
  try {
    final n = PhoneNumber.parse(e164);
    return '+${n.countryCode} ${n.formatNsn()}';
  } catch (_) {
    return e164;
  }
}
