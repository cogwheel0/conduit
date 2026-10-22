import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';

class HermesCapabilityPicker extends StatefulWidget {
  const HermesCapabilityPicker({
    super.key,
    required this.title,
    required this.entries,
    this.requireSelection = false,
  });
  final bool requireSelection;
  final String title;
  final List<Map<String, dynamic>> entries;
  @override
  State<HermesCapabilityPicker> createState() => _HermesCapabilityPickerState();
}

class _HermesCapabilityPickerState extends State<HermesCapabilityPicker> {
  late final _selected = {
    for (final row in widget.entries)
      if (row['enabled'] != false) row['name'].toString(),
  };
  String _query = '';
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          onChanged: (v) => setState(() => _query = v.toLowerCase()),
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.messagesSearch,
          ),
        ),
        Flexible(
          child: widget.entries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Nothing configured for this bot.'),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final row in widget.entries.where(
                      (r) =>
                          r['name'].toString().toLowerCase().contains(_query),
                    ))
                      CheckboxListTile(
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: Text((row['label'] ?? row['name']).toString()),
                        value: _selected.contains(row['name']),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(row['name'].toString());
                          } else {
                            _selected.remove(row['name']);
                          }
                        }),
                      ),
                  ],
                ),
        ),
        if (widget.requireSelection && _selected.isEmpty)
          Text(AppLocalizations.of(context)!.messagesChooseTools),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(AppLocalizations.of(context)!.cancel),
            ),
            FilledButton(
              onPressed: widget.requireSelection && _selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_selected),
              child: Text(AppLocalizations.of(context)!.save),
            ),
          ],
        ),
      ],
    ),
  );
}
