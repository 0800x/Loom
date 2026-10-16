part of 'messenger_shell.dart';

Future<void> _searchSettings(
  BuildContext context,
  List<(IconData, String, String?)> entries,
) async {
  final route = await showSearch<String>(
    context: context,
    delegate: _SettingsSearchDelegate(
      entries,
      tr(context, 'Search settings', 'جستجوی تنظیمات'),
    ),
  );
  if (!context.mounted || route == null || route.isEmpty) return;
  await Navigator.pushNamed(context, route);
}

class _SettingsSearchDelegate extends SearchDelegate<String> {
  _SettingsSearchDelegate(this.entries, String label)
    : super(searchFieldLabel: label);

  final List<(IconData, String, String?)> entries;

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        tooltip: tr(context, 'Clear search', 'پاک کردن جستجو'),
        icon: const Icon(LoomIcons.close_rounded),
        onPressed: () => query = '',
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    icon: const Icon(LoomIcons.arrow_back_rounded),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final matches = entries
        .where(
          (entry) =>
              entry.$3 != null && entry.$2.toLowerCase().contains(needle),
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      return Center(
        child: Text(tr(context, 'No matching settings', 'تنظیمی پیدا نشد')),
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final entry = matches[index];
        return ListTile(
          leading: Icon(entry.$1),
          title: Text(entry.$2),
          onTap: () => close(context, entry.$3!),
        );
      },
    );
  }
}
