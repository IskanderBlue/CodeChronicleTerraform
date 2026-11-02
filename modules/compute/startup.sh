#!/bin/bash
set -euo pipefail

# COS can boot with a restrictive host firewall (INPUT DROP). Ensure required ingress is allowed.
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT

# Drop TCP packets that carry IP options, before the TCP stack sees them.
# CVE-2026-98432 is reached through the IP options of a TCP handshake, and no
# normal client sends IP options.  The fixed kernel (see boot_image) is the
# real fix; this rule is the second defence.  The u32 test reads the IPv4
# header length: more than 5 words means the packet has options.  Dropped
# packets are logged with the prefix "ipopts-drop: " (journalctl -k).
#
# Not fatal: this script runs with set -e, and a missing iptables module must
# not stop the app from starting.
IPOPTS_MATCH=(-p tcp -m u32 --u32 "0>>24&0xF=6:15")
add_raw_rule() {
  iptables -t raw -C PREROUTING "$@" 2>/dev/null || iptables -t raw -I PREROUTING 1 "$@"
}
# DROP first, then LOG at position 1, so LOG sits above DROP.
if ! { add_raw_rule "$${IPOPTS_MATCH[@]}" -j DROP &&
  add_raw_rule "$${IPOPTS_MATCH[@]}" -m limit --limit 6/min -j LOG --log-prefix "ipopts-drop: "; }; then
  echo "WARNING: could not add the IP-options drop rule" >&2
fi

systemctl start docker

METADATA="http://metadata.google.internal/computeMetadata/v1"
TOKEN=""

for i in $(seq 1 10); do
  TOKEN=$(curl -sf -H "Metadata-Flavor: Google" "$METADATA/instance/service-accounts/default/token" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) && break
  echo "Waiting for metadata service... (attempt $i)"
  sleep 3
done

if [ -z "$TOKEN" ]; then
  echo "Failed to get access token from metadata service"
  exit 1
fi

fetch_secret() {
  curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "https://secretmanager.googleapis.com/v1/$1/versions/latest:access" \
    | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['payload']['data']).decode(), end='')"
}

mkdir -p /home/codechroniclenet

cat > /home/codechroniclenet/.env <<EOF
GCP_PROJECT_ID=${project_id}
DJANGO_SETTINGS_MODULE=code_chronicle.settings.production
ALLOWED_HOSTS=${allowed_hosts}
EOF

fetch_secret "${secret_names["cf_origin_cert"]}" > /home/codechroniclenet/origin.pem
fetch_secret "${secret_names["cf_origin_key"]}" > /home/codechroniclenet/origin-key.pem
chmod 600 /home/codechroniclenet/origin-key.pem

cd /home/codechroniclenet

cat > deploy-web.sh <<'DEPLOY'
${deploy_script}
DEPLOY
chmod 755 /home/codechroniclenet/deploy-web.sh

cat > nginx.conf <<'NGINX'
events {}
http {
    include /etc/nginx/mime.types;
    # Two types blocks in the SAME context add to one map, so this extends
    # mime.types rather than replacing it.  A types block inside a location
    # replaces the map instead, which is how every .png under /static/ came to
    # be served as application/octet-stream, and why no social card drew.
    types {
        application/javascript mjs;
    }
    default_type application/octet-stream;

    upstream django_app {
        server 127.0.0.1:8000;
    }

    # The page cache.  A crawler asks for the same read page again days later,
    # after the one-hour edge copy has gone, and each request woke the Neon
    # compute.  A hit here runs no Django and reads no row.
    #
    # The app decides what is kept and for how long: it sends X-Accel-Expires
    # only on an anonymous 200 from a read page (web/http_cache.py in the app).
    # proxy_ignore_headers below makes that header the only signal, and with
    # no proxy_cache_valid nothing else is kept.  nginx also keeps nothing that
    # carries Set-Cookie.  deploy-web.sh clears the cache on every deploy.
    #
    # inactive is longer than the app's 7 days, so an entry expires by its own
    # time and not by disuse.  max_size is far above the ~400 MB the whole
    # free-tier corpus needs.
    proxy_cache_path /var/cache/nginx/pages levels=1:2 keys_zone=pages:10m
                     max_size=1g inactive=8d use_temp_path=off;
    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }
    server {
        listen 443 ssl;
        server_name _;
        ssl_certificate /etc/nginx/certs/origin.pem;
        ssl_certificate_key /etc/nginx/certs/origin-key.pem;
        location /static/ {
            alias /staticfiles/;
            try_files $uri =404;
            access_log off;
            expires 30d;
        }
        location / {
            proxy_pass http://django_app;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_redirect off;

            proxy_cache pages;
            # The host is in the key: a page names its own origin in the
            # canonical link, and www, app and the apex all serve it.
            proxy_cache_key "$scheme$host$request_uri";
            proxy_ignore_headers Cache-Control Expires;
            # A session cookie means a reader the tier gate may treat
            # differently.  Never answer that request from the cache, and
            # never keep its answer.  The edge cache rule uses the same test.
            proxy_cache_bypass $cookie_sessionid;
            proxy_no_cache $cookie_sessionid;
            # Two bots asking for one new page at once cost one render.
            proxy_cache_lock on;
            # If Django or Neon fails, an expired copy is better than an error.
            proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
            # HIT, MISS, BYPASS or nothing: shows in curl -I and in the log.
            add_header X-Page-Cache $upstream_cache_status always;
        }
    }
}
NGINX

docker rm -f codechroniclenet-nginx 2>/dev/null || true

docker volume create staticfiles 2>/dev/null || true

bash /home/codechroniclenet/deploy-web.sh ${app_image}

# Daily off-host encrypted backup of the irreproducible user data.
# CodeChronicle: tasks/complete/security-hardening-rollout.md, B7.
#
# A systemd timer, not cron: Container-Optimized OS ships no crontab for any
# user, including root.  It also belongs to the machine rather than to whoever
# last logged in, which a user crontab would not.
#
# This lives here because startup.sh is what rebuilds the VM.  Units written by
# hand into /etc survive a reboot but not a rebuild, and a schedule lost in a
# rebuild is silent — which is the exact failure the dead-man's switch
# (BACKUP_HEALTHCHECK_URL) exists to catch.
cat > /etc/systemd/system/cc-backup.service <<'UNIT'
[Unit]
Description=CodeChronicle off-host encrypted user-data backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec codechroniclenet-web python manage.py backup_userdata
# The retention purge rides the backup's schedule rather than getting a timer
# of its own.  CodeChronicle's Privacy Policy says a reading record is kept for
# up to two years and then deleted; purge_reading_records does the deleting,
# and until this line nothing called it, so the sentence was a promise with no
# machinery.  Daily is more often than the promise needs, and that is the
# point: the cheapest schedule is the one that already runs.
#
# --apply, because without it the command only reports, which is right for a
# person and useless for a timer.  The retention period is the command's own
# default (730 days), so the promise has one home.
#
# Order matters twice.  It runs AFTER the backup, so a delete always has a
# fresh backup behind it, and systemd stops a Type=oneshot unit at the first
# ExecStart that fails — a backup that did not work is not followed by a
# delete.  And the backup pings BACKUP_HEALTHCHECK_URL from inside
# backup_userdata, so that alarm is already sent before this line runs and a
# purge failure can never redden it.  A backup alarm must mean the backup
# failed; an alarm nobody trusts is worse than none.
#
# A purge failure does leave the UNIT failed, visible in `systemctl status
# cc-backup`.  If that needs watching from off-host, give it its own
# healthchecks.io check (the free tier allows 20; period 1 day, grace 6 h)
# rather than folding it into the backup's.
ExecStart=/usr/bin/docker exec codechroniclenet-web python manage.py purge_reading_records --apply
UNIT

cat > /etc/systemd/system/cc-backup.timer <<'UNIT'
[Unit]
Description=Run the CodeChronicle backup daily

[Timer]
OnCalendar=*-*-* 07:00:00 UTC
# Runs a schedule missed while the VM was down, at the next boot.  It does not
# retry within the same day, so a deploy replacing the container while the
# timer fires costs one backup.
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now cc-backup.timer

docker run -d \
  --name codechroniclenet-nginx \
  --restart unless-stopped \
  --network host \
  -v ./nginx.conf:/etc/nginx/nginx.conf:ro \
  -v ./origin.pem:/etc/nginx/certs/origin.pem:ro \
  -v ./origin-key.pem:/etc/nginx/certs/origin-key.pem:ro \
  -v staticfiles:/staticfiles:ro \
  nginx:1.27-alpine
