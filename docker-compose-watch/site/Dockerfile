# Static site. nginx reads files from disk on every request, so `action: sync` is enough
# for changes to show up: no restart, no reload.
FROM nginx:1.27.5-alpine
COPY html/ /usr/share/nginx/html/
