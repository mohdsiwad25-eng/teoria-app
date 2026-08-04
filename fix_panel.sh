#!/bin/bash
set -e
cd /opt/teoria
cp server.js server.js.bak_panelfix
echo "→ إصلاح جافاسكربت اللوحة..."
python3 /opt/teoria/fix_panel.py
node --check /opt/teoria/server.js || { echo "❌ صياغة"; cp server.js.bak_panelfix server.js; exit 1; }
echo "→ فحص قالب اللوحة نفسه..."
node -e "
const fs=require('fs');
const src=fs.readFileSync('/opt/teoria/server.js','utf8');
const i=src.indexOf('const PANEL_HTML = ');
const s=src.indexOf('\`', i); let k=s+1;
while(k<src.length){ if(src[k]==='\\\\'){k+=2;continue;} if(src[k]==='\`') break; k++; }
const html=eval(src.slice(s,k+1));
const a=html.lastIndexOf('<script>'), b=html.lastIndexOf('</script>');
fs.writeFileSync('/tmp/panel.js', html.slice(a+8,b));
" && node --check /tmp/panel.js && echo "   ✅ جافاسكربت اللوحة سليم" || { echo "   ❌ لسا مكسور"; cp server.js.bak_panelfix server.js; exit 1; }
pm2 restart teoria --update-env
sleep 3
echo "→ فحص:"
curl -s -o /dev/null -w "   /siwad → %{http_code}\n" http://127.0.0.1:3000/siwad
echo ""
echo "✅ افتح اللوحة من جديد (Cmd+Shift+R للتحديث القوي)"
