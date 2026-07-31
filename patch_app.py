import re, sys
P="/opt/teoria/server.js"
h=open(P,encoding="utf-8").read()
orig=h

def rep(old,new,label):
    global h
    assert old in h, "ANCHOR MISSING: "+label
    h=h.replace(old,new,1)
    print("  ✓",label)

# ---------- 1) جدول المعاملات ----------
rep('try{ db.exec("ALTER TABLE students ADD COLUMN banned INTEGER DEFAULT 0"); }catch(e){}',
'''try{ db.exec("ALTER TABLE students ADD COLUMN banned INTEGER DEFAULT 0"); }catch(e){}
db.exec(`CREATE TABLE IF NOT EXISTS applications(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  phone TEXT, name TEXT, full_name TEXT, contact TEXT, gear TEXT, delivery TEXT, note TEXT,
  id_img TEXT, me_img TEXT, res_img TEXT,
  status TEXT DEFAULT 'new',
  created INTEGER, updated INTEGER);`);
try{ db.exec("ALTER TABLE applications ADD COLUMN full_name TEXT"); }catch(e){}
try{ db.exec("ALTER TABLE applications ADD COLUMN contact TEXT"); }catch(e){}''',
"جدول applications")

# ---------- 2) رفع حد حجم الطلب (للصور) ----------
rep('app.use(express.json());','app.use(express.json({limit:"8mb"}));',"حد الحجم 8mb")

# ---------- 3) نقاط الطالب ----------
rep('''// ---------- جلسات اللوحة ----------''',
'''// ---------- معاملة الفحص الطبي (الطالب) ----------
function authStu(req){
  const { phone, token } = req.body||{};
  if(!phone||!token) return null;
  return db.prepare("SELECT * FROM students WHERE phone=? AND token=?").get(norm(phone), String(token));
}
app.post("/api/apply", (req,res)=>{
  try{
    const s = authStu(req);
    if(!s) return res.json({ok:0, err:"سجّل دخولك أول"});
    if(s.banned) return res.json({ok:0, err:"حسابك موقوف — تواصل مع المدرب"});
    const b=req.body||{};
    const gear = b.gear==="auto" ? "auto" : "manual";
    const delivery = b.delivery==="location" ? "location" : "health";
    const idImg=String(b.id_img||""), meImg=String(b.me_img||"");
    if(!idImg.startsWith("data:image/")||!meImg.startsWith("data:image/"))
      return res.json({ok:0, err:"لازم ترفع صورة الهوية وصورة شخصية"});
    if(idImg.length>3.2e6 || meImg.length>3.2e6)
      return res.json({ok:0, err:"الصور كبيرة — جرّب كمان مرة"});
    const fullName=String(b.full_name||"").trim().slice(0,80);
    const contact=String(b.contact||"").replace(/[^\d+]/g,"").slice(0,20);
    if(fullName.length<5) return res.json({ok:0, err:"اكتب اسمك الرباعي كامل"});
    if(contact.length<9) return res.json({ok:0, err:"اكتب رقم تلفون صحيح"});
    const open = db.prepare("SELECT id FROM applications WHERE phone=? AND status!='delivered' ORDER BY id DESC").get(s.phone);
    if(open) return res.json({ok:0, err:"عندك معاملة شغالة حالياً — تابعها من «معاملتي»"});
    const now=Date.now();
    db.prepare(`INSERT INTO applications(phone,name,full_name,contact,gear,delivery,note,id_img,me_img,status,created,updated)
      VALUES(?,?,?,?,?,?,?,?,?, 'new', ?,?)`)
      .run(s.phone, s.name, fullName, contact, gear, delivery, String(b.note||"").slice(0,300), idImg, meImg, now, now);
    ev("apply","📄 معاملة جديدة: "+s.name+" ("+(gear==="auto"?"أوتوماتيك":"جير")+" · "+(delivery==="health"?"توصيل للصحة":"توصيل لمكانه")+")");
    res.json({ok:1});
  }catch(e){ console.log(e); res.json({ok:0, err:"صار خطأ — جرّب كمان مرة"}); }
});
app.post("/api/apply/mine", (req,res)=>{
  const s = authStu(req);
  if(!s) return res.json({ok:0});
  const a = db.prepare("SELECT id,gear,delivery,status,created,updated,res_img FROM applications WHERE phone=? ORDER BY id DESC").get(s.phone);
  if(!a) return res.json({ok:1, app:null});
  res.json({ok:1, app:a});
});

// ---------- جلسات اللوحة ----------''',
"نقاط الطالب /api/apply")

# ---------- 4) نقاط اللوحة ----------
rep('''app.post("/siwad/api/delete", guard, (req,res)=>{''',
'''app.get("/siwad/api/apps", guard, (req,res)=>{
  const rows=db.prepare("SELECT id,phone,name,full_name,contact,gear,delivery,note,status,created,updated,(res_img IS NOT NULL) hasres FROM applications ORDER BY id DESC LIMIT 300").all();
  res.json({ok:1, rows});
});
app.get("/siwad/api/app", guard, (req,res)=>{
  const a=db.prepare("SELECT * FROM applications WHERE id=?").get(req.query.id);
  if(!a) return res.json({ok:0});
  res.json({ok:1, app:a});
});
app.post("/siwad/api/app/status", guard, (req,res)=>{
  const a=db.prepare("SELECT * FROM applications WHERE id=?").get(req.body.id);
  if(!a) return res.json({ok:0});
  const st=["new","progress","ready","delivered"].includes(req.body.status)?req.body.status:"new";
  db.prepare("UPDATE applications SET status=?, updated=? WHERE id=?").run(st, Date.now(), a.id);
  ev("apply","حالة معاملة "+a.name+" → "+st);
  res.json({ok:1});
});
app.post("/siwad/api/app/result", guard, (req,res)=>{
  const a=db.prepare("SELECT * FROM applications WHERE id=?").get(req.body.id);
  if(!a) return res.json({ok:0});
  const img=String(req.body.img||"");
  if(!img.startsWith("data:image/")) return res.json({ok:0, err:"صورة مش صالحة"});
  if(img.length>3.2e6) return res.json({ok:0, err:"الصورة كبيرة"});
  db.prepare("UPDATE applications SET res_img=?, status='ready', updated=? WHERE id=?").run(img, Date.now(), a.id);
  ev("apply","📎 رُفعت معاملة "+a.name+" — جاهزة");
  res.json({ok:1});
});
app.post("/siwad/api/app/delete", guard, (req,res)=>{
  const a=db.prepare("SELECT * FROM applications WHERE id=?").get(req.body.id);
  if(a){ db.prepare("DELETE FROM applications WHERE id=?").run(a.id); ev("apply","حذف معاملة "+a.name); }
  res.json({ok:1});
});
app.post("/siwad/api/delete", guard, (req,res)=>{''',
"نقاط اللوحة /siwad/api/apps")

# ---------- 5) تبويب اللوحة ----------
rep('''  <button class="tab" data-t="bc" onclick="tab('bc')">📣 إعلان جماعي</button>''',
'''  <button class="tab" data-t="ap" onclick="tab('ap')">📄 المعاملات <span id="apBadge"></span></button>
  <button class="tab" data-t="bc" onclick="tab('bc')">📣 إعلان جماعي</button>''',
"زر التبويب")

rep('''<div id="t-bc" style="display:none">''',
'''<div id="t-ap" style="display:none">
  <div class="filters">
    <button class="f on" data-af="all" onclick="aflt('all')">الكل</button>
    <button class="f" data-af="new" onclick="aflt('new')">🆕 جديدة</button>
    <button class="f" data-af="progress" onclick="aflt('progress')">⏳ قيد التنفيذ</button>
    <button class="f" data-af="ready" onclick="aflt('ready')">✅ جاهزة</button>
    <button class="f" data-af="delivered" onclick="aflt('delivered')">📬 تسلّمها</button>
  </div>
  <div id="apList"></div>
</div>

<div id="t-bc" style="display:none">''',
"قسم المعاملات")

# ---------- 6) جافاسكربت اللوحة ----------
rep(''' ["ov","st","bc","se"].forEach(x=>$("#t-"+x).style.display=x===t?"":"none");}''',
''' ["ov","st","ap","bc","se"].forEach(x=>$("#t-"+x).style.display=x===t?"":"none");
 if(t==="ap") loadApps();}
var AF="all", APPS=[];
function aflt(f){AF=f;document.querySelectorAll("[data-af]").forEach(x=>x.classList.toggle("on",x.dataset.af===f));renderApps();}
function stLbl(s){return s==="new"?"🆕 جديدة":s==="progress"?"⏳ قيد التنفيذ":s==="ready"?"✅ جاهزة":"📬 تسلّمها";}
async function loadApps(){ var r=await api("apps"); APPS=(r&&r.rows)||[]; renderApps(); }
function renderApps(){
  var L=APPS.filter(function(a){return AF==="all"||a.status===AF;});
  var nNew=APPS.filter(function(a){return a.status==="new";}).length;
  var bd=$("#apBadge"); if(bd) bd.textContent=nNew?("("+nNew+")"):"";
  $("#apList").innerHTML=L.map(function(a){
    return '<div class="stu"><div>'+
    '<span class="st '+(a.status==="new"?"p":"a")+'">'+stLbl(a.status)+'</span>'+
    '<div class="nm">'+esc(a.full_name||a.name)+'</div><span class="ph">'+esc(a.contact||("0"+a.phone))+'</span>'+
    '<div class="meta">'+(a.gear==="auto"?"🅰️ أوتوماتيك":"⚙️ جير عادي")+' · '+
      (a.delivery==="health"?"🏥 توصيل للصحة":"🚗 توصيل لمكانه")+'</div>'+
    '<div class="meta">قدّم '+ago(a.created)+(a.note?(' · 📝 '+esc(a.note)):'')+'</div></div>'+
    '<div class="acts">'+
    '<button class="btn sm ghost" data-aa="view" data-id="'+a.id+'">🖼️ الصور</button>'+
    '<button class="btn sm g" data-aa="up" data-id="'+a.id+'">📎 ارفع المعاملة</button>'+
    '<button class="btn sm ghost" data-aa="st" data-id="'+a.id+'">🔄 الحالة</button>'+
    '<a class="btn sm ghost" style="text-decoration:none" target="_blank" href="https://wa.me/972'+a.phone+'">واتساب</a>'+
    '<button class="btn sm r" data-aa="del" data-id="'+a.id+'" data-nm="'+esc(a.name)+'">🗑️</button>'+
    '</div></div>';
  }).join("")||'<div class="hint" style="text-align:center;padding:20px">ما في معاملات</div>';
  document.querySelectorAll("#apList [data-aa]").forEach(function(b){ b.onclick=function(){
    var id=+b.dataset.id, a=b.dataset.aa;
    if(a==="view")appView(id); else if(a==="up")appUp(id);
    else if(a==="st")appSt(id); else if(a==="del")appDel(id,b.dataset.nm);
  };});
}
async function appView(id){
  var r=await api("app?id="+id); if(!r.ok)return;
  var w=window.open("","_blank");
  var d='<html dir="rtl"><head><meta charset="utf8"><title>صور المعاملة</title></head>'+
    '<body style="background:#111;margin:0;padding:12px;text-align:center;font-family:sans-serif">'+
    '<p style="color:#fff">صورة الهوية</p><img style="max-width:100%;border-radius:10px" src="'+r.app.id_img+'">'+
    '<p style="color:#fff">صورة شخصية</p><img style="max-width:100%;border-radius:10px" src="'+r.app.me_img+'">'+
    (r.app.res_img?('<p style="color:#0f0">المعاملة المرفوعة</p><img style="max-width:100%;border-radius:10px" src="'+r.app.res_img+'">'):'')+
    '</body></html>';
  w.document.write(d); w.document.close();
}
function appUp(id){
  var inp=document.createElement("input"); inp.type="file"; inp.accept="image/*";
  inp.onchange=function(){
    var f=inp.files[0]; if(!f)return;
    var rd=new FileReader();
    rd.onload=function(){
      var im=new Image();
      im.onload=async function(){
        var mx=1400, sc=Math.min(1, mx/Math.max(im.width,im.height));
        var cv=document.createElement("canvas");
        cv.width=Math.round(im.width*sc); cv.height=Math.round(im.height*sc);
        cv.getContext("2d").drawImage(im,0,0,cv.width,cv.height);
        var data=cv.toDataURL("image/jpeg",0.72);
        var r=await api("app/result",{id:id,img:data});
        alert(r.ok?"انرفعت ✅ — صارت جاهزة والطالب بيشوفها":(r.err||"ما زبطت"));
        loadApps();
      };
      im.src=rd.result;
    };
    rd.readAsDataURL(f);
  };
  inp.click();
}
async function appSt(id){
  var NL2=String.fromCharCode(10);
  var s=prompt("الحالة الجديدة:"+NL2+"1 = جديدة"+NL2+"2 = قيد التنفيذ"+NL2+"3 = جاهزة"+NL2+"4 = تسلّمها");
  var m={"1":"new","2":"progress","3":"ready","4":"delivered"};
  if(!m[s])return;
  await api("app/status",{id:id,status:m[s]}); loadApps();
}
async function appDel(id,nm){ if(!confirm("حذف معاملة "+nm+"؟"))return;
  await api("app/delete",{id:id}); loadApps(); }''',
"جافاسكربت اللوحة")

assert h!=orig
open(P,"w",encoding="utf-8").write(h)
print("PATCH APPLIED")
