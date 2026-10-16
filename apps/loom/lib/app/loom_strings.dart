import 'package:flutter/widgets.dart';

class LoomStrings {
  const LoomStrings(this.locale);
  final Locale locale;
  bool get _fa => locale.languageCode == 'fa';

  String get appName => _fa ? 'لوم' : 'Loom';
  String get tagline => _fa
      ? 'ارتباط خصوصی که همیشه راهی پیدا می‌کند.'
      : 'Private communication that keeps finding a path.';
  String get createIdentity => _fa ? 'ساخت هویت' : 'Create Identity';
  String get restoreIdentity => _fa ? 'بازیابی هویت' : 'Restore Identity';
  String get linkDevice => _fa ? 'پیوند دستگاه موجود' : 'Link Existing Device';
  String get exploreLocal => _fa ? 'کاوش شبکه محلی' : 'Explore Local Network';
  String get advanced => _fa ? 'پیشرفته' : 'Advanced';
  String get chats => _fa ? 'گفتگوها' : 'Chats';
  String get people => _fa ? 'افراد' : 'People';
  String get calls => _fa ? 'تماس‌ها' : 'Calls';
  String get settings => _fa ? 'تنظیمات' : 'Settings';
  String get chooseNode => _fa
      ? 'محل زندگی هویت لوم را انتخاب کنید'
      : 'Choose where your Loom identity lives';
  String get recommended => _fa ? 'پیشنهادی' : 'Recommended';
  String get nearby => _fa ? 'نزدیک' : 'Nearby';
  String get iran => _fa ? 'ایران' : 'Iran';
  String get international => _fa ? 'بین‌المللی' : 'International';
  String get saved => _fa ? 'ذخیره‌شده' : 'Saved';
  String get search => _fa ? 'جستجو' : 'Search';
  String get enterManually => _fa ? 'ورود دستی' : 'Enter Manually';
  String get scanQr => _fa ? 'اسکن QR' : 'Scan QR';
  String get discoverLocal => _fa ? 'یافتن Node محلی' : 'Discover Local Node';
  String get hostNode => _fa ? 'میزبانی Node' : 'Host a Node';
  String get identity => _fa ? 'هویت' : 'Identity';
  String get security => _fa ? 'امنیت' : 'Security';
  String get media => _fa ? 'رسانه' : 'Media';
  String get files => _fa ? 'فایل‌ها' : 'Files';
  String get voice => _fa ? 'صدا' : 'Voice';
  String get links => _fa ? 'پیوندها' : 'Links';
  String get groups => _fa ? 'گروه‌ها' : 'Groups';
  String get recovery => _fa ? 'بازیابی' : 'Recovery';

  static LoomStrings of(BuildContext context) =>
      LoomStrings(Localizations.localeOf(context));
}

String tr(BuildContext context, String en, String fa) =>
    Localizations.localeOf(context).languageCode == 'fa' ? fa : en;
