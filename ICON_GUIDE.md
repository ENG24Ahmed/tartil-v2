# دليل أيقونة التطبيق (حجم الملفات وأين تضعها)

## ✅ المسار الجاهز لأيقونة 512×512

**ضع الأيقونة (512×512) هنا بالاسم التالي:**

```
المشروع/quran_app/assets/icon/app_icon.png
```

أي: انسخ ملف الأيقونة الذي حمّلته إلى مجلد **`assets/icon/`** داخل المشروع، وغيّر اسمه إلى **`app_icon.png`**.

بعد ذلك شغّل في الطرفية:
```bash
flutter pub get
dart run flutter_launcher_icons
```
سيتم توليد كل الأحجام (أندرويد، iOS، ويب، Windows، macOS) تلقائياً.

---

## ملخص سريع (مرجع)

| المنصة   | المسار (بدءاً من مجلد المشروع) | الأحجام المطلوبة |
|----------|--------------------------------|-------------------|
| **ويب**  | `web/` و `web/icons/`          | 192، 512، favicon |
| **أندرويد** | `android/app/src/main/res/mipmap-***/` | 48، 72، 96، 144، 192 |
| **iOS**  | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` | عدة أحجام |

---

## 1) الويب (Web)

- **أيقونة التبويب (Favicon)**  
  - **المسار:** `web/favicon.png`  
  - **الحجم:** **32×32** أو **16×16** (يفضّل 32×32).

- **أيقونات PWA / Apple Touch**  
  - **المسار:** داخل مجلد `web/icons/`  
  - **الأحجام:**
    - `Icon-192.png` → **192×192** بكسل  
    - `Icon-512.png` → **512×512** بكسل  
    - (اختياري) `Icon-maskable-192.png` و `Icon-maskable-512.png` بنفس الأحجام للـ maskable.

---

## 2) أندرويد (Android)

الأيقونة الرئيسية للتطبيق تُسمّى عادةً `ic_launcher.png` وتوضع في مجلدات الكثافة التالية (كل ملف في مجلده):

| المجلد              | الحجم بالملمتر | الحجم بالبكسل (تقريبي) |
|---------------------|----------------|-------------------------|
| `mipmap-mdpi/`      | 48×48          | **48×48**               |
| `mipmap-hdpi/`      | 72×72          | **72×72**               |
| `mipmap-xhdpi/`     | 96×96          | **96×96**               |
| `mipmap-xxhdpi/`    | 144×144        | **144×144**             |
| `mipmap-xxxhdpi/`   | 192×192        | **192×192**             |

**المسار الكامل من جذر المشروع:**
```
android/app/src/main/res/mipmap-mdpi/ic_launcher.png
android/app/src/main/res/mipmap-hdpi/ic_launcher.png
android/app/src/main/res/mipmap-xhdpi/ic_launcher.png
android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
```

يمكنك البدء بصورة واحدة كبيرة **1024×1024** ثم تصغيرها لهذه الأحجام (يدوياً أو بأداة مثل [flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)).

---

## 3) iOS

الأيقونة توضع في:
```
ios/Runner/Assets.xcassets/AppIcon.appiconset/
```

الأحجام الشائعة (بالبكسل): 20، 29، 40، 60، 76، 83.5، 1024 (للمتجر). يمكن أيضاً استخدام أداة `flutter_launcher_icons` لتوليدها من صورة واحدة (مثلاً 1024×1024).

---

## التوصية العملية

1. **صورة أساسية واحدة:** أنشئ أيقونة بحجم **1024×1024** بكسل (خلفية مربعة، بدون شفافية لأندرويد).
2. **الويب فقط (سريع):**  
   - ضع `favicon.png` (32×32) في `web/`.  
   - ضع `Icon-192.png` و `Icon-512.png` في `web/icons/`.
3. **كل المنصات:** استخدم الحزمة `flutter_launcher_icons` في `pubspec.yaml` وضبط المسارات بحيث تشير إلى صورة الـ 1024×1024، ثم تشغيل الأمر لتوليد كل الأحجام تلقائياً.

إذا حددت المنصة التي تريد البدء بها (ويب / أندرويد / iOS) يمكن توضيح الخطوات بدقة أكبر لتلك المنصة فقط.
