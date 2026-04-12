#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/home/eqemu}"
SERVER_DIR="${INSTALL_ROOT}/server"
CACHE_DIR="${INSTALL_ROOT}/cache"
QUESTS_DIR="${INSTALL_ROOT}/quests"
MAPS_DIR="${INSTALL_ROOT}/maps"
SPIRE_DIR="${INSTALL_ROOT}/spire"
TARGET_USER="${TARGET_USER:-eqemu}"
TARGET_GROUP="${TARGET_GROUP:-}"
ACCESS_USER="${ACCESS_USER:-${SUDO_USER:-}}"
ACCESS_GROUP="${ACCESS_GROUP:-}"
SERVER_NAME="${SERVER_NAME:-EQEmu Linux Server}"
SERVER_SHORTNAME="${SERVER_SHORTNAME:-linux}"
DB_NAME="${DB_NAME:-peq}"
DB_USER="${DB_USER:-peq}"
DB_PASSWORD="${DB_PASSWORD:-peqpass}"
WORLD_ADDRESS="${WORLD_ADDRESS:-}"
LOCAL_ADDRESS="${LOCAL_ADDRESS:-}"
LOGIN_PORT_TITANIUM="${LOGIN_PORT_TITANIUM:-5998}"
LOGIN_PORT_SOD="${LOGIN_PORT_SOD:-5999}"
WORLD_TCP_PORT="${WORLD_TCP_PORT:-9001}"
WORLD_TELNET_PORT="${WORLD_TELNET_PORT:-9000}"
WORLD_HTTP_PORT="${WORLD_HTTP_PORT:-9080}"
QS_PORT="${QS_PORT:-9500}"
UCS_PORT="${UCS_PORT:-7778}"
ZONE_PORT_LOW="${ZONE_PORT_LOW:-7000}"
ZONE_PORT_HIGH="${ZONE_PORT_HIGH:-7400}"
RELEASE_TAG="${RELEASE_TAG:-}"
SPIRE_TAG="${SPIRE_TAG:-}"
SPIRE_PORT="${SPIRE_PORT:-8090}"
SPIRE_BASIC_AUTH_USER="${SPIRE_BASIC_AUTH_USER:-spire}"
SPIRE_BASIC_AUTH_PASSWORD="${SPIRE_BASIC_AUTH_PASSWORD:-spirepass}"
INSTALL_SPIRE=1
CONFIGURE_FIREWALL=1
INSTALL_SYSTEMD=1
ENABLE_SERVICE=1
REMOVE_ALL=0

usage() {
	cat <<'EOF'
EQEmu Linux binary installer

This installer downloads a prebuilt EQEmu Linux server release and the same
runtime content sources used by the current install flows:
  - release binaries from EQEmu releases
  - PEQ database from db.eqemu.dev/latest
  - quests from ProjectEQ/projecteqquests
  - maps from EQEmu/maps
  - Spire from EQEmu/spire releases

Usage:
  sudo ./linux_installer.sh [options]

Options:
  --install-root PATH       Install root. Default: /home/eqemu
  --target-user USER        Service user. Default: eqemu
  --target-group GROUP      Service group. Default: eqemu
  --access-user USER        Extra user granted access to install root. Default: invoking sudo user
  --access-group GROUP      Group used when ACLs are unavailable. Default: access user's primary group
  --server-name NAME        World long name
  --shortname NAME          World short name
  --db-name NAME            Database name. Default: peq
  --db-user USER            Database user. Default: peq
  --db-password PASS        Database password. Default: peqpass
  --world-address IP        Public world address
  --local-address IP        Local/LAN world address
  --release-tag TAG         Specific EQEmu release tag to install
  --spire-tag TAG           Specific Spire release tag to install
  --no-spire                Skip Spire install
  --no-firewall             Skip firewall rule setup
  --remove-all              Remove the EQEmu install, services, DB, and firewall rules
  --no-systemd              Skip systemd unit creation
  --no-enable-service       Create unit but do not enable/start it
  --help                    Show this help
EOF
}

log() {
	printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

retry() {
	local attempts="$1"
	shift
	local attempt=1
	until "$@"; do
		if (( attempt >= attempts )); then
			return 1
		fi
		attempt=$((attempt + 1))
		sleep 2
	done
}

mariadb_admin_cmd() {
	if command_exists mariadb-admin; then
		echo "mariadb-admin"
	else
		echo "mysqladmin"
	fi
}

run_as_target() {
	if [[ "${TARGET_USER}" == "root" ]]; then
		"$@"
	else
		sudo -u "${TARGET_USER}" -H "$@"
	fi
}

download_to() {
	local destination="$1"
	shift
	local url
	for url in "$@"; do
		if curl -fL --retry 3 --connect-timeout 15 -o "${destination}" "${url}"; then
			return 0
		fi
	done
	return 1
}

detect_primary_ip() {
	if command_exists ip; then
		ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; ++i) if ($i == "src") {print $(i + 1); exit}}'
	fi
}

ensure_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		die "Run this installer as root or with sudo."
	fi
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--install-root)
				INSTALL_ROOT="$2"
				SERVER_DIR="${INSTALL_ROOT}/server"
				CACHE_DIR="${INSTALL_ROOT}/cache"
				QUESTS_DIR="${INSTALL_ROOT}/quests"
				MAPS_DIR="${INSTALL_ROOT}/maps"
				shift 2
				;;
			--target-user)
				TARGET_USER="$2"
				shift 2
				;;
			--target-group)
				TARGET_GROUP="$2"
				shift 2
				;;
			--access-user)
				ACCESS_USER="$2"
				shift 2
				;;
			--access-group)
				ACCESS_GROUP="$2"
				shift 2
				;;
			--server-name)
				SERVER_NAME="$2"
				shift 2
				;;
			--shortname)
				SERVER_SHORTNAME="$2"
				shift 2
				;;
			--db-name)
				DB_NAME="$2"
				shift 2
				;;
			--db-user)
				DB_USER="$2"
				shift 2
				;;
			--db-password)
				DB_PASSWORD="$2"
				shift 2
				;;
			--world-address)
				WORLD_ADDRESS="$2"
				shift 2
				;;
			--local-address)
				LOCAL_ADDRESS="$2"
				shift 2
				;;
			--release-tag)
				RELEASE_TAG="$2"
				shift 2
				;;
			--spire-tag)
				SPIRE_TAG="$2"
				shift 2
				;;
			--no-spire)
				INSTALL_SPIRE=0
				shift
				;;
			--no-firewall)
				CONFIGURE_FIREWALL=0
				shift
				;;
			--remove-all)
				REMOVE_ALL=1
				shift
				;;
			--no-systemd)
				INSTALL_SYSTEMD=0
				ENABLE_SERVICE=0
				shift
				;;
			--no-enable-service)
				ENABLE_SERVICE=0
				shift
				;;
			--help|-h)
				usage
				exit 0
				;;
			*)
				die "Unknown option: $1"
				;;
		esac
	done
}

detect_platform() {
	if [[ -f /etc/os-release ]]; then
		# shellcheck disable=SC1091
		source /etc/os-release
	else
		die "Cannot detect Linux distribution."
	fi

	case "${ID:-}" in
		ubuntu|debian)
			PKG_FAMILY="apt"
			;;
		fedora)
			PKG_FAMILY="dnf"
			;;
		rocky|almalinux|rhel|centos)
			if command_exists dnf; then
				PKG_FAMILY="dnf"
			else
				PKG_FAMILY="yum"
			fi
			;;
		*)
			case "${ID_LIKE:-}" in
				*debian*)
					PKG_FAMILY="apt"
					;;
				*rhel*|*fedora*)
					if command_exists dnf; then
						PKG_FAMILY="dnf"
					else
						PKG_FAMILY="yum"
					fi
					;;
				*)
					die "Unsupported distribution: ${PRETTY_NAME:-unknown}"
					;;
			esac
			;;
	esac
}

install_packages() {
	log "Installing runtime packages"
	case "${PKG_FAMILY}" in
		apt)
			export DEBIAN_FRONTEND=noninteractive
			apt-get update
			apt-get install -y build-essential ca-certificates cpanminus curl git jq libmariadb-dev mariadb-client mariadb-server perl libjson-perl libio-stringy-perl luajit rsync unzip wget xdg-utils
			;;
		dnf)
			dnf install -y ca-certificates curl gcc gcc-c++ git jq make mariadb mariadb-devel mariadb-server perl perl-JSON perl-IO-Stringy perl-App-cpanminus luajit rsync unzip wget xdg-utils
			;;
		yum)
			yum install -y ca-certificates curl gcc gcc-c++ git jq make mariadb mariadb-devel mariadb-server perl perl-JSON perl-IO-Stringy perl-App-cpanminus luajit rsync unzip wget xdg-utils
			;;
	esac
}

install_eqemu_perl() {
	local perl_prefix="/opt/eqemu-perl"
	local perl_build_dir="${CACHE_DIR}/eqemu-perl-build"
	local perl_tarball="${CACHE_DIR}/perl5-5.32.1.tar.gz"

	if [[ -x "${perl_prefix}/bin/perl" ]]; then
		log "eqemu-perl already present at ${perl_prefix}"
		return 0
	fi

	log "Installing eqemu-perl runtime to ${perl_prefix}"
	mkdir -p "${perl_prefix}" "${perl_build_dir}"

	download_to "${perl_tarball}" \
		"https://github.com/EQEmu/Server/releases/download/v1.2/perl5-5.32.1.tar.gz" || die "Failed to download eqemu-perl source tarball"

	rm -rf "${perl_build_dir}"
	mkdir -p "${perl_build_dir}"
	tar -xzf "${perl_tarball}" --strip-components=1 -C "${perl_build_dir}"

	pushd "${perl_build_dir}" >/dev/null
	./Configure -des -Dprefix="${perl_prefix}" -Dusethreads -Dusemultiplicity -Duse64bitall -Dnoextensions -Duseshrplib >/dev/null
	make -j"$(nproc)" >/dev/null
	make -j"$(nproc)" install >/dev/null
	popd >/dev/null

	if ! command_exists cpanm; then
		yes | "${perl_prefix}/bin/perl" -MCPAN -e 'install App::cpanminus' >/dev/null
	fi

	"${perl_prefix}/bin/cpanm" --notest DBI >/dev/null
	"${perl_prefix}/bin/cpanm" --notest DBD::mysql@4.046_01 >/dev/null
	"${perl_prefix}/bin/cpanm" --notest JSON >/dev/null
	"${perl_prefix}/bin/cpanm" --notest Data::Dumper >/dev/null
	"${perl_prefix}/bin/cpanm" --notest File::Find >/dev/null
	"${perl_prefix}/bin/cpanm" --notest File::Path >/dev/null
	"${perl_prefix}/bin/cpanm" --notest List::Util >/dev/null
	"${perl_prefix}/bin/cpanm" --notest Switch >/dev/null
	"${perl_prefix}/bin/cpanm" --notest Net::Telnet >/dev/null
	"${perl_prefix}/bin/cpanm" --notest Module::Refresh >/dev/null

	rm -rf "${perl_build_dir}"
}

ensure_user() {
	if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
		log "Creating ${TARGET_USER} user"
		useradd --create-home --home-dir "${INSTALL_ROOT}" --shell /bin/bash "${TARGET_USER}"
	fi

	if [[ -z "${TARGET_GROUP}" ]]; then
		TARGET_GROUP="$(id -gn "${TARGET_USER}")"
	fi

	if [[ -n "${ACCESS_USER}" && -z "${ACCESS_GROUP}" ]] && id -u "${ACCESS_USER}" >/dev/null 2>&1; then
		ACCESS_GROUP="$(id -gn "${ACCESS_USER}")"
	fi
}

grant_access_user() {
	if [[ -z "${ACCESS_USER}" ]]; then
		return 0
	fi

	if ! id -u "${ACCESS_USER}" >/dev/null 2>&1; then
		log "Access user ${ACCESS_USER} does not exist, skipping access grant"
		return 0
	fi

	log "Granting ${ACCESS_USER} access to ${INSTALL_ROOT}"
	if command_exists setfacl; then
		setfacl -R -m "u:${ACCESS_USER}:rwX" "${INSTALL_ROOT}" || true
		setfacl -R -d -m "u:${ACCESS_USER}:rwX" "${INSTALL_ROOT}" || true
	elif [[ -n "${ACCESS_GROUP}" ]]; then
		chgrp -R "${ACCESS_GROUP}" "${INSTALL_ROOT}" || true
		chmod -R g+rwX "${INSTALL_ROOT}" || true
		find "${INSTALL_ROOT}" -type d -exec chmod g+s {} \; || true
	else
		log "No ACL support and no access group available, skipping access grant"
	fi
}

set_content_permissions() {
	local content_dir

	for content_dir in "${QUESTS_DIR}" "${MAPS_DIR}"; do
		[[ -d "${content_dir}" ]] || continue

		log "Setting permissive content permissions on ${content_dir}"
		find "${content_dir}" -type d -exec chmod 777 {} \;
		find "${content_dir}" -type f -exec chmod 666 {} \;
	done

	if command_exists setfacl; then
		log "Setting default ACLs on ${QUESTS_DIR} and ${MAPS_DIR}"
		setfacl -R -m u::rwx,g::rwx,o::rwx,m::rwx "${QUESTS_DIR}" "${MAPS_DIR}" || true
		setfacl -R -d -m u::rwx,g::rwx,o::rwx,m::rwx "${QUESTS_DIR}" "${MAPS_DIR}" || true
	fi
}

prepare_dirs() {
	mkdir -p "${INSTALL_ROOT}" "${SERVER_DIR}" "${CACHE_DIR}" "${SPIRE_DIR}"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${INSTALL_ROOT}"
	grant_access_user
}

determine_release_tag() {
	if [[ -n "${RELEASE_TAG}" ]]; then
		return 0
	fi

	log "Resolving latest EQEmu release tag"
	RELEASE_TAG="$(
		curl -fsSL https://api.github.com/repos/EQEmu/Server/releases/latest |
		jq -r '.tag_name'
	)"

	[[ -n "${RELEASE_TAG}" && "${RELEASE_TAG}" != "null" ]] || die "Could not determine latest release tag."
}

determine_spire_tag() {
	if (( ! INSTALL_SPIRE )); then
		return 0
	fi

	if [[ -n "${SPIRE_TAG}" ]]; then
		return 0
	fi

	log "Resolving latest Spire release tag"
	SPIRE_TAG="$(
		curl -fsSL https://api.github.com/repos/EQEmu/spire/releases/latest |
		jq -r '.tag_name'
	)"

	[[ -n "${SPIRE_TAG}" && "${SPIRE_TAG}" != "null" ]] || die "Could not determine latest Spire release tag."
}

download_release() {
	local zip_file="${CACHE_DIR}/eqemu-server-linux-x64-${RELEASE_TAG}.zip"
	local download_urls=(
		"https://github.com/EQEmu/Server/releases/download/${RELEASE_TAG}/eqemu-server-linux-x64.zip"
		"https://github.com/EQEmu/Server/releases/latest/download/eqemu-server-linux-x64.zip"
		"https://sourceforge.net/projects/eqemulator-core-server.mirror/files/${RELEASE_TAG}/eqemu-server-linux-x64.zip/download"
	)

	log "Downloading EQEmu Linux release ${RELEASE_TAG}"
	if ! download_to "${zip_file}" "${download_urls[@]}"; then
		die "Failed to download eqemu-server-linux-x64.zip for ${RELEASE_TAG}"
	fi

	log "Extracting release zip"
	rm -rf "${SERVER_DIR}"
	mkdir -p "${SERVER_DIR}"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SERVER_DIR}"
	run_as_target unzip -o "${zip_file}" -d "${SERVER_DIR}"
	chmod 755 "${SERVER_DIR}"/*
}

download_spire() {
	local api_url asset_url asset_name archive_path

	if (( ! INSTALL_SPIRE )); then
		return 0
	fi

	api_url="https://api.github.com/repos/EQEmu/spire/releases/tags/${SPIRE_TAG}"
	asset_url="$(
		curl -fsSL "${api_url}" |
		jq -r '
			first(
				.assets[]
				| select(
					(.name | ascii_downcase | test("spire")) and
					(.name | ascii_downcase | test("linux")) and
					(.name | ascii_downcase | test("amd64|x86_64")) and
					(.name | ascii_downcase | test("\\.zip$|\\.tar\\.gz$|\\.tgz$"))
				)
				| .browser_download_url
			)
		'
	)"
	asset_name="$(
		curl -fsSL "${api_url}" |
		jq -r '
			first(
				.assets[]
				| select(
					(.name | ascii_downcase | test("spire")) and
					(.name | ascii_downcase | test("linux")) and
					(.name | ascii_downcase | test("amd64|x86_64")) and
					(.name | ascii_downcase | test("\\.zip$|\\.tar\\.gz$|\\.tgz$"))
				)
				| .name
			)
		'
	)"

	if [[ -z "${asset_url}" || "${asset_url}" == "null" || -z "${asset_name}" || "${asset_name}" == "null" ]]; then
		die "Could not find a clearly named Spire Linux amd64 release asset for ${SPIRE_TAG}. Install Spire manually or run with --no-spire."
	fi

	archive_path="${CACHE_DIR}/${asset_name}"
	log "Downloading Spire ${SPIRE_TAG}"
	download_to "${archive_path}" "${asset_url}" || die "Failed to download Spire release asset"

	rm -rf "${SPIRE_DIR}"
	mkdir -p "${SPIRE_DIR}"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SPIRE_DIR}"

	case "${archive_path}" in
		*.zip)
			run_as_target unzip -o "${archive_path}" -d "${SPIRE_DIR}"
			;;
		*.tar.gz|*.tgz)
			run_as_target tar -xzf "${archive_path}" -C "${SPIRE_DIR}"
			;;
		*)
			die "Unsupported Spire archive format: ${archive_path}"
			;;
	esac

	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SPIRE_DIR}"
}

download_runtime_assets() {
	local raw_base="https://raw.githubusercontent.com/EQEmu/Server/${RELEASE_TAG}"
	local assets_dir="${SERVER_DIR}/assets/patches"

	log "Downloading runtime assets for ${RELEASE_TAG}"
	mkdir -p "${assets_dir}" "${SERVER_DIR}/logs" "${SERVER_DIR}/shared"

	download_to "${SERVER_DIR}/login.template.json" \
		"${raw_base}/loginserver/login_util/login.json" || die "Failed to download login.json template"

	download_to "${SERVER_DIR}/mime.types" \
		"${raw_base}/utils/defaults/mime.types" || die "Failed to download mime.types"

	download_to "${assets_dir}/opcodes.conf" \
		"${raw_base}/utils/patches/opcodes.conf" || die "Failed to download opcodes.conf"
	download_to "${assets_dir}/mail_opcodes.conf" \
		"${raw_base}/utils/patches/mail_opcodes.conf" || die "Failed to download mail_opcodes.conf"
	download_to "${assets_dir}/patch_Titanium.conf" \
		"${raw_base}/utils/patches/patch_Titanium.conf" || die "Failed to download patch_Titanium.conf"
	download_to "${assets_dir}/patch_SoD.conf" \
		"${raw_base}/utils/patches/patch_SoD.conf" || die "Failed to download patch_SoD.conf"
	download_to "${assets_dir}/patch_SoF.conf" \
		"${raw_base}/utils/patches/patch_SoF.conf" || die "Failed to download patch_SoF.conf"
	download_to "${assets_dir}/patch_UF.conf" \
		"${raw_base}/utils/patches/patch_UF.conf" || die "Failed to download patch_UF.conf"
	download_to "${assets_dir}/patch_RoF.conf" \
		"${raw_base}/utils/patches/patch_RoF.conf" || die "Failed to download patch_RoF.conf"
	download_to "${assets_dir}/patch_RoF2.conf" \
		"${raw_base}/utils/patches/patch_RoF2.conf" || die "Failed to download patch_RoF2.conf"
	download_to "${assets_dir}/login_opcodes.conf" \
		"${raw_base}/loginserver/login_util/login_opcodes.conf" || die "Failed to download login_opcodes.conf"
	download_to "${assets_dir}/login_opcodes_sod.conf" \
		"${raw_base}/loginserver/login_util/login_opcodes_sod.conf" || die "Failed to download login_opcodes_sod.conf"
}

download_content() {
	local db_zip="${CACHE_DIR}/db.sql.zip"

	if [[ ! -d "${QUESTS_DIR}/.git" ]]; then
		log "Cloning ProjectEQ quests"
		run_as_target git clone --depth 1 https://github.com/ProjectEQ/projecteqquests.git "${QUESTS_DIR}"
	else
		log "Updating ProjectEQ quests"
		run_as_target git -C "${QUESTS_DIR}" pull --ff-only
	fi

	if [[ ! -d "${MAPS_DIR}/.git" ]]; then
		log "Cloning EQEmu maps"
		run_as_target git clone --depth 1 https://github.com/EQEmu/maps.git "${MAPS_DIR}"
	else
		log "Updating EQEmu maps"
		run_as_target git -C "${MAPS_DIR}" pull --ff-only
	fi

	log "Downloading latest PEQ database dump"
	if ! download_to "${db_zip}" \
		"https://db.eqemu.dev/latest" \
		"http://db.projecteq.net/api/v1/dump/latest"; then
		die "Failed to download latest PEQ database dump"
	fi

	rm -rf "${CACHE_DIR}/db"
	mkdir -p "${CACHE_DIR}/db"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${CACHE_DIR}/db"
	run_as_target unzip -o "${db_zip}" -d "${CACHE_DIR}/db"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${QUESTS_DIR}" "${MAPS_DIR}" "${CACHE_DIR}"
	set_content_permissions
	grant_access_user
}

configure_mariadb() {
	log "Starting MariaDB"
	systemctl enable mariadb --now
	retry 30 "$(mariadb_admin_cmd)" ping --silent

	log "Creating database ${DB_NAME}"
	mariadb <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
CREATE DATABASE \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

configure_firewall() {
	if (( ! CONFIGURE_FIREWALL )); then
		return 0
	fi

	log "Configuring firewall rules"

	if command_exists ufw; then
		ufw allow 9000:9001/tcp || true
		ufw allow 9000:9001/udp || true
		ufw allow 7000:7500/tcp || true
		ufw allow 7000:7500/udp || true
		ufw allow 7778/tcp || true
		ufw allow 5998/tcp || true
		ufw allow 5998/udp || true
		ufw allow 5999/tcp || true
		ufw allow 5999/udp || true
		if (( INSTALL_SPIRE )); then
			ufw allow "${SPIRE_PORT}/tcp" || true
		fi
	elif command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
		firewall-cmd --permanent --add-port=9000-9001/tcp || true
		firewall-cmd --permanent --add-port=9000-9001/udp || true
		firewall-cmd --permanent --add-port=7000-7500/tcp || true
		firewall-cmd --permanent --add-port=7000-7500/udp || true
		firewall-cmd --permanent --add-port=7778/tcp || true
		firewall-cmd --permanent --add-port=5998/tcp || true
		firewall-cmd --permanent --add-port=5998/udp || true
		firewall-cmd --permanent --add-port=5999/tcp || true
		firewall-cmd --permanent --add-port=5999/udp || true
		if (( INSTALL_SPIRE )); then
			firewall-cmd --permanent --add-port="${SPIRE_PORT}/tcp" || true
		fi
		firewall-cmd --reload || true
	else
		log "No supported firewall manager detected, skipping firewall rule setup"
	fi
}

import_database() {
	local dump_dir="${CACHE_DIR}/db/peq-dump"
	local sql_files=(
		create_tables_content.sql
		create_tables_login.sql
		create_tables_player.sql
		create_tables_state.sql
		create_tables_system.sql
	)
	local file

	[[ -d "${dump_dir}" ]] || die "Database dump extract failed; ${dump_dir} not found"

	for file in "${sql_files[@]}"; do
		[[ -f "${dump_dir}/${file}" ]] || die "Missing ${file} in ${dump_dir}"
		log "Importing ${file}"
		mariadb "${DB_NAME}" < "${dump_dir}/${file}"
	done
}

write_configs() {
	local shared_key
	local runtime_ip

	shared_key="$(openssl rand -hex 24)"
	runtime_ip="$(detect_primary_ip || true)"

	if [[ -z "${WORLD_ADDRESS}" ]]; then
		WORLD_ADDRESS="${runtime_ip:-127.0.0.1}"
	fi
	if [[ -z "${LOCAL_ADDRESS}" ]]; then
		LOCAL_ADDRESS="${runtime_ip:-127.0.0.1}"
	fi

	cat > "${SERVER_DIR}/eqemu_config.json" <<EOF
{
  "server": {
    "auto_database_updates": "false",
    "zones": {
      "defaultstatus": "0",
      "ports": {
        "low": "${ZONE_PORT_LOW}",
        "high": "${ZONE_PORT_HIGH}"
      }
    },
    "qsdatabase": {
      "host": "127.0.0.1",
      "port": "3306",
      "username": "${DB_USER}",
      "password": "${DB_PASSWORD}",
      "db": "${DB_NAME}"
    },
    "ucs": {
      "host": "127.0.0.1",
      "port": "${UCS_PORT}"
    },
    "world": {
      "shortname": "${SERVER_SHORTNAME}",
      "longname": "${SERVER_NAME}",
      "address": "${WORLD_ADDRESS}",
      "localaddress": "${LOCAL_ADDRESS}",
      "maxclients": "-1",
      "key": "${shared_key}",
      "loginserver1": {
        "host": "127.0.0.1",
        "port": "${LOGIN_PORT_TITANIUM}",
        "account": "",
        "password": "",
        "legacy": "0"
      },
      "tcp": {
        "ip": "127.0.0.1",
        "port": "${WORLD_TCP_PORT}"
      },
      "telnet": {
        "ip": "0.0.0.0",
        "port": "${WORLD_TELNET_PORT}",
        "enabled": "true"
      },
      "http": {
        "port": "${WORLD_HTTP_PORT}",
        "enabled": "true",
        "mimefile": "mime.types"
      }
    },
    "database": {
      "db": "${DB_NAME}",
      "host": "127.0.0.1",
      "port": "3306",
      "username": "${DB_USER}",
      "password": "${DB_PASSWORD}"
    },
    "queryserver": {
      "host": "127.0.0.1",
      "port": "${QS_PORT}"
    },
    "files": {
      "opcodes": "assets/patches/opcodes.conf",
      "mail_opcodes": "assets/patches/mail_opcodes.conf"
    },
    "directories": {
      "maps": "maps/",
      "quests": "quests/",
      "plugins": "plugins/",
      "lua_modules": "lua_modules/",
      "patches": "assets/patches/",
      "opcodes": "assets/patches/",
      "shared_memory": "shared/",
      "logs": "logs/"
    }
  }
}
EOF

	jq \
		--arg db_name "${DB_NAME}" \
		--arg db_user "${DB_USER}" \
		--arg db_password "${DB_PASSWORD}" \
		--arg titanium_port "${LOGIN_PORT_TITANIUM}" \
		--arg sod_port "${LOGIN_PORT_SOD}" \
		'.database.host = "127.0.0.1" |
		 .database.port = "3306" |
		 .database.db = $db_name |
		 .database.user = $db_user |
		 .database.password = $db_password |
		 .account.auto_create_accounts = true |
		 .worldservers.unregistered_allowed = true |
		 .worldservers.reject_duplicate_servers = false |
		 .security.mode = 14 |
		 .security.allow_password_login = true |
		 .security.allow_token_login = true |
		 .client_configuration.titanium_port = ($titanium_port | tonumber) |
		 .client_configuration.titanium_opcodes = "assets/patches/login_opcodes.conf" |
		 .client_configuration.sod_port = ($sod_port | tonumber) |
		 .client_configuration.sod_opcodes = "assets/patches/login_opcodes_sod.conf"' \
		"${SERVER_DIR}/login.template.json" > "${SERVER_DIR}/login.json"

	rm -f "${SERVER_DIR}/login.template.json"
	chown "${TARGET_USER}:${TARGET_GROUP}" "${SERVER_DIR}/eqemu_config.json" "${SERVER_DIR}/login.json"
	chmod 640 "${SERVER_DIR}/eqemu_config.json" "${SERVER_DIR}/login.json"
	grant_access_user
}

link_content() {
	mkdir -p "${SERVER_DIR}/bin"
	ln -sfn "${SERVER_DIR}/world" "${SERVER_DIR}/bin/world"
	ln -sfn "${SERVER_DIR}/zone" "${SERVER_DIR}/bin/zone"
	ln -sfn "${SERVER_DIR}/loginserver" "${SERVER_DIR}/bin/loginserver"
	ln -sfn "${SERVER_DIR}/queryserv" "${SERVER_DIR}/bin/queryserv"
	ln -sfn "${SERVER_DIR}/shared_memory" "${SERVER_DIR}/bin/shared_memory"
	ln -sfn "${SERVER_DIR}/ucs" "${SERVER_DIR}/bin/ucs"
	ln -sfn "${SERVER_DIR}/eqlaunch" "${SERVER_DIR}/bin/eqlaunch"
	ln -sfn "${QUESTS_DIR}" "${SERVER_DIR}/quests"
	ln -sfn "${QUESTS_DIR}/plugins" "${SERVER_DIR}/plugins"
	ln -sfn "${QUESTS_DIR}/lua_modules" "${SERVER_DIR}/lua_modules"
	ln -sfn "${MAPS_DIR}" "${SERVER_DIR}/maps"
	ln -sfn maps "${SERVER_DIR}/Maps"
	chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SERVER_DIR}"
	grant_access_user
}

write_spire_files() {
	local spire_exec spire_link

	if (( ! INSTALL_SPIRE )); then
		return 0
	fi

	spire_exec="$(
		find "${SPIRE_DIR}" -maxdepth 3 -type f -perm -111 \
			\( -iname 'spire' -o -iname 'spire-*' -o -iname 'server' -o -iname 'spire-server' \) \
			| head -n 1
	)"

	[[ -n "${spire_exec}" ]] || die "Could not find a runnable Spire executable after extraction"
	spire_link="${SERVER_DIR}/spire"
	ln -sfn "${spire_exec}" "${spire_link}"

	cat > "${SPIRE_DIR}/spire.env" <<EOF
BASIC_AUTH_USER=${SPIRE_BASIC_AUTH_USER}
BASIC_AUTH_PASSWORD=${SPIRE_BASIC_AUTH_PASSWORD}
EOF

	cat > "${SPIRE_DIR}/start_spire.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
set -a
source "\${ROOT_DIR}/spire.env"
set +a
cd "${SERVER_DIR}"
exec "${spire_link}"
EOF

	cat > "${SPIRE_DIR}/stop_spire.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
pkill -f "/spire($| )|/spire-" || true
EOF

	chmod 755 "${SPIRE_DIR}/start_spire.sh" "${SPIRE_DIR}/stop_spire.sh"
	chown "${TARGET_USER}:${TARGET_GROUP}" "${SPIRE_DIR}/spire.env" "${SPIRE_DIR}/start_spire.sh" "${SPIRE_DIR}/stop_spire.sh" "${spire_link}"
	chmod 600 "${SPIRE_DIR}/spire.env"
	grant_access_user
}

write_helpers() {
	cat > "${SERVER_DIR}/start_server.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${ROOT_DIR}/run"
LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "${RUN_DIR}" "${LOG_DIR}"

start_proc() {
	local name="$1"
	if [[ -f "${RUN_DIR}/${name}.pid" ]] && kill -0 "$(cat "${RUN_DIR}/${name}.pid")" 2>/dev/null; then
		echo "${name} is already running"
		return 0
	fi
	nohup "${ROOT_DIR}/${name}" >> "${LOG_DIR}/${name}.console.log" 2>&1 &
	echo $! > "${RUN_DIR}/${name}.pid"
	echo "Started ${name} (pid $(cat "${RUN_DIR}/${name}.pid"))"
}

cd "${ROOT_DIR}"
"${ROOT_DIR}/shared_memory" >> "${LOG_DIR}/shared_memory.console.log" 2>&1
start_proc loginserver
sleep 1
start_proc world
sleep 1
start_proc ucs
start_proc queryserv
start_proc zone
EOF

	cat > "${SERVER_DIR}/stop_server.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${ROOT_DIR}/run"

stop_proc() {
	local name="$1"
	local pid_file="${RUN_DIR}/${name}.pid"
	if [[ ! -f "${pid_file}" ]]; then
		return 0
	fi

	local pid
	pid="$(cat "${pid_file}")"
	if kill -0 "${pid}" 2>/dev/null; then
		kill "${pid}" 2>/dev/null || true
		for _ in $(seq 1 20); do
			if ! kill -0 "${pid}" 2>/dev/null; then
				break
			fi
			sleep 1
		done
		if kill -0 "${pid}" 2>/dev/null; then
			kill -9 "${pid}" 2>/dev/null || true
		fi
	fi
	rm -f "${pid_file}"
	echo "Stopped ${name}"
}

stop_proc zone
stop_proc queryserv
stop_proc ucs
stop_proc world
stop_proc loginserver
EOF

	cat > "${SERVER_DIR}/server_restart.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
"${SERVER_DIR}/stop_server.sh"
sleep 2
"${SERVER_DIR}/start_server.sh"
EOF

	chmod 755 "${SERVER_DIR}/start_server.sh" "${SERVER_DIR}/stop_server.sh" "${SERVER_DIR}/server_restart.sh"
	chown "${TARGET_USER}:${TARGET_GROUP}" "${SERVER_DIR}/start_server.sh" "${SERVER_DIR}/stop_server.sh" "${SERVER_DIR}/server_restart.sh"
	if (( INSTALL_SPIRE )); then
		cat > "${INSTALL_ROOT}/spire_start.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^spire.service'; then
  sudo systemctl start spire
else
  sudo -u ${TARGET_USER} "${SPIRE_DIR}/start_spire.sh"
fi
EOF

		cat > "${INSTALL_ROOT}/spire_stop.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^spire.service'; then
  sudo systemctl stop spire
else
  sudo -u ${TARGET_USER} "${SPIRE_DIR}/stop_spire.sh"
fi
EOF

		cat > "${INSTALL_ROOT}/spire_web.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
URL="http://127.0.0.1:${SPIRE_PORT}"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\${URL}" >/dev/null 2>&1 || printf '%s\n' "\${URL}"
else
  printf '%s\n' "\${URL}"
fi
EOF

		cat > "${INSTALL_ROOT}/spire_web_admin.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
URL="http://127.0.0.1:${SPIRE_PORT}/admin"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\${URL}" >/dev/null 2>&1 || printf '%s\n' "\${URL}"
else
  printf '%s\n' "\${URL}"
fi
EOF

		chmod 755 "${INSTALL_ROOT}/spire_start.sh" "${INSTALL_ROOT}/spire_stop.sh" "${INSTALL_ROOT}/spire_web.sh" "${INSTALL_ROOT}/spire_web_admin.sh"
		chown "${TARGET_USER}:${TARGET_GROUP}" "${INSTALL_ROOT}/spire_start.sh" "${INSTALL_ROOT}/spire_stop.sh" "${INSTALL_ROOT}/spire_web.sh" "${INSTALL_ROOT}/spire_web_admin.sh"
	fi
	grant_access_user
}

run_post_install_steps() {
	log "Applying database updates"
	run_as_target bash -lc "cd '${SERVER_DIR}' && FORCE_INTERACTIVE=1 ./world database:updates --skip-backup --force"

	log "Priming shared memory"
	run_as_target bash -lc "cd '${SERVER_DIR}' && ./shared_memory"
}

stop_existing_services() {
	if [[ -d /run/systemd/system ]]; then
		if systemctl list-unit-files | grep -q '^spire.service'; then
			log "Stopping existing spire service"
			systemctl stop spire || true
		fi
		if systemctl list-unit-files | grep -q '^eqemu.service'; then
			log "Stopping existing eqemu service"
			systemctl stop eqemu || true
		fi
	fi
}

start_existing_services() {
	if (( ! ENABLE_SERVICE )); then
		return 0
	fi

	if [[ -d /run/systemd/system ]]; then
		if systemctl list-unit-files | grep -q '^eqemu.service'; then
			log "Starting eqemu service"
			systemctl start eqemu || true
		fi
		if (( INSTALL_SPIRE )) && systemctl list-unit-files | grep -q '^spire.service'; then
			log "Starting spire service"
			systemctl start spire || true
		fi
	fi
}

remove_firewall_rules() {
	log "Removing firewall rules"
	if command_exists ufw; then
		ufw delete allow 9000:9001/tcp || true
		ufw delete allow 9000:9001/udp || true
		ufw delete allow 7000:7500/tcp || true
		ufw delete allow 7000:7500/udp || true
		ufw delete allow 7778/tcp || true
		ufw delete allow 5998/tcp || true
		ufw delete allow 5998/udp || true
		ufw delete allow 5999/tcp || true
		ufw delete allow 5999/udp || true
		ufw delete allow "${SPIRE_PORT}/tcp" || true
	elif command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
		firewall-cmd --permanent --remove-port=9000-9001/tcp || true
		firewall-cmd --permanent --remove-port=9000-9001/udp || true
		firewall-cmd --permanent --remove-port=7000-7500/tcp || true
		firewall-cmd --permanent --remove-port=7000-7500/udp || true
		firewall-cmd --permanent --remove-port=7778/tcp || true
		firewall-cmd --permanent --remove-port=5998/tcp || true
		firewall-cmd --permanent --remove-port=5998/udp || true
		firewall-cmd --permanent --remove-port=5999/tcp || true
		firewall-cmd --permanent --remove-port=5999/udp || true
		firewall-cmd --permanent --remove-port="${SPIRE_PORT}/tcp" || true
		firewall-cmd --reload || true
	fi
}

remove_systemd_units() {
	if [[ ! -d /run/systemd/system ]]; then
		return 0
	fi

	log "Removing systemd units"
	systemctl stop spire || true
	systemctl stop eqemu || true
	systemctl disable spire || true
	systemctl disable eqemu || true
	rm -f /etc/systemd/system/spire.service
	rm -f /etc/systemd/system/eqemu.service
	systemctl daemon-reload || true
}

remove_database() {
	if ! command_exists mariadb; then
		return 0
	fi

	if systemctl list-unit-files | grep -q '^mariadb'; then
		systemctl start mariadb || true
	fi

	log "Dropping MariaDB database and users"
	mariadb <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

remove_install_root() {
	log "Removing install root ${INSTALL_ROOT}"
	rm -rf "${INSTALL_ROOT}"
}

remove_target_user() {
	if [[ "${TARGET_USER}" != "eqemu" ]]; then
		return 0
	fi

	if id -u "${TARGET_USER}" >/dev/null 2>&1; then
		log "Removing service user ${TARGET_USER}"
		userdel -r "${TARGET_USER}" || true
	fi
}

remove_eqemu_perl() {
	if [[ -d /opt/eqemu-perl ]]; then
		log "Removing /opt/eqemu-perl"
		rm -rf /opt/eqemu-perl
	fi
}

remove_everything() {
	stop_existing_services
	remove_systemd_units
	remove_firewall_rules
	remove_database
	remove_eqemu_perl
	remove_install_root
	remove_target_user
	log "Removal complete"
	exit 0
}

install_service() {
	if (( ! INSTALL_SYSTEMD )); then
		return 0
	fi

	if [[ ! -d /run/systemd/system ]]; then
		log "systemd not detected, skipping service install"
		return 0
	fi

	cat > /etc/systemd/system/eqemu.service <<EOF
[Unit]
Description=EQEmu Server
After=network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service

[Service]
Type=forking
User=${TARGET_USER}
Group=${TARGET_GROUP}
WorkingDirectory=${SERVER_DIR}
ExecStart=${SERVER_DIR}/start_server.sh
ExecStop=${SERVER_DIR}/stop_server.sh
PIDFile=${SERVER_DIR}/run/world.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload

	if (( INSTALL_SPIRE )); then
		cat > /etc/systemd/system/spire.service <<EOF
[Unit]
Description=Spire EQEmu Admin
After=network-online.target mariadb.service eqemu.service
Wants=network-online.target
Requires=mariadb.service

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_GROUP}
WorkingDirectory=${SPIRE_DIR}
ExecStart=${SPIRE_DIR}/start_spire.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload
	fi

	if (( ENABLE_SERVICE )); then
		systemctl enable --now eqemu.service
		if (( INSTALL_SPIRE )); then
			systemctl enable --now spire.service || true
		fi
	fi
}

write_report() {
	cat > "${INSTALL_ROOT}/install_config.yml" <<EOF
release_tag: "${RELEASE_TAG}"
spire_tag: "${SPIRE_TAG}"
install_root: "${INSTALL_ROOT}"
server_dir: "${SERVER_DIR}"
spire_dir: "${SPIRE_DIR}"
target_user: "${TARGET_USER}"
target_group: "${TARGET_GROUP}"
server:
  longname: "${SERVER_NAME}"
  shortname: "${SERVER_SHORTNAME}"
  world_address: "${WORLD_ADDRESS}"
  local_address: "${LOCAL_ADDRESS}"
database:
  name: "${DB_NAME}"
  user: "${DB_USER}"
  password: "${DB_PASSWORD}"
spire:
  enabled: ${INSTALL_SPIRE}
  port: ${SPIRE_PORT}
  basic_auth_user: "${SPIRE_BASIC_AUTH_USER}"
  basic_auth_password: "${SPIRE_BASIC_AUTH_PASSWORD}"
downloads:
  binaries: "EQEmu release zip"
  database: "https://db.eqemu.dev/latest"
  quests: "https://github.com/ProjectEQ/projecteqquests"
  maps: "https://github.com/EQEmu/maps"
  spire: "https://github.com/EQEmu/spire"
ports:
  world: "9000-9001"
  zone: "7000-7500"
  ucs: "7778"
  login_titanium: "5998"
  login_sod: "5999"
  spire: "${SPIRE_PORT}"
commands:
  eqemu_start: "${SERVER_DIR}/start_server.sh"
  eqemu_stop: "${SERVER_DIR}/stop_server.sh"
  eqemu_restart: "${SERVER_DIR}/server_restart.sh"
EOF
	if (( INSTALL_SPIRE )); then
		cat >> "${INSTALL_ROOT}/install_config.yml" <<EOF
  spire_start: "${INSTALL_ROOT}/spire_start.sh"
  spire_stop: "${INSTALL_ROOT}/spire_stop.sh"
  spire_web: "${INSTALL_ROOT}/spire_web.sh"
  spire_web_admin: "${INSTALL_ROOT}/spire_web_admin.sh"
EOF
	fi
	chown "${TARGET_USER}:${TARGET_GROUP}" "${INSTALL_ROOT}/install_config.yml"
	chmod 600 "${INSTALL_ROOT}/install_config.yml"
	grant_access_user
}

print_summary() {
	printf '\n'
	printf '========================================\n'
	printf 'EQEmu Install Summary\n'
	printf '========================================\n'
	printf 'MariaDB\n'
	printf '  Host: 127.0.0.1\n'
	printf '  Port: 3306\n'
	printf '  Database: %s\n' "${DB_NAME}"
	printf '  Username: %s\n' "${DB_USER}"
	printf '  Password: %s\n' "${DB_PASSWORD}"
	if (( INSTALL_SPIRE )); then
		printf 'Spire\n'
		printf '  URL: http://127.0.0.1:%s\n' "${SPIRE_PORT}"
		printf '  Admin URL: http://127.0.0.1:%s/admin\n' "${SPIRE_PORT}"
		printf '  Username: %s\n' "${SPIRE_BASIC_AUTH_USER}"
		printf '  Password: %s\n' "${SPIRE_BASIC_AUTH_PASSWORD}"
	fi
	printf 'Config file: %s/install_config.yml\n' "${INSTALL_ROOT}"
	printf '========================================\n'
	printf '\n'
}

main() {
	parse_args "$@"
	ensure_root
	if (( REMOVE_ALL )); then
		detect_platform
		remove_everything
	fi
	stop_existing_services
	detect_platform
	install_packages
	install_eqemu_perl
	ensure_user
	prepare_dirs
	determine_release_tag
	determine_spire_tag
	download_release
	download_spire
	download_runtime_assets
	download_content
	configure_mariadb
	configure_firewall
	import_database
	write_configs
	link_content
	write_spire_files
	write_helpers
	run_post_install_steps
	install_service
	start_existing_services
	write_report
	print_summary
	log "Install complete at ${SERVER_DIR}"
}

main "$@"
