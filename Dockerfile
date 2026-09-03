# syntax=docker/dockerfile:1
FROM alpine:3.8
LABEL maintainer="Stille <stille@ioiox.com>"

# frp 版本 / 发布仓库；laosan-xx/frp 已私有，构建时需传 FRP_PAT
# 令牌优先用 BuildKit secret 传入（不进镜像历史）：
#   docker build --secret id=FRP_PAT,env=FRP_PAT -t frps .
# 也支持 --build-arg FRP_PAT=xxx（会留在镜像历史里，仅本地构建时图省事用）
# 或 --build-arg FRP_RELEASE_REPO=你的账号/公开镜像仓库 彻底绕开私有仓库
ARG VERSION=0.80.7
ARG FRP_RELEASE_REPO=laosan-xx/frp
ARG FRP_PAT=""

ENV VERSION ${VERSION}
ENV TZ=Asia/Shanghai
WORKDIR /

RUN apk add --no-cache tzdata \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone

RUN --mount=type=secret,id=FRP_PAT,target=/run/secrets/frp_pat \
    if [ "$(uname -m)" = "x86_64" ]; then export PLATFORM=amd64 ; \
	elif [ "$(uname -m)" = "aarch64" ]; then export PLATFORM=arm64 ; \
	elif [ "$(uname -m)" = "armv7" ]; then export PLATFORM=arm ; \
	elif [ "$(uname -m)" = "armv7l" ]; then export PLATFORM=arm ; \
	elif [ "$(uname -m)" = "armhf" ]; then export PLATFORM=arm ; fi \
	&& FILE_NAME=frp_${VERSION}_linux_${PLATFORM} \
	&& apk add --no-cache curl \
	&& if [ -s /run/secrets/frp_pat ]; then FRP_PAT="$(cat /run/secrets/frp_pat)"; fi \
	&& ( if [ -n "${FRP_PAT}" ]; then \
	       ASSET_ID=$(curl -fsSL --connect-timeout 20 --retry 3 \
	         -H "Authorization: Bearer ${FRP_PAT}" \
	         -H "Accept: application/vnd.github+json" \
	         "https://api.github.com/repos/${FRP_RELEASE_REPO}/releases/tags/v${VERSION}" \
	         | sed 's/": */":/g' | tr ',{' '\n\n' \
	         | awk -v n="\"name\":\"${FILE_NAME}.tar.gz\"" '{ line=$0; sub(/^[ \t]+/,"",line); sub(/[[:space:]]*$/,"",line); split(line,kv,":"); if (kv[1]=="\"id\"") id=kv[2]; if (line==n) { print id; exit } }') \
	       && echo "private asset id: ${ASSET_ID}" \
	       && curl -fsSL --connect-timeout 20 --retry 3 \
	            -H "Authorization: Bearer ${FRP_PAT}" \
	            -H "Accept: application/octet-stream" \
	            -o "${FILE_NAME}.tar.gz" \
	            "https://api.github.com/repos/${FRP_RELEASE_REPO}/releases/assets/${ASSET_ID}"; \
	     else \
	       wget --no-check-certificate -O "${FILE_NAME}.tar.gz" \
	         https://github.com/${FRP_RELEASE_REPO}/releases/download/v${VERSION}/${FILE_NAME}.tar.gz; \
	     fi ) \
	&& tar xzf frp_${VERSION}_linux_${PLATFORM}.tar.gz \
	&& cd frp_${VERSION}_linux_${PLATFORM} \
	&& mkdir /frp \
	&& mv frps frps.toml /frp \
	&& cd .. \
	&& rm -rf *.tar.gz frp_${VERSION}_linux_${PLATFORM}

VOLUME /frp

CMD /frp/frps -c /frp/frps.toml
