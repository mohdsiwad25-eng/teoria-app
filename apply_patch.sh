#!/bin/bash
# ===== TeoriaAI — إضافة ميزة معاملة الفحص الطبي =====
set -e
cd /opt/teoria
echo "→ نسخة احتياطية..."
cp server.js server.js.bak_apply
cp data.db data.db.bak_apply 2>/dev/null || true

echo "→ تطبيق الباتش..."
python3 /opt/teoria/patch_app.py

echo "→ فحص الصياغة..."
if node --check /opt/teoria/server.js; then
  echo "   ✅ الصياغة سليمة"
else
  echo "   ❌ فشل — استرجاع النسخة القديمة"
  cp server.js.bak_apply server.js
  exit 1
fi

echo "→ إعادة التشغيل..."
pm2 restart teoria --update-env
sleep 4

echo "→ فحص التشغيل..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/siwad)
if [ "$CODE" = "200" ]; then
  echo "   ✅ السيرفر شغال ($CODE)"
else
  echo "   ❌ السيرفر ما رد ($CODE) — استرجاع"
  cp server.js.bak_apply server.js
  pm2 restart teoria --update-env
  exit 1
fi

echo "→ فحص الجدول..."
node -e "const D=require('better-sqlite3')('/opt/teoria/data.db');
const t=D.prepare(\"SELECT name FROM sqlite_master WHERE type='table' AND name='applications'\").get();
console.log(t? '   ✅ جدول applications موجود' : '   ❌ الجدول مفقود');"

echo ""
echo "══════════════════════════════════════"
echo "✅ تمت الإضافة — افتح /siwad وبتلاقي تبويب 📄 المعاملات"
echo "══════════════════════════════════════"
