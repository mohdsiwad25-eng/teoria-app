#!/bin/bash
# ===== TeoriaAI — إدارة الملفات والنسخ الاحتياطي (وداعاً جيت هَب) =====
set -e
cd /opt/teoria
echo "→ نسخة احتياطية..."
cp server.js server.js.bak_files
cp data.db data.db.bak_files 2>/dev/null || true

echo "→ تطبيق الباتش..."
python3 /opt/teoria/patch_files.py

echo "→ فحص صياغة السيرفر..."
node --check /opt/teoria/server.js || { echo "❌ فشل"; cp server.js.bak_files server.js; exit 1; }

echo "→ فحص جافاسكربت اللوحة نفسه..."
node -e "
const fs=require('fs');
const src=fs.readFileSync('/opt/teoria/server.js','utf8');
const i=src.indexOf('const PANEL_HTML = ');
const s=src.indexOf('\`', i); let k=s+1;
while(k<src.length){ if(src[k]==='\\\\'){k+=2;continue;} if(src[k]==='\`') break; k++; }
const html=eval(src.slice(s,k+1));
const a=html.lastIndexOf('<script>'), b=html.lastIndexOf('</script>');
fs.writeFileSync('/tmp/panel2.js', html.slice(a+8,b));
" && node --check /tmp/panel2.js || { echo "❌ جافاسكربت اللوحة مكسور"; cp server.js.bak_files server.js; exit 1; }
echo "   ✅ اللوحة سليمة"

echo "→ صلاحيات مجلد الموقع..."
chown -R root:root /var/www/teoria 2>/dev/null || true
mkdir -p /opt/teoria/backups

echo "→ إعادة التشغيل..."
pm2 restart teoria --update-env
sleep 4

CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/siwad)
[ "$CODE" = "200" ] || { echo "❌ السيرفر ما رد ($CODE)"; cp server.js.bak_files server.js; pm2 restart teoria --update-env; exit 1; }
echo "   ✅ السيرفر شغال"

echo "→ اختبار النسخة الاحتياطية..."
node -e "
process.env.NODE_NO_WARNINGS=1;
const {execSync}=require('child_process');
const fs=require('fs');
try{
  execSync('tar -czf /tmp/test-bak.tar.gz -C /var/www teoria 2>/dev/null');
  const sz=fs.statSync('/tmp/test-bak.tar.gz').size;
  console.log('   ✅ النسخ يشتغل — حجم تجريبي:', Math.round(sz/1024)+'KB');
  fs.unlinkSync('/tmp/test-bak.tar.gz');
}catch(e){ console.log('   ⚠️ تحذير:', e.message); }
"
echo ""
echo "════════════════════════════════════════════"
echo "✅ خلص! افتح /siwad ← تبويب 📤 الملفات"
echo "   • ارفع أي ملف مباشرة من جهازك"
echo "   • نزّل نسخة احتياطية كاملة بكبسة"
echo "   • استرجع أي ملف من النسخ السابقة"
echo "════════════════════════════════════════════"
