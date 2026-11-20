#!/bin/sh
# Throwaway CA + server cert for rd.test (test only).
set -eu
cd /certs
[ -s server.crt ] && exit 0
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=rd-e2e-ca" -keyout ca.key -out ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=rd.test" -keyout server.key -out server.csr 2>/dev/null
cat > san.ext <<EXT
subjectAltName=DNS:rd.test,DNS:edge.test
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EXT
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile san.ext -out server.crt 2>/dev/null
chmod 644 server.key
