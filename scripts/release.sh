#!/usr/bin/env bash
#
# 发版到 npm。必须在**真终端**里跑：passkey 2FA 只在 stdout 是 TTY 时才开浏览器，
# behind a pipe 会跳过浏览器直接 EOTP。详见 AGENTS.md「Publishing with 2FA on the account」。
#
#   scripts/release.sh --dry-run     只跑预检，不发布（安全，随时可跑）
#   scripts/release.sh               发布 package.json 里的版本
#   scripts/release.sh 0.12.1        同上，并先断言版本号等于 0.12.1
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
PKG=$(node -p "require('./package.json').name")
DRY=0
EXPECT=""
for a in "$@"; do
  case "${a}" in
    --dry-run) DRY=1 ;;
    -*) echo "未知参数: ${a}"; exit 2 ;;
    *)  EXPECT="${a}" ;;
  esac
done

die() { echo; echo "❌ $1"; exit 1; }
step() { echo; echo "── $1"; }

step "1/7 分支与工作区"
b=$(git rev-parse --abbrev-ref HEAD)
[ "${b}" = "main" ] || die "当前在 ${b}，发版只从 main 发"
[ -z "$(git status --porcelain)" ] || die "工作区不干净，先提交或清理"
git pull --ff-only || die "快进失败。先自己处理分叉，不要 rebase、不要 autostash"

step "2/7 版本号"
VER=$(node -p "require('./package.json').version")
LOCK=$(node -p "require('./package-lock.json').version")
[ "${VER}" = "${LOCK}" ] || die "package.json(${VER}) 与 package-lock.json(${LOCK}) 不一致。用 npm version <x.y.z> --no-git-tag-version 改两处，别手改单边"
if [ -n "${EXPECT}" ] && [ "${VER}" != "${EXPECT}" ]; then
  die "package.json 是 ${VER}，不是你说的 ${EXPECT} —— bump 的 PR 合了吗？"
fi
echo "${PKG}@${VER}（package-lock 一致）"

step "3/7 这个版本是不是已经发过"
# --prefer-online：不加会读本地缓存，报上一个版本（AGENTS.md 明确记过这个坑）
if npm view --prefer-online "${PKG}@${VER}" version >/dev/null 2>&1; then
  die "${PKG}@${VER} 已经在 registry 上了。要重发必须换版本号，npm 不允许覆盖"
fi
echo "registry 上还没有 ${VER} ✓"

step "4/7 测试"
node --test >/dev/null 2>&1 || die "node --test 没过，先别发"
echo "全量测试通过 ✓"

step "5/7 登录态"
# 注意：whoami 返回用户名只排除「没登录」，**不证明能发布** ——
# 存储的 token 能通过认证但不满足 2FA，EOTP 会在打包之后才报，读起来像打包失败。
who=$(npm whoami 2>&1) || die "npm 未登录（whoami: ${who}）。先 npm login --auth-type=web。
注意：publish 报 E404「包不在 registry」多半也是登录过期；用 npm whoami 与 npm owner ls ${PKG} 交叉判断，别只认 ENEEDAUTH"
echo "npm 身份：${who}（只说明已登录，不代表 2FA 能过）"
npm owner ls "${PKG}" || die "读不到 owner 列表，多半仍是登录态问题"

step "6/7 将要发布的内容"
npm pack --dry-run 2>&1 | tail -25

if [ "${DRY}" = "1" ]; then
  echo; echo "✅ DRY RUN：预检全过，未发布。去掉 --dry-run 即可真发。"
  exit 0
fi

step "7/7 npm publish"
LOG="npm-publish-${VER}.log"
cat <<EOF
现在会弹浏览器要 passkey。成功判据：输出里有 PUT … 202、本命令 exit 0。
「Your package is being processed」是异步接受，不是失败；registry 几分钟内仍可能显示旧版本。
完整输出留在 ${LOG}（用 script(1) 保 pty，不用管道——管道会让 npm 跳过浏览器）。
EOF
echo
# BSD/macOS 的 script(1) 参数顺序：script [-q] <file> <command...>
script -q "${LOG}" npm publish --access public
rc=$?
[ ${rc} -eq 0 ] || die "npm publish 退出码 ${rc}，详见 ${LOG} 与 ~/.npm/_logs/（文件名是 UTC，换算后再判断新旧）"

step "验收：registry"
for i in $(seq 1 10); do
  got=$(npm view --prefer-online "${PKG}" version 2>/dev/null)
  [ "${got}" = "${VER}" ] && break
  echo "  registry 还是 ${got:-空}，15s 后再看 (${i}/10)"; sleep 15
done
[ "${got:-}" = "${VER}" ] || die "等了 150s，registry 仍是 ${got:-空}。publish 是异步的，再等几分钟手动跑：npm view --prefer-online ${PKG} version"
echo "registry version = ${got} ✓"

step "验收：解包看真正发出去的东西"
# 只认 exit code 不够，要拆开看 src/ 真的在包里
tmp=$(mktemp -d) || die "建不出临时目录"
( cd "${tmp}" && npm pack "${PKG}@${VER}" --prefer-online >/dev/null 2>&1 \
  && tar tzf ./*.tgz | grep -q '^package/src/' ) \
  || die "解包验收失败：${PKG}@${VER} 的 tarball 里没看到 src/"
echo "tarball 里 src/ 存在 ✓"

step "验收：npx 拉起"
# 必须离开包自己的目录，否则 npx 会解析成本地包并报 command not found
( cd "${tmp}" && npx -y "${PKG}@${VER}" --version ) || die "npx 拉起失败"
rm -rf "${tmp}"

echo
echo "✅ ${PKG}@${VER} 已发布并验收通过。"
