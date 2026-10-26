# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# what distro is the image being built for
ARG ALPINE_TAG=3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
ARG DEBIAN_TAG=13.6-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
# renovate: datasource=docker depName=golang versioning=docker
ARG GOLANG_TAG=1.27.3-alpine3.24@sha256:f2c872bcee949b7be9c490efd02b48a8a2fbf947cdf533f1c58525ec9d8170fd

# renovate: datasource=github-releases depName=open-policy-agent/conftest
ARG DEFAULT_CONFTEST_VERSION=0.70.1
# Commit that tag v${DEFAULT_CONFTEST_VERSION} must resolve to (the conftest-builder
# stage fails closed on a mismatch). Update together with the version:
#   git ls-remote https://github.com/open-policy-agent/conftest refs/tags/v<version>
ARG DEFAULT_CONFTEST_COMMIT=0b42cb5cd1aa1dc1c9025a5e83c7e963166d08c0

# Stage 1: build artifact and download deps

FROM --platform=$BUILDPLATFORM golang:${GOLANG_TAG} AS builder

# These are automatically populated by Docker
ARG TARGETOS
ARG TARGETARCH

ARG ATLANTIS_VERSION=dev
ENV ATLANTIS_VERSION=${ATLANTIS_VERSION}
ARG ATLANTIS_COMMIT=none
ENV ATLANTIS_COMMIT=${ATLANTIS_COMMIT}
ARG ATLANTIS_DATE=unknown
ENV ATLANTIS_DATE=${ATLANTIS_DATE}

ARG DEFAULT_CONFTEST_VERSION
ENV DEFAULT_CONFTEST_VERSION=${DEFAULT_CONFTEST_VERSION}

WORKDIR /app

# This is needed to download transitive dependencies instead of compiling them
# https://github.com/montanaflynn/golang-docker-cache
# https://github.com/golang/go/issues/27719
# renovate: datasource=apk depName=bash
ENV BUILDER_BASH_VERSION="5.3.9-r1"

RUN apk add --no-cache \
    bash=${BUILDER_BASH_VERSION}

COPY go.mod go.sum ./
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod graph | awk '{if ($1 !~ "@") print $2}' | xargs go get

COPY . /app
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags "-s -w -X 'main.version=${ATLANTIS_VERSION}' -X 'main.commit=${ATLANTIS_COMMIT}' -X 'main.date=${ATLANTIS_DATE}'" -v -o atlantis .

# Fork-only: build conftest from source instead of downloading the release
# binary. The upstream release binaries are built with a Go toolchain and
# golang.org/x/net that carry fixable High CVEs (Go stdlib CVE-2026-78667,
# CVE-2026-78669, CVE-2026-97031; x/net CVE-2026-78669), and no fixed upstream
# release exists yet. This stage compiles the same tag with the builder's Go
# toolchain and bumps only x/net. Revert to the release-tarball download (with
# checksums.txt verification) once upstream ships a fixed conftest.
FROM --platform=$BUILDPLATFORM golang:${GOLANG_TAG} AS conftest-builder

# These are automatically populated by Docker
ARG TARGETOS
ARG TARGETARCH

ARG DEFAULT_CONFTEST_VERSION
ARG DEFAULT_CONFTEST_COMMIT

# renovate: datasource=apk depName=git
ENV CONFTEST_BUILDER_GIT_VERSION="2.54.0-r0"

SHELL ["/bin/sh", "-o", "errexit", "-o", "nounset", "-c"]
RUN apk add --no-cache git=${CONFTEST_BUILDER_GIT_VERSION}

# Never let Go fetch a different toolchain than the pinned golang image's.
ENV GOTOOLCHAIN=local

WORKDIR /src
# Fetch the tag, then verify the commit it resolves to (fails closed).
RUN git clone --quiet --depth 1 --branch "v${DEFAULT_CONFTEST_VERSION}" \
        https://github.com/open-policy-agent/conftest . && \
    test "$(git rev-parse HEAD)" = "${DEFAULT_CONFTEST_COMMIT}"

# Bump only the modules below their fixed versions. x/crypto and x/text in
# conftest 0.70.1 are already at v0.56.0 / v0.41.0, which are fixed.
# The version ldflags match conftest's .goreleaser.yml.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go get golang.org/x/net@v0.60.0 && \
    go mod tidy && \
    mkdir -p "/usr/local/bin/cft/versions/${DEFAULT_CONFTEST_VERSION}" && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath \
        -ldflags "-s -w -X github.com/open-policy-agent/conftest/internal/version.Version=${DEFAULT_CONFTEST_VERSION}" \
        -o "/usr/local/bin/cft/versions/${DEFAULT_CONFTEST_VERSION}/conftest" ./main.go && \
    ln -s "/usr/local/bin/cft/versions/${DEFAULT_CONFTEST_VERSION}/conftest" /usr/local/bin/conftest

FROM debian:${DEBIAN_TAG} AS debian-base

# Define package versions for Debian
# renovate: datasource=deb depName=ca-certificates
ENV DEBIAN_CA_CERTIFICATES_VERSION="20250419+deb13u1"
# renovate: datasource=deb depName=curl
ENV DEBIAN_CURL_VERSION="8.14.1-2+deb13u7"
# renovate: datasource=deb depName=git
ENV DEBIAN_GIT_VERSION="1:2.47.3-0+deb13u1"
# renovate: datasource=deb depName=unzip
ENV DEBIAN_UNZIP_VERSION="6.0-29+deb13u1"
# renovate: datasource=deb depName=openssh-server
ENV DEBIAN_OPENSSH_SERVER_VERSION="1:10.0p1-7+deb13u4"
# renovate: datasource=deb depName=dumb-init
ENV DEBIAN_DUMB_INIT_VERSION="1.2.5-3"
# renovate: datasource=deb depName=gnupg
ENV DEBIAN_GNUPG_VERSION="2.4.7-21+deb13u1"
# renovate: datasource=deb depName=openssl
ENV DEBIAN_OPENSSL_VERSION="3.5.7-1~deb13u3"

# Set up the 'atlantis' user and adjust permissions. User with uid 1000 is for backwards compatibility
RUN groupadd --gid 1000 atlantis && \
    useradd --uid 100 --system --create-home --gid 1000 --shell /bin/bash atlantis && \
    useradd --uid 1000 --system --home=/home/atlantis --gid 1000 --shell /bin/bash atlantis2 && \
    chown atlantis:atlantis /home/atlantis/ && \
    chmod ug+rwx /home/atlantis/

# Install packages needed to run Atlantis.
# We place this last as it will bust less docker layer caches when packages update
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates=${DEBIAN_CA_CERTIFICATES_VERSION} \
    curl=${DEBIAN_CURL_VERSION} \
    git=${DEBIAN_GIT_VERSION} \
    unzip=${DEBIAN_UNZIP_VERSION} \
    openssh-server=${DEBIAN_OPENSSH_SERVER_VERSION} \
    dumb-init=${DEBIAN_DUMB_INIT_VERSION} \
    gnupg=${DEBIAN_GNUPG_VERSION} \
    openssl=${DEBIAN_OPENSSL_VERSION} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Stage 2 - Alpine
# Creating the individual distro builds using targets.
#
# Since v0.49.0 the images ship no Terraform or OpenTofu binaries. Atlantis
# downloads the version it needs at runtime (see --default-tf-version and
# --tf-download), so the image carries none of the advisories filed against
# bundled third-party binaries.
#
# With no terraform on PATH, Atlantis refuses to start until
# --default-tf-version is set (flag, ATLANTIS_DEFAULT_TF_VERSION, or the
# server config file). Deliberately no ENV ATLANTIS_DEFAULT_TF_VERSION here:
# environment variables take precedence over the server config file, so a
# version baked into the image would silently override a version pinned in
# that file.
FROM alpine:${ALPINE_TAG} AS alpine

ARG ATLANTIS_PORT=4141

EXPOSE ${ATLANTIS_PORT}

HEALTHCHECK --interval=5m --timeout=3s \
    CMD curl -f http://localhost:${ATLANTIS_PORT:-4141}/healthz || exit 1

# Set up the 'atlantis' user and adjust permissions
RUN addgroup --gid 1000 atlantis && \
    adduser -u 100 -S -G atlantis atlantis && \
    chown atlantis:root /home/atlantis/ && \
    chmod u+rwx /home/atlantis/

# copy atlantis binary
COPY --from=builder /app/atlantis /usr/local/bin/atlantis
# copy dependencies
COPY --from=conftest-builder /usr/local/bin/conftest /usr/local/bin/conftest
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# renovate: datasource=apk depName=ca-certificates
ENV CA_CERTIFICATES_VERSION="20261020-r0"
# renovate: datasource=apk depName=curl
ENV CURL_VERSION="8.23.0-r0"
# renovate: datasource=apk depName=git
ENV GIT_VERSION="2.54.0-r0"
# renovate: datasource=apk depName=unzip
ENV UNZIP_VERSION="6.0-r16"
# renovate: datasource=apk depName=bash
ENV BASH_VERSION="5.3.9-r1"
# renovate: datasource=apk depName=openssh
ENV OPENSSH_VERSION="10.3_p1-r1"
# renovate: datasource=apk depName=dumb-init
ENV DUMB_INIT_VERSION="1.2.5-r4"
# renovate: datasource=apk depName=gcompat
ENV GCOMPAT_VERSION="1.1.0-r4"
# renovate: datasource=apk depName=coreutils-env
ENV COREUTILS_ENV_VERSION="9.11-r0"

# Install packages needed to run Atlantis.
# We place this last as it will bust less docker layer caches when packages update
RUN apk add --no-cache \
    ca-certificates=${CA_CERTIFICATES_VERSION} \
    curl=${CURL_VERSION} \
    git=${GIT_VERSION} \
    unzip=${UNZIP_VERSION} \
    bash=${BASH_VERSION} \
    openssh=${OPENSSH_VERSION} \
    dumb-init=${DUMB_INIT_VERSION} \
    gcompat=${GCOMPAT_VERSION} \
    coreutils-env=${COREUTILS_ENV_VERSION}

# Strip file capabilities only under fcap_scan_dirs (common rootfs locations for
# binaries and libs: /bin, /sbin, /usr, /opt, /lib, /lib64). This is a scoped
# scan, not a full getcap -r /: walking from / would traverse /proc, /sys, /dev,
# etc. and is slow/noisy. Anything outside fcap_scan_dirs is not checked. Strip
# and verify share the same list; post-pass getcap|grep fails the build if
# capabilities remain under that scope.
# renovate: datasource=apk depName=libcap
ENV LIBCAP_VERSION="2.78-r0"
# hadolint ignore=DL4006
RUN fcap_scan_dirs="/bin /sbin /usr /opt /lib /lib64" && \
    apk add --no-cache libcap=${LIBCAP_VERSION} && \
    command -v getcap >/dev/null && command -v setcap >/dev/null && \
    for d in $fcap_scan_dirs; do \
        [ -d "$d" ] && getcap -r "$d" 2>/dev/null; \
    done | awk '{ print $1 }' | sort -u | while read -r f; do \
        [ -n "$f" ] && { setcap -r "$f" 2>/dev/null || echo "warning: could not strip caps from $f" >&2; }; \
    done && \
    remaining="$(for d in $fcap_scan_dirs; do [ -d "$d" ] && getcap -r "$d" 2>/dev/null || :; done)" && \
    if [ -n "$remaining" ]; then \
        echo "failed to remove all file capabilities (post-pass getcap under fcap_scan_dirs):" >&2; \
        echo "$remaining" >&2; \
        exit 1; \
    fi && \
    apk del libcap

ARG DEFAULT_CONFTEST_VERSION
ENV DEFAULT_CONFTEST_VERSION=${DEFAULT_CONFTEST_VERSION}

# Set the entry point to the atlantis user and run the atlantis command
USER atlantis
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["server"]

# Stage 2 - Debian
FROM debian-base AS debian

ARG ATLANTIS_PORT=4141

EXPOSE ${ATLANTIS_PORT}

HEALTHCHECK --interval=5m --timeout=3s \
    CMD curl -f http://localhost:${ATLANTIS_PORT:-4141}/healthz || exit 1

# copy atlantis binary
COPY --from=builder /app/atlantis /usr/local/bin/atlantis
# copy dependencies
COPY --from=conftest-builder /usr/local/bin/conftest /usr/local/bin/conftest
# copy docker-entrypoint.sh
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ARG DEFAULT_CONFTEST_VERSION
ENV DEFAULT_CONFTEST_VERSION=${DEFAULT_CONFTEST_VERSION}

# Same as Alpine: strip and verify only under fcap_scan_dirs (scoped rootfs
# trees, not the entire image). Post-pass: if getcap still reports any
# "path = cap_set" line under that scope, the build fails. Strip may use
# 2>/dev/null and setcap || true; verification is the hard guarantee.
# renovate: datasource=deb depName=libcap2-bin
ENV DEBIAN_LIBCAP2_BIN_VERSION="1:2.75-10+deb13u1+b3"
# hadolint ignore=DL4006
RUN fcap_scan_dirs="/bin /sbin /usr /opt /lib /lib64" && \
    apt-get update && \
    apt-get install -y --no-install-recommends libcap2-bin=${DEBIAN_LIBCAP2_BIN_VERSION} && \
    command -v getcap >/dev/null && command -v setcap >/dev/null && \
    for d in $fcap_scan_dirs; do \
        [ -d "$d" ] && getcap -r "$d" 2>/dev/null; \
    done | awk '{ print $1 }' | sort -u | while read -r f; do \
        [ -n "$f" ] && { setcap -r "$f" 2>/dev/null || echo "warning: could not strip caps from $f" >&2; }; \
    done && \
    remaining="$(for d in $fcap_scan_dirs; do [ -d "$d" ] && getcap -r "$d" 2>/dev/null || :; done)" && \
    if [ -n "$remaining" ]; then \
        echo "failed to remove all file capabilities (post-pass getcap under fcap_scan_dirs):" >&2; \
        echo "$remaining" >&2; \
        exit 1; \
    fi && \
    apt-get purge -y libcap2-bin && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the entry point to the atlantis user and run the atlantis command
USER atlantis
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["server"]
