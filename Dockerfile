# openhost-fittrackee — FitTrackee (SamR1/FitTrackee) packaged for OpenHost.
#
# FitTrackee requires PostgreSQL + PostGIS. To keep this a single OpenHost app
# (no external managed DB), we bundle PostgreSQL/PostGIS INSIDE the container
# and store its data cluster under the persistent app-data dir. A small Python
# auth-proxy fronts gunicorn and auto-logs-in the OpenHost owner by minting a
# FitTrackee JWT into the SPA's localStorage.
FROM fittrackee/fittrackee:v1.3.3

USER root

# PostgreSQL 16 + PostGIS from Alpine repos, plus python3 for the auth-proxy
# and su-exec/gosu-equivalent for privilege drop. The upstream image is Alpine.
RUN apk add --no-cache \
        postgresql16 postgresql16-contrib postgis \
        python3 su-exec bash

COPY auth_proxy.py /usr/local/bin/auth_proxy.py
COPY start.sh /usr/local/bin/oh-start.sh
RUN chmod +x /usr/local/bin/oh-start.sh

EXPOSE 8080

# Override the upstream tini/entrypoint: we run our own supervisor.
ENTRYPOINT []
CMD ["/usr/local/bin/oh-start.sh"]
