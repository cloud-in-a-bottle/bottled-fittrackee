# openhost-fittrackee

[FitTrackee](https://github.com/SamR1/FitTrackee) (self-hosted outdoor activity
and workout tracker) packaged for OpenHost with one-click owner SSO.

Log workouts (GPX upload or manual entry), track distance/duration/elevation,
view stats and a calendar, and manage everything from a single self-hosted app.

> **Note on scope:** FitTrackee is oriented toward *outdoor / endurance*
> activities (running, cycling, hiking, GPX routes). It does **not** have a
> dedicated set/rep weightlifting logger or a bodyweight-over-time chart. If
> your primary goal is barbell lifting + bodyweight tracking, see
> [openhost-lyftr](https://github.com/imbue-openhost/openhost-lyftr) instead.

## Architecture

FitTrackee requires PostgreSQL + PostGIS. To keep this a single self-contained
OpenHost app, PostgreSQL 16 + PostGIS are **bundled inside the container**, with
the data cluster stored under the persistent app-data dir. A small Python
auth-proxy fronts gunicorn and provides owner SSO.

```
OpenHost router → auth-proxy (:8080) → gunicorn/Flask (:5000) → Postgres (127.0.0.1:5432)
```

`start.sh` initialises the cluster on first boot, runs `ftcli db upgrade`,
provisions the owner via `ftcli users create` (pre-activated), then launches
gunicorn and the auth-proxy.

## SSO model

FitTrackee is a localStorage-JWT SPA (no cookies, no header auth). We bridge
OpenHost's `X-OpenHost-Is-Owner` signal into its own JWT scheme:

1. On the owner's first HTML navigation, the auth-proxy injects a bootstrap
   script into `index.html`.
2. That script (only if no `authToken` present) calls `/_openhost/sso`.
3. `/_openhost/sso` verifies the owner header and mints an HS256 JWT with
   `sub` = the owner's user id, signed with the same `APP_SECRET_KEY` gunicorn
   validates against.
4. The script writes it to `localStorage.authToken` and reloads —
   FitTrackee's `CHECK_AUTH_USER` picks it up and loads the profile.

Anonymous visitors get FitTrackee's normal login form (no auto-login).

### Credential handling

- **No user password is written to disk.** The `ftcli`-created owner account
  uses a throwaway random password that is discarded immediately; owner auth is
  JWT-only.
- `$OPENHOST_APP_DATA_DIR/.app_secret` — FitTrackee's JWT signing key (app
  config, not a user credential; persisted so sessions survive restarts).
- `$OPENHOST_APP_DATA_DIR/.pgpass` — the loopback-only Postgres role password.
  The DB never listens off-loopback inside the container.
- `$OPENHOST_APP_DATA_DIR/.owner_uid` — the owner's numeric user id (not a
  secret).

## Persistence

Under `$OPENHOST_APP_DATA_DIR`: `pgdata/` (the Postgres cluster — all activity
data), `uploads/` (GPX + images), `staticmap_cache/`, `logs/`, and the marker
files above.

## Upstream

FitTrackee is AGPL-3.0-licensed:
https://github.com/SamR1/FitTrackee ·
https://codeberg.org/FitTrackee/FitTrackee
