FROM alpine:latest
LABEL maintainer="markos@chandras.me"

RUN apk add --no-cache bash ca-certificates git github-cli jq coreutils

COPY delete-old-branches /usr/bin/delete-old-branches
COPY discover-branches /usr/bin/discover-branches
COPY build-matrix /usr/bin/build-matrix

ENTRYPOINT ["/usr/bin/delete-old-branches"]
