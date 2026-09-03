#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# fonts color
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
GreenBG="\033[42;37m"
RedBG="\033[41;37m"
Font="\033[0m"
# fonts color

# variable
FRP_VERSION=${FRP_VERSION:-0.80.7}
REPO=${REPO:-laosan-xx/frps}
# frp 发布仓库（laosan-xx/frp 已设为私有，匿名下载会 404）
FRP_RELEASE_REPO=${FRP_RELEASE_REPO:-laosan-xx/frp}
# 有该私有仓库读权限的 GitHub PAT，未设置时按公开仓库处理
FRP_PAT=${FRP_PAT:-}
WORK_PATH=$(dirname $(readlink -f $0))
FRP_NAME=frps
FRP_PATH=/usr/local/frp
PROXY_URL="https://ghfast.top/"

# check frps
if [ -f "/usr/local/frp/${FRP_NAME}" ] || [ -f "/usr/local/frp/${FRP_NAME}.toml" ] || [ -f "/lib/systemd/system/${FRP_NAME}.service" ];then
    echo -e "${Green}=========================================================================${Font}"
    echo -e "${RedBG}当前已退出脚本.${Font}"
    echo -e "${Green}检查到服务器已安装${Font} ${Red}${FRP_NAME}${Font}"
    echo -e "${Green}请手动确认和删除${Font} ${Red}/usr/local/frp/${Font} ${Green}目录下的${Font} ${Red}${FRP_NAME}${Font} ${Green}和${Font} ${Red}/${FRP_NAME}.toml${Font} ${Green}文件以及${Font} ${Red}/lib/systemd/system/${FRP_NAME}.service${Font} ${Green}文件,再次执行本脚本.${Font}"
    echo -e "${Green}参考命令如下:${Font}"
    echo -e "${Red}rm -rf /usr/local/frp/${FRP_NAME}${Font}"
    echo -e "${Red}rm -rf /usr/local/frp/${FRP_NAME}.toml${Font}"
    echo -e "${Red}rm -rf /lib/systemd/system/${FRP_NAME}.service${Font}"
    echo -e "${Green}=========================================================================${Font}"
    exit 2
fi

while ! test -z "$(ps -A | grep -w ${FRP_NAME})"; do
    FRPSPID=$(ps -A | grep -w ${FRP_NAME} | awk 'NR==1 {print $1}')
    kill -9 $FRPSPID
done

# check pkg
if type apt-get >/dev/null 2>&1 ; then
    if ! type wget >/dev/null 2>&1 ; then
        apt-get install wget -y
    fi
    if ! type curl >/dev/null 2>&1 ; then
        apt-get install curl -y
    fi
fi

if type yum >/dev/null 2>&1 ; then
    if ! type wget >/dev/null 2>&1 ; then
        yum install wget -y
    fi
    if ! type curl >/dev/null 2>&1 ; then
        yum install curl -y
    fi
fi

# check network
GOOGLE_HTTP_CODE=$(curl -o /dev/null --connect-timeout 5 --max-time 8 -s --head -w "%{http_code}" "https://www.google.com")
PROXY_HTTP_CODE=$(curl -o /dev/null --connect-timeout 5 --max-time 8 -s --head -w "%{http_code}" "${PROXY_URL}")

# check arch
if [ $(uname -m) = "x86_64" ]; then
    PLATFORM=amd64
fi

if [ $(uname -m) = "aarch64" ]; then
    PLATFORM=arm64
fi

if [ -z "${PLATFORM}" ]; then
    echo -e "${Red}无法识别当前架构: $(uname -m), 目前仅支持 x86_64 / aarch64 / armv7${Font}"
    exit 1
fi

FILE_NAME=frp_${FRP_VERSION}_linux_${PLATFORM}
TAG="v${FRP_VERSION}"
ASSET="${FILE_NAME}.tar.gz"
TARBALL="${WORK_PATH}/${ASSET}"

# 私有仓库匿名下载会拿到 404 的 JSON/HTML，必须校验是真正的 tar.gz
verify_tarball() {
	tar -tzf "$1" >/dev/null 2>&1
}

# 能直连 GitHub 就直连，否则先走代理再回退官方地址
candidate_urls() {
	local repo="$1"
	local url="https://github.com/${repo}/releases/download/${TAG}/${ASSET}"
	if [ "$GOOGLE_HTTP_CODE" == "200" ] || [ "$PROXY_HTTP_CODE" != "200" ]; then
		echo "$url"
	else
		echo "${PROXY_URL}${url}"
		echo "$url"
	fi
}

# 公开下载（仓库未私有，或 FRP_RELEASE_REPO 指向自己的镜像仓库时可用）
download_public() {
	local repo="$1" url
	for url in $(candidate_urls "$repo"); do
		rm -f "${TARBALL}"
		if curl -fsSL --connect-timeout 20 --retry 3 "$url" -o "${TARBALL}" && verify_tarball "${TARBALL}"; then
			echo -e "${Green}下载成功: ${url}${Font}"
			return 0
		fi
	done
	rm -f "${TARBALL}"
	return 1
}

# 私有仓库下载：GitHub API 资产接口（Bearer）优先，回退带令牌的浏览器下载地址
download_private() {
	local repo="$1" asset_id

	echo -e "${Green}检测到 FRP_PAT, 尝试从私有仓库 ${repo} 下载 ${TAG} ...${Font}"

	asset_id=$(curl -fsSL --connect-timeout 20 --retry 3 \
		-H "Authorization: Bearer ${FRP_PAT}" \
		-H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/${repo}/releases/tags/${TAG}" |
		sed 's/": */":/g' | tr ',{' '\n\n' |
		awk -v n="\"name\":\"${ASSET}\"" '
			{
				line = $0
				sub(/^[ \t]+/, "", line)
				sub(/[[:space:]]*$/, "", line)
				split(line, kv, ":")
				if (kv[1] == "\"id\"") { id = kv[2] }
				if (line == n) { print id; exit }
			}')

	if [ -n "$asset_id" ]; then
		rm -f "${TARBALL}"
		if curl -fsSL --connect-timeout 20 --retry 3 \
			-H "Authorization: Bearer ${FRP_PAT}" \
			-H "Accept: application/octet-stream" \
			"https://api.github.com/repos/${repo}/releases/assets/${asset_id}" \
			-o "${TARBALL}" && verify_tarball "${TARBALL}"; then
			echo -e "${Green}下载成功: ${repo} ${TAG} (asset ${asset_id})${Font}"
			return 0
		fi
	fi

	rm -f "${TARBALL}"
	if curl -fsSL --connect-timeout 20 --retry 3 \
		-u "x-access-token:${FRP_PAT}" \
		"https://github.com/${repo}/releases/download/${TAG}/${ASSET}" \
		-o "${TARBALL}" && verify_tarball "${TARBALL}"; then
		echo -e "${Green}下载成功: ${repo} ${TAG}${Font}"
		return 0
	fi

	rm -f "${TARBALL}"
	return 1
}

# 下载 frps.toml
download_toml() {
	local url="https://raw.githubusercontent.com/${REPO}/master/${FRP_NAME}.toml"
	local urls
	if [ "$GOOGLE_HTTP_CODE" == "200" ] || [ "$PROXY_HTTP_CODE" != "200" ]; then
		urls="$url"
	else
		urls="${PROXY_URL}${url} ${url}"
	fi
	for url in $urls; do
		rm -f "${WORK_PATH}/${FRP_NAME}.toml"
		if curl -fsSL --connect-timeout 20 --retry 3 "$url" -o "${WORK_PATH}/${FRP_NAME}.toml" &&
			[ -s "${WORK_PATH}/${FRP_NAME}.toml" ]; then
			return 0
		fi
	done
	rm -f "${WORK_PATH}/${FRP_NAME}.toml"
	return 1
}

if [ -f "${TARBALL}" ] && verify_tarball "${TARBALL}"; then
	echo -e "${Green}文件 ${ASSET} 已存在, 跳过下载.${Font}"
else
	DOWNLOAD_OK=0

	if [ -n "${FRP_PAT}" ]; then
		download_private "${FRP_RELEASE_REPO}" && DOWNLOAD_OK=1
	fi

	if [ "${DOWNLOAD_OK}" -ne 1 ]; then
		echo -e "${Yellow}尝试公开下载 ${FRP_RELEASE_REPO} ${TAG} ...${Font}"
		download_public "${FRP_RELEASE_REPO}" && DOWNLOAD_OK=1
	fi

	if [ "${DOWNLOAD_OK}" -ne 1 ]; then
		echo -e "${Red}下载 frp ${TAG} 失败!${Font}"
		echo -e "${Yellow}${FRP_RELEASE_REPO} 已设为私有仓库, 匿名下载会 404.${Font}"
		echo -e "${Yellow}请先执行 export FRP_PAT='github_pat_xxx'(需有该仓库读权限) 后重试,${Font}"
		echo -e "${Yellow}或用 FRP_RELEASE_REPO=owner/repo 指定自己的公开镜像仓库.${Font}"
		exit 1
	fi
fi

if [ -f "${WORK_PATH}/${FRP_NAME}.toml" ]; then
	echo -e "${Green}文件 ${FRP_NAME}.toml 已存在, 跳过下载.${Font}"
elif ! download_toml; then
	echo -e "${Red}下载 ${FRP_NAME}.toml 失败, 请检查网络或 REPO 设置!${Font}"
	exit 1
fi

tar -zxvf "${TARBALL}"
mkdir -p ${FRP_PATH}
mv "${WORK_PATH}/${FILE_NAME}/${FRP_NAME}" ${FRP_PATH}
mv "${WORK_PATH}/${FRP_NAME}.toml" ${FRP_PATH}

# 配置 frps.service
cat >/lib/systemd/system/frps.service <<'EOF'
[Unit]
Description=Frp Server Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/frp/frps -c /usr/local/frp/frps.toml

[Install]
WantedBy=multi-user.target

EOF

systemctl daemon-reload
sudo systemctl start ${FRP_NAME}
sudo systemctl enable ${FRP_NAME}

# clean
rm -rf ${WORK_PATH}/${FILE_NAME}.tar.gz ${WORK_PATH}/${FILE_NAME} ${FRP_NAME}_linux_install.sh

echo -e "${Green}====================================================================${Font}"
echo -e "${Green}安装成功,请先修改 ${FRP_NAME}.toml 文件,确保格式及配置正确无误!${Font}"
echo -e "${Red}vi /usr/local/frp/${FRP_NAME}.toml${Font}"
echo -e "${Green}修改完毕后执行以下命令重启服务:${Font}"
echo -e "${Red}sudo systemctl restart ${FRP_NAME}${Font}"
echo -e "${Green}====================================================================${Font}"
