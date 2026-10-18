import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/loom_strings.dart';
import '../../../dev/preview_data.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../application/avatar_photo.dart';
import '../application/local_avatar_store.dart';
import 'profile_header.dart';
import 'own_avatar.dart' show loomAvatarColors;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({required this.preview, super.key});
  final bool preview;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  LoomLocalAvatarStore? _avatar;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = widget.preview
        ? null
        : LoomOnboardingScope.of(context).committedIdentity?.identityId;
    final next = id == null ? null : LoomLocalAvatarStore.forIdentity(id);
    if (identical(next, _avatar)) {
      return;
    }
    _avatar?.removeListener(_changed);
    _avatar = next;
    _avatar?.addListener(_changed);
    if (_avatar != null) {
      unawaited(_avatar!.load());
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _avatar?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _save(Future<void> Function(LoomLocalAvatarStore) action) async {
    final avatar = _avatar;
    if (_saving || avatar == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      await action(avatar);
      if (mounted) {
        unawaited(
          LoomOnboardingScope.of(context).synchronizeProfile(force: true),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is AvatarPhotoTooLarge
                  ? tr(
                      context,
                      'Choose a photo under 8 MB and 40 megapixels.',
                      'عکسی کوچک‌تر از ۸ مگابایت و ۴۰ مگاپیکسل انتخاب کنید.',
                    )
                  : tr(
                      context,
                      'Could not save your changes. Try another photo or check free storage.',
                      'تغییرات ذخیره نشد. عکس دیگری انتخاب کنید یا فضای خالی دستگاه را بررسی کنید.',
                    ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _choosePhoto() => _save((avatar) async {
    final photo = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Photos',
          extensions: ['jpg', 'jpeg', 'png', 'webp'],
          mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
          uniformTypeIdentifiers: [
            'public.jpeg',
            'public.png',
            'org.webmproject.webp',
          ],
        ),
      ],
    );
    if (photo == null || !mounted || !identical(avatar, _avatar)) {
      return;
    }
    if (await photo.length() > 8 * 1024 * 1024) {
      throw const AvatarPhotoTooLarge();
    }
    final png = await normalizeAvatarPhoto(await photo.readAsBytes());
    if (!mounted || !identical(avatar, _avatar)) {
      return;
    }
    await avatar.setPhoto(png);
  });

  Future<void> _editName(String current) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _DisplayNameDialog(initial: current),
    );
    if (value != null && mounted) {
      await _save((avatar) => avatar.setDisplayName(value));
    }
  }

  Future<void> _copy(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Address copied', 'نشانی کپی شد'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.loom;
    final onboarding = widget.preview ? null : LoomOnboardingScope.of(context);
    final receipt = onboarding?.receipt;
    final identity = onboarding?.committedIdentity;
    final name = widget.preview
        ? LoomPreviewData.profile.name
        : _avatar?.displayName?.isNotEmpty == true
        ? _avatar!.displayName!
        : onboarding?.displayName.trim().isNotEmpty == true
        ? onboarding!.displayName
        : onboarding?.username.trim().isNotEmpty == true
        ? onboarding!.username
        : tr(context, 'My profile', 'پروفایل من');
    final address = widget.preview
        ? LoomPreviewData.profile.address
        : receipt?.address;
    final canEdit = _avatar != null && !_saving;
    final syncLabel = _avatar?.syncing == true
        ? tr(context, 'Syncing profile…', 'در حال همگام‌سازی پروفایل…')
        : _avatar?.pendingUpload == true
        ? tr(
            context,
            'Saved here · waiting to sync',
            'ذخیره شد · در انتظار همگام‌سازی',
          )
        : _avatar?.revision != null
        ? tr(context, 'Profile synced', 'پروفایل همگام‌شده')
        : tr(context, 'Public profile', 'پروفایل عمومی');
    return Scaffold(
      body: CustomScrollView(
        key: const ValueKey('profile-scroll'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          LoomProfileHeader(name: name, identityId: identity?.identityId),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            sliver: SliverList.list(
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: canEdit ? _choosePhoto : null,
                      icon: const Icon(LoomIcons.add_a_photo_outlined),
                      label: Text(tr(context, 'Set photo', 'انتخاب عکس')),
                    ),
                    TextButton.icon(
                      onPressed: canEdit ? () => _editName(name) : null,
                      icon: const Icon(LoomIcons.edit_outlined),
                      label: Text(tr(context, 'Edit info', 'ویرایش اطلاعات')),
                    ),
                    IconButton(
                      tooltip: tr(context, 'My QR', 'کد QR من'),
                      onPressed: widget.preview || receipt == null
                          ? null
                          : () => Navigator.pushNamed(context, '/profile-qr'),
                      icon: const Icon(LoomIcons.qr_code_rounded),
                    ),
                  ],
                ),
                if (address != null)
                  ListTile(
                    title: Text(address, textDirection: TextDirection.ltr),
                    subtitle: Text(tr(context, 'Loom address', 'نشانی لوم')),
                    trailing: const Icon(LoomIcons.copy_outlined),
                    onTap: () => _copy(address),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          syncLabel,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: _avatar?.pendingUpload == true
                                    ? p.warning
                                    : p.textSecondary,
                              ),
                        ),
                      ),
                      if (_avatar?.pendingUpload == true ||
                          _avatar?.syncError != null)
                        TextButton(
                          onPressed: _avatar?.syncing == true
                              ? null
                              : () => unawaited(
                                  onboarding!.synchronizeProfile(force: true),
                                ),
                          child: Text(tr(context, 'Retry', 'تلاش دوباره')),
                        ),
                    ],
                  ),
                ),
                _Section(
                  title: tr(context, 'Photo & avatar', 'عکس و آواتار'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'Make it yours', 'به سلیقه خودت'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tr(
                              context,
                              'Your photo, name and avatar color sync with your Home Node and are visible to people who know your Loom address.',
                              'عکس، نام و رنگ آواتار با سرور شما همگام می‌شوند و افرادی که نشانی لوم شما را دارند آن‌ها را می‌بینند.',
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: p.textSecondary),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: canEdit ? _choosePhoto : null,
                                icon: const Icon(
                                  LoomIcons.add_photo_alternate_outlined,
                                  size: 19,
                                ),
                                label: Text(
                                  tr(
                                    context,
                                    _avatar?.photo == null
                                        ? 'Choose photo'
                                        : 'Change photo',
                                    _avatar?.photo == null
                                        ? 'انتخاب عکس'
                                        : 'تغییر عکس',
                                  ),
                                ),
                              ),
                              if (_avatar?.photo != null)
                                TextButton(
                                  onPressed: canEdit
                                      ? () => _save(
                                          (avatar) => avatar.removePhoto(),
                                        )
                                      : null,
                                  child: Text(
                                    tr(
                                      context,
                                      'Use initials',
                                      'نمایش حروف نام',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            tr(context, 'Initials color', 'رنگ حروف نام'),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < loomAvatarColors.length; i++)
                                Semantics(
                                  selected: _avatar?.colorIndex == i,
                                  label: _colorLabel(context, i),
                                  child: Tooltip(
                                    message: _colorLabel(context, i),
                                    child: SizedBox.square(
                                      dimension: 44,
                                      child: IconButton(
                                        onPressed: canEdit
                                            ? () => _save(
                                                (avatar) => avatar.setColor(i),
                                              )
                                            : null,
                                        style: IconButton.styleFrom(
                                          backgroundColor: loomAvatarColors[i],
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor:
                                              loomAvatarColors[i].withValues(
                                                alpha: .4,
                                              ),
                                        ),
                                        icon: Icon(
                                          _avatar?.colorIndex == i
                                              ? LoomIcons.check_rounded
                                              : LoomIcons.circle_outlined,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (widget.preview || identity == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                tr(
                                  context,
                                  widget.preview
                                      ? 'Design preview only · changes stay on this device.'
                                      : 'Sign in to personalize your profile.',
                                  widget.preview
                                      ? 'پیش‌نمایش طراحی · تغییرات روی همین دستگاه می‌مانند.'
                                      : 'برای شخصی‌سازی پروفایل وارد حساب شوید.',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                _Section(
                  title: tr(context, 'Account', 'حساب کاربری'),
                  children: [
                    ListTile(
                      leading: Icon(LoomIcons.edit_rounded, color: p.primary),
                      title: Text(tr(context, 'Display name', 'نام نمایشی')),
                      subtitle: Text(name),
                      onTap: canEdit ? () => _editName(name) : null,
                    ),
                    _IdentityValue(
                      label: tr(context, 'Username', 'نام کاربری'),
                      value: widget.preview
                          ? LoomPreviewData.profile.username
                          : onboarding?.username.isNotEmpty == true
                          ? '@${onboarding!.username}'
                          : '—',
                    ),
                    _IdentityValue(
                      label: tr(context, 'Home Node', 'سرور حساب'),
                      value: widget.preview
                          ? LoomPreviewData.profile.homeNode
                          : receipt?.homeNode ?? '—',
                    ),
                  ],
                ),
                _Section(
                  title: tr(context, 'Security & devices', 'امنیت و دستگاه‌ها'),
                  children: [
                    LoomSettingsRow(
                      icon: LoomIcons.fingerprint_rounded,
                      title: tr(
                        context,
                        'Identity & devices',
                        'هویت و دستگاه‌ها',
                      ),
                      subtitle: tr(
                        context,
                        'Review your identity and signed-in devices',
                        'بررسی هویت و دستگاه‌های واردشده',
                      ),
                      onTap: () => Navigator.pushNamed(context, '/security'),
                    ),
                    _IdentityValue(
                      label: tr(
                        context,
                        'Identity fingerprint',
                        'اثر انگشت هویت',
                      ),
                      value: widget.preview
                          ? LoomPreviewData.profile.fingerprint
                          : identity?.fingerprint ?? '—',
                    ),
                  ],
                ),
                _Section(
                  title: tr(context, 'Personalize Loom', 'شخصی‌سازی لوم'),
                  children: [
                    LoomSettingsRow(
                      icon: LoomIcons.palette_outlined,
                      title: tr(context, 'Appearance', 'ظاهر'),
                      subtitle: tr(
                        context,
                        'Theme & Liquid Glass',
                        'پوسته و شیشه',
                      ),
                      onTap: () =>
                          Navigator.pushNamed(context, '/settings/appearance'),
                    ),
                    LoomSettingsRow(
                      icon: LoomIcons.notifications_none_rounded,
                      title: tr(context, 'Notifications', 'اعلان‌ها'),
                      onTap: () => Navigator.pushNamed(
                        context,
                        '/settings/notifications',
                      ),
                      showDivider: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _colorLabel(BuildContext context, int index) => tr(
  context,
  const ['Ocean', 'Violet', 'Jade', 'Coral', 'Amber', 'Slate'][index],
  const ['اقیانوسی', 'بنفش', 'یشمی', 'مرجانی', 'کهربایی', 'خاکستری آبی'][index],
);

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: context.loom.textSecondary),
          ),
        ),
        LoomSettingsGroup(children: children),
      ],
    ),
  );
}

class _IdentityValue extends StatelessWidget {
  const _IdentityValue({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: context.loom.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            value,
            textDirection: TextDirection.ltr,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}

class _DisplayNameDialog extends StatefulWidget {
  const _DisplayNameDialog({required this.initial});
  final String initial;
  @override
  State<_DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<_DisplayNameDialog> {
  late final _text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _text.text.trim();
    if (name.isNotEmpty &&
        name.length <= 80 &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      Navigator.pop(context, name);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'Display name', 'نام نمایشی')),
    content: TextField(
      controller: _text,
      autofocus: true,
      maxLength: 80,
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, 'Cancel', 'لغو')),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(tr(context, 'Save', 'ذخیره')),
      ),
    ],
  );
}
