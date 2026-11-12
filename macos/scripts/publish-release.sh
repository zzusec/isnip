#!/bin/sh
# 临时分支打包 → 私有源码/安装包、公开安装包 → 匿名 SHA-256 验收 → 普通快进 main → 本机安装。
# 用法：sh macos/scripts/publish-release.sh [版本号] [--no-install]
set -eu

install_local=1
[ -z "${AIRSNIP_NO_INSTALL:-}" ] || install_local=0
rest=
for arg in "$@"; do
  case $arg in
    --no-install) install_local=0 ;;
    *) rest="$rest $arg" ;;
  esac
done
# shellcheck disable=SC2086
set -- $rest

CODE_REPO=zzusec/airsnip

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

die() { echo "publish-release: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "只能在 macOS 上执行"

plist=macos/Info.plist
declared=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
version=${1:-$declared}
version=${version#v}
[ "$version" = "$declared" ] || die "Info.plist 是 ${declared}，要发 $version 请先更新 Info.plist 并提交"
python3 - "$version" <<'PY'
import re, sys
if not re.fullmatch(r'\d+\.\d+\.\d+', sys.argv[1]):
    sys.exit('无效版本号；需要 major.minor.patch')
PY

pub_repo=$(/usr/libexec/PlistBuddy -c 'Print :AirSnipUpdateRepository' "$plist")
[ "$pub_repo" = zzusec/airsnip-releases ] || die "公开升级仓库不匹配；停止发布"

branch=$(git symbolic-ref --quiet --short HEAD) || die "请在临时分支发布，不能使用 detached HEAD"
[ "$branch" != main ] || die "发布前只允许提交到临时分支，不能从 main 直接发布"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "有未提交的改动，请先提交"
sha=$(git rev-parse HEAD)
git fetch -q origin
remote_sha=$(git ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')
[ "$remote_sha" = "$sha" ] || die "当前提交尚未推送到临时分支 ${branch}"
git merge-base --is-ancestor origin/main "$sha" || die "main 有当前分支未包含的历史；请先整合，禁止强推"

TOKEN=${GH_TOKEN:-}
if [ -z "$TOKEN" ] && [ -r "$HOME/.gh-release-token" ]; then
  TOKEN=$(tr -d ' \n' < "$HOME/.gh-release-token")
fi
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
  TOKEN=$(gh auth token 2>/dev/null | tr -d ' \n' || true)
fi
[ -n "$TOKEN" ] || die "缺少 GH_TOKEN、~/.gh-release-token 或 gh 登录态"

api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/airsnip-publish.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

api -f "https://api.github.com/repos/$CODE_REPO" -o "$scratch/repository.json"
python3 - "$scratch/repository.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('private') is not True:
    sys.exit('源码仓库未确认是私有仓库；停止发布，绝不向公开仓库上传源码')
PY

for repo in "$CODE_REPO" "$pub_repo"; do
  code=$(api -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$repo/releases/tags/v$version")
  [ "$code" = 404 ] || die "$repo 已存在 v${version}（HTTP ${code}）：请递增版本号"
done

echo "== 打包 v$version =="
sh macos/scripts/release-app.sh "$version"
[ "$(git rev-parse HEAD)" = "$sha" ] || die "打包期间 HEAD 已改变；未创建 Release"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "打包期间源码已改变；未创建 Release"

dist=$root/macos/dist
base=airsnip-macos-arm64-v$version
assets="$base.dmg $base.dmg.sha256 $base.zip $base.zip.sha256"
for f in $assets; do [ -s "$dist/$f" ] || die "缺少产物 $dist/$f"; done
source=airsnip-source-v$version.zip
git archive --format=zip --prefix="airsnip-v$version/" --output="$dist/$source" "$sha"
( cd "$dist" && shasum -a 256 "$source" > "$source.sha256" )

( cd "$dist" && shasum -a 256 -c "$base.dmg.sha256" && shasum -a 256 -c "$base.zip.sha256" ) \
  || die "本地 SHA-256 自检未通过"

notes=$scratch/notes.md
awk -v head="## macOS v$version" 'index($0, head) == 1 {f=1; next} /^## /{f=0} f' CHANGELOG.md > "$notes"
[ -s "$notes" ] || echo "macOS v$version" > "$notes"

publish() {
  repo=$1
  target=${2:-}
  files=$3
  url=$(REPO="$repo" TAG="v$version" TARGET="$target" NOTES="$notes" TOKEN="$TOKEN" python3 - <<'PY'
import json, os, subprocess, sys

body = {'tag_name': os.environ['TAG'], 'name': 'macOS ' + os.environ['TAG'],
        'body': open(os.environ['NOTES']).read()}
if os.environ['TARGET']:
    body['target_commitish'] = os.environ['TARGET']
result = subprocess.run(['curl', '-fsS', '-X', 'POST',
                      '-H', 'Authorization: Bearer ' + os.environ['TOKEN'],
                      '-H', 'Accept: application/vnd.github+json',
                      'https://api.github.com/repos/%s/releases' % os.environ['REPO'],
                      '-d', json.dumps(body)], capture_output=True, text=True)
if result.returncode:
    sys.exit('创建 Release 请求失败；未更新 main')
data = json.loads(result.stdout)
if 'upload_url' not in data:
    sys.exit('创建 Release 失败：' + result.stdout[:400])
print(data['upload_url'].split('{')[0])
PY
)
  for f in $files; do
    case $f in
      *.sha256) ct=text/plain ;;
      *) ct=application/octet-stream ;;
    esac
    api -f -X POST -H "Content-Type: $ct" --data-binary @"$dist/$f" "$url?name=$f" -o /dev/null
    echo "  uploaded $f"
  done
}

echo "== 私有仓库 $CODE_REPO =="
publish "$CODE_REPO" "$sha" "$assets $source $source.sha256"
echo "== 公开发布仓库 $pub_repo =="
publish "$pub_repo" "" "$assets"

echo "== 匿名验收 =="
latest=$(curl -sSL -o /dev/null -w '%{url_effective}' "https://github.com/$pub_repo/releases/latest")
echo "  latest -> $latest"
case $latest in
  */tag/v$version) ;;
  *) die "latest 未指向 v$version" ;;
esac
for f in "$base.zip" "$base.dmg"; do
  remote=$(curl -sSL "https://github.com/$pub_repo/releases/download/v$version/$f.sha256" | awk '{print $1}')
  [ ${#remote} -eq 64 ] || die "$f.sha256 未正常上传或格式无效"
  [ "$remote" = "$(awk '{print $1}' "$dist/$f.sha256")" ] || die "$f 线上校验值与本地不一致"
  echo "  ok $f.sha256 $remote"
done

for repo in "$CODE_REPO" "$pub_repo"; do
  api -f "https://api.github.com/repos/$repo/releases/tags/v$version" -o "$scratch/release.json"
  python3 - "$scratch/release.json" "$dist" "$base" "$source" "$repo" "$CODE_REPO" <<'PY'
import hashlib, json, pathlib, sys
metadata = json.load(open(sys.argv[1]))
dist, base, source, repo, code_repo = sys.argv[2:]
expected = {base + suffix for suffix in ('.dmg', '.dmg.sha256', '.zip', '.zip.sha256')}
if repo == code_repo:
    expected.update((source, source + '.sha256'))
assets = metadata.get('assets', [])
if len(assets) != len(expected) or {a['name'] for a in assets} != expected:
    sys.exit('Release 附件不完整或包含非允许附件；main 未更新')
for asset in assets:
    data = (pathlib.Path(dist) / asset['name']).read_bytes()
    if asset.get('state') != 'uploaded' or asset.get('size') != len(data):
        sys.exit('Release 附件状态或大小未通过校验；main 未更新')
    if asset.get('digest') and asset.get('digest') != 'sha256:' + hashlib.sha256(data).hexdigest():
        sys.exit('Release 附件摘要未通过校验；main 未更新')
PY
done

[ "$(git rev-parse HEAD)" = "$sha" ] || die "发布期间 HEAD 已改变；main 未更新"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "发布期间源码已改变；main 未更新"
echo "== 发布验收完成，仅普通快进 origin/main =="
git push origin "$sha:refs/heads/main" || die "main 快进更新失败；请检查分支历史，禁止强推"

[ "$install_local" = 1 ] || { echo "（--no-install：跳过本机安装）"; exit 0; }
echo
echo "== 安装到本机 =="
sh macos/scripts/install-local.sh --built "$dist/AirSnip.app"
