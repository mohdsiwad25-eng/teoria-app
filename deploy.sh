#!/bin/bash
# ===== نشر موقع التوريا رسمياً على zakisouq.com + https + تحديث تلقائي =====
set -e
export DEBIAN_FRONTEND=noninteractive
DOMAIN="zakisouq.com"
EMAIL="mohd.siwad@gmail.com"
REPO="https://github.com/mohdsiwad25-eng/teoria-app.git"

echo ">>> [1/6] تنصيب Nginx والأدوات..."
apt install -y nginx git rsync certbot python3-certbot-nginx >/dev/null

echo ">>> [2/6] تنزيل الموقع من الريبو..."
if [ -d /opt/teoria-site/.git ]; then
  cd /opt/teoria-site && git fetch origin main && git reset --hard origin/main
else
  rm -rf /opt/teoria-site
  git clone --depth 1 "$REPO" /opt/teoria-site
fi

echo ">>> [3/6] سكربت التحديث التلقائي..."
cat > /opt/teoria/update-site.sh << 'UPD'
#!/bin/bash
cd /opt/teoria-site || exit 1
git fetch origin main >/dev/null 2>&1
LOCAL=$(git rev-parse HEAD); REMOTE=$(git rev-parse origin/main)
[ "$LOCAL" = "$REMOTE" ] && [ -f /var/www/teoria/index.html ] && exit 0
git reset --hard origin/main >/dev/null 2>&1
mkdir -p /var/www/teoria
rsync -a --delete --exclude '.git' --exclude 'setup.sh' --exclude 'deploy.sh' /opt/teoria-site/ /var/www/teoria/
# خلي التطبيق يقرأ الداتا من السيرفر نفسه بدل GitHub
find /var/www/teoria -maxdepth 1 -name '*.html' -exec sed -i 's|https://raw.githubusercontent.com/mohdsiwad25-eng/teoria-app/main/|/|g' {} \;
echo "site updated: $REMOTE"
UPD
chmod +x /opt/teoria/update-site.sh
/opt/teoria/update-site.sh || true

echo ">>> [4/6] إعداد Nginx..."
cat > /etc/nginx/sites-available/teoria << NGX
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/teoria;
    index index.html;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript image/svg+xml;
    location /api/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
    }
    location = /admin {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
    }
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGX
ln -sf /etc/nginx/sites-available/teoria /etc/nginx/sites-enabled/teoria
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo ">>> [5/6] شهادة https (Let's Encrypt)..."
if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect; then
  echo "https مفعل ✅"
else
  echo "⚠️ الشهادة ما زبطت (غالباً الـDNS لسا منتشر جزئياً)."
  echo "استنى 15 دقيقة وشغل بس هالأمر:"
  echo "certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL --redirect"
fi

echo ">>> [6/6] التحديث التلقائي كل 5 دقائق..."
( crontab -l 2>/dev/null | grep -v update-site ; echo "*/5 * * * * /opt/teoria/update-site.sh >> /var/log/teoria-update.log 2>&1" ) | crontab -

echo ""
echo "============================================"
echo "  🎉 الموقع الرسمي جاهز:"
echo "  https://${DOMAIN}"
echo "  لوحة الإدارة: https://${DOMAIN}/admin?pass=Teoria2026Admin"
echo "  التحديث: ارفع عالريبو والسيرفر بيسحب لحاله خلال 5 دقائق"
echo "============================================"
