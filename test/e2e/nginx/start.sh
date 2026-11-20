#!/bin/sh
# Installs the shipped nginx files with the test values substituted, then runs nginx.
set -eu
site=${RD_SITE:-rustdesk-ssl.conf}
cp /prod/nginx.conf /etc/nginx/nginx.conf
cp /prod/rustdesk-locations.conf /etc/nginx/rustdesk-locations.conf
rm -f /etc/nginx/conf.d/*
sed -e 's/127.0.0.1:21118/hbbs:21118/' -e 's/127.0.0.1:21119/hbbr:21119/' \
    /prod/rustdesk-http.conf > /etc/nginx/conf.d/00-rustdesk-http.conf
sed -e 's/rustdesk.example.com/rd.test/' -e 's/10.0.0.1;/172.31.250.10;/' \
    -e 's|/etc/ssl/rustdesk/fullchain.pem|/certs/server.crt|' \
    -e 's|/etc/ssl/rustdesk/privkey.pem|/certs/server.key|' \
    "/prod/$site" > /etc/nginx/conf.d/rustdesk.conf
nginx -t
exec nginx -g 'daemon off;'
