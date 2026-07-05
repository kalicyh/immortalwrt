#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/tenda-be12-pro.config}"
JOBS="${JOBS:-$(nproc)}"
INSTALL_DEPS=0

usage() {
	cat <<EOF
Usage: ./build-wsl.sh [--deps] [-j JOBS]

  --deps    install Debian/Ubuntu build dependencies first
  -j JOBS   build parallelism, default: nproc
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--deps)
			INSTALL_DEPS=1
			;;
		-j)
			shift
			JOBS="${1:?missing jobs value}"
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

if [ "$(id -u)" -eq 0 ]; then
	echo "Do not build as root. Use a normal WSL user." >&2
	exit 1
fi

if ! grep -qi microsoft /proc/version /proc/sys/kernel/osrelease 2>/dev/null; then
	echo "Warning: WSL was not detected; continuing anyway." >&2
fi

if [[ "$ROOT" == /mnt/* && "${ALLOW_MNT:-0}" != 1 ]]; then
	echo "Move this repo into WSL's Linux filesystem, for example ~/immortalwrt." >&2
	echo "Building under /mnt/c is slow and can break case-sensitive paths." >&2
	echo "Set ALLOW_MNT=1 to override." >&2
	exit 1
fi

clean_path=""
IFS=: read -r -a path_parts <<<"$PATH"
for path_part in "${path_parts[@]}"; do
	case "$path_part" in
		/mnt/[a-zA-Z]/*|*" "*) continue ;;
	esac
	clean_path="${clean_path:+$clean_path:}$path_part"
done
export PATH="$clean_path"

install_deps() {
	if ! command -v apt-get >/dev/null 2>&1; then
		echo "--deps only supports Debian/Ubuntu WSL with apt-get." >&2
		exit 1
	fi

	local deps available missing pkg
	deps=(
		ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential
		bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk
		gettext gcc-multilib g++-multilib git libgnutls28-dev gperf haveged help2man
		intltool lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev
		libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev
		libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano
		ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply
		python3-docutils python3-pyelftools qemu-utils re2c rsync scons squashfs-tools
		subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd
	)
	available=()
	missing=()

	sudo apt-get update
	for pkg in "${deps[@]}"; do
		if apt-cache show "$pkg" >/dev/null 2>&1; then
			available+=("$pkg")
		else
			missing+=("$pkg")
		fi
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Skipping unavailable apt packages: ${missing[*]}" >&2
	fi
	sudo apt-get install -y "${available[@]}"
}

check_requested_packages() {
	local missing package symbol
	missing=()

	while IFS='=' read -r symbol _; do
		[ -n "$symbol" ] || continue
		if ! grep -Fxq "$symbol=y" .config && ! grep -Fxq "$symbol=m" .config; then
			package="${symbol#CONFIG_PACKAGE_}"
			missing+=("$package")
		fi
	done < <(grep -E '^CONFIG_PACKAGE_[^=]+=(y|m)$' "$CONFIG_FILE" | sort -u)

	if [ "${#missing[@]}" -eq 0 ]; then
		return
	fi

	echo "Requested packages missing after make defconfig:" >&2
	printf '  - %s\n' "${missing[@]}" >&2
	echo "Usually this means a feed is missing, the package was renamed, or dependencies are unmet." >&2
	echo "Fix feeds.conf.default or the package names before building." >&2
	echo "Set ALLOW_MISSING_PACKAGES=1 to continue anyway." >&2

	if [ "${ALLOW_MISSING_PACKAGES:-0}" != 1 ]; then
		exit 1
	fi
}

cd "$ROOT"

if [ "$INSTALL_DEPS" -eq 1 ]; then
	install_deps
fi

if [ ! -f "$CONFIG_FILE" ]; then
	echo "Missing config: $CONFIG_FILE" >&2
	exit 1
fi

./scripts/feeds update -a
./scripts/feeds install -a

cp "$CONFIG_FILE" .config
make defconfig
check_requested_packages
make download -j"$JOBS"

if ! make -j"$JOBS" V=s; then
	echo "Parallel build failed; retrying with -j1 for the exact error." >&2
	make -j1 V=s
fi

echo "Firmware output: $ROOT/bin/targets/mediatek/filogic"
