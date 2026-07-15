#!/bin/bash
# ===== تجهيز نظام تسجيل وتفعيل التوريا — تشغيل مرة واحدة =====
set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/teoria && cd /opt/teoria
apt install -y build-essential python3 >/dev/null 2>&1 || true

cat > package.json << 'EOF'
{
  "name": "teoria-auth",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "@whiskeysockets/baileys": "^6.7.9",
    "better-sqlite3": "^11.3.0",
    "express": "^4.19.2",
    "pino": "^9.4.0",
    "qrcode": "^1.5.4"
  }
}
EOF

echo ">>> تنزيل الحزم (٢-٣ دقائق)..."
npm install --no-audit --no-fund

cat > server.js << 'EOF'
const express = require("express");
const crypto = require("crypto");
const Database = require("better-sqlite3");
const QR = require("qrcode");
const pino = require("pino");
const { default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion, DisconnectReason } = require("@whiskeysockets/baileys");

const PORT = 3000;
const ADMIN_PASS = process.env.ADMIN_PASS || "changeme";
const db = new Database("/opt/teoria/data.db");
db.exec(`CREATE TABLE IF NOT EXISTS students(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT, phone TEXT UNIQUE, jid TEXT,
  code TEXT, code_exp INTEGER, attempts INTEGER DEFAULT 0,
  active INTEGER DEFAULT 0, token TEXT,
  created INTEGER, last_seen INTEGER)`);

let sock=null, qrData=null, waStatus="starting";
async function startWA(){
  const { state, saveCreds } = await useMultiFileAuthState("/opt/teoria/wa_auth");
  const { version } = await fetchLatestBaileysVersion();
  sock = makeWASocket({ version, auth: state, logger: pino({level:"silent"}) });
  sock.ev.on("creds.update", saveCreds);
  sock.ev.on("connection.update", async (u)=>{
    const { connection, lastDisconnect, qr } = u;
    if(qr){ qrData = await QR.toDataURL(qr); waStatus="qr"; }
    if(connection==="open"){ qrData=null; waStatus="connected"; console.log("WA connected"); }
    if(connection==="close"){
      waStatus="disconnected";
      const code = lastDisconnect?.error?.output?.statusCode;
      if(code !== DisconnectReason.loggedOut){ setTimeout(startWA, 3000); }
      else { waStatus="logged_out"; console.log("WA logged out - delete /opt/teoria/wa_auth and restart"); }
    }
  });
}
startWA();

function candidates(raw){
  let p = String(raw||"").replace(/\D/g,"");
  if(p.startsWith("00")) p = p.slice(2);
  if(p.startsWith("970")||p.startsWith("972")) return [p, (p.startsWith("970")?"972":"970")+p.slice(3)];
  if(p.startsWith("0")) p = p.slice(1);
  return ["970"+p, "972"+p];
}
async function resolveJid(raw){
  for(const c of candidates(raw)){
    try{ const r = await sock.onWhatsApp(c+"@s.whatsapp.net");
      if(r && r[0] && r[0].exists) return r[0].jid; }catch(e){}
  }
  return null;
}
const norm = raw => candidates(raw)[0].slice(3);

const app = express();
app.use(express.json());
app.use((req,res,next)=>{ res.setHeader("Access-Control-Allow-Origin","*");
  res.setHeader("Access-Control-Allow-Headers","Content-Type");
  if(req.method==="OPTIONS") return res.end(); next(); });

const rate = {};
app.post("/api/register", async (req,res)=>{
  try{
    const { name, phone } = req.body||{};
    if(!name || String(name).trim().length<2) return res.json({ok:0, err:"اكتب اسمك"});
    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة التفعيل مش جاهزة حالياً — جرب بعد شوي"});
    const key = norm(phone);
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});
    const jid = await resolveJid(phone);
    if(!jid) return res.json({ok:0, err:"الرقم مش مسجل على واتساب — تأكد منه"});
    const code = String(Math.floor(100000+Math.random()*900000));
    const now = Date.now();
    db.prepare(`INSERT INTO students(name,phone,jid,code,code_exp,attempts,created)
      VALUES(?,?,?,?,?,0,?)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, jid=excluded.jid,
      code=excluded.code, code_exp=excluded.code_exp, attempts=0`)
      .run(String(name).trim().slice(0,40), key, jid, code, now+15*60e3, now);
    await sock.sendMessage(jid, { text:
"مرحبا "+String(name).trim()+" \u{1F44B}\nكود تفعيل تطبيق التوريا:\n\n*"+code+"*\n\nالكود صالح لمدة 15 دقيقة." });
    rate[key].push(Date.now());
    res.json({ok:1});
  }catch(e){ console.log(e); res.json({ok:0, err:"صار خطأ — جرب كمان مرة"}); }
});

app.post("/api/verify",(req,res)=>{
  const { phone, code } = req.body||{};
  const s = db.prepare("SELECT * FROM students WHERE phone=?").get(norm(phone||""));
  if(!s) return res.json({ok:0, err:"سجّل أول"});
  if(s.attempts>=6) return res.json({ok:0, err:"محاولات كثيرة — سجّل من جديد"});
  db.prepare("UPDATE students SET attempts=attempts+1 WHERE id=?").run(s.id);
  if(!s.code || Date.now()>s.code_exp) return res.json({ok:0, err:"الكود انتهى — سجّل من جديد"});
  if(String(code).trim()!==s.code) return res.json({ok:0, err:"الكود غلط"});
  const token = crypto.randomBytes(24).toString("hex");
  db.prepare("UPDATE students SET active=1, token=?, code=NULL, last_seen=? WHERE id=?")
    .run(token, Date.now(), s.id);
  res.json({ok:1, token});
});

app.post("/api/check",(req,res)=>{
  const { phone, token } = req.body||{};
  const s = db.prepare("SELECT * FROM students WHERE phone=? AND token=?").get(norm(phone||""), String(token||""));
  if(!s) return res.json({ok:0});
  db.prepare("UPDATE students SET last_seen=? WHERE id=?").run(Date.now(), s.id);
  res.json({ok: s.active?1:0, name:s.name});
});

function admin(req,res,next){ if((req.query.pass||req.headers["x-admin"])===ADMIN_PASS) return next(); res.status(401).send("unauthorized"); }
app.get("/api/admin/state", admin, (req,res)=>{
  res.json({ wa:waStatus, qr:qrData,
    students: db.prepare("SELECT id,name,phone,active,created,last_seen FROM students ORDER BY id DESC").all() });
});
app.post("/api/admin/toggle", admin, (req,res)=>{
  db.prepare("UPDATE students SET active = 1-active WHERE id=?").run(req.body.id);
  res.json({ok:1});
});
app.get("/admin", admin, (req,res)=>{
  res.send('<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf8">'+
'<meta name="viewport" content="width=device-width,initial-scale=1">'+
'<title>إدارة التوريا</title><style>'+
'body{font-family:system-ui;background:#EEF1F4;margin:0;padding:16px;color:#171B21}'+
'h2{margin:6px 0 14px}.box{background:#fff;border-radius:14px;padding:14px;margin-bottom:14px;border:1px solid #e2e6eb}'+
'table{width:100%;border-collapse:collapse;font-size:14px}td,th{padding:9px 6px;border-bottom:1px solid #eee;text-align:right}'+
'.on{color:#178A50;font-weight:800}.off{color:#D6273B;font-weight:800}'+
'button{font-family:inherit;border:none;border-radius:9px;padding:7px 14px;font-weight:800;cursor:pointer}'+
'.act{background:#178A50;color:#fff}.deact{background:#D6273B;color:#fff}'+
'.wa a{background:#1f8a55;color:#fff;text-decoration:none;padding:6px 10px;border-radius:8px;font-size:12.5px}'+
'#qr img{width:230px}.st{font-weight:800}</style></head><body>'+
'<h2>\u{1F6E0} لوحة إدارة التوريا</h2>'+
'<div class="box"><div class="st">واتساب: <span id="wa">...</span></div><div id="qr"></div></div>'+
'<div class="box"><table id="tb"></table></div>'+
'<script>'+
'const PASS=new URLSearchParams(location.search).get("pass");'+
'function ago(t){if(!t)return "-";const m=Math.floor((Date.now()-t)/60000);'+
'return m<1?"هلأ":m<60?m+" د":m<1440?Math.floor(m/60)+" س":Math.floor(m/1440)+" يوم";}'+
'async function load(){'+
'const r=await fetch("/api/admin/state?pass="+PASS); const d=await r.json();'+
'document.getElementById("wa").textContent={connected:"متصل \u2705",qr:"امسح الكود \u{1F447}",disconnected:"منقطع… بيعيد الاتصال",starting:"جاري التشغيل…",logged_out:"مسجّل خروج \u274C"}[d.wa]||d.wa;'+
'document.getElementById("qr").innerHTML=d.qr?String.fromCharCode(60)+"img src=\\""+d.qr+"\\">":"";'+
'const tb=document.getElementById("tb");'+
'tb.innerHTML="<tr><th>الاسم</th><th>الرقم</th><th>الحالة</th><th>آخر ظهور</th><th></th><th></th></tr>"+'+
'd.students.map(s=>"<tr><td>"+s.name+"</td><td dir=ltr>0"+s.phone+"</td>"+'+
'"<td class="+(s.active?"on":"off")+">"+(s.active?"مفعّل":"موقوف")+"</td>"+'+
'"<td>"+ago(s.last_seen)+"</td>"+'+
'"<td><button class="+(s.active?"deact":"act")+" onclick=tg("+s.id+")>"+(s.active?"أوقف":"فعّل")+"</button></td>"+'+
'"<td class=wa><a target=_blank href=https://wa.me/972"+s.phone+">واتساب</a></td></tr>").join("");'+
'}'+
'async function tg(id){await fetch("/api/admin/toggle?pass="+PASS,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({id})});load();}'+
'load(); setInterval(load,5000);'+
'</script></body></html>');
});

app.listen(PORT, ()=>console.log("API on :"+PORT));
EOF

echo ">>> تشغيل الخدمة..."
cd /opt/teoria
ADMIN_PASS="${ADMIN_PASS:-Teoria2026Admin}" pm2 start server.js --name teoria --update-env || pm2 restart teoria --update-env
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
sleep 3
pm2 logs teoria --lines 5 --nostream || true
echo ""
echo "============================================"
echo "  خلص! افتح لوحة الإدارة من المتصفح:"
echo "  http://46.101.218.242:3000/admin?pass=Teoria2026Admin"
echo "============================================"
