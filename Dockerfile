FROM alpine:latest
LABEL maintainer="markos@chandras.me"

RUN apk add --no-cache bash ca-certificates git github-cli jq

COPY delete-old-branches /usr/bin/delete-old-branches
COPY discover-branches /usr/bin/discover-branches

ENTRYPOINT ["/usr/bin/delete-old-branches"]
