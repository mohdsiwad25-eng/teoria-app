#!/bin/bash
set -e
echo ">>> نسخة احتياطية..."
cp /opt/teoria/server.js /opt/teoria/server.js.bak 2>/dev/null || true
cp /opt/teoria/data.db /opt/teoria/data.db.bak 2>/dev/null || true
echo ">>> تركيب النظام..."
cat > /opt/teoria/server.js << 'TEOSRV_EOF'
// ================= TeoriaAI — نظام التفعيل + لوحة القيادة /siwad =================
const express = require("express");
const crypto = require("crypto");
const os = require("os");
const { execSync } = require("child_process");
const Database = require("better-sqlite3");
const QR = require("qrcode");
const pino = require("pino");
const { default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion, DisconnectReason } = require("@whiskeysockets/baileys");

const PORT = 3000;
const SALT = "teoriaai-panel-v1";
const SEED_HASH = "3f65043227221d939f5f4319eefca85d52b6bee5cb9d31d0fc07807d7f93bd53";
const db = new Database("/opt/teoria/data.db");

db.exec(`CREATE TABLE IF NOT EXISTS students(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT, phone TEXT UNIQUE, jid TEXT,
  code TEXT, code_exp INTEGER, attempts INTEGER DEFAULT 0,
  active INTEGER DEFAULT 0, token TEXT,
  created INTEGER, last_seen INTEGER);
CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, created INTEGER);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, t INTEGER, type TEXT, txt TEXT);
CREATE TABLE IF NOT EXISTS progress(id INTEGER PRIMARY KEY AUTOINCREMENT, phone TEXT, t INTEGER, correct INTEGER, total INTEGER, mode TEXT);`);
try{ db.exec("ALTER TABLE students ADD COLUMN banned INTEGER DEFAULT 0"); }catch(e){}

const getS = k => { const r = db.prepare("SELECT v FROM settings WHERE k=?").get(k); return r ? r.v : null; };
const setS = (k,v) => db.prepare("INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(k,String(v));
if(!getS("pass_hash")) setS("pass_hash", SEED_HASH);
if(!getS("reg_open")) setS("reg_open","1");
if(!getS("code_msg")) setS("code_msg","مرحبا {name} 👋\nكود تفعيل تطبيق TeoriaAI:\n\n*{code}*\n\nالكود صالح لمدة 15 دقيقة.");
if(!getS("welcome_msg")) setS("welcome_msg","أهلا {name} 🎉\nتم تفعيل حسابك بتطبيق TeoriaAI بنجاح.\nبالتوفيق بالتوريا! 🚗\nhttps://teoriaai.com");
const ev = (type,txt)=>{ db.prepare("INSERT INTO events(t,type,txt) VALUES(?,?,?)").run(Date.now(),type,txt);
  db.prepare("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 200)").run(); };
const hashPw = p => crypto.pbkdf2Sync(String(p), SALT, 100000, 32, "sha256").toString("hex");

// ================= واتساب =================
let sock=null, qrData=null, waStatus="starting";
async function startWA(){
  const { state, saveCreds } = await useMultiFileAuthState("/opt/teoria/wa_auth");
  const { version } = await fetchLatestBaileysVersion();
  sock = makeWASocket({ version, auth: state, logger: pino({level:"silent"}) });
  sock.ev.on("creds.update", saveCreds);
  sock.ev.on("connection.update", async (u)=>{
    const { connection, lastDisconnect, qr } = u;
    if(qr){ qrData = await QR.toDataURL(qr); waStatus="qr"; }
    if(connection==="open"){ qrData=null; waStatus="connected"; ev("wa","اتصل الواتساب ✅"); }
    if(connection==="close"){
      waStatus="disconnected";
      const code = lastDisconnect?.error?.output?.statusCode;
      if(code !== DisconnectReason.loggedOut){ setTimeout(startWA, 3000); }
      else { waStatus="logged_out"; ev("wa","انفصل الواتساب — لازم إعادة ربط"); }
    }
  });
}
startWA();

function candidates(raw){
  let p = String(raw||"").replace(/\D/g,"");
  if(p.startsWith("00")) p = p.slice(2);
  if(p.startsWith("970")||p.startsWith("972")) return [p,(p.startsWith("970")?"972":"970")+p.slice(3)];
  if(p.startsWith("0")) p = p.slice(1);
  return ["970"+p,"972"+p];
}
async function resolveJid(raw){
  for(const c of candidates(raw)){
    try{ const r = await sock.onWhatsApp(c+"@s.whatsapp.net");
      if(r && r[0] && r[0].exists) return r[0].jid; }catch(e){}
  }
  return null;
}
const norm = raw => candidates(raw)[0].slice(3);
const tmpl = (t,vars)=>String(t||"").replace(/\{(\w+)\}/g,(m,k)=>vars[k]!==undefined?vars[k]:m);

// ================= التطبيق =================
const app = express();
app.use(express.json());
app.use((req,res,next)=>{ res.setHeader("Access-Control-Allow-Origin","*");
  res.setHeader("Access-Control-Allow-Headers","Content-Type");
  if(req.method==="OPTIONS") return res.end(); next(); });

// ---------- API عام (التطبيق) ----------
const rate = {};
app.post("/api/register", async (req,res)=>{
  try{
    if(getS("reg_open")!=="1") return res.json({ok:0, err:"التسجيل مسكّر حالياً — تواصل مع المدرب"});
    const { name, phone } = req.body||{};
    if(!name || String(name).trim().length<2) return res.json({ok:0, err:"اكتب اسمك"});
    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة التفعيل مش جاهزة حالياً — جرب بعد شوي"});
    const key = norm(phone);
    const ex0 = db.prepare("SELECT banned FROM students WHERE phone=?").get(key);
    if(ex0 && ex0.banned) return res.json({ok:0, err:"هذا الرقم محظور — تواصل مع المدرب"});
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});
    const jid = await resolveJid(phone);
    if(!jid) return res.json({ok:0, err:"الرقم مش مسجل على واتساب — تأكد منه"});
    const code = String(Math.floor(100000+Math.random()*900000));
    const now = Date.now(), nm = String(name).trim().slice(0,40);
    db.prepare(`INSERT INTO students(name,phone,jid,code,code_exp,attempts,created)
      VALUES(?,?,?,?,?,0,?)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, jid=excluded.jid,
      code=excluded.code, code_exp=excluded.code_exp, attempts=0`)
      .run(nm, key, jid, code, now+15*60e3, now);
    await sock.sendMessage(jid, { text: tmpl(getS("code_msg"),{name:nm,code}) });
    rate[key].push(Date.now());
    ev("reg", nm+" ("+key+") سجّل وانبعتله كود");
    res.json({ok:1});
  }catch(e){ console.log(e); res.json({ok:0, err:"صار خطأ — جرب كمان مرة"}); }
});

app.post("/api/verify", async (req,res)=>{
  const { phone, code } = req.body||{};
  const s = db.prepare("SELECT * FROM students WHERE phone=?").get(norm(phone||""));
  if(!s) return res.json({ok:0, err:"سجّل أول"});
  if(s.banned) return res.json({ok:0, err:"هذا الرقم محظور — تواصل مع المدرب"});
  if(s.attempts>=6) return res.json({ok:0, err:"محاولات كثيرة — سجّل من جديد"});
  db.prepare("UPDATE students SET attempts=attempts+1 WHERE id=?").run(s.id);
  if(!s.code || Date.now()>s.code_exp) return res.json({ok:0, err:"الكود انتهى — سجّل من جديد"});
  if(String(code).trim()!==s.code) return res.json({ok:0, err:"الكود غلط"});
  const token = crypto.randomBytes(24).toString("hex");
  db.prepare("UPDATE students SET active=1, token=?, code=NULL, last_seen=? WHERE id=?").run(token, Date.now(), s.id);
  ev("verify", s.name+" فعّل حسابه ✅");
  try{ if(waStatus==="connected") await sock.sendMessage(s.jid,{text:tmpl(getS("welcome_msg"),{name:s.name})}); }catch(e){}
  res.json({ok:1, token});
});

app.post("/api/check",(req,res)=>{
  const { phone, token } = req.body||{};
  const s = db.prepare("SELECT * FROM students WHERE phone=? AND token=?").get(norm(phone||""), String(token||""));
  if(!s) return res.json({ok:0});
  db.prepare("UPDATE students SET last_seen=? WHERE id=?").run(Date.now(), s.id);
  res.json({ok: (s.active && !s.banned)?1:0, name:s.name});
});

app.post("/api/progress",(req,res)=>{
  const { phone, token, correct, total, mode } = req.body||{};
  const s = db.prepare("SELECT * FROM students WHERE phone=? AND token=?").get(norm(phone||""), String(token||""));
  if(!s) return res.json({ok:0});
  const c=Math.max(0,Math.min(99,parseInt(correct)||0)), t=Math.max(1,Math.min(99,parseInt(total)||30));
  db.prepare("INSERT INTO progress(phone,t,correct,total,mode) VALUES(?,?,?,?,?)")
    .run(s.phone, Date.now(), c, t, String(mode||"exam").slice(0,12));
  db.prepare("DELETE FROM progress WHERE phone=? AND id NOT IN (SELECT id FROM progress WHERE phone=? ORDER BY id DESC LIMIT 60)").run(s.phone,s.phone);
  res.json({ok:1});
});

// ---------- جلسات اللوحة ----------
function cookies(req){ const o={}; (req.headers.cookie||"").split(";").forEach(p=>{const i=p.indexOf("=");
  if(i>0) o[p.slice(0,i).trim()]=decodeURIComponent(p.slice(i+1).trim());}); return o; }
function session(req){
  const t = cookies(req).tsid; if(!t) return null;
  const s = db.prepare("SELECT * FROM sessions WHERE token=?").get(t);
  if(!s) return null;
  if(Date.now()-s.created > 30*864e5){ db.prepare("DELETE FROM sessions WHERE token=?").run(t); return null; }
  return s;
}
const loginFails = {};
app.post("/siwad/login",(req,res)=>{
  const ip = req.headers["x-real-ip"]||req.ip||"?";
  const f = loginFails[ip]||{n:0,until:0};
  if(Date.now()<f.until) return res.json({ok:0, err:"محاولات كثيرة — استنى 15 دقيقة"});
  if(hashPw(req.body.pass||"") !== getS("pass_hash")){
    f.n++; if(f.n>=5){ f.until=Date.now()+15*60e3; f.n=0; } loginFails[ip]=f;
    return res.json({ok:0, err:"كلمة السر غلط"});
  }
  delete loginFails[ip];
  const token = crypto.randomBytes(32).toString("hex");
  db.prepare("INSERT INTO sessions(token,created) VALUES(?,?)").run(token, Date.now());
  res.setHeader("Set-Cookie", `tsid=${token}; Path=/; Max-Age=${30*86400}; HttpOnly; Secure; SameSite=Lax`);
  res.json({ok:1});
});
app.post("/siwad/logout",(req,res)=>{
  const t=cookies(req).tsid; if(t) db.prepare("DELETE FROM sessions WHERE token=?").run(t);
  res.setHeader("Set-Cookie","tsid=; Path=/; Max-Age=0"); res.json({ok:1});
});
const guard = (req,res,next)=>{ if(session(req)) return next(); res.status(401).json({ok:0, err:"auth"}); };

// ---------- API اللوحة ----------
app.get("/siwad/api/state", guard, (req,res)=>{
  const all = db.prepare("SELECT id,name,phone,active,banned,created,last_seen,code FROM students ORDER BY id DESC").all();
  const pr = db.prepare("SELECT phone, COUNT(*) n, MAX(correct*100/total) best, AVG(correct*100.0/total) avg, MAX(t) last FROM progress GROUP BY phone").all();
  const prMap={}; pr.forEach(p=>prMap[p.phone]={n:p.n,best:Math.round(p.best||0),avg:Math.round(p.avg||0),last:p.last});
  all.forEach(s=>s.prog=prMap[s.phone]||null);
  const now=Date.now(), day=864e5, t0=new Date(); t0.setHours(0,0,0,0);
  const stats={ total:all.length,
    today: all.filter(s=>s.created>=t0.getTime()).length,
    week: all.filter(s=>now-s.created<7*day).length,
    active: all.filter(s=>s.active).length,
    pending: all.filter(s=>!s.active).length,
    online24: all.filter(s=>s.last_seen && now-s.last_seen<day).length,
    banned: all.filter(s=>s.banned).length };
  const chart=[]; for(let i=13;i>=0;i--){ const d0=t0.getTime()-i*day;
    chart.push({d:new Date(d0).toLocaleDateString("ar",{day:"numeric",month:"numeric"}),
      n: all.filter(s=>s.created>=d0 && s.created<d0+day).length}); }
  let disk=""; try{ disk=execSync("df -h / | tail -1").toString().trim().split(/\s+/)[4]; }catch(e){}
  const mem = Math.round((1-os.freemem()/os.totalmem())*100)+"%";
  const events = db.prepare("SELECT * FROM events ORDER BY id DESC LIMIT 6").all();
  res.json({ wa:waStatus, qr:qrData, stats, chart, srv:{mem,disk},
    events, reg_open:getS("reg_open"), students: all,
    bc: BC.running?{running:1,sent:BC.sent,total:BC.total}:{running:0},
    msgs:{code_msg:getS("code_msg"), welcome_msg:getS("welcome_msg")} });
});
app.post("/siwad/api/toggle", guard, (req,res)=>{
  const s=db.prepare("SELECT * FROM students WHERE id=?").get(req.body.id);
  if(!s) return res.json({ok:0});
  db.prepare("UPDATE students SET active=1-active WHERE id=?").run(s.id);
  ev("toggle",(s.active?"إيقاف ":"تفعيل ")+s.name); res.json({ok:1});
});
app.post("/siwad/api/ban", guard, (req,res)=>{
  const s=db.prepare("SELECT * FROM students WHERE id=?").get(req.body.id);
  if(!s) return res.json({ok:0});
  db.prepare("UPDATE students SET banned=1-banned, active=CASE WHEN banned=0 THEN 0 ELSE active END WHERE id=?").run(s.id);
  ev("ban",(s.banned?"فك حظر ":"حظر 🚫 ")+s.name); res.json({ok:1});
});
app.get("/siwad/api/prog", guard, (req,res)=>{
  const s=db.prepare("SELECT phone FROM students WHERE id=?").get(req.query.id);
  if(!s) return res.json({ok:0});
  res.json({ok:1, rows: db.prepare("SELECT t,correct,total,mode FROM progress WHERE phone=? ORDER BY id DESC LIMIT 15").all(s.phone)});
});
app.post("/siwad/api/delete", guard, (req,res)=>{
  const s=db.prepare("SELECT * FROM students WHERE id=?").get(req.body.id);
  if(s){ db.prepare("DELETE FROM students WHERE id=?").run(s.id); ev("del","حذف "+s.name); }
  res.json({ok:1});
});
app.post("/siwad/api/add", guard, async (req,res)=>{
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
});
app.post("/siwad/api/msg", guard, async (req,res)=>{
  try{
    const s=db.prepare("SELECT * FROM students WHERE id=?").get(req.body.id);
    if(!s||!s.jid) return res.json({ok:0, err:"طالب مش موجود"});
    if(waStatus!=="connected") return res.json({ok:0, err:"الواتساب مش متصل"});
    await sock.sendMessage(s.jid,{text:String(req.body.text||"").slice(0,1500)});
    ev("msg","رسالة لـ"+s.name); res.json({ok:1});
  }catch(e){ res.json({ok:0, err:"ما انبعتت"}); }
});
// ---------- إعلان جماعي ----------
const BC={running:false,sent:0,total:0,stop:false};
app.post("/siwad/api/broadcast", guard, async (req,res)=>{
  if(BC.running) return res.json({ok:0, err:"في إرسال شغال"});
  if(waStatus!=="connected") return res.json({ok:0, err:"الواتساب مش متصل"});
  const text=String(req.body.text||"").trim(); if(text.length<3) return res.json({ok:0, err:"اكتب الرسالة"});
  const target=req.body.target==="pending"?0:1;
  const list=db.prepare("SELECT * FROM students WHERE active=? AND jid IS NOT NULL").all(target);
  if(!list.length) return res.json({ok:0, err:"ما في مستلمين"});
  BC.running=true; BC.sent=0; BC.total=list.length; BC.stop=false;
  ev("bc","بدأ إعلان جماعي لـ"+list.length);
  (async ()=>{
    for(const s of list){
      if(BC.stop||waStatus!=="connected") break;
      try{ await sock.sendMessage(s.jid,{text:tmpl(text,{name:s.name})}); BC.sent++; }catch(e){}
      await new Promise(r=>setTimeout(r, 15000+Math.random()*15000));
    }
    ev("bc","خلص الإعلان: "+BC.sent+"/"+BC.total); BC.running=false;
  })();
  res.json({ok:1});
});
app.post("/siwad/api/broadcast/stop", guard,(req,res)=>{ BC.stop=true; res.json({ok:1}); });
// ---------- إعدادات ----------
app.post("/siwad/api/settings", guard,(req,res)=>{
  const b=req.body||{};
  if(b.code_msg!==undefined) setS("code_msg", String(b.code_msg).slice(0,600));
  if(b.welcome_msg!==undefined) setS("welcome_msg", String(b.welcome_msg).slice(0,600));
  if(b.reg_open!==undefined) setS("reg_open", b.reg_open?"1":"0");
  ev("set","تعديل إعدادات"); res.json({ok:1});
});
app.post("/siwad/api/changepass", guard,(req,res)=>{
  const {oldp,newp}=req.body||{};
  if(hashPw(oldp||"")!==getS("pass_hash")) return res.json({ok:0, err:"كلمة السر الحالية غلط"});
  if(!newp||String(newp).length<8) return res.json({ok:0, err:"الجديدة قصيرة (8+ أحرف)"});
  setS("pass_hash", hashPw(newp));
  db.prepare("DELETE FROM sessions").run();
  ev("set","تغيير كلمة سر اللوحة"); res.json({ok:1, relogin:1});
});
app.post("/siwad/api/relink", guard, async (req,res)=>{
  try{ try{ await sock.logout(); }catch(e){}
    execSync("rm -rf /opt/teoria/wa_auth");
    waStatus="starting"; qrData=null; startWA();
    ev("wa","طلب إعادة ربط الواتساب"); res.json({ok:1});
  }catch(e){ res.json({ok:0}); }
});

// ================= واجهة اللوحة =================
const LOGIN_HTML = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TeoriaAI — دخول</title>
<link href="https://fonts.googleapis.com/css2?family=Alexandria:wght@500;700;800;900&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box;font-family:'Alexandria',sans-serif}
body{min-height:100vh;display:grid;place-items:center;background:linear-gradient(160deg,#154A97,#1D5FBF 60%,#123E7E);padding:20px}
.card{background:#fff;border-radius:22px;padding:34px 28px;width:100%;max-width:380px;box-shadow:0 30px 80px rgba(0,0,0,.35);text-align:center}
.logo{width:64px;height:64px;border-radius:18px;background:#1D5FBF;color:#FFC53D;display:grid;place-items:center;font-size:30px;margin:0 auto 14px}
h1{font-size:21px;font-weight:900;color:#171B21}
p{color:#67707D;font-size:13.5px;margin:6px 0 20px}
input{width:100%;padding:14px;border:2px solid #E2E6EB;border-radius:13px;font-family:inherit;font-size:16px;text-align:center;letter-spacing:1px}
input:focus{outline:none;border-color:#1D5FBF}
button{width:100%;margin-top:14px;padding:14px;border:none;border-radius:13px;background:#1D5FBF;color:#fff;font-family:inherit;font-weight:900;font-size:16px;cursor:pointer;border-bottom:4px solid #154A97}
.err{color:#D6273B;font-weight:700;font-size:13px;min-height:18px;margin-top:10px}
</style></head><body>
<div class="card">
  <div class="logo">🛡️</div>
  <h1>لوحة قيادة TeoriaAI</h1>
  <p>منطقة خاصة بالمدرب</p>
  <input type="password" id="pw" placeholder="كلمة السر" onkeydown="if(event.key==='Enter')go()">
  <button onclick="go()">دخول</button>
  <div class="err" id="err"></div>
</div>
<script>
async function go(){
  const r=await fetch("/siwad/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({pass:document.getElementById("pw").value})});
  const d=await r.json();
  if(d.ok) location.reload(); else document.getElementById("err").textContent=d.err||"غلط";
}
</script></body></html>`;

const PANEL_HTML = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TeoriaAI — لوحة القيادة</title>
<link href="https://fonts.googleapis.com/css2?family=Alexandria:wght@500;700;800;900&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box;font-family:'Alexandria',sans-serif}
:root{--bg:#EEF1F4;--sf:#fff;--ink:#171B21;--mut:#67707D;--ln:rgba(23,27,33,.1);--pr:#1D5FBF;--prd:#154A97;--ac:#FFC53D;--ok:#178A50;--okl:#E6F5ED;--dg:#D6273B;--dgl:#FBE9EC}
[data-th="d"]{--bg:#0F1216;--sf:#171B21;--ink:#ECEFF3;--mut:#9AA3AF;--ln:rgba(236,239,243,.13);--okl:#12291C;--dgl:#301A1E}
body{background:var(--bg);color:var(--ink);padding-bottom:40px}
.top{position:sticky;top:0;z-index:9;background:var(--sf);border-bottom:1px solid var(--ln);padding:12px 16px;display:flex;align-items:center;gap:10px}
.top .lg{width:38px;height:38px;border-radius:11px;background:var(--pr);color:var(--ac);display:grid;place-items:center;font-size:19px}
.top h1{font-size:16.5px;font-weight:900;flex:1}
.top button{background:none;border:1px solid var(--ln);border-radius:10px;padding:7px 11px;cursor:pointer;font-family:inherit;color:var(--ink);font-size:14px}
.tabs{display:flex;gap:6px;padding:12px 14px;overflow-x:auto;position:sticky;top:62px;background:var(--bg);z-index:8}
.tab{border:1.5px solid var(--ln);background:var(--sf);color:var(--ink);border-radius:12px;padding:9px 16px;font-family:inherit;font-weight:800;font-size:13.5px;cursor:pointer;white-space:nowrap}
.tab.on{background:var(--pr);color:#fff;border-color:var(--pr)}
.wrap{padding:0 14px;max-width:1000px;margin:0 auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;margin-bottom:14px}
.kpi{background:var(--sf);border:1px solid var(--ln);border-radius:15px;padding:14px}
.kpi b{display:block;font-size:26px;font-weight:900}
.kpi span{font-size:12.5px;color:var(--mut);font-weight:700}
.kpi.blue b{color:var(--pr)}.kpi.green b{color:var(--ok)}.kpi.red b{color:var(--dg)}.kpi.yellow b{color:#C79020}
.box{background:var(--sf);border:1px solid var(--ln);border-radius:16px;padding:16px;margin-bottom:14px}
.box h3{font-size:15px;font-weight:900;margin-bottom:12px}
.chart{display:flex;align-items:flex-end;gap:5px;height:110px}
.chart .bar{flex:1;display:flex;flex-direction:column;align-items:center;gap:4px}
.chart .bar i{width:100%;background:var(--pr);border-radius:5px 5px 0 0;min-height:3px}
.chart .bar em{font-style:normal;font-size:9.5px;color:var(--mut)}
.chart .bar b{font-size:11px}
.wa{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.pill{padding:6px 14px;border-radius:20px;font-weight:800;font-size:13px}
.pill.g{background:var(--okl);color:var(--ok)}.pill.r{background:var(--dgl);color:var(--dg)}.pill.y{background:#FFF3D6;color:#8a6100}
#qr img{width:220px;border-radius:12px;margin-top:10px}
.evt{font-size:13px;color:var(--mut);padding:7px 0;border-bottom:1px dashed var(--ln)}
.evt:last-child{border:none}
input,textarea,select{width:100%;padding:12px;border:1.5px solid var(--ln);border-radius:12px;font-family:inherit;font-size:14.5px;background:var(--sf);color:var(--ink)}
textarea{min-height:100px;resize:vertical}
.btn{border:none;border-radius:12px;padding:11px 20px;font-family:inherit;font-weight:900;font-size:14px;cursor:pointer;background:var(--pr);color:#fff;border-bottom:3px solid var(--prd)}
.btn.g{background:var(--ok);border-color:#0f6339}.btn.r{background:var(--dg);border-color:#a11527}.btn.ghost{background:var(--sf);color:var(--ink);border:1.5px solid var(--ln)}
.btn.sm{padding:7px 12px;font-size:12.5px;border-bottom-width:2px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.filters{display:flex;gap:6px;overflow-x:auto;margin:10px 0}
.f{border:1.5px solid var(--ln);background:var(--sf);color:var(--ink);border-radius:20px;padding:6px 13px;font-size:12.5px;font-weight:800;cursor:pointer;white-space:nowrap;font-family:inherit}
.f.on{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.stu{background:var(--sf);border:1px solid var(--ln);border-radius:14px;padding:13px;margin-bottom:9px}
.stu .nm{font-weight:900;font-size:15px}
.stu .ph{color:var(--mut);font-size:13px;direction:ltr;display:inline-block}
.stu .meta{font-size:11.5px;color:var(--mut);margin-top:3px}
.stu .st{float:left;font-size:12px;font-weight:900;padding:4px 11px;border-radius:14px}
.stu .st.a{background:var(--okl);color:var(--ok)}.stu .st.p{background:var(--dgl);color:var(--dg)}
.stu .acts{display:flex;gap:6px;margin-top:10px;flex-wrap:wrap}
.prog{height:10px;background:#22262D;border-radius:6px;overflow:hidden;margin:10px 0;position:relative}
.prog i{display:block;height:100%;background:var(--ac)}
.hint{font-size:12px;color:var(--mut);margin-top:6px;line-height:1.7}
.lbl{font-size:13px;font-weight:800;margin:12px 0 6px;display:block}
.switch{display:flex;align-items:center;gap:10px;font-weight:800;font-size:14px}
.ok-t{color:var(--ok);font-weight:800;font-size:13px;min-height:18px}
@media(min-width:700px){.stu{display:grid;grid-template-columns:1fr auto;align-items:center}.stu .acts{margin-top:0}}
</style></head><body data-th="l">
<div class="top">
  <div class="lg">🛡️</div><h1>لوحة قيادة TeoriaAI</h1>
  <button onclick="th()">🌙</button>
  <button onclick="out()">خروج</button>
</div>
<div class="tabs">
  <button class="tab on" data-t="ov" onclick="tab('ov')">📊 نظرة عامة</button>
  <button class="tab" data-t="st" onclick="tab('st')">👥 الطلاب</button>
  <button class="tab" data-t="bc" onclick="tab('bc')">📣 إعلان جماعي</button>
  <button class="tab" data-t="se" onclick="tab('se')">⚙️ إعدادات</button>
</div>
<div class="wrap">

<div id="t-ov">
  <div class="grid" id="kpis"></div>
  <div class="box"><h3>حالة الواتساب</h3><div class="wa" id="waBox"></div><div id="qr"></div></div>
  <div class="box"><h3>تسجيلات آخر ١٤ يوم</h3><div class="chart" id="chart"></div></div>
  <div class="box"><h3>آخر الأحداث</h3><div id="events"></div></div>
</div>

<div id="t-st" style="display:none">
  <div class="box">
    <h3>➕ إضافة طالب يدوياً (بيتفعّل فوراً وبتوصله رسالة ترحيب)</h3>
    <div class="row"><input id="anm" placeholder="الاسم" style="flex:2;min-width:130px">
    <input id="aph" placeholder="رقم الواتساب 059..." style="flex:2;min-width:130px;direction:ltr">
    <button class="btn g" onclick="addStu()">أضِف</button></div>
    <div class="ok-t" id="addMsg"></div>
  </div>
  <input id="q" placeholder="🔎 ابحث بالاسم أو الرقم..." oninput="render()">
  <div class="filters">
    <button class="f on" data-f="all" onclick="flt('all')">الكل</button>
    <button class="f" data-f="active" onclick="flt('active')">المفعّلين</button>
    <button class="f" data-f="pending" onclick="flt('pending')">غير مفعّل</button>
    <button class="f" data-f="today" onclick="flt('today')">جداد اليوم</button>
    <button class="f" data-f="online" onclick="flt('online')">نشطين (٢٤س)</button>
    <button class="f" data-f="banned" onclick="flt('banned')">🚫 محظورين</button>
  </div>
  <div id="list"></div>
</div>

<div id="t-bc" style="display:none">
  <div class="box">
    <h3>📣 رسالة جماعية من رقمك</h3>
    <span class="lbl">لمين؟</span>
    <select id="bcT"><option value="active">كل المفعّلين</option><option value="pending">غير المفعّلين</option></select>
    <span class="lbl">الرسالة ({name} = اسم الطالب)</span>
    <textarea id="bcTx" placeholder="مثال: مرحبا {name} 👋 تذكير: امتحان التوريا الرسمي يوم الخميس — راجعوا خطة الـ٣ أيام بالتطبيق 🚗"></textarea>
    <div class="hint">⚠️ الإرسال بفواصل ١٥-٣٠ ثانية بين رسالة ورسالة لحماية رقمك — الإعلان لـ١٠٠ طالب بياخد حوالي نص ساعة، خلي الصفحة مفتوحة أو سكّرها عادي، السيرفر بيكمل لحاله.</div>
    <div id="bcProg"></div>
    <div class="row" style="margin-top:10px">
      <button class="btn" id="bcGo" onclick="bcast()">🚀 ابعت</button>
      <button class="btn r" id="bcStop" onclick="bcstop()" style="display:none">⏹️ أوقف</button>
    </div>
    <div class="ok-t" id="bcMsg"></div>
  </div>
</div>

<div id="t-se" style="display:none">
  <div class="box"><h3>باب التسجيل</h3>
    <label class="switch"><input type="checkbox" id="regOpen" style="width:22px;height:22px" onchange="saveSet()"> التسجيل الجديد مفتوح</label>
    <div class="hint">سكّره إذا بدك توقف استقبال طلاب جدد مؤقتاً — الطلاب الحاليين ما بيتأثروا.</div>
  </div>
  <div class="box"><h3>نصوص الرسائل</h3>
    <span class="lbl">رسالة الكود ({name} و {code})</span><textarea id="mCode"></textarea>
    <span class="lbl">رسالة الترحيب بعد التفعيل ({name})</span><textarea id="mWel"></textarea>
    <button class="btn" style="margin-top:10px" onclick="saveMsgs()">💾 احفظ النصوص</button>
    <div class="ok-t" id="setMsg"></div>
  </div>
  <div class="box"><h3>الواتساب</h3>
    <button class="btn ghost" onclick="relink()">🔄 إعادة ربط الواتساب (QR جديد)</button>
    <div class="hint">استعملها إذا غيّرت الرقم أو انفصل نهائياً — بيطلع QR جديد بتبويب النظرة العامة.</div>
  </div>
  <div class="box"><h3>كلمة سر اللوحة</h3>
    <div class="row"><input type="password" id="op" placeholder="الحالية" style="flex:1;min-width:120px">
    <input type="password" id="np" placeholder="الجديدة (8+)" style="flex:1;min-width:120px">
    <button class="btn" onclick="chpass()">غيّر</button></div>
    <div class="ok-t" id="pwMsg"></div>
  </div>
</div>

</div>
<script>
let D=null, FLT="all";
const $=s=>document.querySelector(s);
function th(){const b=document.body;b.dataset.th=b.dataset.th==="d"?"l":"d";localStorage.tpTh=b.dataset.th;}
if(localStorage.tpTh)document.body.dataset.th=localStorage.tpTh;
function tab(t){document.querySelectorAll(".tab").forEach(x=>x.classList.toggle("on",x.dataset.t===t));
 ["ov","st","bc","se"].forEach(x=>$("#t-"+x).style.display=x===t?"":"none");}
function flt(f){FLT=f;document.querySelectorAll(".f").forEach(x=>x.classList.toggle("on",x.dataset.f===f));render();}
async function api(p,body){const r=await fetch("/siwad/api/"+p,{method:body?"POST":"GET",
 headers:{"Content-Type":"application/json"},body:body?JSON.stringify(body):undefined});
 if(r.status===401){location.reload();return{}}return r.json();}
function ago(t){if(!t)return "ما فتح بعد";const m=Math.floor((Date.now()-t)/60000);
 return m<1?"هلأ":m<60?"قبل "+m+" د":m<1440?"قبل "+Math.floor(m/60)+" س":"قبل "+Math.floor(m/1440)+" يوم";}
async function load(){
  D=await api("state"); if(!D.stats)return;
  const s=D.stats;
  $("#kpis").innerHTML=
   kpi(s.total,"إجمالي الطلاب","blue")+kpi(s.active,"مفعّلين","green")+
   kpi(s.pending,"غير مفعّل","red")+kpi(s.today,"سجّلوا اليوم","yellow")+
   kpi(s.week,"هذا الأسبوع","blue")+kpi(s.online24,"نشطين ٢٤ ساعة","green")+kpi(s.banned,"محظورين","red");
  const waMap={connected:['متصل ✅','g'],qr:['بحاجة مسح QR 👇','y'],disconnected:['منقطع — بيعيد الاتصال','y'],starting:['جاري التشغيل…','y'],logged_out:['مفصول — اعمل إعادة ربط','r']};
  const w=waMap[D.wa]||[D.wa,'y'];
  $("#waBox").innerHTML='<span class="pill '+w[1]+'">'+w[0]+'</span>'+
   '<span class="hint">السيرفر: رام '+D.srv.mem+' · قرص '+D.srv.disk+'</span>';
  $("#qr").innerHTML=D.qr?'<img src="'+D.qr+'">':"";
  const mx=Math.max(1,...D.chart.map(c=>c.n));
  $("#chart").innerHTML=D.chart.map(c=>'<div class="bar"><b>'+(c.n||"")+'</b><i style="height:'+(c.n/mx*80)+'px"></i><em>'+c.d+'</em></div>').join("");
  $("#events").innerHTML=(D.events||[]).map(e=>'<div class="evt">'+new Date(e.t).toLocaleTimeString("ar",{hour:"2-digit",minute:"2-digit"})+" — "+e.txt+'</div>').join("")||'<div class="hint">ولا حدث بعد</div>';
  $("#regOpen").checked=D.reg_open==="1";
  if(document.activeElement!==$("#mCode")&&document.activeElement!==$("#mWel")){$("#mCode").value=D.msgs.code_msg;$("#mWel").value=D.msgs.welcome_msg;}
  bcUI(D.bc); render();
}
function kpi(n,l,c){return '<div class="kpi '+c+'"><b>'+n+'</b><span>'+l+'</span></div>';}
function render(){
  if(!D||!D.students)return;
  const q=($("#q").value||"").trim(), t0=new Date();t0.setHours(0,0,0,0);
  let L=D.students.filter(s=>!q||s.name.includes(q)||("0"+s.phone).includes(q.replace(/\\D/g,"")));
  if(FLT==="active")L=L.filter(s=>s.active);
  if(FLT==="pending")L=L.filter(s=>!s.active);
  if(FLT==="today")L=L.filter(s=>s.created>=t0.getTime());
  if(FLT==="online")L=L.filter(s=>s.last_seen&&Date.now()-s.last_seen<864e5);
  if(FLT==="banned")L=L.filter(s=>s.banned);
  $("#list").innerHTML=L.map(s=>'<div class="stu">'+
   '<div><span class="st '+(s.active?"a":"p")+'">'+(s.active?"مفعّل":"غير مفعّل")+'</span>'+
   '<div class="nm">'+s.name+'</div><span class="ph">0'+s.phone+'</span>'+
   '<div class="meta">سجّل '+ago(s.created)+' · آخر ظهور: '+ago(s.last_seen)+'</div></div>'+
   '<div class="acts">'+
   '<button class="btn sm '+(s.active?"r":"g")+'" onclick="tg('+s.id+')">'+(s.active?"أوقف":"فعّل")+'</button>'+
   '<button class="btn sm ghost" onclick="pm('+s.id+',\\''+s.name.replace(/'/g,"")+'\\')">💬 رسالة</button>'+
   '<a class="btn sm ghost" style="text-decoration:none" target="_blank" href="https://wa.me/972'+s.phone+'">واتساب</a>'+
   '<button class="btn sm ghost" onclick="del('+s.id+',\\''+s.name.replace(/'/g,"")+'\\')">🗑️</button>'+
   '</div></div>').join("")||'<div class="hint" style="text-align:center;padding:20px">ما في نتائج</div>';
}
async function tg(id){await api("toggle",{id});load();}
async function ban(id,nm,isB){if(!confirm(isB?("فك الحظر عن "+nm+"؟"):("حظر "+nm+"؟ ما رح يقدر يسجل ولا يفوت (حسابه بيتوقف).")))return;
 await api("ban",{id});load();}
async function prog(id,nm){const r=await api("prog?id="+id);
 if(!r.ok||!r.rows.length){alert(nm+": ما في امتحانات مسجلة بعد");return;}
 alert("📈 آخر امتحانات "+nm+":\n\n"+r.rows.map(x=>{
  const p=Math.round(x.correct*100/x.total);
  return new Date(x.t).toLocaleDateString("ar")+" — "+x.correct+"/"+x.total+" ("+p+"%)"+(p>=87?" ✅":"");
 }).join("\n"));}
async function del(id,nm){if(confirm("متأكد بدك تحذف "+nm+"؟ ما في رجعة."))
 {await api("delete",{id});load();}}
async function pm(id,nm){const t=prompt("رسالة لـ"+nm+" (بتنبعت من رقمك):");
 if(!t)return;const r=await api("msg",{id,text:t});alert(r.ok?"انبعتت ✅":(r.err||"ما زبطت"));}
async function addStu(){
 const r=await api("add",{name:$("#anm").value,phone:$("#aph").value});
 $("#addMsg").textContent=r.ok?"انضاف واتفعّل ✅":(r.err||"غلط");
 if(r.ok){$("#anm").value="";$("#aph").value="";load();}}
function bcUI(bc){
 if(bc&&bc.running){$("#bcGo").style.display="none";$("#bcStop").style.display="";
  $("#bcProg").innerHTML='<div class="prog"><i style="width:'+(bc.sent/bc.total*100)+'%"></i></div><div class="hint">'+bc.sent+' / '+bc.total+' انبعتت…</div>';}
 else{$("#bcGo").style.display="";$("#bcStop").style.display="none";
  if($("#bcProg").innerHTML&&bc&&!bc.running)$("#bcProg").innerHTML="";}}
async function bcast(){
 if(!confirm("متأكد؟ الرسالة رح تنبعت من رقمك لكل المجموعة."))return;
 const r=await api("broadcast",{text:$("#bcTx").value,target:$("#bcT").value});
 $("#bcMsg").textContent=r.ok?"بلّش الإرسال 🚀":(r.err||"غلط");load();}
async function bcstop(){await api("broadcast/stop",{});$("#bcMsg").textContent="وقّفناه";load();}
async function saveSet(){await api("settings",{reg_open:$("#regOpen").checked});}
async function saveMsgs(){await api("settings",{code_msg:$("#mCode").value,welcome_msg:$("#mWel").value});
 $("#setMsg").textContent="انحفظت ✅";setTimeout(()=>$("#setMsg").textContent="",2000);}
async function chpass(){const r=await api("changepass",{oldp:$("#op").value,newp:$("#np").value});
 $("#pwMsg").textContent=r.ok?"اتغيرت ✅ سجّل دخول من جديد":(r.err||"غلط");
 if(r.ok)setTimeout(()=>location.reload(),1500);}
async function relink(){if(!confirm("رح ينفصل الواتساب الحالي ويطلع QR جديد — أكيد؟"))return;
 await api("relink",{});tab("ov");load();}
async function out(){await fetch("/siwad/logout",{method:"POST"});location.reload();}
load(); setInterval(load, 5000);
</script></body></html>`;

app.get("/siwad",(req,res)=>{
  res.setHeader("Content-Type","text/html; charset=utf-8");
  res.send(session(req)? PANEL_HTML : LOGIN_HTML);
});

app.listen(PORT, ()=>console.log("TeoriaAI system on :"+PORT));
TEOSRV_EOF
sed -i 's|location = /admin|location /siwad|' /etc/nginx/sites-available/teoria 2>/dev/null || true
nginx -t && systemctl reload nginx
cd /opt/teoria && pm2 restart teoria --update-env
sleep 3
pm2 logs teoria --lines 4 --nostream || true
echo ""
echo "============================================"
echo "  🛡️ اللوحة المطورة جاهزة: https://teoriaai.com/siwad"
echo "  جديد: تقدم الطلاب 📈 + نظام الحظر 🚫"
echo "============================================"
