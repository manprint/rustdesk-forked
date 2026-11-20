# Handoff — 2026-11-19 (seconda sessione)

Agente: Claude Code, modello Fable 5.2. Primo commit su `main`; nessun push (repo senza remote).
Container, immagini di test, volumi cache e build cache inutilizzata rimossi; nessun processo in background.

## Stato

Lavoro previsto completato e verificato:
- `test/e2e/run.sh` su tutte e 6 le varianti: **48/48 PASS**, due giri consecutivi (il secondo con
  `Cargo.lock` aggiornato e immagini ricostruite). Recovery 14-17 s; 300 dispositivi in < 1 s;
  reload graceful di Apache e nginx con tunnel aperti: PASS.
- Test unitari 30/30 (`scripts/cargo.sh test --locked`); `docker compose build` e
  `docker compose -f compose.allinone.yml build` ok.

Modifiche di questa sessione:
- nginx: `limit_req` 30 r/s burst 200 → **100 r/s burst 1000** (`nginx/rustdesk-http.conf`,
  `nginx/rustdesk-locations.conf`, tabella README). Prima: 429 a ~211/300 dispositivi da un IP.
- `test/e2e/variant-*.yml`: `depends_on` + `restart: on-failure` su proxy nginx ed `edge`
  (nginx esce se l'upstream non è ancora risolvibile; difetto solo dei test).
- Step reload: `e2e.py` riprova la registrazione (IP blocker, 60 s) e stampa `READY`; `run.sh`
  fa il reload dopo `READY`.
- `server/Cargo.lock`: aggiornamento mirato (`update -p`), advisory **44 → 20**.
- `CLAUDE.md` (note operative), `.gitignore` (`__pycache__/`).

Terza parte (stessa data): `Makefile` (immagini, `save`, `push`, test, audit, sync), README con
sezioni "Immagini" e "Sviluppo", `CLAUDE.md` come runbook di aggiornamento. `compose.allinone.yml`
riscritto: default plain dietro proxy di frontiera (`127.0.0.1:8080`), righe `[plain]`/`[ssl]`
commentate, `/data` in bind mount (`10001:10001`, `0700`), rete fissa `172.31.251.0/24`.
Corretto `rd-healthcheck` (non aveva mai funzionato). Provato a mano in plain e ssl.

## Decisioni aperte (dell'utente)

1. **20 advisory residui** (`scripts/cargo.sh audit`): nessun fix semver-compatibile, servono salti
   di major in `server/Cargo.toml`, cioè divergenza dal codice upstream. Raggiungibilità:
   - `axum` (→ `axum`/`h2` lato server): dichiarato, non usato in `server/src`.
   - `sqlx` 0.6 + `rustls` 0.20 + `webpki-roots` 0.22 + `ring` 0.16: solo sqlite, TLS non usato.
   - `libsqlite3-sys` 0.24 (SQLite incluso, 2 CVE): query interne con parametri; non analizzato
     oltre.
   - `rustls` 0.21 + `rustls-webpki` 0.101 (verifica certificati): **unico percorso attivo**,
     `check_software_update()` in `server/src/main.rs` (POST HTTPS giornaliero via `reqwest`).
     Opzione a basso costo: disattivare quel controllo (modifica locale, toglie anche l'uscita
     verso internet di hbbs).
   - `quick-xml` (proc-macro wayland, solo build), `users`, `crypto-bigint`: non analizzati oltre.
2. Volume anonimo `0ab65df4…`: data-dir Docker-in-Docker creato il 2026-11-17, prima di questo
   progetto. Non toccato.
3. Remote e push: da fare su richiesta.

## Note pratiche

- Non modificare `test/e2e/run.sh` mentre è in esecuzione.
- Output dei test: leggere solo `PASS|FAIL|RESULT` e il `SUMMARY`.
- Immagini base rimaste in locale: `rust:1.100-alpine3.24`, `nginx:1.29-alpine`, `httpd:2.4`.
