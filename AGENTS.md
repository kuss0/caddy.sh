# Agent Handoff

This repository maintains a small Bash installer and maintenance script for Caddy with the Cloudflare DNS plugin. The target user wants a practical one-command installer, a numbered maintenance menu, a `c` shortcut, self-update, Caddy upgrade, and safe uninstall behavior.

## Start Here

1. Check the worktree first:

   ```bash
   git status --short --branch
   ```

2. Read these files before changing behavior:

   - `README.md`: user-facing commands and promises.
   - `install.sh`: one-command bootstrapper.
   - `caddy.sh`: installed maintenance script.

3. Keep the public one-line command working:

   ```bash
   bash <(wget -O- https://github.com/kuss0/caddy.sh/raw/main/install.sh)
   ```

## User Intent

- This is a Caddy + Cloudflare DNS-01 helper, not a general web panel.
- The user wants 233boy-style numbered maintenance choices.
- The shortcut command is `c`, normally `/usr/local/bin/c -> /usr/local/bin/caddy.sh`.
- Avoid CDN/proxy installer URLs. Use GitHub raw URLs directly.
- Do not add "AI" product features to the user menu unless explicitly requested. AI handoff belongs in repo docs like this file.
- Do not initialize live Caddy, request certificates, purge data, or remove services unless the user explicitly asks.

## Safety Invariants

- Token input must not echo.
- `init` must fail before writing config if ports 80/443 are occupied by non-Caddy processes.
- Existing unmanaged `/etc/caddy/Caddyfile` or `/etc/systemd/system/caddy.service` must not be overwritten without `init --force`.
- `init` should download/validate Caddy before writing config and roll back changed config files on startup failure.
- `add` and `remove` must validate, reload, and roll back on failure.
- `self-update` must validate downloaded script syntax before replacing the current script.
- `upgrade-caddy` must preserve rollback for the old Caddy binary when reload fails.
- `uninstall --purge` must require explicit confirmation unless `CADDY_ASSUME_YES=1`.
- Non-root execution should try `sudo` and fail with a clear message if sudo is unavailable.

## Validation

Run these before committing:

```bash
bash -n caddy.sh
shellcheck -x caddy.sh
bash -n install.sh
shellcheck install.sh
```

Smoke-test install without touching live Caddy:

```bash
tmpdir="$(mktemp -d)"
SCRIPT_URL=file:///root/caddy.sh/caddy.sh \
INSTALL_PATH="${tmpdir}/caddy.sh" \
SHORTCUT_PATH="${tmpdir}/c" \
bash install.sh --no-init
"${tmpdir}/caddy.sh" help >/dev/null
"${tmpdir}/c" help >/dev/null
rm -rf "${tmpdir}"
```

Useful interactive checks:

```bash
./caddy.sh menu
./caddy.sh menu </dev/null
```

The non-TTY menu path should fail clearly instead of hanging.

## Deployment Notes On This Host

The repo lives at `/root/caddy.sh`.

After changing `caddy.sh`, sync the local top-level and installed copies when appropriate:

```bash
install -m 0755 /root/caddy.sh/caddy.sh /root/caddy-cloudflare-deploy.sh
SCRIPT_URL=file:///root/caddy.sh/caddy.sh bash /root/caddy.sh/install.sh --no-init
```

Then verify:

```bash
bash -n /root/caddy-cloudflare-deploy.sh
shellcheck -x /root/caddy-cloudflare-deploy.sh
/usr/local/bin/caddy.sh help >/dev/null
/usr/local/bin/c help >/dev/null
```

If the user asks to publish, commit and push to `origin main`.

## Common Change Map

- Installer "no response": inspect visible download behavior first. Avoid `wget -qO-` in docs because failed downloads can look like an empty script.
- Script update behavior: `c self-update` / `c update-script`.
- Caddy binary update behavior: `c upgrade-caddy` / `c update-caddy`.
- Shortcut behavior: `install.sh` and `install_shortcut()` in `caddy.sh`.
- Menu behavior: `cmd_menu()` in `caddy.sh`.
- Add site behavior: `cmd_add()` in `caddy.sh`.
- Uninstall behavior: `cmd_uninstall()` and `confirm_purge()` in `caddy.sh`.

