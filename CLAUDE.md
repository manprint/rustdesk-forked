# rustdesk-deploy-ssl

Deploy Docker di RustDesk server (hbbs + hbbr) raggiungibile solo via WebSocket su 443 dietro
Apache/nginx. Uso e deploy: `README.md`; scelte, risultati e storia: `README.md` sezione
"Sviluppo". Comandi: `make help`.

## Mappa

- `server/`: sorgenti vendorizzati = fork `lejianwen/rustdesk-server@forapi` + upstream
  `rustdesk/rustdesk-server` + hardening locale. Commit di provenienza in `server/UPSTREAM`.
  Logica principale: `src/rendezvous_server.rs` (hbbs), `src/relay_server.rs` (hbbr).
- `Makefile`: `images` (`server`, `allinone`), `smoke`, `save`, `push`, `test`, `e2e`, `audit`, `sync`, `clean`.
- `.github/workflows/docker.yml`: build + `scripts/smoke-allinone.sh` + push di
  `ghcr.io/manprint/rustdesk-allinone` (`:main` a ogni push su `main`, `:X.Y.Z`/`:X.Y`/`:latest`
  per i tag `vX.Y.Z`). Action fissate per commit: per alzarle,
  `git ls-remote https://github.com/<action> refs/tags/<vN>`.
- `Dockerfile` + `docker-compose.yml`: immagine `rustdesk-server-ws`, deploy hbbs + hbbr (porte ws
  21118/21119 solo su loopback).
- `Dockerfile.allinone` + `compose.allinone.yml` + `allinone/rootfs`: immagine `rustdesk-allinone`,
  container unico con nginx e s6-overlay; `rd-render-nginx` genera la config nginx **dai file di
  `nginx/`** (non duplicarli). Il compose è di default in modalità plain (dietro proxy di
  frontiera); ssl si attiva scambiando le righe `[plain]`/`[ssl]`. `/data` è un bind mount
  (`RD_DATA_DIR`, `10001:10001`, `0700`, deve esistere).
- `apache/`, `nginx/`: config proxy di produzione. I test e2e montano questi stessi file.
- `scripts/cargo.sh`: cargo dentro l'immagine Rust fissata. `scripts/sync-upstream.sh`: merge upstream.
- `test/e2e/run.sh`: suite e2e + stabilità, 6 varianti (`variant-*.yml`), client reale.

## Vincoli da non rompere

- hbbs/hbbr si fidano di `X-Real-IP`: le porte ws devono restare raggiungibili solo dal proxy,
  e ogni config proxy deve sovrascrivere quell'header.
- I proxy lasciano passare solo `/ws/id` e `/ws/relay` con upgrade WebSocket; il resto è 404.
- Timeout tunnel dei proxy (120 s) > heartbeat del server (10 s) e keep-alive client (30 s).
- Una modifica a `apache/` o `nginx/` va validata con la variante e2e corrispondente; una a
  `nginx/` anche con `allinone-*` (stessi file).
- `rd-render-nginx` e `test/e2e/nginx/start.sh` adattano i file di `nginx/` con `sed` su stringhe
  letterali: `rustdesk.example.com`, `listen 443 ssl;`, `listen 80;`, `set_real_ip_from 10.0.0.1;`,
  `/etc/ssl/rustdesk/{fullchain,privkey}.pem`, `127.0.0.1:21118`, `127.0.0.1:21119`. Se cambiano
  nei file, aggiornare i due script.
- Nomi immagine e tag: `rustdesk-server-ws:${RD_TAG}` e `${RD_IMAGE:-rustdesk-allinone}:${RD_TAG}`
  nei compose devono coincidere con `IMAGES` e `TAG` del `Makefile`; il nome su ghcr
  (`rustdesk-allinone`) è in `env.IMAGE` del workflow.
- I commenti nel codice e nelle config sono in inglese; documentazione in italiano.

## Stato di `server/` (verificato il 2026-11-19 contro i commit di `server/UPSTREAM`)

- Identici a upstream: `libs/hbb_common` (tutto), `src/relay_server.rs`, `common.rs`,
  `database.rs`, `peer.rs`, `hbbr.rs`, `utils.rs`, `build.rs`.
- Dal fork: `src/jwt.rs`, `src/version.rs`, `tests/jwt_tests.rs`, `--must-login` in `src/main.rs`,
  `pub mod jwt` in `src/lib.rs`, feature `serde` di `chrono` in `Cargo.toml`.
- Locale: solo `src/rendezvous_server.rs` (registro peer WebSocket `WsReg`, `register_ws_peer`,
  `unregister_ws_peer`, `touch_ws_peer`, `send_to_ws_peer`, `recv_ws_queue`; `send`/`send_bytes`
  con `SINK_SEND_TIMEOUT`; `MAX_WS_PEERS`, `MAX_REG_PER_IP`, `MAX_IDS_PER_IP`; heartbeat
  `WS_HEARTBEAT_MS`, `WS_DEAD_PEER_MS`) e `Cargo.lock`.
- Tenere le modifiche locali in `server/src`: `libs/hbb_common` viene sovrascritto a ogni sync.
- Per rifare il confronto:
  `. server/UPSTREAM; git clone -q $UPSTREAM_REPO /tmp/up; git -C /tmp/up checkout -q $UPSTREAM_COMMIT; diff -rq -x libs /tmp/up/src server/src`

## Aggiornamento e fix di sicurezza

Eseguire in ordine; ogni passo va committato a parte. Mai saltare il punto 6.

1. **Sorgenti upstream**: `make sync` (= `scripts/sync-upstream.sh master`; `REF=<tag|commit>` per
   un ref preciso). Richiede `server/` senza modifiche pendenti in git.
   Fa il merge a tre vie file per file,
   sostituisce `libs/hbb_common` con il commit puntato da upstream e riscrive `server/UPSTREAM`.
   - Conflitti: `grep -rn '<<<<<<<' server/` e file `*.upstream` (aggiunti da entrambe le parti).
     Attesi solo in `src/rendezvous_server.rs` (già successo nel merge `36a0996..680b603`):
     risolvere tenendo sia il supporto WebSocket del fork sia l'hardening locale.
   - `Cargo.lock` in conflitto: prendere la versione upstream e rifare il punto 3 (gli
     aggiornamenti mirati vanno riapplicati).
   - Se cambia `libs/hbb_common/protos/*.proto`: il tester e2e li ricompila da lì alla build,
     controllare `test/e2e/tester/e2e.py` solo se cambiano i messaggi usati.
2. **Fork**: se lo script segnala `NOTE: fork forapi moved`, rivedere a mano
   `git diff FORK_COMMIT..<nuovo>` nel repo del fork, portare solo ciò che serve a hbbs/hbbr
   (non l'API/web console) e aggiornare `FORK_COMMIT` in `server/UPSTREAM`.
3. **Dipendenze Rust**: `make audit`. Baseline al 2026-11-19: **20 advisory senza fix
   semver-compatibile** (`sqlx` 0.6, `libsqlite3-sys` 0.24, `rustls` 0.20/0.21, `rustls-webpki`
   0.101, `webpki-roots` 0.22/0.25/0.26, `ring` 0.16, `h2` 0.3, `quick-xml`, `users`,
   `crypto-bigint`; tabella di raggiungibilità nel README). Un numero più alto = advisory nuovi:
   - `scripts/cargo.sh update -p <crate>` (più `-p` in un comando; `-p nome@versione` se il lock
     ne ha più versioni). Evitare `update` globale: 574 crate, rischio inutile.
   - Se cargo non sale da solo: `update -p <crate> --precise <versione>` (servito per `axum`
     0.5.17 → `axum-core` 0.2.9 e per `rustls` 0.23.46).
   - `scripts/cargo.sh tree --locked -i <crate>` mostra chi trascina una crate.
   - Un fix che richiede un major in `server/Cargo.toml` è una divergenza da upstream: decisione
     dell'utente, non farla di iniziativa.
4. **Toolchain e immagini base** (fissate, vanno alzate a mano):
   - `ARG RUST_IMAGE` (tag + digest) in `Dockerfile` **e** `Dockerfile.allinone`: devono coincidere
     (`scripts/cargo.sh` legge quello di `Dockerfile`).
   - `ARG NGINX_IMAGE` e `S6_VERSION` + i tre `S6_SHA_*` in `Dockerfile.allinone` (sha256 dai file
     `.sha256` della release s6-overlay).
   - Immagini dei test: `httpd`, `nginx` in `test/e2e/variant-*.yml`, `python`/`ubuntu` nei
     Dockerfile di `test/e2e/`, `RUSTDESK_CLIENT_VERSION` in `test/e2e/client/Dockerfile` (alzarla
     per verificare la compatibilità con i client nuovi).
5. **Build e test unitari**: `make test` (30 test, ~2 min più la compilazione), poi `make images`.
6. **Suite e2e**: `make e2e` deve dare tutto PASS: 6 varianti × 8 passi = 48 `PASS` nel `SUMMARY`.
   ~8 min a variante, ~50 min in tutto, una variante alla volta (rete e progetto compose fissi).
7. **Rilascio**: tag `vX.Y.Z` su `main` e `git push origin vX.Y.Z` (la CI pubblica l'all-in-one
   su ghcr; un tag già pubblicato non va spostato, se la CI fallisce si corregge e si rilascia la
   patch successiva). In alternativa `make images TAG=<tag>` (poi `make save` o `make push REGISTRY=...`), `RD_TAG`
   in `.env`, `docker compose up -d` (hbbs riavviato = tutti i dispositivi si ricollegano in
   ~20 s; hbbr riavviato = sessioni in corso interrotte). Per i proxy usare reload, non restart.
8. Pulizia: `make clean`, `docker builder prune`.

Fix di sicurezza scritto in casa: modificare `server/src`, aggiungere un test (unitario in
`server/` o un controllo in `test/e2e/tester/e2e.py`), poi punti 5-7. Se il fix vale anche per
upstream resterà come modifica locale: il merge a tre vie del punto 1 lo conserva.

Cosa controllare periodicamente: release di `rustdesk/rustdesk-server` e `rustdesk/hbb_common`,
ramo `forapi` del fork, advisory RustSec (`make audit`), release di nginx/httpd/s6-overlay,
nuove versioni del client RustDesk (cambi nel protocollo WebSocket).

## Note operative

- Output lungo dei test: leggere solo le righe `PASS|FAIL|RESULT` e il `SUMMARY` finale.
- Non modificare `test/e2e/run.sh` mentre è in esecuzione (bash lo legge a pezzi).
- `scripts/cargo.sh` usa volumi Docker `rustdesk-cargo-*` come cache: si possono eliminare
  (`make clean`); il primo `audit` dopo ricompila `cargo-audit`. Non lanciarlo durante i test e2e.
- I test unitari creano `server/test.sqlite3*` (ignorati da git e dal build context).
- `.dockerignore` esclude `**/*.md` e `dist`: modificare la documentazione non invalida la cache.
- `docker compose config` e `build` richiedono `RD_DOMAIN` (in `.env` o nell'ambiente).
- `axum` è dichiarato ma non usato in `server/src`; `sqlx` usa solo sqlite (niente TLS). L'unico
  TLS in uscita è `check_software_update()` (`src/main.rs`, POST giornaliero via `reqwest`).
- IP blocker di hbbs: oltre `MAX_REG_PER_IP` registrazioni nuove da un IP, rifiuto per 60 s
  (`IP_BLOCK_DUR`); i dispositivi già noti sono esenti. Lo step e2e di reload gira subito dopo
  quel test: il tester riprova e stampa `READY`, `run.sh` fa il reload solo dopo.
- nginx risolve gli upstream all'avvio ed esce se non esistono: nei test servono `depends_on` e
  `restart: on-failure` (in produzione gli upstream sono su `127.0.0.1`).
- `compose.allinone.yml` non è coperto da `make e2e` (i test usano l'immagine con i propri
  compose): dopo una modifica provarlo a mano in plain e ssl (`up -d`, stato `healthy`,
  `curl` con upgrade WebSocket su `/ws/id` = 101). Rete fissa `172.31.251.0/24`: il gateway è il
  default di `RD_EDGE_PROXY` (quella dei test è `172.31.250.0/24`).
- Script eseguiti via `docker exec` nell'all-in-one (healthcheck): `#!/bin/sh`, non
  `with-contenv` (`/command` non è nel `PATH`).
- In questa sandbox il repo è su virtiofs e `chown` non ha effetto: per provare il bind mount
  usare `RD_DATA_DIR` su un filesystem locale. `curl` verso nomi di test: `--noproxy '*'`.
- `.dockerignore` esclude `data` e `certs` (cartelle `0700` di un altro uid romperebbero la build).
- Build arm64 (`make images PLATFORM=linux/arm64`) mai provata.
