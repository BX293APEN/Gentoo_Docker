# =============================================================================
# Dockerfile  ―  Gentoo rootfs ビルド環境
# Ubuntu 24.04 LTS ベース
# =============================================================================

FROM ubuntu:24.04

ARG WS
ARG ENTRY_POINT
ARG LANG

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && \
    apt upgrade -y && \
    apt install -y --no-install-recommends \
        wget \
        curl \
        tar \
        xz-utils \
        dosfstools \
        e2fsprogs \
        util-linux \
        parted \
        bash \
        ca-certificates \
        language-pack-ja \
        grep \
        perl && \
    mkdir -p /${WS} && \
    update-locale LANG=${LANG} && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

COPY ${ENTRY_POINT} /${WS}/${ENTRY_POINT}
RUN chmod +x /${WS}/${ENTRY_POINT}

WORKDIR /${WS}
