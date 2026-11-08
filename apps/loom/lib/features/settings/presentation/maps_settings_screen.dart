import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../messaging/application/map_tile_preferences.dart';
import '../../nodes/application/node_directory_controller.dart';
import '../../../app/loom_strings.dart';

/// Runtime tile-source selection for in-chat maps, following the appearance
/// panel structure: framed preview, grouped cards, segmented selection and
/// inline per-provider configuration.
class LoomMapsSettingsScreen extends StatefulWidget {
  const LoomMapsSettingsScreen({super.key});

  @override
  State<LoomMapsSettingsScreen> createState() => _LoomMapsSettingsScreenState();
}

class _LoomMapsSettingsScreenState extends State<LoomMapsSettingsScreen> {
  late final TextEditingController _custom;
  late final TextEditingController _server;
  late final TextEditingController _cartoKey;

  @override
  void initState() {
    super.initState();
    final preferences = LoomMapTilePreferences.instance;
    _custom = TextEditingController(text: preferences.customTemplate);
    _server = TextEditingController(text: preferences.serverTemplate);
    _cartoKey = TextEditingController(text: preferences.cartoApiKey);
  }

  @override
  void dispose() {
    _custom.dispose();
    _server.dispose();
    _cartoKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: LoomGlassAppBar(
      title: Text(tr(context, 'Maps', 'نقشه‌ها')),
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ListenableBuilder(
        listenable: LoomMapTilePreferences.instance,
        builder: (context, _) {
          final preferences = LoomMapTilePreferences.instance;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _section(
                context,
                title: tr(context, 'Basemap source', 'منبع نقشه'),
                detail: tr(
                  context,
                  'Choose where map tiles are loaded from. Location previews and the map viewer follow this setting immediately.',
                  'انتخاب کنید تایل‌های نقشه از کجا بارگیری شوند. پیش‌نمایش موقعیت و نمایشگر نقشه بلافاصله از این تنظیم پیروی می‌کنند.',
                ),
                child: LoomSettingsGroup(
                  children: [
                    for (final provider in LoomMapTileProvider.values)
                      _providerRow(context, preferences, provider),
                  ],
                ),
              ),
              if (preferences.provider == LoomMapTileProvider.custom) ...[
                const SizedBox(height: LoomSpacing.lg),
                _section(
                  context,
                  title: tr(context, 'Custom template', 'قالب سفارشی'),
                  detail: tr(
                    context,
                    'Any XYZ raster tile URL with {z} {x} {y} placeholders, e.g. https://tiles.example.org/{z}/{x}/{y}.png',
                    'هر آدرس تایل XYZ با جای‌نگذار‌های {z} {x} {y}، مثلاً https://tiles.example.org/{z}/{x}/{y}.png',
                  ),
                  child: LoomSettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          LoomSpacing.md,
                          LoomSpacing.sm,
                          LoomSpacing.md,
                          LoomSpacing.sm,
                        ),
                        child: TextField(
                          controller: _custom,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          onChanged: preferences.updateCustomTemplate,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'https://…/{z}/{x}/{y}.png',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (preferences.provider == LoomMapTileProvider.server) ...[
                const SizedBox(height: LoomSpacing.lg),
                _section(
                  context,
                  title: tr(context, 'Home Node tiles', 'تایل‌های سرور من'),
                  detail: tr(
                    context,
                    'Serve tiles from your own node’s cache (set it up in the node’s admin panel).',
                    'تایل‌ها از کش سرور خودت سرو می‌شوند (راه‌اندازی در پنل مدیریت سرور).',
                  ),
                  child: LoomSettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          LoomSpacing.md,
                          LoomSpacing.sm,
                          LoomSpacing.md,
                          LoomSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _server,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                onChanged: preferences.updateServerTemplate,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText:
                                      'https://node.example.org/tiles/{z}/{x}/{y}.png',
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                            const SizedBox(width: LoomSpacing.sm),
                            IconButton(
                              tooltip: tr(
                                context,
                                'Fill from current node',
                                'پر کردن از سرور فعلی',
                              ),
                              onPressed: () => _fillFromNode(context),
                              icon: const Icon(LoomIcons.sync_rounded),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (preferences.provider == LoomMapTileProvider.carto) ...[
                const SizedBox(height: LoomSpacing.lg),
                _section(
                  context,
                  title: tr(context, 'CARTO basemap key', 'کلید CARTO'),
                  detail: tr(
                    context,
                    'Optional. CARTO basemaps (with a true dark variant) require an operator key.',
                    'اختیاری. نقشه‌های CARTO (با تم تاریک واقعی) به کلید نیاز دارند.',
                  ),
                  child: LoomSettingsGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          LoomSpacing.md,
                          LoomSpacing.sm,
                          LoomSpacing.md,
                          LoomSpacing.sm,
                        ),
                        child: TextField(
                          controller: _cartoKey,
                          autocorrect: false,
                          onChanged: preferences.updateCartoApiKey,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'public basemap key',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: LoomSpacing.lg),
              _section(
                context,
                title: tr(context, 'About providers', 'دربارهٔ ارائه‌دهنده‌ها'),
                child: LoomSettingsGroup(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(LoomSpacing.md),
                      child: Text(
                        tr(
                          context,
                          'OpenStreetMap and Snapp Maps need no key. Your Home Node can cache tiles for your country in advance — see the node admin panel. Google’s terms do not allow caching or redistributing their tiles, so Google is not offered as a direct source.',
                          'OpenStreetMap و اسنپ‌مپ کلید نمی‌خواهند. سرور شما می‌تواند تایل‌های کشورتان را از قبل کش کند — پنل مدیریت سرور را ببینید. شرایط استفادهٔ گوگل کش یا بازنشر تایل‌هایش را اجازه نمی‌دهد، بنابراین گوگل به‌عنوان منبع مستقیم ارائه نمی‌شود.',
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.loom.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _providerRow(
    BuildContext context,
    LoomMapTilePreferences preferences,
    LoomMapTileProvider provider,
  ) {
    final selected = preferences.provider == provider;
    final (label, detail, icon) = switch (provider) {
      LoomMapTileProvider.osm => (
        tr(context, 'OpenStreetMap', 'اوپن‌استریت‌مپ'),
        tr(context, 'Default · no key', 'پیش‌فرض · بدون کلید'),
        LoomIcons.http_rounded,
      ),
      LoomMapTileProvider.snappmaps => (
        tr(context, 'Snapp Maps', 'اسنپ‌مپ'),
        tr(context, 'Persian labels · no key', 'برچسب فارسی · بدون کلید'),
        LoomIcons.map_outlined,
      ),
      LoomMapTileProvider.carto => (
        tr(context, 'CARTO', 'کارتو'),
        tr(context, 'Voyager style · dark variant', 'استایل Voyager · تم تاریک'),
        LoomIcons.copy_outlined,
      ),
      LoomMapTileProvider.server => (
        tr(context, 'My Home Node', 'سرور خودم'),
        tr(context, 'Cached on your node', 'کش‌شده روی سرور شما'),
        LoomIcons.dns_outlined,
      ),
      LoomMapTileProvider.custom => (
        tr(context, 'Custom URL', 'آدرس سفارشی'),
        tr(context, 'Any XYZ tile template', 'هر قالب تایل XYZ'),
        LoomIcons.link,
      ),
    };
    return LoomSettingsRow(
      icon: icon,
      title: label,
      subtitle: detail,
      showDivider: provider != LoomMapTileProvider.values.last,
      trailing: selected
          ? Icon(
              LoomIcons.check,
              size: 20,
              color: context.loom.primary,
            )
          : null,
      onTap: () => preferences.select(provider),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required Widget child,
    String? detail,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(
          left: LoomSpacing.sm,
          right: LoomSpacing.sm,
          bottom: LoomSpacing.sm,
        ),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(
            left: LoomSpacing.sm,
            right: LoomSpacing.sm,
            bottom: LoomSpacing.sm,
          ),
          child: Text(
            detail,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.loom.textSecondary,
            ),
          ),
        ),
      child,
    ],
  );

  void _fillFromNode(BuildContext context) {
    LoomNodeDirectoryController? directory;
    try {
      directory = LoomNodeDirectoryScope.of(context);
    } catch (_) {
      directory = null;
    }
    final endpoint = directory?.selectedEndpoint;
    if (endpoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              context,
              'No Home Node selected yet',
              'هنوز سروری انتخاب نشده است',
            ),
          ),
        ),
      );
      return;
    }
    final base = endpoint.replace(
      path: '',
      query: '',
      fragment: '',
    );
    _server.text = '${base.toString()}/tiles/{z}/{x}/{y}.png';
    LoomMapTilePreferences.instance.updateServerTemplate(_server.text);
  }
}
