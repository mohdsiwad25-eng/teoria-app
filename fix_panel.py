P="/opt/teoria/server.js"
h=open(P,encoding="utf-8").read()
orig=h

# الإصلاح: نشيل الـ onclick المكسور ونستبدله بمعرّف + ربط لاحق (بلا أي quotes متداخلة)
bad_variants = [
  """<button class=\\"btn\\" style=\\"margin-top:10px\\" onclick=\\"tab(\\\\'st\\\\');flt(\\\\'pending\\\\')\\">شوف الطلاب المنتظرين ←</button>""",
  '''<button class="btn" style="margin-top:10px" onclick="tab(\\'st\\');flt(\\'pending\\')">شوف الطلاب المنتظرين ←</button>''',
]
good = '''<button class="btn" style="margin-top:10px" id="pendGo">شوف الطلاب المنتظرين ←</button>'''

hit=None
for b in bad_variants:
    if b in h: hit=b; break
if hit:
    h=h.replace(hit, good)
    print("  ✓ شلنا الـonclick المكسور")
else:
    # بحث مرن: أي زر فيه pendGo أو الشرطة المائلة داخل tab(
    import re
    m=re.search(r'<button class="btn" style="margin-top:10px" onclick="tab\([^"]*?\)">شوف الطلاب المنتظرين ←</button>', h)
    if m:
        h=h.replace(m.group(0), good); print("  ✓ شلنا الـonclick المكسور (بحث مرن)")
    else:
        print("  ! ما لقيت الزر — بنكمل للربط")

# نربط الزر بأمان بعد الرسم
anchor = """    : ''; }"""
if anchor in h and "pendGo" in h:
    h=h.replace(anchor, """    : '';
    var pg=document.getElementById("pendGo");
    if(pg) pg.onclick=function(){ tab("st"); flt("pending"); }; }""", 1)
    print("  ✓ ربطنا الزر بأمان")

# تنظيف احتياطي: أي \\' متبقية داخل قالب اللوحة
import re
before=h.count("\\'")
h=h.replace("tab(\\'st\\');flt(\\'pending\\')", 'tab("st");flt("pending")')
if h.count("\\'")!=before: print("  ✓ نظّفنا شرطات مائلة متبقية")

assert h!=orig, "ما في تغيير — يمكن الملف متأثر بشكل مختلف"
open(P,"w",encoding="utf-8").write(h)
print("FIXED")
