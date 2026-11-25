#!/usr/bin/env bash
# 把 GitHub 上已经发好的 release 原样搬到 GitCode 的镜像仓库 gitcode.com/yyandbug/kitty-tools（GitCode 2026 年改名 AtomGit，
#   gitcode.com = atomgit.com），给打不开 GitHub 的国内用户下载和 App 内更新用（2026-11-25 拍板 A1 / D1）。
# 用法：macos/publish-gitcode.sh [tag…]，例如 macos/publish-gitcode.sh macos-v0.10.4 windows-v0.3.1 emoji-pack-1。
#   不带参数就只换两个清单。DRY_RUN=1 只读不写（不要令牌），列出会做什么。
# 什么时候跑：GitHub 上的 release 发完、build-dmg.sh / build-release.ps1 头部那两条 curl 核过之后（mac-native §7）。重跑同一条
#   命令就是补发：已经在 GitCode 上、大小对得上的附件跳过。
# 做的事：
#   1. 每个 tag：读 GitHub 上那个 release（标题、说明、附件）。GitCode 上还没有这个标签就跳过它——镜像（项目设置 › 仓库镜像，
#      只同步分支、标签、提交，不带 release；隔几个小时才自己拉一次、没有触发同步的接口）还没同步过来：先去点「同步」再重跑；不在 GitCode 上自己建标签（两边会不一样）。
#      建 / 改同名 release（标题、说明照搬；GitHub 上的 latest 那个标 latest，*-update 标 pre），附件用 gh 拉下来原样传上去，
#      文件名照 GitHub 上的（空格已经是「.」），所以两边的下载地址只差 https://github.com/YyAdnBug/ ↔ https://gitcode.com/yyandbug/
#      （Updater / Windows 的 UpdateManifest 靠这一点换站）。传完匿名下载核一遍大小。
#   2. 两个清单（macos-update.json 在 release「macos-update」上，windows-update.json 在「windows-update」上）：取 GitHub 上现在那份，
#      地址换成 GitCode 的（sha256 不变：同一份字节；发布页 …/releases/tag/<tag> → …/releases/<tag>，GitCode 的页面没有 tag/），
#      它指的包在 GitCode 上都能下才换上（先删旧的再传：同名附件再传会被拒）。GitCode 没有 releases/latest/download/<文件>
#      （那个地址返回网页），所以 mac 也要一个固定标签 macos-update（GitHub 上一个轻量标签、不建 release，镜像带过去）。
#      windows-update.json 另外用 sign-manifest.swift 签名、传 windows-update.json.sig（W1：Windows 包没有代码签名，Windows 版只认
#      签名对得上写死公钥的 GitCode 清单）；钥匙串里还没有签名钥匙时只传清单、提示一句。
# 令牌（D1）：你自己在 GitCode 个人设置 › 访问令牌 里建（只勾仓库读写、设到期时间），自己存进钥匙串（会提示粘贴，不进 shell 历史）：
#     security add-generic-password -a "$USER" -s kitty-tools-gitcode -w
#   脚本只从钥匙串读（读不到再看环境变量 GITCODE_TOKEN），经 curl -K - 从标准输入交给 curl：不进命令行参数、网址和输出；
#   附件的预签名上传地址同样走标准输入、不打印。别给这个脚本加 set -x。
# 失败：401 / 403 是令牌失效或权限不够；429、5xx 由 curl 退避重试。一步没成就接着做别的，最后退出码 1，重跑补上。
# 接口文档：https://atomgit-api-doc.atomgit.com/（14.release）；默认限流 400 次 / 分。
set -euo pipefail

GH_REPO="YyAdnBug/kitty-tools"
GH_WEB="https://github.com/$GH_REPO"
GC_WEB="https://gitcode.com/yyandbug/kitty-tools"
API="https://api.gitcode.com/api/v5/repos/yyandbug/kitty-tools"
SIGN="$(cd "$(dirname "$0")" && pwd)/sign-manifest.swift"
DRY="${DRY_RUN:-0}"
FAILED=0
TMP=$(mktemp -d) && trap 'rm -rf "$TMP"' EXIT

fail() { echo "✗ $*" >&2; FAILED=1; }
uri() { jq -rn --arg s "$1" '$s | @uri'; }

TOKEN=""
if [[ "$DRY" != 1 ]]; then
  TOKEN=$(security find-generic-password -s kitty-tools-gitcode -w 2>/dev/null || true)
  TOKEN="${TOKEN:-${GITCODE_TOKEN:-}}"
  [[ -n "$TOKEN" ]] || {
    echo "没找到 GitCode 令牌：在 GitCode 个人设置 › 访问令牌 里建一个，再执行"
    echo '  security add-generic-password -a "$USER" -s kitty-tools-gitcode -w'
    exit 1
  }
fi

# 带令牌的接口请求，正文写到标准输出；令牌从标准输入交给 curl（-K -），不进命令行参数。失败时把 GitCode 的回复打到标准错误
api() {
  local method=$1 path=$2 out="$TMP/api.out"
  shift 2
  if printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS --fail-with-body --retry 3 -o "$out" -K - -X "$method" -H 'Accept: application/json' "$@" "$API$path"; then
    cat "$out"
  else
    echo "  GitCode：$(head -c 300 "$out" 2>/dev/null)" >&2
    return 1
  fi
}

# GitCode 上这个标签的 release（JSON，匿名读）；没有就什么都不输出
gc_release() {
  local status
  status=$(curl -sS --retry 3 -o "$TMP/rel.json" -w '%{http_code}' "$API/releases/tags/$(uri "$1")") || return 1
  case "$status" in
    200) cat "$TMP/rel.json" ;;
    404) ;;
    *) echo "  GitCode 读 release $1 返回 $status" >&2 && return 1 ;;
  esac
}

# GitCode 上的全部标签（匿名，一行一个）
gc_tags() {
  local page=1 out
  while ((page <= 20)); do
    out=$(curl -sS --fail --retry 3 "$API/tags?per_page=100&page=$page") || return 1
    [[ "$(jq length <<<"$out")" -gt 0 ]] || break
    jq -r '.[].name' <<<"$out"
    page=$((page + 1))
  done
}

# 建或改 release：tag 标题 说明 状态（latest / pre / 空）
ensure_release() {
  local tag=$1 body=${3:-$2} payload
  payload=$(jq -n --arg tag "$tag" --arg name "$2" --arg body "$body" --arg st "$4" \
    '{tag_name: $tag, name: $name, body: $body} + (if $st == "" then {} else {release_status: $st} end)')
  if [[ "$DRY" == 1 ]]; then
    echo "  （试跑）建或改 release $tag：$2${4:+（$4）}"
  elif [[ -n "$(gc_release "$tag")" ]]; then
    api PATCH "/releases/$(uri "$tag")" -H 'Content-Type: application/json' \
      --data-binary "$(jq 'del(.tag_name)' <<<"$payload")" >/dev/null
  else
    api POST "/releases" -H 'Content-Type: application/json' --data-binary "$payload" >/dev/null
  fi
}

# GitCode 上已有的附件（名字 \t 大小 \t id），不含源码包
gc_assets() {
  gc_release "$1" | jq -r '.assets[]? | select(.id != null and (.type | ascii_downcase) != "source")
    | [.name, (.size // 0), .id] | @tsv'
}

delete_asset() {
  if [[ "$DRY" == 1 ]]; then echo "  （试跑）删掉旧的 $1/$2" && return; fi
  api DELETE "/releases/$(uri "$1")/attach_files/$3" >/dev/null
}

# 传一个附件：先取预签名上传地址，再 PUT（地址和要带的头经标准输入交给 curl，不打印）
upload() {
  local tag=$1 file=$2 name=$3 target
  if [[ "$DRY" == 1 ]]; then echo "  （试跑）传 $tag/$name" && return; fi
  target=$(api GET "/releases/$(uri "$tag")/upload_url?file_name=$(uri "$name")") || return 1
  [[ "$(jq -r '.url // ""' <<<"$target")" == https://* ]] || { echo "  上传地址不对" >&2 && return 1; }
  jq -r '"url = \(.url | @json)", (.headers // {} | to_entries[] | "header = \("\(.key): \(.value)" | @json)")' <<<"$target" |
    curl -sS --fail-with-body --retry 3 -o "$TMP/put.out" -K - -T "$file" ||
    { echo "  上传：$(head -c 300 "$TMP/put.out" 2>/dev/null)" >&2 && return 1; }
}

# 匿名能不能下、总共多少字节（GitCode 302 到带签名的 file-cdn 地址；只要第一个字节）
remote_size() {
  curl -sS -L --retry 2 -r 0-0 -o /dev/null -D - "$GC_WEB/releases/download/$(uri "$1")/$(uri "$2")" 2>/dev/null |
    tr -d '\r' | awk -F/ 'tolower($0) ~ /^content-range:/ { size = $NF } END { print size }'
}

# 传完核大小：GitCode 收到上传的回调有一点延迟，最多等 10 秒
verify_size() {
  local i
  [[ "$DRY" == 1 ]] && return
  for i in 1 2 3 4 5; do
    [[ "$(remote_size "$1" "$2")" == "$3" ]] && return
    sleep 2
  done
  return 1
}

publish_tag() {
  local tag=$1 info status existing name size line
  info=$(gh release view "$tag" -R "$GH_REPO" --json name,body,assets) || { fail "GitHub 上没有 release $tag" && return; }
  grep -qxF "$tag" <<<"$GC_TAGS" || {
    fail "GitCode 上还没有标签 $tag：镜像还没同步过来，到 GitCode 项目设置 › 仓库镜像 点「同步」后重跑"
    return
  }
  status=""
  [[ "$tag" == *-update ]] && status=pre
  [[ "$tag" == "$LATEST" ]] && status=latest
  echo "→ $tag"
  ensure_release "$tag" "$(jq -r .name <<<"$info")" "$(jq -r '.body // ""' <<<"$info")" "$status" ||
    { fail "$tag：建 / 改 release 没成" && return; }
  existing=$(gc_assets "$tag") || { fail "$tag：读不到 GitCode 上的附件" && return; }
  while IFS=$'\t' read -r name size; do
    # 清单由 refresh_channel 换（地址要改成 GitCode 的）
    [[ "$name" == macos-update.json* || "$name" == windows-update.json* ]] && continue
    line=$(awk -F'\t' -v n="$name" '$1 == n' <<<"$existing")
    if [[ -n "$line" && "$(cut -f2 <<<"$line")" == "$size" ]]; then
      echo "  · $name 已在"
      continue
    fi
    [[ -z "$line" ]] || delete_asset "$tag" "$name" "$(cut -f3 <<<"$line")" || { fail "$tag/$name：删不掉大小不对的旧附件" && continue; }
    if [[ "$DRY" == 1 ]]; then echo "  （试跑）传 $name（$size 字节）" && continue; fi
    gh release download "$tag" -R "$GH_REPO" -p "$name" -D "$TMP" --clobber || { fail "$tag/$name：从 GitHub 下不来" && continue; }
    if upload "$tag" "$TMP/$name" "$name" && verify_size "$tag" "$name" "$size"; then
      echo "  ✓ $name"
    else
      fail "$tag/$name：没传上去或大小对不上"
    fi
    rm -f "$TMP/$name"
  done < <(jq -r '.assets[] | [.name, .size] | @tsv' <<<"$info")
}

# 清单：channel（标签）文件名 GitHub 上那份的地址 release 标题
refresh_channel() {
  local tag=$1 file=$2 src=$3 title=$4 url line
  echo "→ $tag/$file"
  curl -fsSL --retry 3 "$src" -o "$TMP/gh-$file" || { fail "读不到 GitHub 上的 $file" && return; }
  sed -e "s#$GH_WEB/releases/tag/#$GC_WEB/releases/#g" -e "s#$GH_WEB/#$GC_WEB/#g" "$TMP/gh-$file" >"$TMP/$file"
  # 它指的每个包都要在 GitCode 上下得到（mac 的在最外层，Windows 的在 x64 / arm64 里）
  while IFS= read -r url; do
    [[ "$url" == "$GC_WEB/releases/download/"* ]] || { fail "$file 里有不是 GitCode 的地址" && return; }
    [[ "$(curl -sS -L -r 0-0 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" == 206 ]] ||
      { fail "$file 指的 ${url##*/} 在 GitCode 上还下不到：先搬那一版（publish-gitcode.sh <那一版的 tag>）" && return; }
  done < <(jq -r '.. | objects | .url? // empty' "$TMP/$file")
  grep -qxF "$tag" <<<"$GC_TAGS" || {
    fail "GitCode 上还没有标签 $tag：先在 GitHub 推这个标签（git tag $tag && git push origin $tag），到 GitCode 项目设置 › 仓库镜像 点「同步」后重跑"
    return
  }
  # Windows 的要带签名（W1：Windows 包没有代码签名，Windows 版只认签名对得上的 GitCode 清单）：钥匙串里有钥匙才签
  local signed="" same=""
  if [[ "$file" == windows-update.json ]]; then
    if swift "$SIGN" public-key >/dev/null 2>&1; then
      signed=1
    else
      echo "  ! 钥匙串里没有清单签名钥匙（swift macos/sign-manifest.swift new-key）：这份不带签名，Windows 版不会用它"
    fi
  fi
  if curl -fsSL "$GC_WEB/releases/download/$tag/$file" -o "$TMP/gc-$file" 2>/dev/null && cmp -s "$TMP/$file" "$TMP/gc-$file"; then
    same=1
    # 签名每次签出来都不一样（ECDSA），只看在不在
    if [[ -z "$signed" ]] || curl -fsSL -o /dev/null "$GC_WEB/releases/download/$tag/$file.sig" 2>/dev/null; then
      echo "  · 没变"
      return
    fi
  fi
  ensure_release "$tag" "$title" "App 内更新读的清单，别删" pre || { fail "$tag：建 / 改 release 没成" && return; }
  replace_asset "$tag" "$file" "$TMP/$file" "$same" || return
  [[ -z "$same" ]] && echo "  ✓ 换成 $(jq -r .version "$TMP/$file")"
  if [[ -n "$signed" ]]; then
    if [[ "$DRY" == 1 ]]; then echo "  （试跑）签名、传 $file.sig" && return; fi
    swift "$SIGN" sign "$TMP/$file" || { fail "$tag/$file：签不了名" && return; }
    replace_asset "$tag" "$file.sig" "$TMP/$file.sig" "" && echo "  ✓ 签名"
  fi
}

# 换掉 release 上的一个附件（先删旧的：同名再传会被拒）；same 非空时不动它
replace_asset() {
  local tag=$1 name=$2 path=$3 same=$4 line
  [[ -z "$same" ]] || return 0
  line=$(gc_assets "$tag" | awk -F'\t' -v n="$name" '$1 == n') || true
  [[ -z "$line" ]] || delete_asset "$tag" "$name" "$(cut -f3 <<<"$line")" || { fail "$tag/$name：删不掉旧的" && return 1; }
  upload "$tag" "$path" "$name" && verify_size "$tag" "$name" "$(stat -f%z "$path")" || { fail "$tag/$name：没传上去" && return 1; }
}

GC_TAGS=$(gc_tags) || { echo "读不到 GitCode 上的标签（网络？）"; exit 1; }
LATEST=$(gh release view -R "$GH_REPO" --json tagName -q .tagName)
for tag in "$@"; do publish_tag "$tag"; done
refresh_channel macos-update macos-update.json "$GH_WEB/releases/latest/download/macos-update.json" "macOS 更新清单"
refresh_channel windows-update windows-update.json "$GH_WEB/releases/download/windows-update/windows-update.json" \
  "Windows 更新清单"
# 核对（同 build-dmg.sh 头部那两条，换成 GitCode）：清单能下、它指的 zip 能下
[[ "$DRY" == 1 ]] || for file in macos-update windows-update; do
  echo "$file：$(curl -sS -L -o /dev/null -w '%{http_code}' "$GC_WEB/releases/download/$file/$file.json" 2>/dev/null)"
done
exit "$FAILED"
