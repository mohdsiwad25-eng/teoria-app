#!/bin/bash
# ===== TeoriaAI — إصلاح التسجيل بدون واتساب =====
set -e
cd /opt/teoria
echo "→ نسخة احتياطية..."
cp server.js server.js.bak_reg
cp data.db data.db.bak_reg 2>/dev/null || true

echo "→ تطبيق الباتش..."
python3 /opt/teoria/patch_reg.py

echo "→ فحص الصياغة..."
if node --check /opt/teoria/server.js; then
  echo "   ✅ سليم"
else
  echo "   ❌ فشل — استرجاع"; cp server.js.bak_reg server.js; exit 1
fi

echo "→ إعادة التشغيل..."
pm2 restart teoria --update-env
sleep 4

CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/siwad)
if [ "$CODE" = "200" ]; then
  echo "   ✅ السيرفر شغال"
else
  echo "   ❌ ما رد ($CODE) — استرجاع"; cp server.js.bak_reg server.js; pm2 restart teoria --update-env; exit 1
fi

echo "→ اختبار تسجيل فعلي (رقم تجريبي)..."
R=$(curl -s -X POST http://127.0.0.1:3000/api/enter -H "Content-Type: application/json" \
  -d '{"name":"اختبار النظام","phone":"0599000111"}')
echo "   الرد: $R"
node -e "
const D=require('better-sqlite3')('/opt/teoria/data.db');
const s=D.prepare('SELECT name,phone,active FROM students WHERE phone=?').get('599000111');
if(s){ console.log('   ✅ انحفظ باللوحة:', s.name, '| مفعّل:', s.active);
       D.prepare('DELETE FROM students WHERE phone=?').run('599000111');
       console.log('   🧹 حذفنا التجربة'); }
else { console.log('   ❌ ما انحفظ!'); process.exit(1); }
"
echo ""
echo "════════════════════════════════════════"
echo "✅ التسجيل صار يشتغل حتى والواتساب مفصول"
echo "   الطلاب بيبينوا باللوحة وبتفعّلهم بكبسة"
echo "════════════════════════════════════════"
