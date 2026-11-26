# One-shot seed job: writes stack metadata into the shared named volume, then exits 0.
FROM busybox:1.37.0
COPY seed.sh /usr/local/bin/seed
RUN chmod 0755 /usr/local/bin/seed
CMD ["/usr/local/bin/seed"]
