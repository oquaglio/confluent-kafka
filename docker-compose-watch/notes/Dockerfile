# Generated page. Sources in /src are synced, then `build-notes` regenerates /www/index.html
# inside the running container (`action: sync+exec`). busybox httpd serves the result.
FROM busybox:1.37.0
COPY build.sh /usr/local/bin/build-notes
RUN chmod 0755 /usr/local/bin/build-notes && mkdir -p /www
COPY content/ /src/
RUN build-notes
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
