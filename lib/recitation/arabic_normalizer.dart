class ArabicNormalizer {
  ArabicNormalizer._();

  static final RegExp _quranicMarks = RegExp(
    r'[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u08D4-\u08FF\u0640]',
  );

  static final RegExp _nonArabicLettersOrDigits = RegExp(
    r'[^\u0621-\u064A\u0660-\u06690-9\s]',
  );

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _repeatedAlef = RegExp(r'ا{2,}');
  static final RegExp _repeatedLetter = RegExp(r'(.)\1+');
  static final RegExp _weakLetters = RegExp(r'[اويء]');

  static String normalizeBasic(String text) {
    var value = text.trim();
    if (value.isEmpty) return '';

    value = value.replaceAll(_quranicMarks, '');
    value = value
        .replaceAll('ٱ', 'ا')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');

    value = value.replaceAll(_nonArabicLettersOrDigits, ' ');
    value = value.replaceAll(_whitespace, ' ').trim();
    return value;
  }

  static String normalizeForSearch(String text) {
    var value = normalizeBasic(text);
    if (value.isEmpty) return '';

    // ASR often spells harf-by-harfi as words (e.g. «ألف لام ميم») while
    // `search_text` in the recitation DB is the joined rasm (e.g. «الم»).
    value = _expandHijaiLetterNameTokens(value);

    value = value
        .replaceAll('ؤ', 'و')
        .replaceAll('ئ', 'ي')
        .replaceAll('ء', '')
        .replaceAll(_repeatedAlef, 'ا');

    value = _collapseConsecutiveSingleHijaiRun(value);
    // ASR (خصوصًا العربية) يخلط الضاد والظاء؛ نوحّد إلى الضاد لكل مسارات البحث والمطابقة.
    value = value.replaceAll('ظ', 'ض');
    value = value.replaceAll(_whitespace, ' ').trim();
    return value;
  }

  /// Spoken / educational names of isolated letters → single harf, after
  /// [normalizeBasic] has unified alif etc.
  static const List<(String, String)> _hijaiNamePairs = [
    ('ألف', 'ا'),
    ('باء', 'ب'),
    ('تاء', 'ت'),
    ('ثاء', 'ث'),
    ('جيم', 'ج'),
    ('حاء', 'ح'),
    ('خاء', 'خ'),
    ('دال', 'د'),
    ('ذال', 'ذ'),
    ('راء', 'ر'),
    ('زاء', 'ز'),
    ('سين', 'س'),
    ('شين', 'ش'),
    ('صاد', 'ص'),
    ('ضاد', 'ض'),
    ('طاء', 'ط'),
    ('ظاء', 'ظ'),
    ('عين', 'ع'),
    ('غين', 'غ'),
    ('فاء', 'ف'),
    ('قاف', 'ق'),
    ('كاف', 'ك'),
    ('لام', 'ل'),
    ('ميم', 'م'),
    ('نون', 'ن'),
    ('هاء', 'ه'),
    ('واو', 'و'),
    ('ياء', 'ي'),
  ];

  static final Map<String, String> _hijaiNameToHarf = () {
    final m = <String, String>{};
    for (final (name, harf) in _hijaiNamePairs) {
      final k = normalizeBasic(name);
      if (k.isNotEmpty) {
        m[k] = harf;
      }
    }
    return m;
  }();

  static String _expandHijaiLetterNameTokens(String value) {
    final parts = value.split(' ').where((p) => p.isNotEmpty);
    final out = <String>[];
    for (final t in parts) {
      out.add(_hijaiNameToHarf[t] ?? t);
    }
    return out.join(' ');
  }

  static bool _isSingleHijaiLetterToken(String t) {
    if (t.length != 1) return false;
    final c = t.codeUnitAt(0);
    if (c < 0x621 || c > 0x64A) return false;
    if (c == 0x640) return false; // kashida
    return true;
  }

  /// e.g. «ا ل م» → «الم» so it matches the mushaf/DB (muqatta'at, طه, يس, …).
  static String _collapseConsecutiveSingleHijaiRun(String value) {
    final parts = value.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) {
      return value;
    }
    final out = <String>[];
    var buf = <String>[];
    void flush() {
      if (buf.isEmpty) return;
      if (buf.length >= 2) {
        out.add(buf.join());
      } else {
        out.addAll(buf);
      }
      buf = [];
    }

    for (final t in parts) {
      if (_isSingleHijaiLetterToken(t)) {
        buf.add(t);
      } else {
        flush();
        out.add(t);
      }
    }
    flush();
    return out.join(' ');
  }

  /// Builds tolerant forms for one token to absorb common ASR/Quran orthography
  /// variations (hamza chairs, alif runs, weak letters, and shadda-like doubling).
  static Set<String> tokenMatchForms(String token) {
    final forms = <String>{};

    void addForm(String value) {
      final compact = value.replaceAll(_whitespace, '').trim();
      if (compact.isNotEmpty) {
        forms.add(compact);
      }
    }

    final basic = normalizeBasic(token);
    final search = normalizeForSearch(token);
    addForm(basic);
    addForm(search);

    final hamzaUnified = basic.replaceAll('ؤ', 'ء').replaceAll('ئ', 'ء');
    addForm(hamzaUnified);
    addForm(hamzaUnified.replaceAll('ء', ''));
    addForm(hamzaUnified.replaceAll('ء', 'ا'));

    for (final form in List<String>.from(forms)) {
      addForm(form.replaceAll(_repeatedAlef, 'ا'));
      addForm(_collapseRepeatedLetters(form));
    }

    for (final form in List<String>.from(forms)) {
      final weakStripped = _collapseRepeatedLetters(
        form.replaceAll(_weakLetters, ''),
      );
      if (weakStripped.length >= 2) {
        addForm(weakStripped);
      }
    }

    // Frequent ASR drift around the Divine Name, e.g. "الاه", "االه".
    for (final form in List<String>.from(forms)) {
      if (_looksLikeAllahVariant(form)) {
        addForm('الله');
        addForm('الاه');
        addForm('اله');
        addForm('لله');
        addForm('له');
      }
    }

    // Rasm the ASR often mishears; extend *expected* token forms (pairwise match).
    for (final form in List<String>.from(forms)) {
      final drifts = _rasmToCommonAsrDrift[form];
      if (drifts == null) {
        continue;
      }
      for (final alt in drifts) {
        addForm(alt);
        addForm(normalizeForSearch(alt));
      }
    }

    // ض / ظ: التعرف الصوتي يخلطهما كثيرًا؛ نعاملهما كسطح واحد للمطابقة.
    for (final form in List<String>.from(forms)) {
      addForm(_unifyDadZahForMatch(form));
    }

    return forms;
  }

  /// يوحّد الظّ إلى الضّ حتى تتطابق أشكال التوازن مع أشكال الخطأ الصوتي.
  static String _unifyDadZahForMatch(String s) => s.replaceAll('ظ', 'ض');

  /// Extra spoken-like compact forms (after the usual normalization cycle).
  ///
  /// [الحروف المقطعة]: ١٤ تركيبًا في ٢٩ سورة (المصحف)، وفق القوائم المعتمدة في
  /// المراجع العلمية مثل [ويكيبيديا: Muqattaʿat](https://en.wikipedia.org/wiki/Muqatta%CA%BFat)
  /// والجداول المختصرة في التفاسير.
  static const Map<String, List<String>> _rasmToCommonAsrDrift = {
    'مدهامتان': [
      'مدهامه',
      'مدهاما',
      'مدهام',
      'مدههامتان',
      'مدههامتن',
      'مدهماتان',
      'مدهماتا',
    ],
    // الم — البقرة، آل عمران، العنكبوت، الروم، لقمان، السجدة
    'الم': [
      'الام',
      'اللم',
      'الما',
      'المم',
      'الفلامميم',
      'الفلام ميم',
      'الف لام ميم',
      'الفلام',
      'اللميم',
    ],
    // الر — يونس، هود، يوسف، إبراهيم، الحجر
    'الر': [
      'الز',
      'الزر',
      'الف لام راء',
      'الفلامراء',
      'الفلام راء',
      'اللر',
      'الرا',
    ],
    // المر — الرعد
    'المر': [
      'الامر',
      'الف لام ميم راء',
      'الفلامميمراء',
      'الم ر',
      'المرر',
    ],
    // المص — الأعراف
    'المص': [
      'الامص',
      'المصص',
      'الف لام ميم صاد',
      'الفلامميمصاد',
      'المصاد',
    ],
    // كهيعص — مريم
    'كهيعص': [
      'كهيعض',
      'كهياعص',
      'كهيعصص',
      'كاهيعص',
      'كاف هاء ياء عين صاد',
      'كهيع',
      'كهيعصاد',
    ],
    // طه — طه
    'طه': [
      'طها',
      'طاه',
      'طاها',
      'طا هاء',
      'طاء هاء',
      'طهه',
      'طهاه',
    ],
    // طسم — الشعراء، القصص
    'طسم': [
      'طصم',
      'طاسميم',
      'طا سين ميم',
      'طاس ميم',
      'طسمم',
      'طس ميم',
    ],
    // طس — النمل
    'طس': [
      'طص',
      'طاسين',
      'طا سين',
      'طسس',
    ],
    // يس — يس
    'يس': [
      'يص',
      'ياسين',
      'يا سين',
      'ياس',
      'يسس',
    ],
    // حم — غافر، فصلت، الزخرف، الدخان، الجاثية، الأحقاف
    'حم': [
      'حام',
      'حاميم',
      'حا ميم',
      'حاء ميم',
      'حمم',
      'هام',
      'ها ميم',
    ],
    // حمعسق — الشورى
    'حمعسق': [
      'حمعسك',
      'حامعينسينقاف',
      'حمعسقي',
      'حمعسقق',
      'حمعس',
      'حمعينقاف',
    ],
    // ص — ص
    'ص': [
      'صاد',
      'صا',
      'صص',
      'ساد',
    ],
    // ق — ق
    'ق': [
      'قاف',
      'قا',
      'قق',
      'ك',
    ],
    // ن — نون والقلم
    'ن': [
      'نون',
      'نا',
      'نن',
    ],
  };

  static String _collapseRepeatedLetters(String value) {
    return value.replaceAllMapped(_repeatedLetter, (match) => match.group(1)!);
  }

  static bool _looksLikeAllahVariant(String token) {
    final noHamza = token.replaceAll(RegExp(r'[ءؤئ]'), '');
    return RegExp(r'^ا?ل{1,2}ا?ه$').hasMatch(noHamza);
  }
}
