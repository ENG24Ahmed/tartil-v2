-- ============================================================
-- استعلامات جاهزة للاستخدام (نسخ الآية) — الملف: quran-data.sqlite
-- ============================================================

-- 1) جلب (word_number_all -> سورة، آية) لنطاق كلمات (لربط موضع الضغط بالآية)
SELECT word_number_all, surah_number, ayah_number
FROM words
WHERE word_number_all >= ? AND word_number_all <= ?
ORDER BY word_number_all ASC;


-- 2) جلب نص الآية كاملة من عمود uthmani (للعرض والنسخ)
SELECT uthmani
FROM words
WHERE surah_number = ? AND ayah_number = ?
ORDER BY word_number ASC;
