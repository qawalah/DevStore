# Tiny sample for the Docker pipeline: BusyBox httpd serving one page, with the
# HEALTHCHECK that every DevStore Docker app needs (the release waits for it).
FROM busybox:1.37
ARG VERSION=dev
RUN mkdir -p /www && echo "hello-docker $VERSION" > /www/index.html
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
