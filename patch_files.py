P="/opt/teoria/server.js"
h=open(P,encoding="utf-8").read()
orig=h
def rep(old,new,label):
    global h
    assert old in h, "ANCHOR MISSING: "+label
    h=h.replace(old,new,1); print("  OK:",label)

# ========== 1) نقاط الملفات والنسخ الاحتياطي ==========
rep('''// ================= واجهة اللوحة =================''',
'''// ---------- إدارة الملفات والنسخ الاحتياطي ----------
const fs = require("fs");
const path = require("path");
const WEB = "/var/www/teoria";
const BAK = "/opt/teoria/backups";
try{ fs.mkdirSync(BAK,{recursive:true}); }catch(e){}

const SAFE = /^[A-Za-z0-9._-]+$/;
function safeName(n){
  n = String(n||"").trim().replace(/^.*[\\\\/]/,"");
  if(!SAFE.test(n)) return null;
  if(n.startsWith(".")) return null;
  const ok = /\\.(html|json|js|css|png|jpg|jpeg|webp|svg|txt|xml|ico|sh|py)$/i.test(n);
  return ok ? n : null;
}
function human(b){ return b>1048576 ? (b/1048576).toFixed(1)+"MB" : b>1024 ? Math.round(b/1024)+"KB" : b+"B"; }

app.get("/siwad/api/files", guard, (req,res)=>{
  try{
    const out = fs.readdirSync(WEB).filter(f=>{
      try{ return fs.statSync(path.join(WEB,f)).isFile(); }catch(e){ return false; }
    }).map(f=>{
      const st=fs.statSync(path.join(WEB,f));
      return { name:f, size:st.size, human:human(st.size), mtime:st.mtimeMs };
    }).sort((a,b)=>b.mtime-a.mtime);
    let vers=[];
    try{ vers = fs.readdirSync(BAK).filter(f=>f.endsWith(".bak")).sort().reverse().slice(0,40); }catch(e){}
    res.json({ok:1, files:out, versions:vers});
  }catch(e){ res.json({ok:0, err:String(e.message)}); }
});

app.post("/siwad/api/upload", guard, (req,res)=>{
  try{
    const b=req.body||{};
    const name = safeName(b.name);
    if(!name) return res.json({ok:0, err:"اسم ملف غير مسموح"});
    let data = String(b.data||"");
    const i = data.indexOf("base64,");
    if(i>=0) data = data.slice(i+7);
    const buf = Buffer.from(data, "base64");
    if(!buf.length) return res.json({ok:0, err:"الملف فاضي"});
    if(buf.length > 12*1024*1024) return res.json({ok:0, err:"الملف كبير (أكثر من 12 ميجا)"});
    const dest = path.join(WEB, name);
    // نسخة احتياطية من القديم قبل الاستبدال
    let backedUp=0;
    if(fs.existsSync(dest)){
      const stamp = new Date().toISOString().replace(/[:.]/g,"-").slice(0,19);
      fs.copyFileSync(dest, path.join(BAK, name+"."+stamp+".bak"));
      backedUp=1;
      // نبقي آخر 5 نسخ لكل ملف
      const olds = fs.readdirSync(BAK).filter(f=>f.startsWith(name+".") && f.endsWith(".bak")).sort();
      while(olds.length>5){ try{ fs.unlinkSync(path.join(BAK, olds.shift())); }catch(e){} }
    }
    fs.writeFileSync(dest, buf);
    ev("file","📤 رفع ملف: "+name+" ("+human(buf.length)+")"+(backedUp?" — القديم محفوظ":""));
    res.json({ok:1, name, size:human(buf.length), backedUp});
  }catch(e){ console.log(e); res.json({ok:0, err:"ما زبط الرفع"}); }
});

app.post("/siwad/api/file/restore", guard, (req,res)=>{
  try{
    const v = String(req.body.version||"");
    if(!/^[A-Za-z0-9._-]+\\.bak$/.test(v)) return res.json({ok:0, err:"نسخة غير صالحة"});
    const src = path.join(BAK, v);
    if(!fs.existsSync(src)) return res.json({ok:0, err:"النسخة مش موجودة"});
    const orig = v.replace(/\\.\\d{4}-\\d{2}-\\d{2}T[\\d-]+\\.bak$/,"");
    const name = safeName(orig);
    if(!name) return res.json({ok:0, err:"اسم غير مسموح"});
    fs.copyFileSync(src, path.join(WEB,name));
    ev("file","↩️ استرجاع "+name+" من نسخة "+v);
    res.json({ok:1, name});
  }catch(e){ res.json({ok:0, err:"ما زبط الاسترجاع"}); }
});

app.post("/siwad/api/file/delete", guard, (req,res)=>{
  try{
    const name = safeName(req.body.name);
    if(!name) return res.json({ok:0, err:"اسم غير مسموح"});
    if(name==="index.html") return res.json({ok:0, err:"ما بنحذف index.html"});
    const dest = path.join(WEB,name);
    if(fs.existsSync(dest)){
      const stamp = new Date().toISOString().replace(/[:.]/g,"-").slice(0,19);
      fs.copyFileSync(dest, path.join(BAK, name+"."+stamp+".bak"));
      fs.unlinkSync(dest);
      ev("file","🗑️ حذف "+name+" (نسخة محفوظة)");
    }
    res.json({ok:1});
  }catch(e){ res.json({ok:0, err:"ما زبط الحذف"}); }
});

// نسخة احتياطية كاملة: الموقع + قاعدة البيانات
function makeBackup(){
  const stamp = new Date().toISOString().slice(0,10);
  const out = "/tmp/teoria-backup-"+stamp+".tar.gz";
  try{ db.prepare("VACUUM INTO ?").run("/tmp/data-snapshot.db"); }
  catch(e){ try{ fs.copyFileSync("/opt/teoria/data.db","/tmp/data-snapshot.db"); }catch(_){} }
  execSync("tar -czf "+out+" -C /var/www teoria -C /tmp data-snapshot.db 2>/dev/null || tar -czf "+out+" -C /var/www teoria");
  try{ fs.unlinkSync("/tmp/data-snapshot.db"); }catch(e){}
  return out;
}
app.get("/siwad/api/backup", guard, (req,res)=>{
  try{
    const f = makeBackup();
    ev("file","⬇️ تنزيل نسخة احتياطية كاملة");
    res.download(f, path.basename(f), ()=>{ try{ fs.unlinkSync(f); }catch(e){} });
  }catch(e){ console.log(e); res.status(500).json({ok:0, err:"ما زبطت النسخة"}); }
});

// نسخة يومية تلقائية (7 نسخ دوّارة)
function dailyBackup(){
  try{
    const f = makeBackup();
    const day = new Date().getDay();
    fs.copyFileSync(f, "/opt/teoria/backups/daily-"+day+".tar.gz");
    try{ fs.unlinkSync(f); }catch(e){}
    ev("file","💾 نسخة احتياطية يومية تلقائية");
  }catch(e){ console.log("backup err", e.message); }
}

// ================= واجهة اللوحة =================''',
"نقاط الملفات")

# ========== 2) تشغيل النسخة اليومية ==========
rep('''  if(d.getUTCDay()===0 && d.getUTCHours()===3 && d.getUTCMinutes()<5) setS("remind_sent","");''',
'''  if(d.getUTCDay()===0 && d.getUTCHours()===3 && d.getUTCMinutes()<5) setS("remind_sent","");
  if(d.getUTCHours()===1 && d.getUTCMinutes()<5){
    if(getS("last_bak")!==d.toISOString().slice(0,10)){ setS("last_bak", d.toISOString().slice(0,10)); dailyBackup(); }
  }''',
"جدولة النسخة اليومية")

# ========== 3) تبويب اللوحة ==========
rep('''  <button class="tab" data-t="se" onclick="tab('se')">⚙️ إعدادات</button>''',
'''  <button class="tab" data-t="fl" onclick="tab('fl')">📤 الملفات</button>
  <button class="tab" data-t="se" onclick="tab('se')">⚙️ إعدادات</button>''',
"زر التبويب")

rep('''<div id="t-se" style="display:none">''',
'''<div id="t-fl" style="display:none">
  <div class="box">
    <h3>📤 رفع ملف للموقع</h3>
    <div class="hint">اختار الملف من جهازك وبينرفع للموقع فوراً — بلا جيت هَب ولا أوامر. الملف القديم بينحفظ كنسخة قبل الاستبدال.</div>
    <div class="row" style="margin-top:12px">
      <input type="file" id="flIn" multiple style="flex:1;min-width:200px">
      <button class="btn g" id="flGo">⬆️ ارفع</button>
    </div>
    <div id="flProg" style="margin-top:10px"></div>
    <div class="ok-t" id="flMsg"></div>
  </div>
  <div class="box">
    <h3>⬇️ نسخة احتياطية كاملة</h3>
    <div class="hint">بتنزّل ملف مضغوط فيه كل ملفات الموقع + قاعدة بيانات الطلاب والمعاملات. احفظه على جهازك أو الآيكلاود.</div>
    <button class="btn" style="margin-top:10px" id="bakGo">⬇️ نزّل نسخة احتياطية الآن</button>
    <div class="hint" style="margin-top:8px">🔄 وفي نسخة يومية تلقائية بتنحفظ عالسيرفر (آخر ٧ أيام).</div>
  </div>
  <div class="box">
    <h3>📁 ملفات الموقع</h3>
    <div id="flList"></div>
  </div>
  <div class="box">
    <h3>↩️ النسخ السابقة</h3>
    <div class="hint">آخر ٥ نسخ لكل ملف — لو رفعت ملف فيه غلطة، بترجع للنسخة اللي قبلها بكبسة.</div>
    <div id="flVers" style="margin-top:10px"></div>
  </div>
</div>

<div id="t-se" style="display:none">''',
"قسم الملفات")

# ========== 4) جافاسكربت اللوحة ==========
rep(''' ["ov","st","ap","bc","se"].forEach(x=>$("#t-"+x).style.display=x===t?"":"none");
 if(t==="ap") loadApps();}''',
''' ["ov","st","ap","fl","bc","se"].forEach(x=>$("#t-"+x).style.display=x===t?"":"none");
 if(t==="ap") loadApps();
 if(t==="fl") loadFiles();}
function fmtT(ms){ var d=new Date(ms); return d.toLocaleDateString("ar")+" "+d.toLocaleTimeString("ar",{hour:"2-digit",minute:"2-digit"}); }
async function loadFiles(){
  var r=await api("files"); if(!r||!r.ok) return;
  $("#flList").innerHTML=(r.files||[]).map(function(f){
    return '<div class="stu"><div><div class="nm">'+esc(f.name)+'</div>'+
      '<div class="meta">'+f.human+' · آخر تعديل '+fmtT(f.mtime)+'</div></div>'+
      '<div class="acts">'+
      '<a class="btn sm ghost" style="text-decoration:none" target="_blank" href="/'+encodeURIComponent(f.name)+'">👁️ افتح</a>'+
      '<button class="btn sm r" data-fd="'+esc(f.name)+'">🗑️</button>'+
      '</div></div>';
  }).join("")||'<div class="hint">ما في ملفات</div>';
  $("#flVers").innerHTML=(r.versions||[]).map(function(v){
    return '<div class="stu"><div><div class="nm" style="font-size:13px">'+esc(v)+'</div></div>'+
      '<div class="acts"><button class="btn sm ghost" data-fr="'+esc(v)+'">↩️ استرجع</button></div></div>';
  }).join("")||'<div class="hint">ما في نسخ بعد</div>';
  document.querySelectorAll("#flList [data-fd]").forEach(function(b){ b.onclick=function(){ delFile(b.dataset.fd); };});
  document.querySelectorAll("#flVers [data-fr]").forEach(function(b){ b.onclick=function(){ restFile(b.dataset.fr); };});
}
async function delFile(n){ if(!confirm("حذف "+n+"؟ (بينحفظ نسخة قبل الحذف)"))return;
  var r=await api("file/delete",{name:n}); if(!r.ok)alert(r.err||"ما زبط"); loadFiles(); }
async function restFile(v){ if(!confirm("استرجاع هالنسخة؟ رح تستبدل الملف الحالي."))return;
  var r=await api("file/restore",{version:v});
  alert(r.ok?("رجعنا "+r.name+" ✅"):(r.err||"ما زبط")); loadFiles(); }
function uploadOne(file){
  return new Promise(function(resolve){
    var rd=new FileReader();
    rd.onload=async function(){
      var r=await api("upload",{name:file.name, data:rd.result});
      resolve({name:file.name, ok:r&&r.ok, err:(r&&r.err)||""});
    };
    rd.onerror=function(){ resolve({name:file.name, ok:false, err:"ما قدرنا نقرأ الملف"}); };
    rd.readAsDataURL(file);
  });
}''',
"جافاسكربت الملفات")

rep('''load(); setInterval(load, 5000);''',
'''var flBtn=document.getElementById("flGo");
if(flBtn) flBtn.onclick=async function(){
  var inp=document.getElementById("flIn");
  if(!inp.files||!inp.files.length){ $("#flMsg").textContent="اختار ملف أول"; return; }
  flBtn.disabled=true; var old=flBtn.textContent; flBtn.textContent="جاري الرفع…";
  var files=Array.prototype.slice.call(inp.files), done=[];
  for(var i=0;i<files.length;i++){
    $("#flProg").innerHTML='<div class="prog"><i style="width:'+Math.round(i/files.length*100)+'%"></i></div><div class="hint">'+(i+1)+' / '+files.length+' — '+esc(files[i].name)+'</div>';
    done.push(await uploadOne(files[i]));
  }
  $("#flProg").innerHTML='<div class="prog"><i style="width:100%"></i></div>';
  var okN=done.filter(function(d){return d.ok;}).length;
  var bad=done.filter(function(d){return !d.ok;});
  $("#flMsg").innerHTML="انرفع "+okN+" / "+files.length+" ✅"+(bad.length?("<br>فشل: "+bad.map(function(b){return esc(b.name)+" ("+esc(b.err)+")";}).join("، ")):"");
  flBtn.disabled=false; flBtn.textContent=old; inp.value=""; loadFiles();
};
var bakBtn=document.getElementById("bakGo");
if(bakBtn) bakBtn.onclick=function(){
  bakBtn.disabled=true; var o=bakBtn.textContent; bakBtn.textContent="جاري التجهيز… (ممكن ياخد دقيقة)";
  var a=document.createElement("a"); a.href="/siwad/api/backup"; a.download="";
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(function(){ bakBtn.disabled=false; bakBtn.textContent=o; }, 6000);
};
load(); setInterval(load, 5000);''',
"ربط أزرار الملفات")

assert h!=orig
open(P,"w",encoding="utf-8").write(h)
print("PATCH APPLIED")
