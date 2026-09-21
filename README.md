# datamoov pro

Run datamoov on your own server. This repository holds only the installer:
the application itself arrives as ready-made Docker images.

**You need**

- A Linux server (Ubuntu 22.04 or newer is the easy choice). The default
  settings are sized for 32 GB RAM and 16 CPUs; see [Smaller servers](#smaller-servers).
- The GitHub **username** and **access token** we sent you.
- Optional: a domain name (like `data.yourcompany.com`) pointing at the server.

The whole install is five steps and takes about 15 minutes.

---

## 1. Install Docker

Connect to your server and run:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Log out and back in, then check it works:

```bash
docker compose version
```

You should see version `2.24.4` or higher.

## 2. Download this installer

```bash
git clone https://github.com/justdataplease/datamoov_pro.git
cd datamoov_pro
```

## 3. Log in to the image registry

Use the username and token we sent you (paste the token when asked for a
password; nothing appears as you paste, that is normal):

```bash
docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

You should see `Login Succeeded`.

## 4. Answer three questions

```bash
./setup.sh
```

| Question | What to answer |
| --- | --- |
| **Address** | Your domain (`data.yourcompany.com`), or the server's IP address if you have no domain. |
| **How should people connect?** | See the table below. |
| **Database** | **1** to let datamoov run its own database (simplest). **2** if you already have a managed PostgreSQL (AWS RDS, Google Cloud SQL, Neon, ...), then paste its connection URL. |

**Which connection choice is right for me?**

| You have... | Choose | Result |
| --- | --- | --- |
| A domain, server reachable from the internet | **1** HTTPS | Secure padlock, certificate is automatic and free. Ports 80 and 443 must be open. |
| Only an IP address, want encryption | **1** HTTPS | Encrypted, but browsers show a "not private" warning once, because a certificate for a bare IP cannot be verified. |
| Only an IP address, private office network or VPN | **2** HTTP | No encryption. Never use this on the open internet: passwords would travel in clear text. |
| Your own reverse proxy or tunnel (nginx, Cloudflare Tunnel, ...) | **3** | datamoov listens on `127.0.0.1:80`; point your proxy there. |

The script prints a **one-time setup token**. Copy it; you need it in step 5.

> **Back up the `.env` file** the script created (a password manager is fine).
> It holds the key that encrypts your saved credentials. If it is lost, they
> cannot be recovered.

## 5. Start datamoov

```bash
docker compose pull
docker compose up -d --wait --wait-timeout 900
```

The first start takes a few minutes while the database is prepared. When the
command returns, open your address in a browser and add `/bootstrap`:

```text
https://data.yourcompany.com/bootstrap
```

Paste the one-time setup token and create your administrator account.

**Last step, for safety.** Open `.env`, delete everything after
`BOOTSTRAP_TOKEN=` so the line is empty, then run:

```bash
docker compose up -d --no-deps --force-recreate backend
```

Done. 🎉

---

## Everyday commands

Run these inside the `datamoov_pro` folder.

| I want to... | Command |
| --- | --- |
| See if everything is running | `docker compose ps` |
| Read the logs | `docker compose logs --tail 100` |
| Read one service's logs | `docker compose logs --tail 100 backend` |
| Stop datamoov | `docker compose stop` |
| Start it again | `docker compose up -d --wait` |

Data is kept when you stop and start. **Never run `docker compose down -v`**:
the `-v` deletes your data.

## Importing local files

Put files in the `imports/` folder. datamoov can read them, never change them.

## Backups

Back up these three things, together, on a schedule:

1. The `.env` file.
2. The database. Bundled database:
   ```bash
   docker compose exec -T db pg_dump -U datamoov datamoov | gzip > datamoov-db-$(date +%F).sql.gz
   ```
   Managed database: turn on your provider's automatic backups.
3. The pipeline state volumes:
   ```bash
   for v in dlt_state dbt_project; do
     docker run --rm -v datamov_platform_$v:/data:ro -v "$PWD":/backup alpine \
       tar czf /backup/$v-$(date +%F).tar.gz -C /data .
   done
   ```

## Upgrading

1. Get the new installer files: `git pull`
2. In datamoov, switch off schedules and wait for running pipelines to finish.
3. Let background work drain, then stop the application:
   ```bash
   docker compose run --rm --no-deps backend python manage.py await_worker_quiescence --timeout 3600
   docker compose run --rm --no-deps backend python manage.py assistant_worker_drain enable --timeout 900
   docker compose stop $(docker compose config --services | grep -vx db)
   ```
   (This stops everything except the bundled database, which the backup needs.)
4. **Take a backup** (see above).
5. Copy the two `DATAMOV_BACKEND_IMAGE=` and `DATAMOV_FRONTEND_IMAGE=` lines
   from the new `.env.example` over the same two lines in your `.env`.
6. Start the new version:
   ```bash
   docker compose pull
   docker compose up -d --wait --wait-timeout 900
   docker compose exec -T backend python manage.py assistant_worker_drain disable
   ```
7. Switch schedules back on.

If step 6 fails, put the old two lines back in `.env` and run step 6 again.

## Smaller servers

The limits at the bottom of `.env` assume a large server. For a 16 GB machine,
change these two lines, then run `docker compose up -d`:

```text
WORKER_MEMORY_LIMIT=6g
WORKER_MEMORY_ENVELOPE_MB=6144
```

Below 8 GB RAM is not supported.

## Something is wrong

| Problem | Fix |
| --- | --- |
| `docker login` says `denied` | The token is wrong or expired. Ask us for a new one. |
| `pull access denied` during step 5 | You skipped step 3, or your token has no access. |
| Start-up stops at `init` | Run `docker compose logs init`. The last lines say what is wrong, most often the database URL. |
| Browser says "not private" | Expected with HTTPS on a bare IP address. Use a domain to get a trusted certificate. |
| HTTPS certificate is not issued | The domain must point at this server, and ports 80 and 443 must be open in the firewall. Check `docker compose logs https`. |
| "Bad Request (400)" or a CSRF error | The address in your browser differs from the one given to `setup.sh`. Fix the five address lines in `.env`, then run `docker compose up -d`. |
| Port 80 is already in use | Another web server is running. Stop it, or choose connection option 3 and set `EDGE_UI_PORT` in `.env`. |
| Want to redo the questions | Before first start only: delete `.env` and run `./setup.sh` again. Afterwards edit `.env` by hand; a new `.env` would lose your encryption key. |

Still stuck? Send us the output of `docker compose ps` and
`docker compose logs --tail 200 init backend`.

## What is in this folder

| File | Purpose |
| --- | --- |
| `setup.sh` | Asks the three questions and writes `.env`. |
| `.env.example` | Every setting with its default. The current release's image versions live here. |
| `docker-compose.yml` | The application. Always used. |
| `docker-compose.https.yml` | Automatic HTTPS (Caddy). |
| `docker-compose.http.yml` | Plain HTTP for private networks. |
| `docker-compose.localdb.yml` | Bundled PostgreSQL. |
| `nginx/`, `caddy/` | Web server settings. No need to touch. |
| `imports/` | Drop local files here to import them. |

Which of the optional files are active is the `COMPOSE_FILE` line in `.env`.
