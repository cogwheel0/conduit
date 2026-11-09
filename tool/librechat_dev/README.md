# LibreChat dev stack

A local LibreChat server for working on Conduit's LibreChat backend. It runs
the release that `librechat-src` vendors (v0.8.8) with MongoDB and
Meilisearch, and sends chat to an Ollama server on the host, so it needs no
provider keys.

`librechat.yaml` turns on what Conduit uses: prompts, agents, memories, shared
links, file search, the code interpreter toggle, a sample MCP server
(`everything`), and tool approval for MCP calls. Web search and server speech
are commented out there because they need external services.

File search also needs LibreChat's RAG API and a vector database, which this
stack does not run: the option shows, but uploaded files are not indexed. To
work on it, add the `vectordb` and `rag_api` services from
`librechat-src/docker-compose.yml`, set `RAG_API_URL=http://rag_api:8000` for
`api`, and give the RAG API an embeddings provider.

## Start it

You need Docker and [Ollama](https://ollama.com) with a model pulled:

```bash
ollama pull llama3.2
```

On Linux with Docker Engine, Ollama must listen beyond loopback for the
container to reach it: set `OLLAMA_HOST=0.0.0.0` for the Ollama service
(`sudo systemctl edit ollama`, then `Environment="OLLAMA_HOST=0.0.0.0"`
under `[Service]`) and restart it. Docker Desktop needs nothing.

Create `.env` and fill in its secrets:

```bash
cd tool/librechat_dev
cp .env.example .env
for key in CREDS_KEY JWT_SECRET JWT_REFRESH_SECRET MEILI_MASTER_KEY; do
  sed -i '' "s|^$key=.*|$key=$(openssl rand -hex 32)|" .env
done
sed -i '' "s|^CREDS_IV=.*|CREDS_IV=$(openssl rand -hex 16)|" .env
```

(On Linux, drop the `''` after `sed -i`.)

Then start the stack and create a user with a password of its own:

```bash
docker compose up -d
export LIBRECHAT_DEV_PASSWORD=$(openssl rand -hex 12)
echo "$LIBRECHAT_DEV_PASSWORD"   # sign in to the app with this
docker compose exec api npm run create-user -- dev@example.com Dev dev "$LIBRECHAT_DEV_PASSWORD" --email-verified=true
```

The web app is at <http://localhost:3080>. Registration is also open there.

The server listens on this machine's loopback only. To reach it from a phone
on your network, publish it on every interface: add `LIBRECHAT_BIND=0.0.0.0`
to `.env` (or the shell) and run `docker compose up -d` again. Anyone on that
network can then reach the sign-in page, and register while registration is
open.

## Point Conduit at it

| Where Conduit runs | Server address | `DOMAIN_CLIENT` / `DOMAIN_SERVER` in `.env` |
| --- | --- | --- |
| iOS Simulator | `http://localhost:3080` | `http://localhost:3080` |
| Android emulator | `http://10.0.2.2:3080` | `http://10.0.2.2:3080` |
| A phone on your network (needs `LIBRECHAT_BIND=0.0.0.0`) | `http://<this machine's LAN IP>:3080` | the same |

The domains only matter for SSO, whose callbacks redirect to
`DOMAIN_CLIENT`. Restart `api` after changing them:
`docker compose up -d --force-recreate api`.

## The User-Agent ban

Stock LibreChat answers "Illegal request" to any chat or file request whose
User-Agent does not parse as a browser, and scores it as a violation that
bans the user and their IP. Conduit sends a browser User-Agent with
` Conduit/<version>` appended. The stack keeps bans on so a request that
loses that User-Agent shows up here first; they last five minutes instead of
the stock two hours.

Check a User-Agent against the server's own parser:

```bash
./ua_check.sh 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) ... Conduit/4.2.1'
./ua_check.sh   # every string the Conduit tests pin
```

Find bans in the server log (violations themselves are stored, not
logged):

```bash
docker compose logs api | grep -F '[BAN]'
```

Lift a ban early:

```bash
docker compose exec mongodb mongosh LibreChat --quiet \
  --eval 'db.keyv.deleteMany({ key: /^(BANS|ban):/ })'
```

## Record stream fixtures

`record_sse.sh` signs in, starts a generation and writes the raw stream,
which is how the fixtures under
`packages/conduit_core/test/features/librechat/fixtures/` are refreshed:

```bash
export LIBRECHAT_PASSWORD="$LIBRECHAT_DEV_PASSWORD"
./record_sse.sh dev@example.com Ollama llama3.2 'Say hi' fresh.sse
./record_sse.sh dev@example.com Ollama llama3.2 'Count to 50' resume.sse resume
```

## Reset

```bash
docker compose down -v   # also deletes users, chats and uploads
```
