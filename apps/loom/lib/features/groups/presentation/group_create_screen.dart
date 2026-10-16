import 'dart:async';
import 'dart:typed_data';

import 'package:loom_crypto_bridge/loom_crypto_bridge.dart';
import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:loom_protocol/loom_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../people/application/people_controller.dart';
import '../application/groups_controller.dart';
import 'group_avatar.dart';
import 'group_photo_picker.dart';

/// One route owns the draft and submission lifetime. A failed create never
/// dismisses the form or removes the selected people.
class LoomGroupCreateScreen extends StatefulWidget {
  const LoomGroupCreateScreen({
    required this.groups,
    this.people,
    this.pickPhoto,
    super.key,
  });
  final LoomGroupsController groups;
  final LoomPeopleController? people;
  final Future<Uint8List?> Function()? pickPhoto;

  @override
  State<LoomGroupCreateScreen> createState() =>
      _LoomGroupCreateScreenState();
}

class _LoomGroupCreateScreenState extends State<LoomGroupCreateScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _selected = <String, String>{};
  late final LoomPeopleController _people;
  bool _submitting = false, _discarding = false, _allowPop = false;
  String? _error, _createdId;
  Uint8List? _photo;
  bool _pickingPhoto = false;

  void _clearPhoto() {
    final old = _photo;
    _photo = null;
    if (old != null) {
      unawaited(MemoryImage(old).evict());
      old.fillRange(0, old.length, 0);
    }
  }

  Future<void> _choosePhoto() async {
    if (_submitting || _pickingPhoto || _createdId != null) return;
    setState(() => _pickingPhoto = true);
    try {
      final photo = await (widget.pickPhoto ?? pickLoomGroupPhoto)();
      if (!mounted || LoomAppLock.instance.locked) {
        photo?.fillRange(0, photo.length, 0);
        return;
      }
      if (photo != null) {
        LoomGroupProfile.validatePng(photo);
        setState(() {
          _clearPhoto();
          _photo = photo;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr(
            context,
            'Could not prepare this photo. Choose an image smaller than 8 MiB.',
            'تصویر آماده نشد. تصویری کوچک‌تر از ۸ مگابایت انتخاب کنید.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  void _openCreated() {
    final id = _createdId;
    if (id == null) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, id);
    });
  }

  bool get _dirty =>
      _name.text.trim().isNotEmpty || _selected.isNotEmpty || _photo != null;

  @override
  void initState() {
    super.initState();
    LoomAppLock.instance.addListener(_lockChanged);
    _people =
        widget.people ??
        LoomPeopleController.forOnboarding(widget.groups.onboarding);
    unawaited(_people.open());
  }

  void _lockChanged() {
    if (!LoomAppLock.instance.locked || !mounted) return;
    setState(() {
      _clearPhoto();
    });
  }

  @override
  void dispose() {
    LoomAppLock.instance.removeListener(_lockChanged);
    _clearPhoto();
    _name.dispose();
    _search.dispose();
    _searchFocus.dispose();
    if (widget.people == null) _people.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_submitting || _discarding || _pickingPhoto) return;
    if (_createdId != null) {
      _openCreated();
      return;
    }
    if (_dirty) {
      _discarding = true;
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr(c, 'Discard this group?', 'ساخت گروه لغو شود؟')),
          content: Text(
            tr(
              c,
              'Your group name and selected people will be discarded.',
              'نام گروه و اعضای انتخاب‌شده پاک می‌شوند.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(c, 'Keep editing', 'ادامهٔ ویرایش')),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.loom.critical),
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr(c, 'Discard', 'لغو ساخت')),
            ),
          ],
        ),
      );
      _discarding = false;
      if (discard != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  bool _eligible(String address, LoomContactSecurityState security) {
    final home = widget.groups.onboarding.receipt?.homeNode;
    if (home == null ||
        security == LoomContactSecurityState.changed ||
        security == LoomContactSecurityState.unavailable ||
        address == widget.groups.onboarding.receipt?.address) {
      return false;
    }
    try {
      return LoomAddress.parseCanonical(address).isSameNode(home);
    } on FormatException {
      return false;
    }
  }

  void _toggle(String address, String label) {
    if (_submitting || _createdId != null) return;
    setState(() {
      if (_selected.containsKey(address)) {
        _selected.remove(address);
      } else {
        _selected[address] = label;
      }
      _error = null;
    });
  }

  Future<void> _find() async {
    if (_submitting || _people.state == LoomPeopleState.loading) return;
    final query = _search.text.trim();
    if (query.isEmpty) return;
    _searchFocus.unfocus();
    await _people.search(query);
  }

  Future<void> _create() async {
    if (_submitting || _pickingPhoto || !_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      _createdId ??= await widget.groups.create(
        _name.text.trim(),
        _selected.keys.toList(),
      );
      if (!mounted) return;
      if (_createdId == null) {
        setState(
          () => _error = tr(
            context,
            'The group could not be created. Check your connection and selected members, then try again.',
            'گروه ساخته نشد. اتصال و اعضای انتخاب‌شده را بررسی و دوباره تلاش کنید.',
          ),
        );
      } else if (_photo != null &&
          !await widget.groups.setGroupPhoto(_createdId!, _photo)) {
        if (mounted) {
          setState(
            () => _error = tr(
              context,
              'Your group was created. Retry syncing its photo, or open the group now.',
              'گروه ساخته شد. همگام‌سازی تصویر را دوباره امتحان کنید یا اکنون گروه را باز کنید.',
            ),
          );
        }
      } else if (mounted) {
        _openCreated();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr(
            context,
            'The change could not be completed. Your draft is kept here; try again.',
            'تغییر انجام نشد. اطلاعات شما اینجا حفظ شده‌اند؛ دوباره تلاش کنید.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _person(String address, String label, bool eligible) {
    final selected = _selected.containsKey(address);
    return LoomSelectionRow(
      key: ValueKey('create-member-$address'),
      label: label,
      detail: address,
      selected: selected,
      enabled: eligible && !_submitting && _createdId == null,
      unavailableLabel: !eligible
          ? tr(
              context,
              'Choose an available, verified contact on your server.',
              'مخاطب در دسترس و تأییدشده در سرور خود را انتخاب کنید.',
            )
          : null,
      onTap: () => _toggle(address, label),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || (!_dirty && !_submitting && !_pickingPhoto),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_cancel());
    },
    child: Scaffold(
      appBar: LoomGlassAppBar(
        leading: BackButton(onPressed: _submitting ? null : _cancel),
        title: Text(tr(context, 'New group', 'گروه جدید')),
      ),
      body: Column(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: LoomSizing.formMax,
                ),
                child: Form(
                  key: _form,
                  child: ListenableBuilder(
                    listenable: _people,
                    builder: (context, _) {
                      final query = _search.text.trim().toLowerCase();
                      final contacts = _people.contacts
                          .where(
                            (p) => '${p.displayName} ${p.canonicalAddress}'
                                .toLowerCase()
                                .contains(query),
                          )
                          .toList();
                      return ListView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.all(LoomSpacing.md),
                        children: [
                          Center(
                            child: LoomGroupPhotoAvatar(
                              label: _name.text.trim().isEmpty
                                  ? tr(context, 'New group', 'گروه جدید')
                                  : _name.text,
                              size: LoomSizing.largeAvatar,
                              photo: _photo,
                            ),
                          ),
                          Center(
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              children: [
                                TextButton.icon(
                                  key: const ValueKey('group-photo-picker'),
                                  onPressed:
                                      _submitting ||
                                          _pickingPhoto ||
                                          _createdId != null
                                      ? null
                                      : _choosePhoto,
                                  icon: const Icon(
                                    LoomIcons.photo_library_outlined,
                                  ),
                                  label: Text(
                                    _pickingPhoto
                                        ? tr(
                                            context,
                                            'Preparing…',
                                            'آماده‌سازی…',
                                          )
                                        : _photo == null
                                        ? tr(
                                            context,
                                            'Add photo',
                                            'افزودن تصویر',
                                          )
                                        : tr(
                                            context,
                                            'Change photo',
                                            'تغییر تصویر',
                                          ),
                                  ),
                                ),
                                if (_photo != null)
                                  TextButton(
                                    onPressed: _submitting || _createdId != null
                                        ? null
                                        : () => setState(_clearPhoto),
                                    child: Text(
                                      tr(context, 'Remove photo', 'حذف تصویر'),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: LoomSpacing.lg),
                          TextFormField(
                            key: const ValueKey('group-name'),
                            controller: _name,
                            enabled: !_submitting && _createdId == null,
                            autofocus: true,
                            maxLength: 100,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.next,
                            autovalidateMode:
                                AutovalidateMode.onUserInteraction,
                            decoration: InputDecoration(
                              labelText: tr(context, 'Group name', 'نام گروه'),
                            ),
                            onChanged: (_) => setState(() => _error = null),
                            onFieldSubmitted: (_) =>
                                _searchFocus.requestFocus(),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return tr(
                                  context,
                                  'Enter a group name.',
                                  'نام گروه را وارد کنید.',
                                );
                              }
                              if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
                                return tr(
                                  context,
                                  'Use a name without control characters.',
                                  'از نویسه‌های کنترلی در نام استفاده نکنید.',
                                );
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: LoomSpacing.lg),
                          Text(
                            tr(context, 'Members (optional)', 'اعضا (اختیاری)'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: LoomSpacing.xs),
                          Text(
                            tr(
                              context,
                              'Choose contacts or find a username on your server. You can also invite people after creating the group.',
                              'مخاطبان را انتخاب کنید یا نام کاربری را در سرور خود پیدا کنید. بعد از ساخت گروه هم می‌توانید افراد را دعوت کنید.',
                            ),
                          ),
                          if (_selected.isNotEmpty) ...[
                            const SizedBox(height: LoomSpacing.sm),
                            Text(
                              '${_selected.length} ${tr(context, 'selected', 'نفر انتخاب‌شده')}',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: LoomSpacing.xs),
                            Wrap(
                              spacing: LoomSpacing.xs,
                              runSpacing: LoomSpacing.xxs,
                              children: [
                                for (final entry in _selected.entries)
                                  InputChip(
                                    label: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 180,
                                      ),
                                      child: Text(
                                        entry.value,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    onDeleted: _submitting
                                        ? null
                                        : () => _toggle(entry.key, entry.value),
                                    deleteButtonTooltipMessage:
                                        '${tr(context, 'Remove', 'حذف')} ${entry.value}',
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: LoomSpacing.md),
                          TextField(
                            key: const ValueKey('group-member-search'),
                            controller: _search,
                            focusNode: _searchFocus,
                            enabled: !_submitting && _createdId == null,
                            textInputAction: TextInputAction.search,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: tr(
                                context,
                                'Search people',
                                'جستجوی افراد',
                              ),
                              prefixIcon: const Icon(
                                LoomIcons.search_rounded,
                              ),
                              suffixIcon: IconButton(
                                tooltip: tr(
                                  context,
                                  'Find username',
                                  'پیدا کردن نام کاربری',
                                ),
                                onPressed:
                                    _submitting ||
                                        _people.state ==
                                            LoomPeopleState.loading
                                    ? null
                                    : _find,
                                icon: const Icon(
                                  LoomIcons.arrow_forward_rounded,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => _find(),
                            onChanged: (_) {
                              _people.clearSearch();
                              setState(() {});
                            },
                          ),
                          const SizedBox(height: LoomSpacing.sm),
                          if (_people.state == LoomPeopleState.loading)
                            const LinearProgressIndicator(),
                          if (_people.state == LoomPeopleState.error)
                            LoomFeedbackSurface(
                              message: tr(
                                context,
                                'People could not be loaded. Check your connection and the username.',
                                'فهرست افراد بارگذاری نشد. اتصال و نام کاربری را بررسی کنید.',
                              ),
                              actionLabel: tr(context, 'Retry', 'تلاش مجدد'),
                              onAction: _submitting
                                  ? null
                                  : () {
                                      if (_search.text.trim().isNotEmpty) {
                                        unawaited(_find());
                                      } else {
                                        unawaited(_people.open());
                                      }
                                    },
                            ),
                          for (final person in _people.results)
                            _person(
                              person.canonicalAddress,
                              person.displayName,
                              person.canMessage &&
                                  _eligible(
                                    person.canonicalAddress,
                                    person.securityState,
                                  ),
                            ),
                          for (final contact in contacts)
                            if (!_people.results.any(
                              (p) =>
                                  p.canonicalAddress ==
                                  contact.canonicalAddress,
                            ))
                              _person(
                                contact.canonicalAddress,
                                contact.displayName,
                                _eligible(
                                  contact.canonicalAddress,
                                  contact.securityState,
                                ),
                              ),
                          if (contacts.isEmpty &&
                              _people.results.isEmpty &&
                              _people.state != LoomPeopleState.loading &&
                              _people.state != LoomPeopleState.error)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: LoomSpacing.md,
                              ),
                              child: Text(
                                query.isEmpty
                                    ? tr(
                                        context,
                                        'No saved contacts. Find a username or create the group and share an invitation.',
                                        'مخاطبی ذخیره نشده. نام کاربری را پیدا کنید یا گروه را بسازید و دعوت بفرستید.',
                                      )
                                    : tr(
                                        context,
                                        'No matching contacts. Use the search button to find this username.',
                                        'مخاطبی پیدا نشد. برای پیدا کردن نام کاربری، دکمهٔ جستجو را بزنید.',
                                      ),
                              ),
                            ),
                          if (_error != null && _createdId == null) ...[
                            const SizedBox(height: LoomSpacing.md),
                            LoomFeedbackSurface(message: _error!),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(LoomSpacing.md),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: LoomSizing.formMax,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_createdId != null && _error != null)
                          LoomFeedbackSurface(message: _error!),
                        if (_createdId != null)
                          TextButton(
                            key: const ValueKey('open-created-group'),
                            onPressed: _submitting ? null : _openCreated,
                            child: Text(
                              tr(context, 'Open group', 'باز کردن گروه'),
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const ValueKey('create-group-submit'),
                            onPressed: _submitting || _pickingPhoto
                                ? null
                                : _create,
                            icon: _submitting
                                ? const SizedBox.square(
                                    dimension: LoomIconSize.standard,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(LoomIcons.groups_outlined),
                            label: Text(
                              _submitting
                                  ? tr(
                                      context,
                                      'Creating group…',
                                      'در حال ساخت گروه…',
                                    )
                                  : _createdId == null
                                  ? tr(context, 'Create group', 'ساخت گروه')
                                  : tr(
                                      context,
                                      'Retry photo sync',
                                      'تلاش دوباره برای تصویر',
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
