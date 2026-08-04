import re
P="/opt/teoria/server.js"
h=open(P,encoding="utf-8").read()
orig=h
def rep(old,new,label):
    global h
    assert old in h, "ANCHOR MISSING: "+label
    h=h.replace(old,new,1); print("  ✓",label)

# ===== 1) /api/enter — الحفظ أول، الواتساب اختياري =====
old_enter = '''    // جديد أو مسجّل بس ما فعّل — كود واتساب
    if(getS("reg_open")!=="1" && !s) return res.json({ok:0, err:"التسجيل مسكّر حالياً — تواصل مع المدرب"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة التفعيل مش جاهزة حالياً — جرب بعد شوي"});
    if(!s && (!name || String(name).trim().length<2)) return res.json({ok:0, err:"اكتب اسمك"});
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});
    const jid = s ? s.jid : await resolveJid(phone);
    if(!jid) return res.json({ok:0, err:"ما لقينا هالرقم على واتساب — تأكد منه أو احكي مع المدرب"});
    const code = String(Math.floor(100000+Math.random()*900000));
    const now = Date.now(), nm = s ? s.name : String(name).trim().slice(0,40);
    db.prepare(`INSERT INTO students(name,phone,jid,code,code_exp,attempts,created)
      VALUES(?,?,?,?,?,0,?)
      ON CONFLICT(phone) DO UPDATE SET jid=excluded.jid,
      code=excluded.code, code_exp=excluded.code_exp, attempts=0`)
      .run(nm, key, jid, code, now+15*60e3, now);
    await sock.sendMessage(jid, { text: tmpl(getS("code_msg"),{name:nm,code}) });
    rate[key].push(Date.now());
    ev("reg", nm+" ("+key+") — انبعتله كود دخول");
    res.json({ok:1, need_code:1, name:nm});'''

new_enter = '''    // جديد أو مسجّل بس ما فعّل
    if(getS("reg_open")!=="1" && !s) return res.json({ok:0, err:"التسجيل مسكّر حالياً — تواصل مع المدرب"});
    if(!s && (!name || String(name).trim().length<2)) return res.json({ok:0, err:"اكتب اسمك"});
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});

    const now = Date.now(), nm = s ? s.name : String(name).trim().slice(0,40);
    // 1) نحفظ الطالب فوراً — حتى لو الواتساب مفصول (لازم يبين باللوحة)
    let jid = s ? s.jid : null;
    if(!jid && waStatus==="connected"){ try{ jid = await resolveJid(phone); }catch(e){} }
    if(!jid) jid = candidates(phone)[0]+"@s.whatsapp.net";   // تخمين مبدئي
    const code = String(Math.floor(100000+Math.random()*900000));
    db.prepare(`INSERT INTO students(name,phone,jid,code,code_exp,attempts,created)
      VALUES(?,?,?,?,?,0,?)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, jid=excluded.jid,
      code=excluded.code, code_exp=excluded.code_exp, attempts=0`)
      .run(nm, key, jid, code, now+15*60e3, now);
    rate[key].push(Date.now());

    // 2) نحاول نبعت الكود — إذا ما زبط، الطالب بيضل محفوظ وبينتظر تفعيل المدرب
    let sent=0;
    if(waStatus==="connected"){
      try{ await sock.sendMessage(jid, { text: tmpl(getS("code_msg"),{name:nm,code}) }); sent=1; }catch(e){}
    }
    if(sent){
      ev("reg", nm+" ("+key+") — انبعتله كود دخول");
      return res.json({ok:1, need_code:1, name:nm});
    }
    ev("reg", "🔔 "+nm+" ("+key+") سجّل — الكود ما انبعت، بحاجة تفعيل يدوي");
    return res.json({ok:1, pending:1, name:nm,
      msg:"وصلنا طلبك ✅ المدرب رح يفعّل حسابك قريباً — بتقدر تفوت بعدها برقمك مباشرة."});'''
rep(old_enter,new_enter,"/api/enter — حفظ فوري")

# ===== 2) /api/register — نفس المنطق =====
old_reg = '''    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة التفعيل مش جاهزة حالياً — جرب بعد شوي"});
    const key = norm(phone);
    const ex0 = db.prepare("SELECT banned FROM students WHERE phone=?").get(key);
    if(ex0 && ex0.banned) return res.json({ok:0, err:"هذا الرقم محظور — تواصل مع المدرب"});
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});
    const jid = await resolveJid(phone);
    if(!jid) return res.json({ok:0, err:"ما لقينا هالرقم على واتساب — تأكد منه أو احكي مع المدرب"});
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
    res.json({ok:1});'''

new_reg = '''    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    const key = norm(phone);
    const ex0 = db.prepare("SELECT banned FROM students WHERE phone=?").get(key);
    if(ex0 && ex0.banned) return res.json({ok:0, err:"هذا الرقم محظور — تواصل مع المدرب"});
    rate[key] = (rate[key]||[]).filter(t=>Date.now()-t < 3600e3);
    if(rate[key].length>=3) return res.json({ok:0, err:"جربت كثير — استنى ساعة"});
    let jid=null;
    if(waStatus==="connected"){ try{ jid = await resolveJid(phone); }catch(e){} }
    if(!jid) jid = candidates(phone)[0]+"@s.whatsapp.net";
    const code = String(Math.floor(100000+Math.random()*900000));
    const now = Date.now(), nm = String(name).trim().slice(0,40);
    db.prepare(`INSERT INTO students(name,phone,jid,code,code_exp,attempts,created)
      VALUES(?,?,?,?,?,0,?)
      ON CONFLICT(phone) DO UPDATE SET name=excluded.name, jid=excluded.jid,
      code=excluded.code, code_exp=excluded.code_exp, attempts=0`)
      .run(nm, key, jid, code, now+15*60e3, now);
    rate[key].push(Date.now());
    let sent=0;
    if(waStatus==="connected"){
      try{ await sock.sendMessage(jid, { text: tmpl(getS("code_msg"),{name:nm,code}) }); sent=1; }catch(e){}
    }
    ev("reg", nm+" ("+key+")"+(sent?" سجّل وانبعتله كود":" سجّل 🔔 — بحاجة تفعيل يدوي"));
    res.json({ok:1, pending: sent?0:1});'''
rep(old_reg,new_reg,"/api/register — حفظ فوري")

# ===== 3) /api/login — نفس المعالجة =====
old_login = '''    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة التفعيل مش جاهزة — جرب بعد شوي"});
    const key = norm(phone);
    const s = db.prepare("SELECT * FROM students WHERE phone=?").get(key);
    if(!s) return res.json({ok:0, err:"الرقم مش مسجّل — سجّل حساب جديد"});'''
new_login = '''    if(!phone) return res.json({ok:0, err:"اكتب رقمك"});
    const key = norm(phone);
    const s = db.prepare("SELECT * FROM students WHERE phone=?").get(key);
    if(!s) return res.json({ok:0, err:"الرقم مش مسجّل — سجّل حساب جديد"});
    if(waStatus!=="connected") return res.json({ok:0, err:"خدمة الكود مش شغالة حالياً — تواصل مع المدرب وبيفعّلك يدوي"});'''
rep(old_login,new_login,"/api/login")

# ===== 4) اللوحة: تنبيه بالطلاب اللي بينتظروا تفعيل =====
rep('''   kpi(s.week,"هذا الأسبوع","blue")+kpi(s.online24,"نشطين ٢٤ ساعة","green")+kpi(s.banned,"محظورين","red");''',
'''   kpi(s.week,"هذا الأسبوع","blue")+kpi(s.online24,"نشطين ٢٤ ساعة","green")+kpi(s.banned,"محظورين","red");
  var pendBox=$("#pendAlert");
  if(pendBox){ pendBox.innerHTML = s.pending>0
    ? '<div class="box" style="border-color:var(--dg);background:var(--dgl)"><h3>🔔 '+s.pending+' طالب بانتظار التفعيل</h3><div class="hint">اضغط «👥 الطلاب» ← فلتر «غير مفعّل» ← وفعّلهم بكبسة. (لما الواتساب مفصول أو مقيّد، الطلاب بيتسجلوا عادي وبيستنوا تفعيلك)</div><button class="btn" style="margin-top:10px" onclick="tab(\\'st\\');flt(\\'pending\\')">شوف الطلاب المنتظرين ←</button></div>'
    : ''; }''',
"تنبيه المنتظرين")

rep('''<div id="t-ov">
  <div class="grid" id="kpis"></div>''',
'''<div id="t-ov">
  <div class="grid" id="kpis"></div>
  <div id="pendAlert"></div>''',
"مكان التنبيه")

assert h!=orig
open(P,"w",encoding="utf-8").write(h)
print("PATCH APPLIED")
