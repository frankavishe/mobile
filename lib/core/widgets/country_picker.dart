import 'package:flutter/material.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../phone.dart';

/// Bottom sheet listing every country with its dial code; returns the one picked.
Future<IsoCode?> showCountryPicker(BuildContext context) => showModalBottomSheet<IsoCode>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _CountrySheet(),
    );

class _CountrySheet extends StatefulWidget {
  const _CountrySheet();

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  static final _all = [
    for (final iso in IsoCode.values) (iso: iso, dial: dialCode(iso)),
  ]..sort((a, b) => a.iso.name.compareTo(b.iso.name));

  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toUpperCase().replaceAll('+', '');
    final items = q.isEmpty
        ? _all
        : _all
            .where((c) => c.iso.name.contains(q) || c.dial.substring(1).startsWith(q))
            .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Country code (TZ) or dial code (255)',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final c = items[i];
                return ListTile(
                  leading: Text(flagOf(c.iso), style: const TextStyle(fontSize: 24)),
                  title: Text(c.iso.name),
                  trailing: Text(c.dial),
                  onTap: () => Navigator.pop(context, c.iso),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
