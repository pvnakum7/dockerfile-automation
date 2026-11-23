#!/usr/bin/env bash
# docker-update.sh - clone the repositories listed in config/repositories.csv, update the Docker base image
# versions in their Dockerfiles and write ONE report per repository to reports/.
#
#   ./docker-update.sh                      (everything is controlled by environment variables - see ReadMe.md)
#
# Needs: bash 4.3+, git, curl, jq, awk, sed, base64.   Exit codes: 0 ok | 1 some repositories failed | 2 setup/config error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config/repositories.csv}"
REPOS_DIR="${REPOS_DIR:-$SCRIPT_DIR/repos}"
REPORTS_DIR="${REPORTS_DIR:-$SCRIPT_DIR/reports}"

STRATEGY="${STRATEGY:-both}"                 # same_major | new_major | both
DRY_RUN="${DRY_RUN:-true}"                   # true = report only, Dockerfiles are never modified
COMMIT_PUSH="${COMMIT_PUSH:-false}"          # true (with DRY_RUN=false) = commit to a new branch and push it
CREATE_PR="${CREATE_PR:-false}"              # true = also open a pull request (implies COMMIT_PUSH)
TEST_MODE="${TEST_MODE:-false}"              # true = never push / open PRs (the mailer sends nothing either)
REPOSITORIES="${REPOSITORIES:-}"             # optional comma separated Repo_Name filter
BRANCH_PRIORITY="${BRANCH_PRIORITY:-dev development develop main}"
MAX_DEPTH="${MAX_DEPTH:-4}"                  # Dockerfile search depth below the repository root
MAX_TAG_PAGES="${MAX_TAG_PAGES:-10}"         # registry pages (100 tags each) read per image
DOCKER_CHECK="${DOCKER_CHECK:-false}"        # true = also run `docker buildx build --check` on modified Dockerfiles
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-DevOps Automation}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-devops-automation@users.noreply.github.com}"

SEP=$'\037'
is_true() { case "${1,,}" in true|1|yes|y) return 0 ;; *) return 1 ;; esac; }
log() { printf '%s | %-5s | %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

for c in git curl jq awk sed base64 mktemp; do command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c" >&2; exit 2; }; done
[[ -f "$CONFIG_FILE" ]] || { echo "config file not found: $CONFIG_FILE" >&2; exit 2; }
case "$STRATEGY" in same_major|new_major|both) ;; *) echo "STRATEGY must be same_major|new_major|both" >&2; exit 2 ;; esac
mkdir -p "$REPOS_DIR" "$REPORTS_DIR"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RUN_DATE="$(date +%Y-%m-%d)"; FILE_DATE="$(date +%d-%b-%Y | tr 'A-Z' 'a-z')"

# ================================================================== config
# read_csv FILE -> Repo_Name US Repo_Link US POC US Email US CC_Email US Token_Name   (columns found by header name)
read_csv() {
    LC_ALL=C awk '
    function split_csv(line, out,   n, i, c, inq, cur) {
        n = 0; cur = ""; inq = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inq) { if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ } else inq = 0 } else cur = cur c }
            else if (c == "\"") inq = 1
            else if (c == ",") { out[++n] = cur; cur = "" }
            else cur = cur c
        }
        out[++n] = cur; return n
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { sub(/\r$/, ""); if (NR == 1) sub(/^\357\273\277/, "") }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    !hdr { n = split_csv($0, h); for (i = 1; i <= n; i++) idx[tolower(trim(h[i]))] = i; hdr = 1; next }
    { split_csv($0, f)
      printf "%s\037%s\037%s\037%s\037%s\037%s\n", trim(f[idx["repo_name"]]), trim(f[idx["repo_link"]]), trim(f[idx["poc"]]), trim(f[idx["email"]]), trim(f[idx["cc_email"]]), trim(f[idx["token_name"]]) }' "$1"
}

selected() {   # selected NAME -> true when no filter or NAME is in REPOSITORIES
    [[ -z "${REPOSITORIES// /}" ]] && return 0
    local n="${1,,}" x; local IFS=,
    for x in $REPOSITORIES; do x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; [[ "${x,,}" == "$n" ]] && return 0; done
    return 1
}

# ================================================================== git
# git_run TOKEN LINK args... : git with the token sent as an HTTP header for that host only (never in argv or the URL)
git_run() {
    local tok="$1" link="$2"; shift 2
    if [[ -n "$tok" && "$link" =~ ^(https?)://([^/@]+@)?([^/]+)/ ]]; then
        ( export GIT_CONFIG_COUNT=1 GIT_TERMINAL_PROMPT=0
          export "GIT_CONFIG_KEY_0=http.${BASH_REMATCH[1]}://${BASH_REMATCH[3]}/.extraheader"
          export "GIT_CONFIG_VALUE_0=Authorization: Basic $(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')"
          git "$@" </dev/null )
    else
        GIT_TERMINAL_PROMPT=0 git "$@" </dev/null
    fi
}

git_error() {  # git_error STDERR_FILE -> short human reason
    local e; e="$(tr '\n' ' ' <"$1" | sed -E 's#(https?://)[^/@ ]+@#\1#g' | cut -c1-200)"
    case "${e,,}" in
        *"authentication failed"*|*"could not read username"*|*"invalid username or password"*|*"403"*) echo "authentication failed - check the token / its repository access" ;;
        *"not found"*|*"does not exist"*|*"not a git repository"*|*"404"*) echo "repository not found (or the token cannot see it)" ;;
        *"could not resolve"*|*"timed out"*|*"unable to access"*) echo "network error: $e" ;;
        *) echo "git error: $e" ;;
    esac
}

# choose_branch TOKEN LINK -> prints branch (first of BRANCH_PRIORITY that exists, else the default branch); notes go to $NOTES
choose_branch() {
    local tok="$1" link="$2" heads b def
    heads="$(git_run "$tok" "$link" ls-remote --heads "$link" 2>"$WORK/git.err")" || { git_error "$WORK/git.err" >"$WORK/git.msg"; return 1; }
    for b in ${BRANCH_PRIORITY//,/ }; do
        if grep -q "[[:space:]]refs/heads/$b\$" <<<"$heads"; then printf '%s' "$b"; return 0; fi
    done
    def="$(git_run "$tok" "$link" ls-remote --symref "$link" HEAD 2>/dev/null | sed -nE 's#^ref: refs/heads/([^[:space:]]+)[[:space:]]+HEAD.*#\1#p' | head -1)"
    [[ -n "$def" ]] || def="$(sed -nE 's#^[0-9a-f]+[[:space:]]+refs/heads/(.+)$#\1#p' <<<"$heads" | head -1)"
    [[ -n "$def" ]] || { echo "no branches found" >"$WORK/git.msg"; return 1; }
    echo "None of the branches ${BRANCH_PRIORITY// /, } exist; used the default branch '$def'" >>"$NOTES"
    printf '%s' "$def"
}

# ================================================================== registry (Docker Hub + any OCI registry)
CODE=""; ERR=""; ERRKIND=""
http_get() {   # http_get URL [curl args] -> $CODE, headers in $WORK/h, body in $WORK/b
    CODE="$(curl -sS -L --max-time 30 --retry 3 --retry-delay 2 -D "$WORK/h" -o "$WORK/b" -w '%{http_code}' "$@" 2>"$WORK/curl.err" </dev/null)" \
        || { ERRKIND=network; ERR="network error: $(head -c 120 "$WORK/curl.err")"; return 1; }
}
registry_label() {
    case "${1,,}" in
        docker.io) echo "Docker Hub" ;; ghcr.io) echo "GHCR" ;; quay.io) echo "Quay.io" ;; public.ecr.aws) echo "ECR Public" ;;
        mcr.microsoft.com) echo "Microsoft MCR" ;; gcr.io|*.gcr.io|*.pkg.dev) echo "Google Artifact Registry" ;;
        *.azurecr.io) echo "Azure ACR" ;; registry.k8s.io|k8s.gcr.io) echo "Kubernetes Registry" ;; *) echo "OCI Registry ($1)" ;;
    esac
}
tags_hub() {   # tags_hub REPO FILTER OUT
    local ns="${1%%/*}" nm="${1#*/}" url pages=0
    url="https://hub.docker.com/v2/repositories/$ns/$nm/tags?page_size=100&ordering=last_updated"; [[ -n "$2" ]] && url+="&name=$2"
    : >"$3"
    while [[ -n "$url" && $pages -lt $MAX_TAG_PAGES ]]; do
        http_get "$url" || return 1
        case "$CODE" in 200) ;; 404) ERRKIND=notfound; ERR="repository not found on Docker Hub"; return 1 ;;
            401|403) ERRKIND=auth; ERR="Docker Hub denied access (private image?)"; return 1 ;; *) ERRKIND=failed; ERR="Docker Hub API returned HTTP $CODE"; return 1 ;; esac
        jq -r '.results[]?.name // empty' "$WORK/b" >>"$3" 2>/dev/null || { ERRKIND=failed; ERR="invalid response from Docker Hub"; return 1; }
        url="$(jq -r '.next // empty' "$WORK/b" 2>/dev/null)"; pages=$((pages + 1))
    done
}
tags_oci() {   # tags_oci HOST REPO OUT   (anonymous Bearer token flow for GHCR, Quay, MCR, GAR ...)
    local host="$1" repo="$2" url token="" chal realm service scope pages=0 link next
    url="https://$host/v2/$repo/tags/list?n=1000"; : >"$3"
    while [[ -n "$url" && $pages -lt $MAX_TAG_PAGES ]]; do
        http_get "$url" ${token:+-H "Authorization: Bearer $token"} || return 1
        if [[ "$CODE" == 401 && -z "$token" ]]; then
            chal="$(grep -i '^www-authenticate:' "$WORK/h" | tail -1 | tr -d '\r')"
            if [[ "${chal,,}" != *bearer* ]]; then ERRKIND=auth; ERR="registry requires credentials"; return 1; fi
            realm="$(sed -nE 's/.*realm="([^"]*)".*/\1/p' <<<"$chal")"; service="$(sed -nE 's/.*service="([^"]*)".*/\1/p' <<<"$chal")"
            scope="$(sed -nE 's/.*scope="([^"]*)".*/\1/p' <<<"$chal")"; scope="${scope:-repository:$repo:pull}"
            http_get "$realm?service=$service&scope=$scope" || return 1
            token="$(jq -r '.token // .access_token // empty' "$WORK/b" 2>/dev/null)"
            [[ "$CODE" == 200 && -n "$token" ]] || { ERRKIND=auth; ERR="anonymous token refused - image is private or needs credentials"; return 1; }
            continue
        fi
        case "$CODE" in 200) ;; 401|403) ERRKIND=auth; ERR="registry requires credentials"; return 1 ;; 404) ERRKIND=notfound; ERR="repository not found (or private)"; return 1 ;;
            *) ERRKIND=failed; ERR="registry returned HTTP $CODE"; return 1 ;; esac
        jq -r '(.tags // [])[]' "$WORK/b" >>"$3" 2>/dev/null || { ERRKIND=failed; ERR="invalid response from registry"; return 1; }
        link="$(grep -i '^link:' "$WORK/h" | tail -1 | tr -d '\r')"; next="$(sed -nE 's/.*<([^>]+)>[[:space:]]*;[[:space:]]*rel="?next"?.*/\1/p' <<<"$link")"
        if [[ -z "$next" ]]; then url=""; elif [[ "$next" == http* ]]; then url="$next"; else url="https://$host$next"; fi
        pages=$((pages + 1))
    done
}
TAGFILE=""
get_tags() {   # get_tags REGISTRY REPO FILTER -> $TAGFILE (cached for the run)
    local key; key="$WORK/tags.$(printf '%s|%s|%s' "$1" "$2" "$3" | cksum | tr ' ' '_')"
    TAGFILE="$key"; [[ -s "$key" ]] && return 0
    if [[ "$1" == docker.io ]]; then tags_hub "$2" "$3" "$key"; else tags_oci "$1" "$2" "$key"; fi || { rm -f "$key"; return 1; }
    [[ -s "$key" ]] || { ERRKIND=notfound; ERR="registry returned no tags"; return 1; }
}

# ================================================================== version selection
# select_version MODE CURRENT_TAG DEPTH PARITY < tags -> highest suitable tag (same: same release line, new: later release line)
# A candidate must have the SAME variant suffix (-slim, -alpine3.20 ...), be a stable release (no rc/beta/...) and be newer.
select_version() {
    LC_ALL=C awk -v mode="$1" -v cur="$2" -v depth="$3" -v parity="$4" '
    function parse(t,   rest, ns, suf, n, i, tk, nt) {
        P_ok = 0; P_pre = ""; rest = t
        if (rest ~ /^[vV]/) { P_pre = substr(rest, 1, 1); rest = substr(rest, 2) }
        if (!match(rest, /^[0-9]+(\.[0-9]+)*/)) return
        ns = substr(rest, 1, RLENGTH); suf = substr(rest, RLENGTH + 1)
        n = split(ns, P_n, "."); if (n > 4 || P_n[1] + 0 > 999) return
        if (suf != "" && suf !~ /^[-_+]/) return
        P_build = -1; P_var = suf
        if (match(suf, /^[_+][0-9]+/)) { P_build = substr(suf, 2, RLENGTH - 1) + 0; P_var = substr(suf, RLENGTH + 1) }
        nt = split(suf, tk, /[-_.+]/)
        for (i = 1; i <= nt; i++) if (tolower(tk[i]) ~ /^(alpha|beta|rc|nightly|dev|devel|preview|snapshot|canary|edge|test|testing|unstable|pre|ea|main|master|latest|milestone|insiders?)[0-9]*$/) return
        P_cnt = n
        P_key = sprintf("%06d.%06d.%06d.%06d.%06d", P_n[1], P_n[2], P_n[3], P_n[4], (P_build < 0 ? 0 : P_build))
        P_line = "L"; for (i = 1; i <= depth; i++) P_line = P_line sprintf("%06d.", (i <= n ? P_n[i] : 0))
        P_ok = 1
    }
    BEGIN { depth += 0; if (depth < 1) depth = 1; parse(cur); if (!P_ok) { bad = 1 }
            C_pre = P_pre; C_var = P_var; C_has = (P_build >= 0); C_key = P_key; C_line = P_line; C_cnt = P_cnt; minc = (C_cnt < 3 ? C_cnt : 3) }
    bad { next }
    { parse($0); if (!P_ok || P_pre != C_pre || P_var != C_var || (P_build >= 0) != C_has || P_cnt < minc) next
      if (mode == "same") { if (P_line != C_line || P_key <= C_key) next }
      else { if (P_line <= C_line) next; if (parity == "even" && P_n[1] % 2 != 0) next }
      if (best == "" || P_key > bkey || (P_key == bkey && P_cnt > bcnt)) { best = $0; bkey = P_key; bcnt = P_cnt } }
    END { if (best != "") print best }' "$TAGFILE"
}
line_depth() { case "${1##*/}" in python|golang|php|ruby|mysql|mariadb) echo 2 ;; *) echo 1 ;; esac; }

# ================================================================== Dockerfile helpers
# extract_froms FILE -> LINE US IMAGE US SKIP_REASON   (stages, scratch and earlier stage aliases are ignored)
extract_froms() {
    LC_ALL=C awk '
    { l = $0; sub(/\r$/, "", l) }
    match(l, /^[ \t]*[Ff][Rr][Oo][Mm][ \t]+/) {
        rest = substr(l, RLENGTH + 1)
        while (match(rest, /^--[^ \t]+[ \t]+/)) rest = substr(rest, RLENGTH + 1)
        n = split(rest, w, /[ \t]+/); ref = w[1]; lc = tolower(ref)
        alias = (n >= 3 && toupper(w[2]) == "AS") ? tolower(w[3]) : ""
        if (!(lc in stage) && lc != "scratch" && ref != "") {
            why = ""; last = ref; sub(/.*\//, "", last)
            if (ref ~ /\$/) why = "image reference uses ARG/variables - update manually"
            else if (ref ~ /@/) why = "image is pinned by digest"
            else if (last !~ /:/) why = "no tag (implicit latest) - nothing to upgrade"
            printf "%d\037%s\037%s\n", NR, ref, why
        }
        if (alias != "") stage[alias] = 1
    }' "$1"
}
# parse_ref IMAGE -> REG REPO IMG TAG
parse_ref() {
    local ref="$1" name="$1" last first
    last="${ref##*/}"; TAG=""
    if [[ "$last" == *:* ]]; then TAG="${last#*:}"; name="${ref%:*}"; fi
    first="${name%%/*}"
    if [[ "$name" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then REG="${first,,}"; REPO="${name#*/}"
    else REG=docker.io; REPO="$name"; [[ "$REPO" == */* ]] || REPO="library/$REPO"; fi
    case "$REG" in index.docker.io|registry-1.docker.io) REG=docker.io ;; esac
    IMG="${REPO#library/}"
}
replace_on_line() {   # replace_on_line FILE LINE OLD NEW  (literal replacement, line endings untouched)
    LC_ALL=C awk -v ln="$2" -v old="$3" -v new="$4" 'NR == ln { i = index($0, old); if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) } { print }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# ================================================================== technology detection
detect_technologies() {   # -> $TECHS lines: Technology US directory ("." = repository root)
    local p rel dir base
    : >"$TECHS"
    while IFS= read -r p; do
        rel="${p#"$REPO_DIR"/}"; dir="$(dirname "$rel")"; base="$(basename "$rel")"
        case "$base" in
            package.json) echo "Node.js${SEP}$dir"
                grep -q '"react"' "$p" 2>/dev/null && echo "React${SEP}$dir"
                grep -q '"@angular/core"' "$p" 2>/dev/null && echo "Angular${SEP}$dir"
                grep -q '"vue"' "$p" 2>/dev/null && echo "Vue.js${SEP}$dir" ;;
            requirements.txt|pyproject.toml|Pipfile|setup.py) echo "Python${SEP}$dir" ;;
            pom.xml) echo "Java Maven${SEP}$dir" ;;
            build.gradle|build.gradle.kts) echo "Java Gradle${SEP}$dir" ;;
            go.mod) echo "Go${SEP}$dir" ;;
            *.csproj|*.sln) echo ".NET${SEP}$dir" ;;
            Gemfile) echo "Ruby${SEP}$dir" ;;
            composer.json) echo "PHP${SEP}$dir" ;;
        esac
    done < <(find "$REPO_DIR" -maxdepth $((MAX_DEPTH + 1)) \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \) -prune -o -type f \
              \( -name package.json -o -name requirements.txt -o -name pyproject.toml -o -name Pipfile -o -name setup.py -o -name pom.xml -o -name 'build.gradle*' \
                 -o -name go.mod -o -name '*.csproj' -o -name '*.sln' -o -name Gemfile -o -name composer.json \) -print | LC_ALL=C sort) | awk '!s[$0]++' >"$TECHS.tmp"
    mv "$TECHS.tmp" "$TECHS"
}
image_tech() {   # image name -> regex of technologies that run on it
    case "${1##*/}" in
        node) echo "Node.js|React|Angular|Vue.js" ;; python) echo "Python" ;; golang) echo "Go" ;; php) echo "PHP" ;; ruby) echo "Ruby" ;;
        maven|gradle|openjdk|eclipse-temurin|amazoncorretto|temurin) echo "Java Maven|Java Gradle" ;;
        sdk|aspnet|runtime|dotnet) echo ".NET" ;; *) echo "" ;;
    esac
}
tech_present() {   # tech_present REGEX DOCKERFILE_DIR -> true when such a technology lives in/above/below that directory
    local pat="$1" fdir="$2" t d
    [[ -n "$pat" ]] || return 1
    while IFS=$SEP read -r t d; do
        [[ "$t" =~ ^($pat)$ ]] || continue
        [[ "$d" == "." || "$fdir" == "." || "$d" == "$fdir" || "$d" == "$fdir"/* || "$fdir" == "$d"/* ]] && return 0
    done <"$TECHS"
    return 1
}

# ================================================================== per-Dockerfile processing
row() { printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$@" >>"$ROWS"; }

validate_dockerfile() {   # validate_dockerfile FILE ORIGINAL PLANS -> 0 ok / 1 failed (reason in VREASON)
    local f="$1" orig="$2" plans="$3" a b ln old new
    a="$(grep -ciE '^[[:space:]]*FROM[[:space:]]' "$orig")"; b="$(grep -ciE '^[[:space:]]*FROM[[:space:]]' "$f")"
    [[ "$a" == "$b" ]] || { VREASON="FROM instruction count changed ($a -> $b)"; return 1; }
    while IFS=$SEP read -r ln old new; do
        sed -n "${ln}p" "$f" | grep -qF -- "$new" || { VREASON="line $ln does not contain $new"; return 1; }
    done <"$plans"
    if is_true "$DOCKER_CHECK" && command -v docker >/dev/null 2>&1; then
        docker buildx build --check -f "$f" "$(dirname "$f")" >"$WORK/docker.out" 2>&1 || { VREASON="docker buildx build --check failed: $(tail -n 2 "$WORK/docker.out" | tr '\n' ' ' | cut -c1-150)"; return 1; }
    fi
    VREASON="static syntax check"; is_true "$DOCKER_CHECK" && VREASON="static syntax check + docker buildx check"
    return 0
}

process_dockerfile() {   # process_dockerfile RELATIVE_PATH
    local rel="$1" f="$REPO_DIR/$1" fdir plans="$WORK/plans" nP=0 nSK=0 nF=0 nUTD=0 nM=0 ln ref why label pat sel_same sel_new sfx newref depth parity status remark vres vdet
    fdir="$(dirname "$rel")"; : >"$plans"; ROWS="$WORK/df_rows"; : >"$ROWS"
    T_DF=$((T_DF + 1))
    while IFS=$SEP read -r ln ref why <&4; do
        T_FROM=$((T_FROM + 1))
        if [[ -n "$why" ]]; then row "$rel" "-" "-" "$ref" "-" "-" SKIPPED "$why"; nSK=$((nSK + 1)); continue; fi
        parse_ref "$ref"; label="$(registry_label "$REG")"
        if ! [[ "$TAG" =~ ^[vV]?[0-9]+(\.[0-9]+)*([-_+].*)?$ ]]; then
            row "$rel" "$label" "$IMG" "$ref" "-" "-" SKIPPED "tag '$TAG' is not a version number"; nSK=$((nSK + 1)); continue; fi
        sfx="$(printf '%s' "$TAG" | sed -E 's/^[vV]?[0-9]+(\.[0-9]+)*//; s/^[_+][0-9]+//')"
        if ! get_tags "$REG" "$REPO" "$sfx"; then
            if [[ "$ERRKIND" == auth || "$ERRKIND" == notfound ]]; then row "$rel" "$label" "$IMG" "$ref" "-" "-" SKIPPED "$ERR"; nSK=$((nSK + 1))
            else row "$rel" "$label" "$IMG" "$ref" "-" "-" FAILED "$ERR"; nF=$((nF + 1)); fi
            continue
        fi
        depth="$(line_depth "$REPO")"; parity=""; [[ "${REPO##*/}" == node ]] && parity=even
        sel_same=""; sel_new=""
        [[ "$STRATEGY" != new_major ]] && sel_same="$(select_version same "$TAG" "$depth" "")"
        [[ "$STRATEGY" != same_major ]] && sel_new="$(select_version new "$TAG" "$depth" "$parity")"
        if [[ "$STRATEGY" != new_major ]]; then
            if [[ -n "$sel_same" ]]; then
                newref="${ref%:*}:$sel_same"
                row "$rel" "$label" "$IMG" "$ref" "$newref" "Same Major" "@SAME@" "@REMARK@"
                printf '%s\037%s\037%s\n' "$ln" "$ref" "$newref" >>"$plans"; nP=$((nP + 1))
            else row "$rel" "$label" "$IMG" "$ref" "-" "Same Major" UP_TO_DATE "Already on the newest version in this major line"; fi
        fi
        if [[ "$STRATEGY" != same_major ]]; then
            if [[ -n "$sel_new" ]]; then
                pat="$(image_tech "$REPO")"
                if tech_present "$pat" "$fdir"; then remark="Breaking changes possible. technology detected but no declared runtime version to verify against"
                elif [[ -n "$pat" ]]; then remark="Breaking changes possible. ${IMG##*/} image but no matching technology detected for this Dockerfile"
                else remark="Breaking changes possible. new major version - validate before upgrading"; fi
                row "$rel" "$label" "$IMG" "$ref" "${ref%:*}:$sel_new" "New Major" REQUIRES_VALIDATION "$remark"; nM=$((nM + 1))
            else row "$rel" "$label" "$IMG" "$ref" "-" "New Major" UP_TO_DATE "Already on the newest stable major version"; fi
        fi
        [[ -z "$sel_same" ]] && nUTD=$((nUTD + 1))
    done 4< <(extract_froms "$f")

    status="UPDATE_AVAILABLE"; remark="Stable update"; vres="NOT_RUN"; vdet="-"
    if ((nP > 0)) && ! is_true "$DRY_RUN"; then
        cp "$f" "$WORK/original"
        while IFS=$SEP read -r ln old new; do replace_on_line "$f" "$ln" "$old" "$new"; done <"$plans"
        if validate_dockerfile "$f" "$WORK/original" "$plans"; then
            status="UPDATED"; vres="PASSED"; vdet="$VREASON"; N_UPD=$((N_UPD + nP)); CHANGED=1
        else
            cp "$WORK/original" "$f"; status="FAILED"; remark="Validation failed - change reverted: $VREASON"; vres="FAILED"; vdet="reverted: $VREASON"
            N_FAIL=$((N_FAIL + nP))
        fi
    else N_PEND=$((N_PEND + nP)); fi
    STATUS="$status" REMARK="$remark" LC_ALL=C awk -F'\037' -v OFS='\037' '$7 == "@SAME@" { $7 = ENVIRON["STATUS"]; $8 = ENVIRON["REMARK"] } { print }' "$ROWS" >>"$ROWS_ALL"
    printf '%s\037%s\037%s\n' "$rel" "$vres" "$vdet" >>"$VAL_ALL"
    N_SKIP=$((N_SKIP + nSK)); N_FAIL=$((N_FAIL + nF)); N_UTD=$((N_UTD + nUTD)); N_MAJ=$((N_MAJ + nM))
}

# ================================================================== commit / push / pull request
publish_changes() {   # publish_changes TOKEN LINK BASE_BRANCH
    local tok="$1" link="$2" base="$3" br="docker-image-update/$(date +%Y%m%d-%H%M%S)" owner repo api payload code
    if is_true "$TEST_MODE"; then echo "TEST_MODE: commit/push/pull request skipped (changes stay in repos/$SAFE)" >>"$NOTES"; return 0; fi
    git -C "$REPO_DIR" checkout -q -b "$br" </dev/null && git -C "$REPO_DIR" add -A </dev/null \
      && git -C "$REPO_DIR" -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" commit -q -m "chore(docker): update base image versions" -m "Automated by docker-update.sh" </dev/null \
      && git_run "$tok" "$link" -C "$REPO_DIR" push -q origin "$br" 2>"$WORK/git.err" \
      || { echo "commit/push failed: $(git_error "$WORK/git.err")" >>"$NOTES"; return 1; }
    echo "Changes pushed to branch '$br'" >>"$NOTES"
    is_true "$CREATE_PR" || return 0
    if [[ -z "$tok" || ! "$link" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/?$ ]]; then echo "pull request skipped: needs a token and an https GitHub URL" >>"$NOTES"; return 0; fi
    owner="${BASH_REMATCH[2]}"; repo="${BASH_REMATCH[3]%.git}"; api="https://api.github.com"; [[ "${BASH_REMATCH[1]}" == github.com ]] || api="https://${BASH_REMATCH[1]}/api/v3"
    payload="$(jq -n --arg t "chore(docker): update base image versions" --arg h "$br" --arg b "$base" --arg body "Automated Docker base image update." '{title:$t,head:$h,base:$b,body:$body}')"
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -sS --config - -o "$WORK/pr.json" -w '%{http_code}' --max-time 30 -X POST \
            -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' --data-binary "$payload" "$api/repos/$owner/$repo/pulls" 2>/dev/null)"
    if [[ "$code" == 201 ]]; then PRURL="$(jq -r '.html_url // empty' "$WORK/pr.json")"; else echo "pull request failed (HTTP $code)" >>"$NOTES"; fi
    return 0
}

# ================================================================== report
fmt_table() {   # stdin: US separated rows, first row = headers -> aligned table
    LC_ALL=C awk -F'\037' '
        { rows[NR] = $0; if (NF > nf) nf = NF; for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i) }
        function pad(s, n) { while (length(s) < n) s = s " "; return s }
        function line(r,   i, o, c, k) { k = split(r, c, "\037"); o = ""; for (i = 1; i <= nf; i++) o = o (i > 1 ? "  " : "") pad(i <= k ? c[i] : "", w[i]); sub(/ +$/, "", o); return o }
        END { print line(rows[1]); s = ""; for (i = 1; i <= nf; i++) { d = ""; for (k = 0; k < w[i]; k++) d = d "-"; s = s (i > 1 ? "  " : "") d } print s
              for (r = 2; r <= NR; r++) print line(rows[r]) }'
}
write_report() {   # write_report NAME LINK TOKNAME -> reports/<name>-report-<dd-mon-yyyy>.txt
    local name="$1" link="$2" tokname="$3" out="$REPORTS_DIR/$SAFE-report-$FILE_DATE.txt" shown overall
    shown="$(printf '%s' "$link" | sed -E 's#(https?://)[^/@]+@#\1#')"
    overall=SUCCESS; ((N_FAIL > 0)) && overall=PARTIAL_SUCCESS; [[ -n "$RERR" ]] && overall=FAILED
    {
        printf 'Repository: %s\nDate: %s\nRepository URL: %s\n' "$name" "$RUN_DATE" "$shown"
        [[ -n "$BRANCH" ]] && printf 'Branch Analysed: %s\n' "$BRANCH"
        printf 'GitHub Token Used: %s\n' "${tokname:-(none)}"
        [[ -n "$PRURL" ]] && printf 'Pull Request: %s\n' "$PRURL"
        printf '\n'
        [[ -n "$RERR" ]] && printf 'REPOSITORY PROCESSING FAILED: %s\n\n' "$RERR"
        printf 'Technology Detection Summary\n'
        if [[ -s "$TECHS" ]]; then
            LC_ALL=C awk -F'\037' '{ d = ($2 == "." ? "root" : $2); if (!($1 in l)) { order[++n] = $1; l[$1] = d } else l[$1] = l[$1] ", " d } END { for (i = 1; i <= n; i++) printf "  - %s: %s\n", order[i], l[order[i]] }' "$TECHS"
        else echo "  - None detected"; fi
        printf '\n"Dockerfile Image Update Details"\n'
        if [[ -s "$ROWS_ALL" ]]; then
            { printf 'Dockerfile Location\037Registry\037Image Name\037Old Image Version\037New Image Version\037Upgrade Type\037Status\037Remarks\n'; cat "$ROWS_ALL"; } | fmt_table
        else echo "(no Dockerfile with a FROM instruction found)"; fi
        printf '\nValidation Details\n'
        if [[ -s "$VAL_ALL" ]]; then
            { printf 'Dockerfile Location\037Validation\037Details\n'
              LC_ALL=C awk -F'\037' -v OFS='\037' '{ print $1, ($2 == "NOT_RUN" ? "NOT_RUN (nothing modified)" : $2), $3 }' "$VAL_ALL"; } | fmt_table
        else echo "(none)"; fi
        if [[ -s "$NOTES" ]]; then printf '\nNotes\n'; sed 's/^/  - /' "$NOTES"; fi
        printf '\nRepo Dockerfile Image Update Summary:\n\nDate: %s\nRepository Name: %s\nRepository Link: %s\n\n' "$RUN_DATE" "$name" "$shown"
        printf 'Total Dockerfiles: %s\nTotal FROM instructions: %s\nUpdated Images: %s\nSkipped Images: %s\nFailed Images: %s\nUp-to-date Images: %s\n' \
            "$T_DF" "$T_FROM" "$N_UPD" "$N_SKIP" "$N_FAIL" "$N_UTD"
        printf 'Pending (update proposed, not applied) Images: %s\nMajor Upgrade Recommendations: %s\nOverall Status: %s\n' "$N_PEND" "$N_MAJ" "$overall"
    } >"$out"
    log INFO "$name: report written to ${out#"$SCRIPT_DIR"/} ($overall)"
}

# ================================================================== one repository
process_repo() {   # process_repo NAME LINK TOKEN_NAME
    local name="$1" link="$2" tokname="$3" tok="" rel branch
    SAFE="$(safe_name "$name")"; REPO_DIR="$REPOS_DIR/$SAFE"
    ROWS_ALL="$WORK/rows_all"; VAL_ALL="$WORK/val_all"; NOTES="$WORK/notes"; TECHS="$WORK/techs"
    : >"$ROWS_ALL"; : >"$VAL_ALL"; : >"$NOTES"; : >"$TECHS"
    T_DF=0 T_FROM=0 N_UPD=0 N_SKIP=0 N_FAIL=0 N_UTD=0 N_PEND=0 N_MAJ=0 CHANGED=0; RERR=""; BRANCH=""; PRURL=""
    log INFO "$name: processing"
    if [[ -z "$link" ]]; then RERR="Repo_Link is empty in $(basename "$CONFIG_FILE")"; write_report "$name" "" "$tokname"; return 1; fi
    if [[ -n "$tokname" ]]; then
        if [[ "$tokname" =~ ^[A-Z][A-Z0-9_]*$ && ( "$tokname" == *TOKEN* || "$tokname" == *PAT* ) ]]; then tok="${!tokname:-}"
        else RERR="Token_Name '$tokname' is not a valid token variable name"; write_report "$name" "$link" "$tokname"; return 1; fi
        [[ -n "$tok" ]] || { RERR="token variable $tokname is not set (Jenkins credential / environment)"; write_report "$name" "$link" "$tokname"; return 1; }
    fi
    branch="$(choose_branch "$tok" "$link")" || { RERR="$(cat "$WORK/git.msg")"; write_report "$name" "$link" "$tokname"; return 1; }
    BRANCH="$branch"
    rm -rf "$REPO_DIR"
    git_run "$tok" "$link" clone -q --depth 1 --branch "$branch" "$link" "$REPO_DIR" 2>"$WORK/git.err" || { RERR="clone failed: $(git_error "$WORK/git.err")"; write_report "$name" "$link" "$tokname"; return 1; }
    detect_technologies
    while IFS= read -r rel; do process_dockerfile "$rel"; done < <(cd "$REPO_DIR" && find . -maxdepth $((MAX_DEPTH + 1)) \
        \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv -o -name .terraform \) -prune -o \
        -type f \( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name '*.dockerfile' \) -print | sed 's#^\./##' | LC_ALL=C sort)
    ((T_DF == 0)) && echo "No Dockerfile found in the repository" >>"$NOTES"
    if ((CHANGED == 1)) && { is_true "$COMMIT_PUSH" || is_true "$CREATE_PR"; }; then publish_changes "$tok" "$link" "$branch"; fi
    write_report "$name" "$link" "$tokname"
    return 0
}

# ================================================================== main
log INFO "start: strategy=$STRATEGY dry_run=$DRY_RUN test_mode=$TEST_MODE config=${CONFIG_FILE#"$SCRIPT_DIR"/}"
FAILED=0; COUNT=0
while IFS=$SEP read -r -u 3 name link poc email cc tokname; do
    [[ -n "$name" ]] || { log WARN "row without Repo_Name skipped"; continue; }
    selected "$name" || continue
    COUNT=$((COUNT + 1))
    process_repo "$name" "$link" "$tokname" || { FAILED=$((FAILED + 1)); log ERROR "$name: ${RERR:-failed}"; }
done 3< <(read_csv "$CONFIG_FILE")
((COUNT > 0)) || { log ERROR "no repositories selected from $CONFIG_FILE"; exit 2; }
log INFO "done: $COUNT repositories, $FAILED failed. Reports in ${REPORTS_DIR#"$SCRIPT_DIR"/}/"
((FAILED > 0)) && exit 1
exit 0
