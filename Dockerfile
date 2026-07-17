# openhost-fittrackee — FitTrackee (SamR1/FitTrackee) packaged for OpenHost.
#
# FitTrackee requires PostgreSQL + PostGIS. To keep this a single OpenHost app
# (no external managed DB), we bundle PostgreSQL/PostGIS INSIDE the container
# and store its data cluster under the persistent app-data dir. A small Python
# auth-proxy fronts gunicorn and auto-logs-in the OpenHost owner by minting a
# FitTrackee JWT into the SPA's localStorage.
FROM fittrackee/fittrackee:v1.3.3

USER root

# PostgreSQL + PostGIS from Alpine repos, plus python3 for the auth-proxy and
# su-exec for privilege drop. The upstream image is Alpine. We install the
# postgis package first and let it pull in its matching postgresql major
# version (currently 18), then add that same major's -contrib, so the postgis
# extension control files live in the SAME version dir the server uses. Pinning
# a different major (e.g. postgresql16) puts postgis in the wrong extension dir
# and "CREATE EXTENSION postgis" fails.
RUN apk add --no-cache postgis python3 su-exec bash && \
    apk add --no-cache postgresql-contrib && \
    # Record the postgres bin dir for start.sh (major version is whatever
    # postgis depended on).
    PGVER="$(ls -d /usr/libexec/postgresql* 2>/dev/null | grep -oE '[0-9]+$' | head -1)" && \
    echo "PGVER=${PGVER}" > /etc/oh-pg-version

COPY auth_proxy.py /usr/local/bin/auth_proxy.py
COPY start.sh /usr/local/bin/oh-start.sh
RUN chmod +x /usr/local/bin/oh-start.sh

EXPOSE 8080

# Override the upstream tini/entrypoint: we run our own supervisor.
ENTRYPOINT []
CMD ["/usr/local/bin/oh-start.sh"]
