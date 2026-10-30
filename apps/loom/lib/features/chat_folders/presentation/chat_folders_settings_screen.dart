import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../application/chat_folder_controller.dart';
import 'chat_folder_labels.dart';

class LoomChatFoldersSettingsScreen extends StatefulWidget {
  const LoomChatFoldersSettingsScreen({super.key});

  @override
  State<LoomChatFoldersSettingsScreen> createState() =>
      _LoomChatFoldersSettingsScreenState();
}

class _LoomChatFoldersSettingsScreenState
    extends State<LoomChatFoldersSettingsScreen> {
  bool _opened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(LoomChatFoldersScope.of(context).open());
    });
  }

  @override
  Widget build(BuildContext context) {
    final folders = LoomChatFoldersScope.of(context);
    return AnimatedBuilder(
      animation: folders,
      builder: (context, _) {
        final activeFolders = folders.folders
            .where((folder) => !folder.locked)
            .toList(growable: false);
        return Scaffold(
          appBar: LoomGlassAppBar(
            title: Text(tr(context, 'Chat Folders', 'پوشه‌های گفتگو')),
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  LoomSpacing.md,
                  LoomSpacing.sm,
                  LoomSpacing.md,
                  LoomSpacing.xl,
                ),
                children: [
                  _IntroCard(),
                  if (folders.errorMessage != null) ...[
                    const SizedBox(height: LoomSpacing.sm),
                    _ErrorNotice(message: folders.errorMessage!),
                  ],
                  if (folders.recommendations.isNotEmpty) ...[
                    const SizedBox(height: LoomSpacing.lg),
                    _SectionTitle(
                      tr(context, 'Recommended Folders', 'پوشه‌های پیشنهادی'),
                    ),
                    const SizedBox(height: LoomSpacing.xs),
                    LoomSettingsCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < folders.recommendations.length;
                            index++
                          )
                            _RecommendationRow(
                              folder: folders.recommendations[index],
                              showDivider:
                                  index != folders.recommendations.length - 1,
                              onAdd: folders.folders.length >= 10
                                  ? null
                                  : () => unawaited(
                                      folders.addPreset(
                                        folders.recommendations[index].id,
                                      ),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: LoomSpacing.lg),
                  _SectionTitle(tr(context, 'Your Folders', 'پوشه‌های شما')),
                  const SizedBox(height: LoomSpacing.xs),
                  if (activeFolders.isEmpty)
                    LoomSettingsCard(
                      padding: const EdgeInsets.all(LoomSpacing.md),
                      child: Text(
                        tr(
                          context,
                          'No folders added. Chats stay in one clean list until you add a folder.',
                          'هنوز پوشه‌ای اضافه نشده است. تا وقتی پوشه‌ای نسازید، گفتگوها در یک فهرست ساده می‌مانند.',
                        ),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.loom.textSecondary,
                        ),
                      ),
                    )
                  else
                    LoomSettingsCard(
                      padding: EdgeInsets.zero,
                      child: ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        itemCount: activeFolders.length,
                        // Flutter supplies the destination after removal;
                        // the controller retains its insertion-slot contract.
                        onReorderItem: (oldIndex, newIndex) => unawaited(
                          folders.reorder(
                            oldIndex + 1,
                            newIndex + 1 + (newIndex > oldIndex ? 1 : 0),
                          ),
                        ),
                        itemBuilder: (context, index) {
                          final folder = activeFolders[index];
                          return _ActiveFolderRow(
                            key: ValueKey(folder.id),
                            index: index,
                            folder: folder,
                            showDivider: index != activeFolders.length - 1,
                            onEdit: folder.preset
                                ? null
                                : () => _editFolder(context, folders, folder),
                            // Removal is instant in the controller; guard it
                            // with a confirm so a stray swipe can't delete a
                            // curated folder.
                            onRemove: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: Text(
                                    tr(
                                      dialogContext,
                                      'Remove folder?',
                                      'پوشه حذف شود؟',
                                    ),
                                  ),
                                  content: Text(
                                    tr(
                                      dialogContext,
                                      'Chats stay in All Chats — only the folder is removed.',
                                      'گفتگوها در «همه گفتگوها» می‌مانند — فقط پوشه حذف می‌شود.',
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: Text(
                                        tr(dialogContext, 'Cancel', 'لغو'),
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: Text(
                                        tr(dialogContext, 'Remove', 'حذف'),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                unawaited(folders.remove(folder.id));
                              }
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: LoomSpacing.sm),
                  FilledButton.icon(
                    onPressed: folders.folders.length >= 10
                        ? null
                        : () => _editFolder(context, folders, null),
                    icon: const Icon(LoomIcons.add_rounded),
                    label: Text(
                      tr(context, 'Create New Folder', 'ساخت پوشه جدید'),
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.lg),
                  LoomSettingsCard(
                    padding: const EdgeInsets.all(LoomSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          LoomIcons.compare_arrows_rounded,
                          color: context.loom.primary,
                        ),
                        const SizedBox(width: LoomSpacing.sm),
                        Expanded(
                          child: Text(
                            tr(
                              context,
                              'When you add folders, tap a folder name or swipe left and right across the conversation list to switch between them.',
                              'وقتی پوشه اضافه کنید، روی نام پوشه بزنید یا روی فهرست گفتگوها به چپ و راست بکشید تا بین آن‌ها جابه‌جا شوید.',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (activeFolders.isNotEmpty) ...[
                    const SizedBox(height: LoomSpacing.md),
                    Center(
                      child: TextButton(
                        onPressed: () => _confirmRestore(context, folders),
                        child: Text(
                          tr(context, 'Remove all folders', 'حذف همه پوشه‌ها'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmRestore(
    BuildContext context,
    LoomChatFolderController folders,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          tr(context, 'Remove all folders?', 'همه پوشه‌ها حذف شوند؟'),
        ),
        content: Text(
          tr(
            context,
            'Your folder setup will be cleared. Your chats are not deleted and remain available in the main chat list.',
            'تنظیمات پوشه‌ها پاک می‌شود. هیچ گفتگویی حذف نمی‌شود و همه گفتگوها در فهرست اصلی باقی می‌مانند.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'Cancel', 'لغو')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'Remove', 'حذف')),
          ),
        ],
      ),
    );
    if (confirmed == true) await folders.restoreDefaults();
  }

  Future<void> _editFolder(
    BuildContext context,
    LoomChatFolderController folders,
    LoomChatFolderDefinition? existing,
  ) async {
    final name = TextEditingController(text: existing?.name ?? '');
    var direct = existing?.includeDirect ?? true;
    var groups = existing?.includeGroups ?? true;
    var self = existing?.includeSelf ?? true;
    var unread = existing?.unreadOnly ?? false;
    var pinned = existing?.pinnedOnly ?? false;
    var muted = existing?.mutedOnly ?? false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final canSave =
              name.text.trim().isNotEmpty &&
              name.text.trim().length <= 32 &&
              (direct || groups || self);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              LoomSpacing.md,
              0,
              LoomSpacing.md,
              MediaQuery.viewInsetsOf(sheetContext).bottom + LoomSpacing.lg,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existing == null
                        ? tr(sheetContext, 'Create Folder', 'ساخت پوشه')
                        : tr(sheetContext, 'Edit Folder', 'ویرایش پوشه'),
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: LoomSpacing.md),
                  TextField(
                    controller: name,
                    maxLength: 32,
                    autofocus: true,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      labelText: tr(sheetContext, 'Folder name', 'نام پوشه'),
                      hintText: tr(sheetContext, 'Work', 'کار'),
                    ),
                  ),
                  const SizedBox(height: LoomSpacing.sm),
                  Text(
                    tr(sheetContext, 'Chat types', 'نوع گفتگوها'),
                    style: Theme.of(sheetContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: LoomSpacing.xs),
                  Wrap(
                    spacing: LoomSpacing.xs,
                    runSpacing: LoomSpacing.xs,
                    children: [
                      FilterChip(
                        selected: direct,
                        label: Text(tr(sheetContext, 'Personal', 'شخصی')),
                        onSelected: (value) =>
                            setSheetState(() => direct = value),
                      ),
                      FilterChip(
                        selected: groups,
                        label: Text(tr(sheetContext, 'Groups', 'گروه‌ها')),
                        onSelected: (value) =>
                            setSheetState(() => groups = value),
                      ),
                      FilterChip(
                        selected: self,
                        label: Text(tr(sheetContext, 'Saved', 'ذخیره‌شده')),
                        onSelected: (value) =>
                            setSheetState(() => self = value),
                      ),
                    ],
                  ),
                  const SizedBox(height: LoomSpacing.md),
                  Text(
                    tr(sheetContext, 'Filters', 'فیلترها'),
                    style: Theme.of(sheetContext).textTheme.titleSmall,
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: unread,
                    title: Text(
                      tr(sheetContext, 'Unread only', 'فقط خوانده‌نشده'),
                    ),
                    onChanged: (value) => setSheetState(() => unread = value),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: pinned,
                    title: Text(
                      tr(sheetContext, 'Pinned only', 'فقط سنجاق‌شده'),
                    ),
                    onChanged: (value) => setSheetState(() => pinned = value),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: muted,
                    title: Text(tr(sheetContext, 'Muted only', 'فقط بی‌صدا')),
                    onChanged: (value) => setSheetState(() => muted = value),
                  ),
                  const SizedBox(height: LoomSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: canSave
                          ? () async {
                              if (existing == null) {
                                await folders.createCustom(
                                  name: name.text,
                                  includeDirect: direct,
                                  includeGroups: groups,
                                  includeSelf: self,
                                  unreadOnly: unread,
                                  pinnedOnly: pinned,
                                  mutedOnly: muted,
                                );
                              } else {
                                await folders.updateCustom(
                                  existing.id,
                                  name: name.text,
                                  includeDirect: direct,
                                  includeGroups: groups,
                                  includeSelf: self,
                                  unreadOnly: unread,
                                  pinnedOnly: pinned,
                                  mutedOnly: muted,
                                );
                              }
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                            }
                          : null,
                      child: Text(tr(sheetContext, 'Save', 'ذخیره')),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    name.dispose();
  }
}

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: LoomSpacing.sm),
      Container(
        width: 94,
        height: 76,
        decoration: BoxDecoration(
          color: context.loom.primary.withAlphaFraction(.12),
          borderRadius: BorderRadius.circular(LoomRadii.surface),
        ),
        child: Icon(
          LoomIcons.folder_outlined,
          size: 48,
          color: context.loom.primary,
        ),
      ),
      const SizedBox(height: LoomSpacing.md),
      Text(
        tr(
          context,
          'Folders are optional. Add only the categories you actually want.',
          'پوشه‌ها اختیاری‌اند. فقط دسته‌هایی را اضافه کنید که واقعاً می‌خواهید.',
        ),
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: context.loom.textSecondary),
      ),
    ],
  );
}

class _RecommendationRow extends StatelessWidget {
  const _RecommendationRow({
    required this.folder,
    required this.showDivider,
    required this.onAdd,
  });

  final LoomChatFolderDefinition folder;
  final bool showDivider;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: Text(loomChatFolderLongDisplayName(context, folder)),
        subtitle: Text(loomChatFolderDescription(context, folder)),
        trailing: FilledButton(
          onPressed: onAdd,
          child: Text(tr(context, 'Add', 'افزودن')),
        ),
      ),
      if (showDivider) const Divider(height: 1),
    ],
  );
}

class _ActiveFolderRow extends StatelessWidget {
  const _ActiveFolderRow({
    required this.index,
    required this.folder,
    required this.showDivider,
    required this.onEdit,
    required this.onRemove,
    super.key,
  });

  final int index;
  final LoomChatFolderDefinition folder;
  final bool showDivider;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        leading: ReorderableDragStartListener(
          index: index,
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(LoomIcons.compare_arrows_rounded),
          ),
        ),
        title: Text(loomChatFolderLongDisplayName(context, folder)),
        subtitle: Text(loomChatFolderDescription(context, folder)),
        trailing: PopupMenuButton<String>(
          icon: const Icon(LoomIcons.more_horiz_rounded),
          onSelected: (value) {
            if (value == 'edit') onEdit?.call();
            if (value == 'remove') onRemove?.call();
          },
          itemBuilder: (context) => [
            if (onEdit != null)
              PopupMenuItem(
                value: 'edit',
                child: Text(tr(context, 'Edit', 'ویرایش')),
              ),
            PopupMenuItem(
              value: 'remove',
              child: Text(tr(context, 'Remove', 'حذف')),
            ),
          ],
        ),
      ),
      if (showDivider) const Divider(height: 1),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: context.loom.primary,
      fontWeight: FontWeight.w700,
    ),
  );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => LoomSettingsCard(
    padding: const EdgeInsets.all(LoomSpacing.sm),
    child: Row(
      children: [
        Icon(LoomIcons.error_outline_rounded, color: context.loom.critical),
        const SizedBox(width: LoomSpacing.sm),
        Expanded(child: Text(message)),
      ],
    ),
  );
}
