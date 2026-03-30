#!/bin/bash
# build.sh — build and package GeminiTop with dynamically discovered apps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

USB_DIR="$SCRIPT_DIR/usb_deploy"
APP_ROOT="$SCRIPT_DIR/apps"
HTOP_ROOT="$SCRIPT_DIR/htop"
APP_INDEX_NAME="catalog.txt"
DROPBEAR_SRC="$SCRIPT_DIR/dropbear/dropbear-2025.88"
DROPBEAR_PATCH="$SCRIPT_DIR/dropbear/patch_auth.py"

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
DISCOVERED_APPS=()
SELECTED_APPS=()
BUILT_APPS=()
MISSING_TOOLS=()

ACTION="build"
INTERACTIVE=0
INSTALL_DEPS=0
CLI_SELECTED_APPS=""
QUIET=1

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

expand_build_tool_token() {
    local tool="$1"
    tool="${tool//\$\{GNU_PREFIX\}/$GNU_PREFIX}"
    printf '%s\n' "$tool"
}

run_quiet() {
    local display="$1"
    local name="$2"
    shift 2
    if [ "$QUIET" -eq 1 ]; then
        local log
        log="$(mktemp)"
        "$@" > "$log" 2>&1 &
        local pid=$!
        local spinner="|/-\\"
        local i=0
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s... %c ' "$display" "${spinner:$((i%4)):1}"
            i=$((i + 1))
            sleep 0.12
        done
        set +e
        wait "$pid"
        local rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            printf '\r  %-40s %s\n' "$display" "FAILED" >&2
            echo "" >&2
            echo "===== $name FAILED =====" >&2
            cat "$log" >&2
            rm -f "$log"
            return 1
        fi
        printf '\r  %s... ok    \n' "$display"
        rm -f "$log"
        return 0
    else
        "$@"
    fi
}

add_unique_missing() {
    local value="$1"
    if ! array_contains "$value" "$@"; then
        MISSING_TOOLS+=("$value")
    fi
}

discover_apps() {
    DISCOVERED_APPS=()
    local dir
    while IFS= read -r dir; do
        [ -f "$dir/app.cfg" ] || continue
        DISCOVERED_APPS+=("$(basename "$dir")")
    done <<EOF
$(find "$APP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
EOF
}

app_cfg_value() {
    local app_id="$1"
    local key="$2"
    local cfg="$APP_ROOT/$app_id/app.cfg"

    [ -f "$cfg" ] || return 0
    awk -F= -v wanted="$key" '
        /^[[:space:]]*#/ { next }
        NF < 2 { next }
        {
            key = $1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key != wanted)
                next
            value = substr($0, index($0, "=") + 1)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$cfg"
}

app_title() {
    local value
    value="$(app_cfg_value "$1" "title")"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$1"
    fi
}

app_dependencies() {
    local raw dep
    raw="$(app_cfg_value "$1" "depends")"
    raw="${raw//,/ }"
    for dep in $raw; do
        dep="$(trim "$dep")"
        [ -n "$dep" ] && printf '%s\n' "$dep"
    done
}

build_tools_from_file() {
    local tools_file="$1"
    local line

    [ -f "$tools_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -n "$line" ] || continue
        case "$line" in
            \#*)
                continue
                ;;
            *)
                line="$(expand_build_tool_token "$line")"
                printf '%s\n' "$line"
                ;;
        esac
    done < "$tools_file"
}

app_build_tools() {
    local app_id="$1"
    build_tools_from_file "$APP_ROOT/$app_id/build-tools.lst"
}

htop_build_tools() {
    build_tools_from_file "$HTOP_ROOT/build-tools.lst"
}

detect_host_os() {
    case "$(uname -s)" in
        Darwin) printf 'macos\n' ;;
        Linux) printf 'linux\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

detect_package_manager() {
    if command_exists brew; then
        printf 'brew\n'
    elif command_exists apt-get; then
        printf 'apt\n'
    else
        printf 'unknown\n'
    fi
}

detect_cross_prefix() {
    local candidate

    if [ -n "${CROSS_PREFIX:-}" ] && command_exists "${CROSS_PREFIX}-gcc"; then
        printf '%s\n' "$CROSS_PREFIX"
        return 0
    fi

    for candidate in arm-unknown-linux-gnueabihf arm-linux-gnueabihf; do
        if command_exists "${candidate}-gcc"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'arm-unknown-linux-gnueabihf\n'
}

HOST_OS="$(detect_host_os)"
PACKAGE_MANAGER="$(detect_package_manager)"
GNU_PREFIX="$(detect_cross_prefix)"
export CROSS_PREFIX="$GNU_PREFIX"
CC_GNU="${GNU_PREFIX}-gcc"

print_install_help() {
    echo "Install the ARM GNU cross-toolchain:"
    echo "  macOS: brew tap messense/macos-cross-toolchains && brew install arm-unknown-linux-gnueabihf"
    echo "  Linux: sudo apt-get install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf"
}

print_usage() {
    cat <<EOF
Usage: ./build.sh [options]

Options:
  clean                 Clean build artifacts and usb_deploy
  --clean               Same as clean
  --interactive         Open the interactive build menu
  --check-deps          Check host dependencies for the selected apps
  --install-deps        Attempt to install missing host dependencies
  --apps=a,b,c          Build and stage only the selected apps and their dependencies
  --verbose, -v         Show full build output (default is compact with spinner)
  --help                Show this help

With no arguments in a TTY, the script opens an interactive menu.
In non-interactive mode it builds all discovered apps.
EOF
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            clean|--clean)
                ACTION="clean"
                ;;
            --interactive)
                INTERACTIVE=1
                ;;
            --check-deps)
                ACTION="check-deps"
                ;;
            --install-deps)
                ACTION="install-deps"
                INSTALL_DEPS=1
                ;;
            --apps=*)
                CLI_SELECTED_APPS="${arg#--apps=}"
                ;;
            --verbose|-v)
                QUIET=0
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $arg" >&2
                print_usage
                exit 1
                ;;
        esac
    done
}

append_selected_app() {
    local app_id="$1"
    if ! array_contains "$app_id" "${SELECTED_APPS[@]-}"; then
        SELECTED_APPS+=("$app_id")
    fi
}

resolve_app_selector() {
    local selector="$1"

    case "$selector" in
        ''|*[!0-9]*)
            printf '%s\n' "$selector"
            return 0
            ;;
    esac

    if [ "$selector" -lt 1 ] || [ "$selector" -gt "${#DISCOVERED_APPS[@]}" ]; then
        echo "ERROR: app selection '$selector' is out of range" >&2
        exit 1
    fi

    printf '%s\n' "${DISCOVERED_APPS[$((selector - 1))]}"
}

resolve_app_with_dependencies() {
    local app_id="$1"
    local dep

    if ! array_contains "$app_id" "${DISCOVERED_APPS[@]-}"; then
        echo "ERROR: app '$app_id' was not found under apps/" >&2
        exit 1
    fi

    if array_contains "$app_id" "${SELECTED_APPS[@]-}"; then
        return 0
    fi

    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        resolve_app_with_dependencies "$dep"
    done <<EOF
$(app_dependencies "$app_id")
EOF

    append_selected_app "$app_id"
}

select_all_apps() {
    SELECTED_APPS=()
    local app_id
    for app_id in "${DISCOVERED_APPS[@]}"; do
        resolve_app_with_dependencies "$app_id"
    done
}

select_apps_from_csv() {
    local csv="$1"
    local normalized app_id

    SELECTED_APPS=()
    normalized="${csv//,/ }"
    for app_id in $normalized; do
        app_id="$(trim "$app_id")"
        [ -n "$app_id" ] || continue
        app_id="$(resolve_app_selector "$app_id")"
        resolve_app_with_dependencies "$app_id"
    done

    if [ "${#SELECTED_APPS[@]}" -eq 0 ]; then
        echo "ERROR: no apps selected" >&2
        exit 1
    fi
}

choose_apps_interactively() {
    local app_id choice index

    echo ""
    echo "Discovered apps:"
    index=1
    for app_id in "${DISCOVERED_APPS[@]}"; do
        printf "  %d. %-12s %s\n" "$index" "$app_id" "$(app_title "$app_id")"
        index=$((index + 1))
    done
    echo ""
    printf "App selection (all, ids, or menu numbers) [all]: "
    IFS= read -r choice
    choice="$(trim "$choice")"
    if [ -z "$choice" ] || [ "$choice" = "all" ]; then
        select_all_apps
    else
        select_apps_from_csv "$choice"
    fi
}

add_missing() {
    local tool="$1"
    shift
    local item
    if command_exists "$tool"; then
        return 0
    fi
    for item in "$@"; do
        if [ "$item" = "$tool" ]; then
            return 0
        fi
    done
    add_unique_missing "$tool" "${MISSING_TOOLS[@]-}"
}

collect_missing_tools() {
    local app_id tool

    MISSING_TOOLS=()
    add_missing git "${MISSING_TOOLS[@]-}"
    add_missing make "${MISSING_TOOLS[@]-}"
    add_missing python3 "${MISSING_TOOLS[@]-}"
    add_missing perl "${MISSING_TOOLS[@]-}"
    add_missing tar "${MISSING_TOOLS[@]-}"
    add_missing file "${MISSING_TOOLS[@]-}"
    add_missing "$CC_GNU" "${MISSING_TOOLS[@]-}"
    add_missing "${GNU_PREFIX}-g++" "${MISSING_TOOLS[@]-}"
    add_missing "${GNU_PREFIX}-ar" "${MISSING_TOOLS[@]-}"
    add_missing "${GNU_PREFIX}-strip" "${MISSING_TOOLS[@]-}"

    if ! command_exists curl && ! command_exists wget; then
        add_unique_missing "curl-or-wget" "${MISSING_TOOLS[@]-}"
    fi

    for app_id in "${SELECTED_APPS[@]}"; do
        while IFS= read -r tool; do
            [ -n "$tool" ] || continue
            add_missing "$tool" "${MISSING_TOOLS[@]-}"
        done <<EOF
$(app_build_tools "$app_id")
EOF
    done

    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        add_missing "$tool" "${MISSING_TOOLS[@]-}"
    done <<EOF
$(htop_build_tools)
EOF
}

print_missing_tools() {
    local tool

    if [ "${#MISSING_TOOLS[@]}" -eq 0 ]; then
        echo "All required build tools are available."
        return 0
    fi

    echo "Missing tools:"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo ""
    print_install_help
}

install_missing_tools() {
    local sudo_prefix=""
    local cross_formula="arm-unknown-linux-gnueabihf"

    if [ "${#MISSING_TOOLS[@]}" -eq 0 ]; then
        echo "No missing tools to install."
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        brew)
            if ! command_exists brew; then
                echo "ERROR: Homebrew not found." >&2
                return 1
            fi
            echo "Installing host dependencies with Homebrew..."
            brew tap messense/macos-cross-toolchains >/dev/null 2>&1 || true
            brew install git python perl gnu-tar file-formula ncurses "$cross_formula"
            ;;
        apt)
            if [ "$(id -u)" -ne 0 ]; then
                sudo_prefix="sudo "
            fi
            echo "Installing host dependencies with apt-get..."
            ${sudo_prefix}apt-get update
            ${sudo_prefix}apt-get install -y \
                git make python3 perl curl wget tar file ncurses-bin \
                gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf
            ;;
        *)
            echo "Automatic dependency installation is only wired up for Homebrew and apt-get right now."
            print_install_help
            return 1
            ;;
    esac
}

show_dependency_report() {
    echo ""
    echo "========================================="
    echo "  Gemini — Dependency Check"
    echo "========================================="
    echo "Host OS:          $HOST_OS"
    echo "Package manager:  $PACKAGE_MANAGER"
    echo "GNU cross prefix: $GNU_PREFIX"
    echo "Root tools:       htop"
    echo "Selected apps:    ${SELECTED_APPS[*]}"
    echo ""
    collect_missing_tools
    print_missing_tools
}

build_dropbear() {
    local dbcc dbstatic dbprefix dbar dbranlib dbstrip dbconfig

    [ "$QUIET" -eq 0 ] && echo "[1/4] Building dropbear..." || true
    run_quiet "[1/4] dropbear" "dropbear fetch" bash "$SCRIPT_DIR/dropbear/fetch_source.sh"

    dbcc="${GEMINI_DROPBEAR_CC:-$CC_GNU}"
    dbstatic=""
    if [[ "$dbcc" == *musl* ]]; then
        dbstatic="--enable-static"
    fi
    if ! command_exists "$dbcc"; then
        echo "ERROR: Dropbear compiler $dbcc not found in PATH" >&2
        exit 1
    fi

    dbprefix="${dbcc%-gcc}"
    dbar="${dbprefix}-ar"
    dbranlib="${dbprefix}-ranlib"
    dbstrip="${dbprefix}-strip"
    dbconfig="$DROPBEAR_SRC/config.h"

    command_exists "$dbar" || dbar="${GNU_PREFIX}-ar"
    command_exists "$dbranlib" || dbranlib="${GNU_PREFIX}-ranlib"
    command_exists "$dbstrip" || dbstrip="${GNU_PREFIX}-strip"

    if [ ! -f "$DROPBEAR_SRC/Makefile" ] || \
       ! grep -Fq "CC=$dbcc" "$DROPBEAR_SRC/Makefile" 2>/dev/null || \
       ! grep -Fq "AR=$dbar" "$DROPBEAR_SRC/Makefile" 2>/dev/null || \
       ! grep -Fq "RANLIB=$dbranlib" "$DROPBEAR_SRC/Makefile" 2>/dev/null || \
       ! grep -Fq "STRIP=$dbstrip" "$DROPBEAR_SRC/Makefile" 2>/dev/null || \
       ! grep -Eq '^#define HAVE_CRYPT 1$' "$dbconfig" 2>/dev/null || \
       ! grep -Eq '^#define HAVE_CRYPT_H 1$' "$dbconfig" 2>/dev/null; then
        [ "$QUIET" -eq 0 ] && echo "  Configuring..." || true
        run_quiet "[1/4] dropbear" "dropbear configure" bash -c "cd '$DROPBEAR_SRC' && ./configure \
            --host=arm-linux \
            CC='$dbcc' \
            AR='$dbar' \
            RANLIB='$dbranlib' \
            STRIP='$dbstrip' \
            --disable-zlib --disable-wtmp --disable-lastlog \
            --disable-utmp --disable-utmpx --disable-pututline \
            --disable-pututxline $dbstatic"
    fi

    if ! grep -q "PATCHED" "$DROPBEAR_SRC/src/svr-authpasswd.c" 2>/dev/null; then
        [ "$QUIET" -eq 0 ] && echo "  Applying auth bypass patch..." || true
        run_quiet "[1/4] dropbear" "dropbear patch" python3 "$DROPBEAR_PATCH" "$DROPBEAR_SRC/src/svr-authpasswd.c"
    fi

    "$dbranlib" "$DROPBEAR_SRC/libtomcrypt/libtomcrypt.a" 2>/dev/null || true
    "$dbranlib" "$DROPBEAR_SRC/libtommath/libtommath.a" 2>/dev/null || true
    run_quiet "[1/4] dropbear" "dropbear make" make -C "$DROPBEAR_SRC" PROGRAMS="dropbear dropbearkey" MULTI=1 -j"$JOBS"
}

build_core_components() {
    build_dropbear

    [ "$QUIET" -eq 0 ] && echo "[2/4] Building libgemini..." || true
    run_quiet "[2/4] libgemini" "libgemini" make -C libgemini -j"$JOBS"

    [ "$QUIET" -eq 0 ] && echo "[3/4] Building orchestrator..." || true
    run_quiet "[3/4] orchestrator" "orchestrator" make -C orchestrator -j"$JOBS"

    [ "$QUIET" -eq 0 ] && echo "[4/4] Building launcher..." || true
    run_quiet "[4/4] launcher" "launcher" make -C launcher -j"$JOBS"
}

build_app() {
    local app_id="$1"
    local script="$APP_ROOT/$app_id/build-app.sh"

    if array_contains "$app_id" "${BUILT_APPS[@]-}"; then
        return 0
    fi

    if [ -f "$script" ]; then
        [ "$QUIET" -eq 0 ] && echo "[app] Building $app_id..." || true
        if run_quiet "[app] $app_id" "$app_id" bash "$script"; then
            :
        else
            return 1
        fi
    else
        [ "$QUIET" -eq 0 ] && echo "  No build-app.sh for $app_id, nothing to build." || true
    fi
    BUILT_APPS+=("$app_id")
    [ "$QUIET" -eq 0 ] && echo "" || true
}

build_htop_payload() {
    local script="$HTOP_ROOT/build-app.sh"

    [ -f "$script" ] || return 0

    [ "$QUIET" -eq 0 ] && echo "[tool] Building htop..." || true
    run_quiet "[tool] htop" "htop" bash "$script"
    [ "$QUIET" -eq 0 ] && echo "" || true
}

clean_all() {
    local app_id script

    echo "Cleaning build artifacts..."
    make clean
    rm -rf "$USB_DIR"
    [ -d "$DROPBEAR_SRC" ] && make -C "$DROPBEAR_SRC" clean 2>/dev/null || true

    discover_apps
    for app_id in "${DISCOVERED_APPS[@]}"; do
        script="$APP_ROOT/$app_id/build-app.sh"
        if [ -f "$script" ]; then
            bash "$script" clean
        fi
    done

    script="$HTOP_ROOT/build-app.sh"
    if [ -f "$script" ]; then
        bash "$script" clean
    fi

    echo "Done."
}

stage_copy() {
    local source_abs="$1"
    local dest_abs="$2"

    if [ -d "$source_abs" ]; then
        mkdir -p "$dest_abs"
        cp -R "$source_abs"/. "$dest_abs"/
    else
        mkdir -p "$(dirname "$dest_abs")"
        cp "$source_abs" "$dest_abs"
    fi
}

stage_manifest_dir() {
    local source_dir="$1"
    local dest_dir="$2"
    local manifest="$3"
    local label="$4"
    local line command payload src dst source_abs dest_abs

    if [ ! -f "$manifest" ]; then
        echo "ERROR: $label is missing stage.lst" >&2
        exit 1
    fi

    mkdir -p "$dest_dir"

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        [ -n "$line" ] || continue
        case "$line" in
            \#*)
                continue
                ;;
            mkdir\ *)
                payload="$(trim "${line#mkdir }")"
                mkdir -p "$dest_dir/$payload"
                ;;
            copy\ *)
                payload="$(trim "${line#copy }")"
                if [[ "$payload" == *"->"* ]]; then
                    src="$(trim "${payload%%->*}")"
                    dst="$(trim "${payload#*->}")"
                else
                    src="$payload"
                    dst="$(basename "$src")"
                fi
                source_abs="$source_dir/$src"
                dest_abs="$dest_dir/$dst"
                if [ ! -e "$source_abs" ]; then
                    echo "ERROR: stage source not found for $label: $src" >&2
                    exit 1
                fi
                stage_copy "$source_abs" "$dest_abs"
                ;;
            *)
                echo "ERROR: unsupported stage directive in $manifest: $line" >&2
                exit 1
                ;;
        esac
    done < "$manifest"
}

stage_app() {
    local app_id="$1"
    stage_manifest_dir "$APP_ROOT/$app_id" "$USB_DIR/apps/$app_id" \
        "$APP_ROOT/$app_id/stage.lst" "$app_id"
}

stage_htop_payload() {
    stage_manifest_dir "$HTOP_ROOT" "$USB_DIR" "$HTOP_ROOT/stage.lst" "htop"
}

write_app_index() {
    local index_path="$USB_DIR/apps/$APP_INDEX_NAME"
    : > "$index_path"
    local app_id
    for app_id in "${SELECTED_APPS[@]}"; do
        printf '%s\n' "$app_id" >> "$index_path"
    done
}

assemble_payload() {
    local app_id size rel file_path

    [ "$QUIET" -eq 1 ] && echo ""
    echo "Assembling USB deploy folder..."
    rm -rf "$USB_DIR"
    mkdir -p "$USB_DIR/apps" "$USB_DIR/logs"

    cp scripts/gemn_auto.sh "$USB_DIR/gemn_auto.sh"
    cp orchestrator/geminiorchestrator "$USB_DIR/geminiorchestrator"
    cp launcher/geminilauncher "$USB_DIR/geminilauncher"
    cp launcher/gemini_wifi.sh "$USB_DIR/gemini_wifi.sh"
    cp "$DROPBEAR_SRC/dropbearmulti" "$USB_DIR/dropbear"
    stage_htop_payload

    for app_id in "${SELECTED_APPS[@]}"; do
        stage_app "$app_id"
    done
    write_app_index

    echo ""
    echo "========================================="
    echo "  USB Deploy Folder Ready"
    echo "========================================="
    echo ""
    echo "Contents:"
    while IFS= read -r file_path; do
        size="$(ls -lh "$file_path" | awk '{print $5}')"
        rel="${file_path#$USB_DIR/}"
        printf "  %-50s %s\n" "$rel" "$size"
    done <<EOF
$(find "$USB_DIR" -type f | sort)
EOF
    echo ""
    echo "Total size: $(du -sh "$USB_DIR" | awk '{print $1}')"
    echo ""
    echo "Copy usb_deploy/ contents to a FAT32 USB stick (8GB or smaller), then plug into the unit."
    echo ""
}

run_build() {
    if [ "$QUIET" -eq 1 ]; then
        echo "Building... (use --verbose for full output)"
        echo ""
    else
        echo "========================================="
        echo "  Gemini — Build & Package"
        echo "========================================="
        echo "Host OS:          $HOST_OS"
        echo "GNU cross prefix: $GNU_PREFIX"
        echo "Root tools:       htop"
        echo "Selected apps:    ${SELECTED_APPS[*]}"
        echo ""
    fi

    collect_missing_tools
    if [ "${#MISSING_TOOLS[@]}" -ne 0 ]; then
        print_missing_tools
        if [ "$INSTALL_DEPS" -eq 1 ]; then
            install_missing_tools
            collect_missing_tools
        fi
        if [ "${#MISSING_TOOLS[@]}" -ne 0 ]; then
            echo "ERROR: missing required build tools." >&2
            exit 1
        fi
    fi

    build_core_components
    build_htop_payload
    BUILT_APPS=()
    local app_id
    for app_id in "${SELECTED_APPS[@]}"; do
        build_app "$app_id"
    done
    assemble_payload
}

interactive_menu() {
    local choice

    discover_apps
    while true; do
        echo ""
        echo "========================================="
        echo "  Gemini — Interactive Build"
        echo "========================================="
        echo "1. Build all apps and package usb_deploy"
        echo "2. Build selected apps and package usb_deploy"
        echo "3. Check dependencies"
        echo "4. Install missing dependencies"
        echo "5. Clean"
        echo "6. Exit"
        echo ""
        printf "Choose an option [1-6]: "
        IFS= read -r choice
        case "$choice" in
            1|"")
                select_all_apps
                ACTION="build"
                break
                ;;
            2)
                choose_apps_interactively
                ACTION="build"
                break
                ;;
            3)
                choose_apps_interactively
                ACTION="check-deps"
                break
                ;;
            4)
                choose_apps_interactively
                ACTION="install-deps"
                INSTALL_DEPS=1
                break
                ;;
            5)
                ACTION="clean"
                break
                ;;
            6)
                exit 0
                ;;
            *)
                echo "Please choose 1-6."
                ;;
        esac
    done
}

parse_args "$@"
discover_apps

if [ -t 0 ] && [ -t 1 ] && [ "$#" -eq 0 ]; then
    INTERACTIVE=1
fi

if [ "$INTERACTIVE" -eq 1 ]; then
    interactive_menu
fi

case "$ACTION" in
    clean)
        clean_all
        exit 0
        ;;
esac

if [ -n "$CLI_SELECTED_APPS" ]; then
    select_apps_from_csv "$CLI_SELECTED_APPS"
elif [ "${#SELECTED_APPS[@]}" -eq 0 ]; then
    select_all_apps
fi

case "$ACTION" in
    check-deps)
        show_dependency_report
        ;;
    install-deps)
        show_dependency_report
        install_missing_tools
        show_dependency_report
        ;;
    build)
        run_build
        ;;
    *)
        echo "ERROR: unsupported action '$ACTION'" >&2
        exit 1
        ;;
esac
