import 'dart:async';

import 'package:loom_design/loom_design.dart';
import 'package:loom_models/loom_models.dart';
import 'package:flutter/material.dart';

import '../../../app/loom_strings.dart';
import '../../calls/presentation/call_surfaces.dart';
import '../../messaging/application/messaging_session_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../../profile/presentation/peer_profile_screen.dart';
import '../../profile/presentation/own_avatar.dart';
import '../application/people_controller.dart';
import 'contact_qr_scanner_screen.dart';
import '../../media/application/media_capabilities.dart';

class LoomPeopleScreen extends StatefulWidget {
  const LoomPeopleScreen({
    this.selectForChat = false,
    this.selectForCall = false,
    this.focusSearch = false,
    this.embedded = false,
    this.onConversationSelected,
    this.controller,
    super.key,
  });
  final bool selectForChat;
  final bool selectForCall;
  final bool focusSearch;
  final bool embedded;
  final ValueChanged<String>? onConversationSelected;
  final LoomPeopleController? controller;
  @override
  State<LoomPeopleScreen> createState() => _LoomPeopleScreenState();
}

class _LoomPeopleScreenState extends State<LoomPeopleScreen> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  LoomPeopleController? _people;
  bool _ownsPeople = false;
  String? _startingAddress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_people != null) {
      return;
    }
    _people =
        widget.controller ??
        LoomPeopleController.forOnboarding(LoomOnboardingScope.of(context));
    _ownsPeople = widget.controller == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_people!.open());
      }
    });
  }

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
    if (_ownsPeople) {
      _people?.dispose();
    }
    super.dispose();
  }

  Future<void> _runSearch() async {
    final value = search.text.trim();
    if (value.isNotEmpty) {
      FocusManager.instance.primaryFocus?.unfocus();
      await _people?.search(value);
    }
  }

  Future<void> _scanContactQr() async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const LoomContactQrScannerScreen(),
      ),
    );
    if (!mounted || address == null || address.isEmpty) {
      return;
    }
    search
      ..text = address
      ..selection = TextSelection.collapsed(offset: address.length);
    setState(() {});
    await _runSearch();
  }

  Future<void> _addContact(LoomResolvedPerson person) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr(context, 'Add contact?', 'افزودن مخاطب؟')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(person.displayName),
            const SizedBox(height: 8),
            SelectableText(
              person.canonicalAddress,
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 12),
            Text(tr(context, 'Identity fingerprint', 'اثر انگشت هویت')),
            SelectableText(
              person.security.identityFingerprint,
              textDirection: TextDirection.ltr,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(tr(context, 'Cancel', 'انصراف')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(tr(context, 'Add', 'افزودن')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final saved = _people!.addContact(person);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved
              ? tr(context, 'Contact saved', 'مخاطب ذخیره شد')
              : _people!.errorMessage ??
                    tr(
                      context,
                      'Contact could not be saved.',
                      'مخاطب ذخیره نشد.',
                    ),
        ),
      ),
    );
  }

  Future<void> _message(String address) async {
    if (_startingAddress != null) {
      return;
    }
    setState(() => _startingAddress = address);
    try {
      final messaging = LoomMessagingSessionScope.of(context);
      await messaging.open();
      if (!mounted) {
        return;
      }
      final conversation = await messaging.startConversation(address);
      if (!mounted) {
        return;
      }
      if (conversation == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              messaging.errorMessage ??
                  tr(
                    context,
                    'Could not open this chat. Try again.',
                    'باز کردن گفتگو ممکن نشد. دوباره تلاش کنید.',
                  ),
            ),
          ),
        );
        return;
      }
      if (widget.onConversationSelected != null) {
        widget.onConversationSelected!(conversation.id);
      } else if (widget.selectForChat) {
        Navigator.pop(context, conversation.id);
      } else {
        Navigator.pushReplacementNamed(
          context,
          '/messenger',
          arguments: conversation.id,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                context,
                'Could not open this chat. Try again.',
                'باز کردن گفتگو ممکن نشد. دوباره تلاش کنید.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _startingAddress = null);
      }
    }
  }

  void _profile(String address, String name, String identityId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LoomPeerProfileScreen(
          address: address,
          displayName: name,
          identityId: identityId,
        ),
      ),
    );
  }

  Future<void> _call(String address) async {
    final kind = await showLoomActionSheet<LoomCallKind>(
      context: context,
      title: tr(context, 'Start a call', 'شروع تماس'),
      builder: (sheet) => Column(
        children: [
          LoomDetailTile(
            leading: const Icon(LoomIcons.call_outlined),
            title: Text(tr(context, 'Voice call', 'تماس صوتی')),
            onTap: () => Navigator.pop(sheet, LoomCallKind.audio),
          ),
          LoomDetailTile(
            leading: const Icon(LoomIcons.videocam_outlined),
            title: Text(tr(context, 'Video call', 'تماس تصویری')),
            onTap: () => Navigator.pop(sheet, LoomCallKind.video),
          ),
        ],
      ),
    );
    if (mounted && kind != null) {
      await startAddressCallFromUi(context, address, kind);
    }
  }

  Future<void> _contactMenu(LoomContact contact) async {
    final changed = contact.securityState == LoomContactSecurityState.changed;
    final action = await showLoomActionSheet<String>(
      context: context,
      title: contact.displayName,
      builder: (sheet) => Column(
        children: [
          LoomDetailTile(
            leading: const Icon(LoomIcons.person_outline_rounded),
            title: Text(tr(context, 'View profile', 'نمایش پروفایل')),
            onTap: () => Navigator.pop(sheet, 'profile'),
          ),
          if (!changed)
            LoomDetailTile(
              leading: const Icon(LoomIcons.call_outlined),
              title: Text(tr(context, 'Call', 'تماس')),
              onTap: () => Navigator.pop(sheet, 'call'),
            ),
          LoomDetailTile(
            leading: Icon(
              LoomIcons.person_remove_outlined,
              color: context.loom.critical,
            ),
            title: Text(tr(context, 'Remove contact', 'حذف مخاطب')),
            onTap: () => Navigator.pop(sheet, 'remove'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (action == 'profile') {
      _profile(
        contact.canonicalAddress,
        contact.displayName,
        contact.identityId,
      );
    }
    if (action == 'call') {
      await _call(contact.canonicalAddress);
    }
    if (action == 'remove') {
      if (!mounted) return;
      final remove = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(tr(context, 'Remove contact?', 'مخاطب حذف شود؟')),
          content: Text(contact.displayName),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(tr(context, 'Cancel', 'لغو')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(tr(context, 'Remove', 'حذف')),
            ),
          ],
        ),
      );
      if (mounted && remove == true) {
        _people?.removeContact(contact.canonicalAddress);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    if (people == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: people,
      builder: (context, _) {
        final query = search.text.trim().toLowerCase();
        final contacts =
            people.contacts
                .where(
                  (c) =>
                      query.isEmpty ||
                      c.displayName.toLowerCase().contains(query) ||
                      c.canonicalAddress.toLowerCase().contains(query),
                )
                .toList()
              ..sort(
                (a, b) => a.displayName.toLowerCase().compareTo(
                  b.displayName.toLowerCase(),
                ),
              );
        final p = context.loom;
        final title = widget.selectForCall
            ? tr(context, 'New call', 'تماس جدید')
            : widget.selectForChat
            ? tr(context, 'New chat', 'گفتگوی جدید')
            : tr(context, 'Contacts', 'مخاطبین');
        return Scaffold(
          extendBodyBehindAppBar: false,
          appBar: LoomGlassAppBar(
            primary: !widget.embedded,
            automaticallyImplyLeading: !widget.embedded,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            title: Text(title),
            actions: [
              if (LoomMediaCapabilities.cameraCapture)
                IconButton(
                  tooltip: tr(context, 'Scan contact QR', 'اسکن QR مخاطب'),
                  onPressed: _scanContactQr,
                  icon: const Icon(LoomIcons.qr_code_scanner_rounded),
                ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(76),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: TextField(
                  controller: search,
                  focusNode: searchFocus,
                  autofocus: widget.focusSearch,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) {
                    people.clearSearch();
                    setState(() {});
                  },
                  onSubmitted: (_) => _runSearch(),
                  decoration: InputDecoration(
                    hintText: tr(
                      context,
                      'Name or username@server',
                      'نام یا username@server',
                    ),
                    prefixIcon: const Icon(LoomIcons.search_rounded),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: tr(context, 'Clear', 'پاک کردن'),
                            onPressed: () {
                              search.clear();
                              people.clearSearch();
                              setState(() {});
                            },
                            icon: const Icon(LoomIcons.close_rounded),
                          ),
                  ),
                ),
              ),
            ),
          ),
          body: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              widget.embedded ? 112 : 32,
            ),
            children: [
              if (query.isNotEmpty) ...[
                LoomDetailTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  tileColor: p.primary.withAlphaFraction(.07),
                  leading: people.state == LoomPeopleState.loading
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          LoomIcons.person_search_outlined,
                          color: p.primary,
                        ),
                  title: Text(
                    tr(
                      context,
                      'Find this username',
                      'پیدا کردن این نام کاربری',
                    ),
                  ),
                  subtitle: Text(
                    search.text.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                  ),
                  onTap: people.state == LoomPeopleState.loading
                      ? null
                      : _runSearch,
                ),
                const SizedBox(height: 8),
              ],
              if (people.state == LoomPeopleState.empty)
                _Notice(
                  text: tr(
                    context,
                    'No account found. Check the username and server.',
                    'حسابی پیدا نشد. نام کاربری و سرور را بررسی کنید.',
                  ),
                ),
              if (people.state == LoomPeopleState.error)
                _Notice(
                  text:
                      people.errorMessage ??
                      tr(
                        context,
                        'Could not load contacts.',
                        'مخاطبین بارگذاری نشدند.',
                      ),
                  error: true,
                ),
              for (final person in people.results) ...[
                _PersonRow(
                  name: person.displayName,
                  identityId: person.identityId,
                  address: person.canonicalAddress,
                  changed:
                      person.securityState ==
                      LoomContactSecurityState.changed,
                  busy: _startingAddress == person.canonicalAddress,
                  onTap: person.canMessage
                      ? () => widget.selectForCall
                            ? _call(person.canonicalAddress)
                            : _message(person.canonicalAddress)
                      : () => _profile(
                          person.canonicalAddress,
                          person.displayName,
                          person.identityId,
                        ),
                  trailing: IconButton(
                    tooltip: people.isContact(person.canonicalAddress)
                        ? tr(context, 'Contact saved', 'مخاطب ذخیره شده')
                        : tr(context, 'Add contact', 'افزودن مخاطب'),
                    onPressed:
                        people.isContact(person.canonicalAddress) ||
                            person.securityState ==
                                LoomContactSecurityState.changed
                        ? null
                        : () => _addContact(person),
                    icon: Icon(
                      people.isContact(person.canonicalAddress)
                          ? LoomIcons.check_rounded
                          : LoomIcons.person_add_alt_rounded,
                    ),
                  ),
                ),
                if (!person.canMessage)
                  _Notice(
                    text:
                        person.securityState ==
                            LoomContactSecurityState.changed
                        ? tr(
                            context,
                            'Identity changed. Verify this person in their profile before messaging.',
                            'هویت تغییر کرده است. پیش از ارسال پیام، پروفایل مخاطب را بررسی کنید.',
                          )
                        : tr(
                            context,
                            'This person has no active device yet.',
                            'این مخاطب هنوز دستگاه فعالی ندارد.',
                          ),
                  ),
              ],
              if (query.isEmpty)
                LoomDetailTile(
                  leading: Icon(
                    LoomIcons.person_add_alt_rounded,
                    color: p.primary,
                  ),
                  title: Text(tr(context, 'Add contact', 'افزودن مخاطب')),
                  onTap: searchFocus.requestFocus,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  tr(context, 'CONTACTS', 'مخاطبین'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: p.textMuted,
                    letterSpacing: .8,
                  ),
                ),
              ),
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 36,
                    horizontal: 24,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        LoomIcons.people_outline_rounded,
                        size: 40,
                        color: p.primary.withAlphaFraction(.65),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        query.isEmpty
                            ? tr(
                                context,
                                'Your people, one tap away',
                                'مخاطبینت، در یک لمس',
                              )
                            : tr(
                                context,
                                'No matching saved contacts',
                                'مخاطب ذخیره‌شده‌ای پیدا نشد',
                              ),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tr(
                          context,
                          LoomMediaCapabilities.cameraCapture
                              ? 'Find a username or scan their QR code.'
                              : 'Find a username or enter their address.',
                          LoomMediaCapabilities.cameraCapture
                              ? 'نام کاربری را جستجو کن یا QR مخاطب را اسکن کن.'
                              : 'نام کاربری یا نشانی مخاطب را وارد کن.',
                        ),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              for (var i = 0; i < contacts.length; i++) ...[
                if (i == 0 ||
                    _initial(contacts[i].displayName) !=
                        _initial(contacts[i - 1].displayName))
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      18,
                      14,
                      18,
                      4,
                    ),
                    child: Text(
                      _initial(contacts[i].displayName),
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: p.primary),
                    ),
                  ),
                _PersonRow(
                  name: contacts[i].displayName,
                  identityId: contacts[i].identityId,
                  address: contacts[i].canonicalAddress,
                  changed:
                      contacts[i].securityState ==
                      LoomContactSecurityState.changed,
                  busy: _startingAddress == contacts[i].canonicalAddress,
                  onTap: () {
                    final contact = contacts[i];
                    if (contact.securityState ==
                        LoomContactSecurityState.changed) {
                      _profile(
                        contact.canonicalAddress,
                        contact.displayName,
                        contact.identityId,
                      );
                    } else if (widget.selectForCall) {
                      unawaited(_call(contact.canonicalAddress));
                    } else {
                      unawaited(_message(contact.canonicalAddress));
                    }
                  },
                  trailing: IconButton(
                    tooltip: tr(context, 'Contact options', 'گزینه‌های مخاطب'),
                    icon: const Icon(LoomIcons.more_horiz_rounded),
                    onPressed: () => _contactMenu(contacts[i]),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

String _initial(String name) =>
    name.trim().isEmpty ? '@' : name.trim().characters.first.toUpperCase();

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.name,
    required this.identityId,
    required this.address,
    required this.changed,
    required this.busy,
    required this.onTap,
    required this.trailing,
  });
  final String name, address;
  final String identityId;
  final bool changed, busy;
  final VoidCallback onTap;
  final Widget trailing;
  @override
  Widget build(BuildContext context) {
    return LoomDetailTile(
      contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 6, 0, 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      onTap: busy ? null : onTap,
      leading: LoomOwnAvatar(name: name, identityId: identityId),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        changed
            ? tr(
                context,
                'Identity changed · verify profile',
                'هویت تغییر کرده · پروفایل را بررسی کنید',
              )
            : address,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textDirection: changed ? null : TextDirection.ltr,
        style: TextStyle(
          color: changed ? context.loom.critical : context.loom.textMuted,
        ),
      ),
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : trailing,
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: error ? context.loom.critical : context.loom.textSecondary,
      ),
    ),
  );
}
