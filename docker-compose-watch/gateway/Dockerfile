# Reverse proxy. nginx reads its config once at startup, so a config change needs
# `action: sync+restart`.
FROM nginx:1.27.5-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
