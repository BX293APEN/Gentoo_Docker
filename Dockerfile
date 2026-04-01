# =============================================================================
# Dockerfile  ―  Gentoo rootfs ビルド環境
# Ubuntu 24.04 LTS ベース
# =============================================================================

FROM ubuntu:24.04

ARG WS
ARG ENTRY_DIR
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
    mkdir -p /${WS} /${ENTRY_DIR}&& \
    chmod 777 /${WS} &&\
    chmod 777 /${ENTRY_DIR} &&\
    update-locale LANG=${LANG} && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*



COPY ${ENTRY_POINT} /${ENTRY_DIR}/${ENTRY_POINT}
RUN chmod +x /${ENTRY_DIR}/${ENTRY_POINT}

WORKDIR /${WS}
