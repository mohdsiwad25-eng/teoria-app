#!/bin/bash
# ===== TeoriaAI patch: تفعيل يدوي فوري + نسخ احتياطي يومي =====
set -e
cd /opt/teoria
cp server.js server.js.bak_patch1

# --- 1) التفعيل اليدوي: فوري دايماً، الرسالة كمالية ---
python3 << 'PY'
h=open("/opt/teoria/server.js",encoding="utf-8").read()
old = '''app.post("/siwad/api/add", guard, async (req,res)=>{
  try{
    const { name, phone } = req.body||{};
    if(!name||!phone) return res.json({ok:0, err:"الاسم والرقم مطلوبين"});
    if(waStatus!=="connected") return res.json({ok:0, err:"الواتساب مش متصل"});
    const jid = await resolveJid(phone);
    if(!jid) return res.json({ok:0, err:"الرقم مش على واتساب"});
    const token = crypto.randomBytes(24).toString("hex");
    const nm=String(name).trim().slice(0,40);
    db.prepare(`INSERT INTO students(name,phone,jid,active,token,created,last_seen)
      VALUES(?,?,?,1,?,?,NULL)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, jid=excluded.jid, active=1`)
      .run(nm, norm(phone), jid, token, Date.now());
    await sock.sendMessage(jid,{text:tmpl(getS("welcome_msg"),{name:nm})});
    ev("add","إضافة يدوية: "+nm); res.json({ok:1});
  }catch(e){ res.json({ok:0, err:"صار خطأ"}); }
});'''
new = '''app.post("/siwad/api/add", guard, async (req,res)=>{
  try{
    const { name, phone } = req.body||{};
    if(!name||!phone) return res.json({ok:0, err:"الاسم والرقم مطلوبين"});
    const nm=String(name).trim().slice(0,40);
    let jid=null;
    if(waStatus==="connected"){ try{ jid = await resolveJid(phone); }catch(e){} }
    if(!jid) jid = candidates(phone)[0]+"@s.whatsapp.net";
    const token = crypto.randomBytes(24).toString("hex");
    db.prepare(`INSERT INTO students(name,phone,jid,active,token,created,last_seen)
      VALUES(?,?,?,1,?,?,NULL)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, active=1`)
      .run(nm, norm(phone), jid, token, Date.now());
    ev("add","إضافة يدوية: "+nm+" ✅");
    let sent=0;
    if(waStatus==="connected"){
      try{ await sock.sendMessage(jid,{text:tmpl(getS("welcome_msg"),{name:nm})}); sent=1; }catch(e){}
    }
    res.json({ok:1, sent});
  }catch(e){ console.log(e); res.json({ok:0, err:"صار خطأ"}); }
});'''
assert old in h, "ADD BLOCK NOT FOUND — ABORT"
h=h.replace(old,new)

# رسالة الواجهة توضح
old2 = ''' $("#addMsg").textContent=r.ok?"انضاف واتفعّل ✅":(r.err||"غلط");'''
new2 = ''' $("#addMsg").textContent=r.ok?(r.sent?"انضاف واتفعّل ووصلته رسالة ✅":"انضاف واتفعّل ✅ (بيفوت فوراً — الرسالة ما انبعتت لأن الواتساب مقيّد)"):(r.err||"غلط");'''
assert old2 in h, "UI MSG NOT FOUND — ABORT"
h=h.replace(old2,new2)
open("/opt/teoria/server.js","w",encoding="utf-8").write(h)
print("patch applied")
PY

# --- تحقق قبل التشغيل ---
node --check /opt/teoria/server.js && echo "SYNTAX OK" || { echo "SYNTAX FAIL — restoring"; cp server.js.bak_patch1 server.js; exit 1; }
pm2 restart teoria --update-env
sleep 3

# --- 2) نسخ احتياطي يومي لقاعدة البيانات (7 نسخ دوّارة) ---
cat > /opt/teoria/backup-db.sh << 'BK'
#!/bin/bash
mkdir -p /opt/teoria/backups
cp /opt/teoria/data.db "/opt/teoria/backups/data-$(date +%u).db"
BK
chmod +x /opt/teoria/backup-db.sh
/opt/teoria/backup-db.sh
( crontab -l 2>/dev/null | grep -v backup-db ; echo "30 2 * * * /opt/teoria/backup-db.sh" ) | crontab -

echo ""
echo "=================== فحص ==================="
curl -s http://127.0.0.1:3000/siwad/api/state | head -c 30; echo ""
ls -la /opt/teoria/backups/
echo "============================================"
echo "✅ التفعيل اليدوي فوري + نسخ احتياطي يومي 2:30 فجراً (7 نسخ دوارة)"
