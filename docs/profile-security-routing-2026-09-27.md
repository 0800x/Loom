# Profile, local protection and reliable acceptance — 2026-09-27

Branch: `main`. Node `0.10.1`, Go Manager `0.8.0`.

## English

### Implemented

- **Acceptance:** SQLite/PostgreSQL record the opaque message and routing intent in one transaction. An immediate worker processes up to four conversations independently, preserves ordering inside its server routing queue, and persists retry state across restarts. A retry of an older accepted client ID repairs a missing intent without creating another message. Discovery is no longer awaited by the acceptance request. Federation outbox and recipient receipts remain separate; acceptance never generates recipient delivery evidence.
- **Client queue:** concurrent token refreshes share one result. Messaging and RTC configuration retry a stale token once with a fresh signed proof. Outbox work is concurrent across up to four chats; sends take priority over read receipts. Definitive rejections retain the encrypted message as Failed for explicit retry instead of retrying forever as Queued. Lock/logout invalidates late refresh results.
- **Profile:** the username is restored from the canonical account address. Name, normalized PNG avatar and color sync through authenticated `/api/v1/profile`; updates cannot change the account address. The server validates PNG dimensions, chunks, CRCs and bounded decompression. Signed federation profiles include the optional avatar without changing the old canonical shape when absent. The local edit outbox survives restart, preserves earlier local photos and does not let a late response erase a newer edit. Profile data is public presentation data.
- **UI:** glass Settings account card, username, shortcuts, colored grouped rows, editable display name, profile sync/retry state, peer avatar in the chat header/profile, and aligned inline + circles in LTR/RTL. Existing reduced-motion behavior remains.
- **Local protection:** optional Android 11+ strong biometric or device-credential authentication gates a Keystore wrapping key. It unwraps a random native vault key used for existing `loom.*` secure-storage values. Migration is serialized with reads/writes and can resume after interruption. Locking removes readable routes/cache and temporary access credentials, blocks screenshots and clears the native vault key. No unauthenticated recovery fallback is added.
- **Operator controls:** Calls page, interactive hidden-secret TURN setup, separate voice/video signaling policies, readiness diagnostics and configuration rollback. Existing TURN must be reachable; the wizard does not deploy it. Groups page reports the missing production MLS engine rather than enabling unsupported group traffic.

### Validation performed

| Check | Result |
|---|---|
| Complete Node test command (`node --experimental-strip-types --test test/*.test.ts`) | 76 passed on Node 24.19.0 |
| Acceptance/routing regressions | Atomic rollback, repair of old missing intents, restart recovery, peer isolation and retry ordering passed |
| Profile tests | Device-proof HTTP boundary, immutable username, persistence/removal, signature tampering and cache passed |
| Existing server regression suite | Device-bound auth, federation/recipient evidence, RTC policy, v2 mailboxes and production strip-only source checks passed |
| Dart source formatting/parsing and icon references | Checked with the available WASM formatter and repository icon declarations; not a Dart analyzer run |
| New Dart regression coverage | Added for token/proof retry, shared refresh and late results, outbox isolation/rejection, profile migration/edit races, and RTL dial alignment; not executed here |
| Flutter analyzer/widget tests/APK; native Keystore; Go tests/build; live PostgreSQL migration | Not executed: corresponding SDKs, device or database were unavailable |

The Node tests used the pinned `ws` 8.21.3 source with upstream Git blob hashes verified. No installed Node or live server was modified. Production pins Node 22.16.0; the local run is not a claim of a Docker build on that exact runtime.

### Required field checks and remaining work

1. Build and install the same new APK on both phones; upgrade both Home Nodes. Check profile sync, the canonical username, photo removal and restart while an edit is pending.
2. Send both directions on one Node, between Nodes, then with one phone offline over Nearby. Restart the Node after acceptance. One check is acceptance; two checks still require recipient evidence. Measure latency using both device/server clocks and recorded routes; no fixed end-to-end latency is promised by unit tests.
3. Enable/disable App lock on Android 11+; test PIN, biometrics, cancellation, process death, backgrounding, interrupted migration, screenshot blocking and unlock. Keep recovery material separate. Rooted-process memory extraction and reliable zeroing of Dart strings are not solved. The separate experimental v2 provider is not made production-approved by this work.
4. In the TUI choose Calls → Configure TURN, or run `sudo /opt/loom-node/bin/loom-node-manager --home /opt/loom-node --configure-calls`. Test both audio and video across different networks with authenticated TURN. Applying these settings restarts the Node and interrupts active calls.
5. **Production MLS/group messaging/group calls and fully offline read receipts remain unimplemented.** The signed Nearby delivery-receipt and proximity-gateway paths already in the branch remain in place; their radio/device acceptance matrix is still required.

## فارسی

### چه چیزی تغییر کرده؟

- پیام رمز‌شده و کار ارسال در یک تراکنش ثبت می‌شوند. worker سرور تا چهار گفتگو را مستقل پردازش می‌کند؛ خطای کشف مقصد و ری‌استارت، کار پذیرفته‌شده را از بین نمی‌برد. ترتیب صف مسیریابی همان گفتگو حفظ می‌شود و گفتگوی دیگر پشت مقصد کند نمی‌ماند. پذیرش سرور همچنان رسید تحویل به گوشی نیست.
- تازه‌سازی هم‌زمان توکن یکی شده است. درخواست پیام و تنظیم RTC، توکن ردشده را یک بار با اثبات تازهٔ دستگاه تکرار می‌کنند. رد قطعی به Failed می‌رود و متن رمز‌شده برای تلاش مجدد صریح باقی می‌ماند؛ دیگر نباید بی‌پایان Queued نمایش داده شود. نتیجهٔ دیررس تازه‌سازی پس از قفل/خروج، نشست را دوباره فعال نمی‌کند.
- یوزرنیم از نشانی واقعی حساب بازیابی می‌شود. نام، عکس PNG حداکثر ۲۵۶×۲۵۶ و رنگ با اثبات دستگاه روی سرور ذخیره و در پروفایل فدره امضا می‌شوند. نشانی حساب قابل تغییر از این API نیست. ویرایش آفلاین و عکس محلی نسخهٔ قبل حفظ می‌شود؛ پاسخ قدیمی ویرایش جدید را پاک نمی‌کند. **نام و عکس عمومی‌اند.**
- تنظیمات با کارت شیشه‌ای حساب، میان‌برها و ردیف‌های رنگی بازطراحی شده؛ وضعیت سینک/تلاش مجدد پروفایل، نام قابل ویرایش، عکس طرف مقابل در هدر/پروفایل و هم‌محوری دایره‌های + در هر دو جهت نوشتار اضافه شده‌اند.
- قفل اختیاری اندروید ۱۱ به بالا به کلید Keystore و احراز هویت سیستم متصل است. هنگام قفل، کلید بومی vault، کش پیام خوانا، صفحات/پیش‌نویس باز و توکن موقت کنار گذاشته می‌شوند؛ اسکرین‌شات بسته می‌شود. مهاجرت ذخیرهٔ امن با عملیات خواندن/نوشتن سریالی است و پس از قطع‌شدن می‌تواند ادامه یابد. این قابلیت مصونیت از memory dump یا نفوذ روی دستگاه روت‌شده نیست.
- TUI بخش Calls با ورودی مخفی secret، تنظیم TURN موجود، کنترل پیشنهادهای صوت/تصویر، بررسی آمادگی و بازگرداندن تنظیمات ناموفق دارد. Groups وضعیت واقعی نبود موتور اجرایی MLS را نشان می‌دهد؛ قابلیت گروهی ساخته‌شده محسوب نمی‌شود.

### نتیجهٔ آزمون و محدودیت

**تمام ۷۶ تست Node روی نسخهٔ 24.19.0 پاس شدند**؛ آزمون ثبت اتمی، صف پس از ری‌استارت، جدایی مقصد کند، پروفایل احرازشده و امضای عکس نیز داخل آن‌هاست. parser/formatter کد Dart بررسی شد و تست‌های رگرسیون کلاینت اضافه شدند، اما analyzer و تست Flutter، بیلد APK/Go، مهاجرت روی PostgreSQL زنده و آزمون واقعی Keystore در این محیط اجرا نشدند. این گزارش تأیید بیلد production با Node پین‌شدهٔ 22.16.0 نیست. روی سرورهای نصب‌شده تغییری اجرا نشده است.

هر دو گوشی و هر دو سرور باید به‌روز شوند. ارسال آنلاین/Nearby در هر دو جهت، بازگشت رسید، عکس پروفایل، قفل با رمز/بیومتریک، ری‌استارت و تماس از دو شبکهٔ متفاوت با TURN واقعی باید روی دستگاه آزموده شوند. **گروه MLS، تماس گروهی و رسید خواندن کاملاً آفلاین همچنان باقی‌اند.** رسید تحویل امضاشدهٔ Nearby و دروازهٔ مجاورتی قبلی حذف یا با رسید جعلی جایگزین نشده‌اند.
