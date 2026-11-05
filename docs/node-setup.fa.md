# نصب Home Node لوم

**راهنمای مرجع فارسی:** تمام مراحل نصب، پیش‌نیازهای سرور، تنظیم دامنه و HTTPS،
انتخاب Caddy یا Nginx، پورت‌ها، تنظیم تماس‌ها، میرورهای Liara و Arvan برای
سرورهای ایران، محدودیت دسترسی GitHub/GHCR و دستورهای آمادهٔ کپی‌و‌اجرا در
انتهای README اصلی قرار دارد:

[مشاهدهٔ راهنمای کامل فارسی راه‌اندازی Home Node](../README.md#persian-home-node-guide)

## نصب معمولی

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh
```

## نصب با میرورهای ایران

لیارا:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh --downloads liara
```

آروان:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/0800x/Loom/main/install.sh \
  -o /tmp/loom-install.sh &&
bash /tmp/loom-install.sh --downloads arvan
```

**محدودیت مهم:** این میرورها همهٔ ترافیک نصب را عبور نمی‌دهند. ایمیج‌های
اختصاصی Loom از GitHub Container Registry و سورس نصب از GitHub دریافت
می‌شوند. اگر دسترسی به این دو سرویس برقرار نباشد، انتخاب Liara یا Arvan
به‌تنهایی نصب را کامل نمی‌کند. این روش نصب آفلاین یا VPN عمومی نیست.

برای مدیریت روزانه، [راهنمای Node Manager](node-manager.md) را ببینید.
برای انتقال و بازیابی، [راهنمای آپدیت و انتقال آفلاین](loom-node-update-and-offline.md)
را مطالعه کنید.