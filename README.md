# Open WebUI + SearXNG with caching (rootless Podman)

Runs two pods as systemd user services (Podman Quadlet):

| Pod      | Container       | Purpose                                   | Host address        |
|----------|-----------------|-------------------------------------------|---------------------|
| `search` | `searxng`       | SearXNG metasearch                        | (internal)          |
|          | `searxng-proxy` | nginx cache for `/search` results         | `127.0.0.1:8888`    |
|          | `fetch-cache`   | Squid TLS-intercepting cache for fetches  | `127.0.0.1:3128`    |
| `owui`   | `open-webui`    | Open WebUI (depends on the `search` pod)  | `127.0.0.1:3000`    |

Inside the `owui` pod, `127.0.0.1:10000` (llama.cpp), `:8888` and `:3128`
are forwarded to the host's loopback by pasta.

llama.cpp runs on the host as a plain user service, `llama-server.service`
(`~/.config/systemd/user/`), running
`/usr/bin/llama-server --models-preset ~/models/models.ini --models-max 1 --port 10000 --embeddings`
with `--api-key-file ~/.config/llama-server/api-key` added.
Starting Open WebUI starts it too. It's a `Wants=` dependency, so Open WebUI
keeps running if llama-server is restarted or stopped. Model configuration
(`~/models/models.ini`) is yours and isn't part of this bundle.

## Requirements

- Podman 5.0+ with pasta networking (rootless)
- systemd user session
- NVIDIA Container Toolkit with CDI (`nvidia.com/gpu=all`)
- `/usr/bin/llama-server` and your `~/models/models.ini` preset file

## Install

    git clone https://github.com/JCallicoat/owui-search
    cd owui-search
    ./install.sh

To keep your current Open WebUI secret key: `WEBUI_SECRET_KEY=... ./install.sh`.
The existing `open-webui` volume is reused, so chats and settings carry over.
To have SearXNG use the Brave Search API, see
[Optional: Brave Search API](#optional-brave-search-api).

`install.sh` prepares everything but starts nothing and doesn't change
lingering. When you're ready:

    systemctl --user start open-webui.service   # also starts llama-server and the search pod
    ./check.sh

Starting replaces any existing containers or pods with the same names,
including an `open-webui` container you started by hand. Stop a llama-server
you started by hand first, or the service can't bind port 10000.

### Optional: autostart and lingering

- **Start at login:** `./install.sh --autostart`. This adds an `[Install]`
  section to the units; re-run without the flag to remove it. (Quadlet units
  can't be turned on with `systemctl --user enable`.)
- **Keep running while logged out / start at boot:**
  `loginctl enable-linger $USER` (undo with `loginctl disable-linger $USER`).
  This lets all of your user's services run without a login session, so it's
  off by default.

### Optional: Brave Search API

SearXNG's default engines scrape search sites, which often answer with
CAPTCHAs or rate limits, so results can be thin. SearXNG's `braveapi` engine
uses Brave's official Search API instead. You need an API key from the
[Brave Search API dashboard](https://api-dashboard.search.brave.com/) (the
**Search** plan).

Pass the key to `install.sh`. Reading it with `read -s` keeps it out of your
shell history:

    read -rsp 'Brave API key: ' BRAVE_API_KEY && export BRAVE_API_KEY
    ./install.sh
    unset BRAVE_API_KEY
    systemctl --user restart searxng   # if it's already running

`install.sh` adds a marked block to the end of
`~/.config/searxng/searxng/settings.yml` that enables `braveapi` with your
key. It only ever changes that block:

- Re-running `install.sh` without `BRAVE_API_KEY` keeps the block and key.
- Re-running with a new `BRAVE_API_KEY` replaces the key.
- `./install.sh --remove-brave` removes the block.

If your `settings.yml` already has its own top-level `engines:` list,
`install.sh` stops instead of adding a second one (YAML would silently use
only one of them). Add this entry to your list yourself:

```yaml
  - name: braveapi
    api_key: "YOUR-API-KEY"
    inactive: false
    shortcut: bra
```

**Brave alongside other engines, or Brave only.** By default SearXNG queries
`braveapi` together with its other engines and merges the results. To use
only Brave, set Open WebUI's SearXNG query URL (Admin → Settings → Web
Search) to:

    http://127.0.0.1:8888/search?engines=braveapi

Leave out the `<query>` placeholder: Open WebUI drops the URL's query string
when the URL contains `<query>`, and keeps it otherwise. Set it back to
`http://127.0.0.1:8888/search?q=<query>` to use all engines again. Either
way, `journalctl --user -u searxng-proxy -f` shows what Open WebUI sends.

**Quota.** Each search SearXNG sends to `braveapi` is one API request, and
Open WebUI may run several searches for one message. The nginx cache answers
a repeated search for an hour without a new request. `./check.sh` uses one
request when Brave is configured. When this was written, Brave charged $5 per
1,000 requests with $5 of free credit each month; check the dashboard for
current pricing and your usage.

The key is stored in `settings.yml`, which `install.sh` makes readable only
by you and the SearXNG container (mode 640).

### Optional: other services on the host (e.g. Kokoro TTS)

Open WebUI's container can only reach the host ports forwarded into its pod.
To let it use another service listening on the host's `127.0.0.1`, forward
that port, then restart the pod:

    ./install.sh --forward-port 8880
    systemctl --user restart owui-pod.service open-webui.service

Open WebUI then reaches the service at `http://127.0.0.1:8880`. Nothing else
about the service is set up or managed here.

- Repeat the option or use commas for several ports:
  `--forward-port 8880,9000`.
- Forwarded ports are saved in `~/.config/open-webui/forward-ports` and kept
  when you re-run `install.sh`. Remove one with `--remove-forward-port 8880`.
- The service has to listen on the host's loopback (`127.0.0.1`, or all
  interfaces). A container that publishes its port with
  `-p 127.0.0.1:8880:8880` works.
- 8080 can't be forwarded (Open WebUI listens on it inside the pod), and
  10000, 8888 and 3128 are always forwarded.
- `./check.sh` checks that each forwarded port answers an HTTP request from
  inside Open WebUI's container.

For [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI) on port 8880,
Open WebUI's
[Kokoro guide](https://docs.openwebui.com/features/chat-conversations/audio/text-to-speech/Kokoro-FastAPI-integration)
gives these settings for Admin → Settings → Audio: Text-to-Speech engine
**OpenAI**, API base URL `http://127.0.0.1:8880/v1`, API key `not-needed`,
model `kokoro`, voice e.g. `af_bella`.

Forwarded services are reachable by URLs the page loader fetches, the same
as the built-in ones (see the `ENABLE_LOCAL_WEB_FETCH` note under
[Notes](#notes)). Kokoro-FastAPI has no authentication by default, so only
forward services you're comfortable exposing to that.

### First sign-in

Open WebUI requires a login. If you used it before without one, your account
is `admin@localhost` with password `admin`; sign in with that and change the
password right away in Settings → Account. New sign-ups are disabled.

### Open WebUI settings

- Admin → Settings → Web Search: engine `searxng`, query URL
  `http://127.0.0.1:8888/search?q=<query>`, and turn on "Trust proxy
  environment" so page fetches use the Squid cache.
- Admin → Settings → Connections: the llama.cpp connection is
  `http://127.0.0.1:10000/v1`, with the API key from
  `~/.config/llama-server/api-key` (`cat` it and paste it in).

## Files

Paths below use the defaults. If `XDG_CONFIG_HOME` or `XDG_CACHE_HOME` is set
to an absolute path, the scripts use it instead of `~/.config` or `~/.cache`.
Unit files go under the systemd user manager's `XDG_CONFIG_HOME` (check with
`systemctl --user show-environment`); `install.sh` warns if that differs from
your shell's. Paths are written into the unit files at install time, so re-run
`install.sh` after changing them.

    ~/.config/searxng/searxng/   settings.yml (incl. Brave API key if set),
                                 favicons.toml
    ~/.config/searxng/nginx/     default.conf
    ~/.config/searxng/squid/     squid.conf, Containerfile, entrypoint.sh,
                                 ca.pem, ca.key (private!), owui-bundle.pem
    ~/.config/open-webui/        open-webui.env (WEBUI_SECRET_KEY),
                                 forward-ports (extra forwarded ports)
    ~/.config/llama-server/      api-key (llama-server API key)
    ~/.config/containers/systemd/  Quadlet units
    ~/.config/systemd/user/      llama-server.service

    ~/.cache/searxng/favicons/   SearXNG favicon cache   (100 MB, favicons.toml)
    ~/.cache/searxng/search/     nginx result cache      (500 MB, default.conf)
    ~/.cache/searxng/fetch/      Squid page cache        (1400 MB, squid.conf)

Re-running `install.sh` keeps your edited configs, CA, secret key and llama
API key, and
refreshes the units and Squid image. After editing a config, restart the
matching service, e.g. `systemctl --user restart fetch-cache`.

## Operate

    systemctl --user start open-webui.service
    systemctl --user stop open-webui.service search-pod.service llama-server.service
    systemctl --user status owui-pod search-pod
    journalctl --user -u open-webui -u llama-server -u searxng -u searxng-proxy -u fetch-cache -f

`./cache-report.sh` shows what's cached: recent searches in the nginx cache
(decoded, with age and whether they've expired), the sites and number of
pages in the Squid cache, and disk usage of all three caches against their
configured limits. `./cache-report.sh --urls` also lists every cached page.
It reads the cache files directly, so it works with the services stopped.
`./cache-report.sh --clear` deletes all cached searches, pages and favicons
after asking (`--yes` skips the question). It stops the cache services that
are running while it deletes, then starts them again; Squid's generated site
certificates are kept.

`./check.sh` tests both caches, Open WebUI (including that login is on and
sign-ups are off), the llama.cpp connection, and that llama-server refuses
requests without its key. If the Brave Search API is configured, it also
checks that `braveapi` returns results (one API request), and that each port
added with `--forward-port` answers from inside Open WebUI's container.
To check by hand:

    curl -sI 'http://127.0.0.1:8888/search?q=test&format=json' | grep X-Cache-Status
    curl -s -o /dev/null --cacert ~/.config/searxng/squid/ca.pem -x http://127.0.0.1:3128 https://example.com/
    podman exec fetch-cache tail -n 2 /var/log/squid/access.log   # TCP_HIT / TCP_MEM_HIT on repeats

## Notes

- Squid decrypts Open WebUI's HTTPS traffic with a local CA that only the
  Open WebUI container trusts. Anyone with `ca.key` can impersonate any site
  to clients that trust it, so keep it private.
- All of Open WebUI's outbound HTTPS goes through Squid, including model
  downloads; objects over 20 MB pass through uncached.
- Open WebUI runs with `ENABLE_LOCAL_WEB_FETCH=True`. Without it, its page
  loader refuses to connect to Squid on 127.0.0.1 and every page fetch fails
  (Legacy/Default function calling). Squid refuses loopback, private (LAN),
  link-local and CGNAT destinations, so fetched URLs can't reach your LAN.
  URLs on `127.0.0.1`/`localhost` bypass Squid (`NO_PROXY`) and aren't
  blocked, so a prompt-injected URL could reach the services in the `owui`
  pod. Those fetches are plain GETs with no credentials: Open WebUI's API
  needs a login, llama-server needs its API key (only `/health` and its web
  UI's static files are open), Squid's cache manager is denied, and SearXNG
  only answers searches. Ports added with `--forward-port` are reachable the
  same way, so how exposed they are depends on the service behind them.
- Open WebUI only accepts browser API calls from its own origins
  (`CORS_ALLOW_ORIGIN`), so other websites open in your browser can't use it.
- Pages are cached for up to 24 h even when sites say not to
  (`refresh_pattern` in squid.conf). Lower it if you need fresher pages.
- Update images: re-run `install.sh`, then restart the services. It pulls
  the SearXNG, nginx and Open WebUI images, and rebuilds the Squid image from
  scratch (no build cache, newer Debian base if available) so Squid gets
  current Debian packages. The replaced Squid image is removed, or left for
  you to `podman rmi` if a running container still uses it.

## Uninstall

    ./uninstall.sh            # keep configs, caches and data
    ./uninstall.sh --purge    # also delete configs, caches, Squid image
