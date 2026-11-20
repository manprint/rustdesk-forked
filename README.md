# RustDesk self-hosted su sola porta 443

Server RustDesk (hbbs + hbbr) in Docker, raggiungibile **solo via HTTPS/WebSocket sulla 443**
dietro Apache o nginx. Nessuna porta 21114-21119 esposta, nessun UDP.

```
client RustDesk ──wss://DOMINIO/ws/id────┐                ┌─ hbbs :21118 (registrazione, segnalazione)
                                         ├─ proxy :443 ───┤
client RustDesk ──wss://DOMINIO/ws/relay─┘                └─ hbbr :21119 (relay delle sessioni)
```

## Cosa sapere prima

- Servono client RustDesk **≥ 1.4.1** con l'opzione WebSocket attiva. Testato con 1.5.3.
- Tutto il traffico delle sessioni passa dal relay (niente P2P/hole punching): la banda delle
  sessioni è banda del server.
- Non c'è API server né web console: `/api/*` risponde 404 (il client la interroga ogni ~15 s, è normale).
- Il codice in `server/` è vendorizzato: fork `lejianwen/rustdesk-server` (ramo `forapi`, supporto
  WebSocket) + upstream `rustdesk/rustdesk-server` + hardening locale. Provenienza in `server/UPSTREAM`.

## Contenuto

| Percorso | Cosa |
|---|---|
| `server/` | sorgenti hbbs/hbbr vendorizzati (con `libs/hbb_common`) |
| `Dockerfile`, `docker-compose.yml` | immagine statica (scratch, uid 10001) e deploy hbbs + hbbr |
| `Dockerfile.allinone`, `compose.allinone.yml`, `allinone/` | container unico hbbs + hbbr + nginx (s6-overlay) |
| `apache/`, `nginx/` | configurazioni proxy: TLS su 443 oppure HTTP su 80 dietro un proxy di frontiera |
| `Makefile` | build di tutte le immagini, export, push, test (`make help`) |
| `scripts/sync-upstream.sh` | riallinea `server/` a upstream |
| `scripts/cargo.sh` | cargo (test, update, audit) nell'immagine Rust fissata |
| `test/e2e/` | test end-to-end e di stabilità con client reale |

## Immagini

Le immagini sono due; `make images` le produce entrambe.

| Immagine | Dockerfile | Contenuto | Usata da |
|---|---|---|---|
| `rustdesk-server-ws` (~19 MB) | `Dockerfile` | `hbbs` e `hbbr` statici su `scratch`, uid 10001, nessuna shell | `docker-compose.yml`, con Apache o nginx sull'host |
| `rustdesk-allinone` (~122 MB) | `Dockerfile.allinone` | gli stessi binari + nginx + s6-overlay, uid 10001 | `compose.allinone.yml` |

Le modalità **ssl** e **plain** non sono immagini diverse: con `rustdesk-server-ws` dipendono dalla
configurazione proxy installata sull'host, con `rustdesk-allinone` dalla variabile `RD_MODE` a
runtime (righe `[plain]`/`[ssl]` di `compose.allinone.yml`). Le due immagini coprono quindi tutte e sei le varianti provate dai test.

```bash
make images                    # rustdesk-server-ws:local e rustdesk-allinone:local
make server                    # solo hbbs + hbbr
make allinone                  # solo all-in-one
make images TAG=1.1.17         # altro tag: poi RD_TAG=1.1.17 in .env
make save TAG=1.1.17           # dist/*.tar.gz + SHA256SUMS-1.1.17 per un host senza registry
make push TAG=1.1.17 REGISTRY=registry.example.com/infra/
make clean                     # immagini, residui dei test, volumi cache, dist/
```

Su un host senza registry: `gunzip -c rustdesk-server-ws-1.1.17.tar.gz | docker load`.
`docker compose build` resta equivalente a `make server` / `make allinone`, senza le label.
Ogni immagine porta le label `org.opencontainers.image.version` (versione di `server/Cargo.toml`),
`rustdesk.upstream.commit` e `rustdesk.fork.commit` (da `server/UPSTREAM`).

`PLATFORM=linux/arm64` passa `--platform` a `docker build`; `Dockerfile.allinone` prevede arm64
(checksum s6-overlay dedicato), ma **la build arm64 non è stata provata** e il client dei test è
solo x86_64.

## Deploy (hbbs + hbbr, proxy sull'host)

```bash
cp .env.example .env          # impostare RD_DOMAIN
make server                   # oppure: docker compose build
docker compose up -d
docker compose logs hbbs | grep 'Key:'     # chiave pubblica da dare ai client
```

hbbs e hbbr pubblicano solo `127.0.0.1:21118` e `127.0.0.1:21119`. **Non pubblicarle mai su un
indirizzo raggiungibile da altri che il proxy**: il server si fida dell'header `X-Real-IP`, che è
il proxy a sovrascrivere; chi le raggiunge direttamente può falsificare il proprio indirizzo e
aggirare i limiti per IP.

Poi installare una delle quattro configurazioni proxy.

### Apache (≥ 2.4.47)

Moduli: `ssl proxy proxy_http headers rewrite reqtimeout` (+ `remoteip` in modalità porta 80), MPM event.

```bash
a2enmod ssl proxy proxy_http headers rewrite reqtimeout remoteip mpm_event
mkdir -p /etc/apache2/rustdesk
cp apache/rustdesk-proxy.conf /etc/apache2/rustdesk/
cp apache/rustdesk-vars.conf  /etc/apache2/conf-available/rustdesk-vars.conf   # modificare i valori
cp apache/rustdesk-mpm.conf   /etc/apache2/mods-available/mpm_event.conf
a2enconf rustdesk-vars
cp apache/rustdesk-ssl.conf   /etc/apache2/sites-available/rustdesk.conf       # oppure rustdesk-plain.conf
a2ensite rustdesk && apachectl configtest && systemctl reload apache2
```

- `rustdesk-ssl.conf`: Apache termina TLS sulla 443.
- `rustdesk-plain.conf`: Apache in HTTP sulla 80 dietro un proxy di frontiera; impostare
  `RD_EDGE_PROXY` in `rustdesk-vars.conf`.

Apache tiene **un thread occupato per ogni tunnel aperto** (verificato: 300 dispositivi = 302 worker
occupati). Thread necessari = dispositivi collegati + 2 × sessioni contemporanee + altri siti.
`rustdesk-mpm.conf` ne prevede 2048; per crescere aumentare `ServerLimit` × `ThreadsPerChild`.
Con molti dispositivi nginx è la scelta più leggera.

### nginx

```bash
cp nginx/rustdesk-http.conf      /etc/nginx/conf.d/00-rustdesk-http.conf
cp nginx/rustdesk-locations.conf /etc/nginx/rustdesk-locations.conf
cp nginx/rustdesk-ssl.conf       /etc/nginx/conf.d/rustdesk.conf     # oppure rustdesk-plain.conf
# modificare server_name, certificati (ssl) o set_real_ip_from (plain)
nginx -t && systemctl reload nginx
```

Ogni tunnel usa due descrittori: riportare nel proprio `nginx.conf` i limiti di `nginx/nginx.conf`
(`worker_rlimit_nofile`, `worker_connections`).

### Modalità porta 80 dietro un proxy di frontiera

La porta 80 non va mai esposta a internet: deve raggiungerla solo il proxy di frontiera, che deve

- inoltrare gli header `Upgrade`/`Connection` (WebSocket) in HTTP/1.1,
- tollerare tunnel inattivi per almeno 120 s,
- inviare l'indirizzo del client in `X-Forwarded-For`,
- esporre verso i client HTTPS sulla 443 con un certificato valido per `RD_DOMAIN`.

## Deploy all-in-one

Un solo container con hbbs, hbbr e nginx supervisionati da s6-overlay, tutto come utente non
privilegiato (uid 10001); hbbs e hbbr ascoltano solo sul loopback del container.

`compose.allinone.yml` è impostato di default in modalità **plain**: HTTP sulla porta 8080,
pubblicata solo su `127.0.0.1`, per stare dietro un proxy di frontiera che termina TLS sulla 443.
Le righe delle due modalità sono nel file, marcate `[plain]` e `[ssl]`.

```bash
cp .env.example .env                                   # RD_DOMAIN
sudo install -d -o 10001 -g 10001 -m 0700 ./data       # cartella dati, vedi sotto
make allinone                 # oppure: docker compose -f compose.allinone.yml build
docker compose -f compose.allinone.yml up -d
docker compose -f compose.allinone.yml logs | grep 'Key:'
```

**Cartella dati** (`RD_DATA_DIR`, default `./data`, montata in bind su `/data`): contiene
`id_ed25519`, `id_ed25519.pub` e `db_v2.sqlite3`. Deve esistere prima dell'avvio con proprietario
`10001:10001` e permessi `0700`: il container gira come uid 10001 senza capability e non può
correggerli da solo. Se la cartella manca Docker rifiuta l'avvio (`bind source path does not
exist`), invece di crearla come root. Con Docker rootless o `userns-remap` l'uid sull'host è
quello rimappato.

| | plain (default) | ssl |
|---|---|---|
| `RD_MODE` | `plain` | `ssl` |
| Porta pubblicata | `127.0.0.1:8080:8080` | `443:8443` |
| Chi termina TLS | il proxy di frontiera | nginx nel container |
| Altro | `RD_EDGE_PROXY` | bind di `RD_CERT_DIR` su `/certs` |

- **plain**: il proxy di frontiera inoltra `/ws/id` e `/ws/relay` a `http://127.0.0.1:8080` e deve
  rispettare i requisiti elencati sopra (porta 80 dietro un proxy di frontiera). `RD_EDGE_PROXY`
  è l'indirizzo da cui il proxy arriva **visto dal container**: con il proxy sullo stesso host è
  il gateway della rete del compose, fissato a `172.31.251.1` (default, non va toccato); con il
  proxy su un altro host va messo il suo indirizzo, e nella riga `ports` `127.0.0.1` va
  sostituito con l'indirizzo di questo host sulla rete condivisa, filtrato dal firewall.
- **ssl**: commentare le righe `[plain]` e togliere il commento alle righe `[ssl]` (modalità,
  porta, volume dei certificati). In `RD_CERT_DIR` (default `./certs`) servono `fullchain.pem` e
  `privkey.pem`, **leggibili dall'uid 10001**:
  `sudo chown root:10001 certs/privkey.pem && sudo chmod 0640 certs/privkey.pem`. Dopo un rinnovo:
  `docker compose -f compose.allinone.yml exec rustdesk nginx -s reload`.
- Se la sottorete `172.31.251.0/24` è già usata, cambiarla in fondo al compose insieme al default
  di `RD_EDGE_PROXY`.

## Configurazione dei client

Impostazioni → Rete → Server ID/Relay:

| Campo | Valore |
|---|---|
| Server ID | `DOMINIO` |
| Server Relay | vuoto |
| Server API | `https://DOMINIO` (obbligatorio: è ciò che fa usare `wss://` al client) |
| Key | la chiave pubblica di hbbs (vedi "Dove sta la key") |

e attivare **Impostazioni → Rete → Usa WebSocket** (`allow-websocket = Y`). Per distribuzione di
massa le stesse opzioni vanno nel file `RustDesk2.toml` del client (è la configurazione usata
dal client reale dei test, `test/e2e/client/entrypoint.sh`):

```toml
[options]
custom-rendezvous-server = 'DOMINIO'
api-server = 'https://DOMINIO'
key = 'CHIAVE'
allow-websocket = 'Y'
```

### Dove sta la key

La key non è una variabile di `.env`: è la chiave pubblica della coppia ed25519 che hbbs genera al
primo avvio nella cartella dati. Con `-k _` hbbs e hbbr usano quella coppia e rifiutano i client
che non hanno la key.

| File in `/data` | Contenuto |
|---|---|
| `id_ed25519.pub` | chiave pubblica: è la **Key** da mettere nei client |
| `id_ed25519` | chiave privata: non va distribuita |

```bash
# all-in-one: cartella RD_DATA_DIR (0700 di uid 10001, serve sudo)
sudo cat ./data/id_ed25519.pub
docker compose -f compose.allinone.yml logs | grep 'Key:'

# hbbs + hbbr: volume rustdesk_data
docker compose logs hbbs | grep 'Key:'
docker run --rm -v rustdesk_data:/d:ro alpine cat /d/id_ed25519.pub
```

La key resta la stessa finché la cartella dati non viene cancellata, anche ricreando i container
o aggiornando l'immagine. Se i due file si perdono hbbs genera una coppia nuova e tutti i client
vanno riconfigurati.

**"La chiave non corrisponde"** sul client: il client che avvia la connessione ha mandato una key
diversa da quella del server (hbbs scrive `Authentication failed ... invalid key`). Lo stato
"Pronto" non la verifica: la registrazione del dispositivo non usa la key, la richiesta di
connessione sì. Controllare il campo Key su quel client e riavviare RustDesk dopo averlo cambiato.

## Limiti e regolazioni

| Parametro | Default | Dove | Note |
|---|---|---|---|
| `RD_MAX_WS_PEERS` | 10000 | `.env` | dispositivi registrati contemporaneamente |
| `RD_MAX_REG_PER_IP` | 30 | `.env` | **nuove** registrazioni per IP in 60 s |
| `RD_MAX_IDS_PER_IP` | 300 | `.env` | nuovi id distinti per IP al giorno |
| `limit_conn rd_conn` | 512 | nginx | tunnel per IP (un ufficio dietro NAT è un IP solo) |
| `limit_req rd_req` | 100 r/s, burst 1000 | nginx | nuove connessioni per IP |
| `MaxRequestWorkers` | 2048 | Apache | tunnel totali |

I dispositivi già noti al server (stesso id, uuid e chiave) non sono soggetti ai limiti per IP:
una sede intera dietro un NAT si ricollega tutta insieme. Alzare `RD_MAX_REG_PER_IP` e
`RD_MAX_IDS_PER_IP` solo per installazioni massive da un unico indirizzo.

## Stabilità: cosa aspettarsi

- Il server manda un heartbeat ogni 10 s su ogni connessione: i tunnel non restano mai inattivi
  per i timeout dei proxy (120 s).
- Un client che perde la connessione riprova con un ciclo fisso di circa 18 s (comportamento del
  client, non configurabile). Dopo un **restart** del proxy i dispositivi tornano raggiungibili
  entro ~20 s; nel frattempo risultano offline subito, senza attese.
- Per cambiare configurazione o certificati usare sempre **reload** (`systemctl reload apache2`,
  `nginx -s reload`): i tunnel aperti non vengono chiusi.
- Il riavvio di hbbr interrompe le sessioni in corso (i dispositivi restano registrati); il
  riavvio di hbbs fa ricollegare tutti i dispositivi, le sessioni in corso proseguono.

## Operatività

- **Backup**: volume `rustdesk_data` (all-in-one: la cartella `RD_DATA_DIR`). Contiene
  `id_ed25519` / `id_ed25519.pub` (se si perdono, tutti i client vanno riconfigurati con la nuova
  chiave) e `db_v2.sqlite3`.
  `docker run --rm -v rustdesk_data:/d:ro -v "$PWD":/b alpine tar czf /b/rustdesk-data.tgz -C /d .`
- **Log**: `docker compose logs -f hbbs hbbr`. L'errore `Failed to get machine uid` all'avvio è innocuo.
- **Aggiornamenti e fix di sicurezza**: procedura in `CLAUDE.md`.

## Test

```bash
make test                          # test unitari di server/ (30)
make e2e                           # tutte le varianti (~8 min ciascuna, non in parallelo)
make e2e V="nginx-ssl"             # una sola (equivale a test/e2e/run.sh nginx-ssl)
```

Varianti: `apache-ssl nginx-ssl apache-plain nginx-plain allinone-ssl allinone-plain`. Per ognuna:
client RustDesk reale che si registra e viene controllato via relay solo sulla 443, 8 MiB integri
nel relay, keepalive per 100 s, indirizzo reale del client (header falsificati ignorati), limiti
per IP, tunnel aperti che sopravvivono a un reload del proxy, ripristino dopo restart del proxy,
di hbbr e crash di hbbs, 300 dispositivi con 40 sessioni contemporanee e riconnessione di massa.
Dettagli nella sezione "Sviluppo".

## Hardening applicato

Server: coda di invio per dispositivo con timeout (un client lento non blocca gli altri), limite
ai dispositivi WebSocket, dimensione massima dei messaggi, nessun panic su input malformato,
limiti di registrazione per IP, relay configurato mantenuto anche se il DNS non risponde all'avvio,
dispositivo segnato offline appena cade la sua connessione.
Container: immagine `scratch` con binari statici, utente 10001, filesystem in sola lettura,
`cap_drop: ALL`, `no-new-privileges`, limiti su pid e file, porte solo su loopback.
Proxy: passano solo `/ws/id` e `/ws/relay` con richiesta di upgrade WebSocket (tutto il resto 404),
`X-Real-IP` sovrascritto, TLS 1.2/1.3, HSTS, timeout sugli header, limiti per IP (nginx).

## Sviluppo

Stato al 2026-11-19. Procedura operativa di aggiornamento: `CLAUDE.md`.

### Scelte di progetto

- **Solo 443.** RustDesk usa di norma TCP 21115-21117 e UDP 21116. hbbs e hbbr hanno anche due
  listener WebSocket (21118 e 21119): pubblicati dietro un proxy come `/ws/id` e `/ws/relay`
  bastano a un client desktop ≥ 1.4.1 con `allow-websocket` attivo e `api-server` in `https://`.
- **Sempre relay** (`ALWAYS_USE_RELAY=Y`): dietro il proxy non c'è altro di raggiungibile, i
  tentativi di connessione diretta aggiungerebbero solo ritardo.
- **Sorgenti vendorizzati** in `server/` invece dell'immagine upstream: servivano modifiche a hbbs
  (vedi sotto) e build riproducibili da un albero fissato.
- **Nessuna API/web console**: del fork si usa solo ciò che serve a hbbs e hbbr.
- **Una sola fonte per le config proxy**: i file di `apache/` e `nginx/` sono quelli di produzione,
  gli stessi montati dai test e copiati nell'immagine all-in-one (`rd-render-nginx` li adatta con
  `sed` all'avvio, non ne esiste una seconda copia).

### Composizione di `server/`

| Origine | Commit (`server/UPSTREAM`) | Data commit |
|---|---|---|
| upstream `rustdesk/rustdesk-server` | `680b6039` | 2026-11-08 |
| `rustdesk/hbb_common` → `libs/hbb_common` | `69cea8da` | 2026-07-26 |
| fork `lejianwen/rustdesk-server@forapi` | `fb8b5b9c` | 2025-09-01 |

Confronto con quei commit (2026-11-19):

- `libs/hbb_common` e i file `src/relay_server.rs`, `common.rs`, `database.rs`, `peer.rs`,
  `hbbr.rs`, `utils.rs` sono **identici a upstream**.
- Dal fork: `src/jwt.rs`, `src/version.rs`, `tests/jwt_tests.rs`, l'opzione `--must-login`
  (`src/main.rs`), `pub mod jwt` (`src/lib.rs`), la feature `serde` di `chrono` (`Cargo.toml`).
- **Modifiche locali: tutte in `src/rendezvous_server.rs`** (~740 righe di differenza da upstream,
  comprese quelle del fork). È l'unico file dove un merge da upstream può andare in conflitto.

Hardening locale in `src/rendezvous_server.rs`:

| Cosa | Dove |
|---|---|
| registro dei dispositivi WebSocket con coda per dispositivo (`WS_PEER_QUEUE` = 16) | `WsReg`, `register_ws_peer`, `send_to_ws_peer`, `recv_ws_queue` |
| invio con timeout, un client lento non blocca gli altri (`SINK_SEND_TIMEOUT` = 10 s) | `send`, `send_bytes` |
| heartbeat del server ogni 10 s, peer morto dopo 35 s | `WS_HEARTBEAT_MS`, `WS_DEAD_PEER_MS`, `touch_ws_peer` |
| dispositivo offline appena cade la sua connessione | `unregister_ws_peer` |
| tetto ai dispositivi WebSocket | `MAX_WS_PEERS` |
| limiti di registrazione per IP configurabili | `MAX_REG_PER_IP`, `MAX_IDS_PER_IP`, `check_ip_blocker` |

Il limite alla dimensione dei messaggi (`DEFAULT_MAX_MESSAGE_KB`, e `WS_DEFAULT_MAX_MESSAGE_SIZE`
in `relay_server.rs`) viene da upstream.

### Immagini e all-in-one

- Build in `rust:1.100-alpine3.24` fissata per digest (`ARG RUST_IMAGE`, uguale nei due
  Dockerfile): binari musl statici, `cargo build --release --locked`, LTO.
- `rustdesk-server-ws`: `scratch`, solo `/usr/bin/hbbs`, `/usr/bin/hbbr` e `/data`.
- `rustdesk-allinone`: base `nginx:1.29-alpine` + s6-overlay v3.2.3.2 (verificato con sha256).
  Servizi s6 in `allinone/rootfs/etc/s6-overlay/s6-rc.d`: `hbbs` → `hbbr`, `init-nginx`
  (esegue `rd-render-nginx`) → `nginx`. hbbs e hbbr ascoltano sul loopback del container; nginx su
  8443 (ssl) o 8080 (plain). Healthcheck: `rd-healthcheck` (porte 21118, 21119 e quella di nginx).
- Root in sola lettura: richiede `S6_READ_ONLY_ROOT=1` e `tmpfs` su `/run` (con `exec`) e `/tmp`,
  come in `compose.allinone.yml`. La config nginx generata sta in `/run/nginx/conf.d`.
- Variabili lette da `rd-render-nginx`: `RD_DOMAIN`, `RD_MODE`, `RD_EDGE_PROXY`, `RD_HTTPS_PORT`
  (8443), `RD_HTTP_PORT` (8080), `RD_TLS_CERT`, `RD_TLS_KEY`.

### Suite di test (`test/e2e/`)

- `docker-compose.test.yml` (hbbs, hbbr, `certs`, `client`, `tester`) + un `variant-*.yml` che
  aggiunge il proxy e possiede il nome `rd.test`. Nelle varianti `-plain` un secondo nginx (`edge`)
  fa da proxy di frontiera con TLS; nelle `allinone-*` hbbs/hbbr sono sostituiti dall'immagine unica.
- `client`: client RustDesk reale 1.5.3 (`.deb` ufficiale su Ubuntu) configurato solo WebSocket.
- `tester/e2e.py`: client di protocollo (websockets + protobuf di `hbb_common`) con quattro modalità:
  `e2e`, `steady`, `recover`, `load`.
- Rete fissa `172.31.250.0/24`, progetto compose `rd-e2e`: **una variante alla volta**.

Passi di `run.sh` per ogni variante:

1. protocollo, sessione, keepalive: 404 fuori da `/ws/*`, registrazione, chiave errata rifiutata,
   sessioni via relay, 8 MiB integri, 100 s di keepalive, IP blocker, offline immediato;
2. hbbs registra l'indirizzo reale del client (mai quello dei proxy, mai un header falsificato);
3. reload della configurazione del proxy con una sessione aperta: niente deve cadere;
4. ripristino dopo restart del proxy, 5. dopo restart di hbbr, 6. dopo crash di hbbs;
7. carico: 300 dispositivi da un solo IP, 45 s di tenuta, 40 sessioni contemporanee,
   riconnessione di massa;
8. il client reale è ancora controllabile dopo il carico.

Parametri: `RD_HOLD_SECONDS` (100), `RD_LOAD_DEVICES` (300), `RD_STEADY_SECONDS` (30),
`RD_RECOVER_MAX` (45), `RD_KEEP=1` lascia in piedi l'ultimo stack.

### Risultati misurati (2026-11-19)

- 6 varianti × 8 passi: **48/48 PASS**, due giri consecutivi; test unitari 30/30.
- Client reale di nuovo controllabile 14-17 s dopo restart del proxy o crash di hbbs (ciclo di
  retry del client: 18 s); 0-1 s dopo il restart di hbbr.
- 300 dispositivi registrati da un IP in meno di 1 s, riconnessione di massa in meno di 1 s.
- Reload graceful di Apache (`apachectl -k graceful`) e nginx (`nginx -s reload`): sessione relay,
  connessione del dispositivo e heartbeat restano attivi.
- Apache: 300 dispositivi = 302 worker occupati (un thread per tunnel).

### Problemi incontrati e soluzioni

| Problema | Soluzione |
|---|---|
| dispositivo ancora "online" per 30 s dopo la caduta del WebSocket | `unregister_ws_peer` in hbbs |
| nginx rifiutava la config: `proxy_buffer_size 64k` oltre il totale dei buffer | `proxy_buffers 4 64k` in `/ws/relay` |
| Apache: un thread per tunnel, i reload graceful tengono vivi i processi vecchi | MPM event dimensionato a 2048 thread, `ServerLimit 32` |
| all-in-one: s6-overlay non partiva con root in sola lettura | `S6_READ_ONLY_ROOT=1`, `tmpfs` su `/run` con `exec` |
| all-in-one: healthcheck sempre fallito (`execlineb: unable to exec ifelse`): `with-contenv` non funziona via `docker exec`, manca `/command` nel `PATH` | `rd-healthcheck` con `#!/bin/sh`: l'ambiente del container c'è già |
| nginx: 429 a ~211 dispositivi su 300 da un IP | `limit_req` da 30 r/s burst 200 a 100 r/s burst 1000 |
| test: nginx esce se l'upstream non è ancora risolvibile | `depends_on` + `restart: on-failure` nelle varianti |
| test del reload falliva subito | partiva nei 60 s dell'IP blocker: il tester riprova e segnala `READY` |
| `sync-upstream.sh` cancellava `.gitignore` di `hbb_common` | corretto nello script |

### Dipendenze e vulnerabilità note

`make audit` (2026-11-19): 44 advisory all'inizio, **20 dopo l'aggiornamento mirato di
`Cargo.lock`**. I 20 residui non hanno un fix compatibile: richiedono salti di versione major in
`server/Cargo.toml`, cioè divergere dal codice upstream.

| Crate | Perché resta | Raggiungibile? |
|---|---|---|
| `rustls` 0.21, `rustls-webpki` 0.101, `webpki-roots` 0.25 | `reqwest` 0.11 (fork rustdesk-org) | **sì**: `check_software_update()` in `src/main.rs`, POST HTTPS giornaliero |
| `h2` 0.3 | `hyper` 0.14 (`reqwest`, `axum`) | solo come client, stesso percorso |
| `sqlx` 0.6, `rustls` 0.20, `webpki-roots` 0.22 | `sqlx` con `runtime-tokio-rustls` | no: si usa solo sqlite, senza TLS |
| `ring` 0.16 | `rustls` 0.20, `jsonwebtoken` 8 (`src/jwt.rs`) | JWT solo con `--must-login`; non analizzato oltre |
| `libsqlite3-sys` 0.24 (SQLite incluso) | `sqlx` 0.6 | query interne parametrizzate; non analizzato oltre |
| `webpki-roots` 0.26 | `tungstenite` 0.26 (client WebSocket di `hbb_common`) | non analizzato |
| `quick-xml` | `wayland-scanner` (proc-macro, solo in compilazione) | no a runtime |
| `users`, `crypto-bigint` | `hbb_common`, `elliptic-curve` | non analizzato |

`axum` è dichiarato in `Cargo.toml` ma non è usato in `server/src`: non c'è alcun server HTTP
oltre ai listener WebSocket.

### Limiti noti e lavoro aperto

- I 20 advisory residui; l'opzione a costo minore è disattivare `check_software_update()`, che
  toglie anche l'unica connessione in uscita di hbbs.
- Build arm64 non provata.
- Compatibilità verificata solo con il client 1.5.3; carico provato fino a 300 dispositivi e 40
  sessioni contemporanee.
- `limit_conn rd_conn 512` (nginx): una sede con più di ~500 tunnel da un solo IP va alzata.
