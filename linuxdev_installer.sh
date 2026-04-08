#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VCPKG_ROOT="${REPO_ROOT}/submodules/vcpkg"
VCPKG_TRIPLET="${VCPKG_TRIPLET:-x64-linux}"
CONFIGURE_AFTER_INSTALL=0
CMAKE_PRESET="${CMAKE_PRESET:-linux-debug}"
SKIP_PACKAGES=0
SKIP_SUBMODULES=0
SKIP_VCPKG=0
PKG_FAMILY=""

usage() {
	cat <<EOF
EQEmu Linux development installer

Installs the Linux packages needed to build EQEmu from source, initializes
submodules, bootstraps the bundled vcpkg checkout, and installs manifest
dependencies from vcpkg.json.

Usage:
  ./linuxdev_installer.sh [options]

Options:
  --configure            Run 'cmake --preset <preset>' after dependencies install
  --preset NAME         CMake preset to use with --configure. Default: ${CMAKE_PRESET}
  --triplet NAME        vcpkg triplet. Default: ${VCPKG_TRIPLET}
  --skip-packages       Skip OS package installation
  --skip-submodules     Skip git submodule update/init
  --skip-vcpkg          Skip vcpkg bootstrap and dependency install
  --help, -h            Show this help

Examples:
  ./linuxdev_installer.sh
  ./linuxdev_installer.sh --configure --preset linux-debug
  ./linuxdev_installer.sh --skip-packages --configure
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

run_root() {
	if [[ "${EUID}" -eq 0 ]]; then
		"$@"
	elif command_exists sudo; then
		sudo "$@"
	else
		die "This step requires root privileges, but sudo is not installed."
	fi
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--configure)
				CONFIGURE_AFTER_INSTALL=1
				shift
				;;
			--preset)
				CMAKE_PRESET="$2"
				shift 2
				;;
			--triplet)
				VCPKG_TRIPLET="$2"
				shift 2
				;;
			--skip-packages)
				SKIP_PACKAGES=1
				shift
				;;
			--skip-submodules)
				SKIP_SUBMODULES=1
				shift
				;;
			--skip-vcpkg)
				SKIP_VCPKG=1
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
	[[ -f /etc/os-release ]] || die "Cannot detect Linux distribution."
	# shellcheck disable=SC1091
	source /etc/os-release

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
	log "Installing Linux build dependencies with ${PKG_FAMILY}"

	case "${PKG_FAMILY}" in
		apt)
			run_root env DEBIAN_FRONTEND=noninteractive apt-get update
			run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
				autoconf \
				automake \
				build-essential \
				ca-certificates \
				ccache \
				cmake \
				curl \
				git \
				libmariadb-dev \
				libmariadb-dev-compat \
				libperl-dev \
				libssl-dev \
				libtool \
				ninja-build \
				pkg-config \
				perl \
				tar \
				unzip \
				uuid-dev \
				zip
			;;
		dnf)
			run_root dnf install -y \
				autoconf \
				automake \
				ca-certificates \
				ccache \
				cmake \
				curl \
				gcc \
				gcc-c++ \
				git \
				libtool \
				mariadb-connector-c-devel \
				make \
				ninja-build \
				openssl-devel \
				perl \
				perl-devel \
				pkgconfig \
				tar \
				unzip \
				libuuid-devel \
				zip
			;;
		yum)
			run_root yum install -y \
				autoconf \
				automake \
				ca-certificates \
				ccache \
				cmake \
				curl \
				gcc \
				gcc-c++ \
				git \
				libtool \
				mariadb-connector-c-devel \
				make \
				ninja-build \
				openssl-devel \
				perl \
				perl-devel \
				pkgconfig \
				tar \
				unzip \
				libuuid-devel \
				zip
			;;
		*)
			die "Package manager family not set."
			;;
	esac
}

init_submodules() {
	log "Initializing git submodules"
	git -C "${REPO_ROOT}" submodule update --init --recursive
}

bootstrap_vcpkg() {
	[[ -d "${VCPKG_ROOT}" ]] || die "Missing ${VCPKG_ROOT}. Did submodules initialize correctly?"

	if [[ ! -x "${VCPKG_ROOT}/vcpkg" ]]; then
		log "Bootstrapping bundled vcpkg"
		"${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics
	else
		log "Bundled vcpkg is already bootstrapped"
	fi
}

install_vcpkg_dependencies() {
	log "Installing vcpkg dependencies for triplet ${VCPKG_TRIPLET}"
	VCPKG_ROOT="${VCPKG_ROOT}" "${VCPKG_ROOT}/vcpkg" install \
		--x-manifest-root="${REPO_ROOT}" \
		--triplet "${VCPKG_TRIPLET}"
}

configure_project() {
	command_exists cmake || die "cmake is not installed."

	log "Configuring project with preset ${CMAKE_PRESET}"
	cmake --preset "${CMAKE_PRESET}"
}

print_next_steps() {
	cat <<EOF

Development dependencies are installed.

Next steps:
  cmake --preset ${CMAKE_PRESET}
  cmake --build build -j\$(nproc)

For the release preset in this repo, use:
  cmake --preset linux-release
  cmake --build build/release -j\$(nproc)

Notes:
  - The project uses the bundled vcpkg checkout at ${VCPKG_ROOT}
  - Override the triplet with VCPKG_TRIPLET=<triplet> or --triplet
  - Re-run with --configure to create/update the build directory automatically
EOF
}

main() {
	parse_args "$@"

	if [[ "${SKIP_PACKAGES}" -eq 0 ]]; then
		detect_platform
		install_packages
	else
		log "Skipping OS package installation"
	fi

	if [[ "${SKIP_SUBMODULES}" -eq 0 ]]; then
		init_submodules
	else
		log "Skipping git submodule initialization"
	fi

	if [[ "${SKIP_VCPKG}" -eq 0 ]]; then
		bootstrap_vcpkg
		install_vcpkg_dependencies
	else
		log "Skipping vcpkg bootstrap and dependency installation"
	fi

	if [[ "${CONFIGURE_AFTER_INSTALL}" -eq 1 ]]; then
		configure_project
	fi

	print_next_steps
}

main "$@"
