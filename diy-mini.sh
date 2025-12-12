#!/bin/bash
#=================================================
#  完整 DIY 脚本 —— 适配 istoreos 24.10 编译环境
#  核心：静态写入稳定 Feed + 一键配置 quickstart + 个性化定制
#  执行时机：在 ./scripts/feeds 之前执行（或编译根目录直接执行）
#=================================================
set -e  # 执行出错立即终止，便于定位问题

#-------------------------------------------------
# 1. 定义必要工具函数（避免执行报错）
#-------------------------------------------------
# 稀疏克隆指定目录（拉取 istore 等包）
function git_sparse_clone() {
  branch="$1" repourl="$2" && shift 2
  git clone --depth=1 -b $branch --single-branch --filter=blob:none --sparse $repourl
  repodir=$(echo $repourl | awk -F '/' '{print $(NF)}')
  cd $repodir && git sparse-checkout set $@
  [ -d "$@" ] && mv -f $@ ../package || echo "警告：$@ 目录不存在，跳过移动"
  cd .. && rm -rf $repodir
}

# 合并仓库指定文件夹（拉取主题等）
function merge_package() {
  if [[ $# -lt 3 ]]; then
    echo "Syntax error: [$#] [$*]" >&2
    return 1
  fi
  trap 'rm -rf "$tmpdir"' EXIT
  branch="$1" curl="$2" target_dir="$3" && shift 3
  rootdir="$PWD"
  localdir="$target_dir"
  [ -d "$localdir" ] || mkdir -p "$localdir"
  tmpdir="$(mktemp -d)" || exit 1
  echo "开始下载：$(echo $curl | awk -F '/' '{print $(NF)}')"
  git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$curl" "$tmpdir"
  cd "$tmpdir"
  git sparse-checkout init --cone
  git sparse-checkout set "$@"
  for folder in "$@"; do
    [ -d "$folder" ] && mv -f "$folder" "$rootdir/$localdir" || echo "警告：$folder 目录不存在，跳过移动"
  done
  cd "$rootdir"
}

#-------------------------------------------------
# 2. 替换 feeds.conf.default（静态写入稳定 Feed，先备份）
#-------------------------------------------------
echo "===== 备份并替换 feeds.conf.default ====="
cp -f feeds.conf.default feeds.conf.default.bak  # 备份原有配置
cat > feeds.conf.default <<'EOF'
src-git packages https://github.com/jjm2473/packages.git;istoreos-24.10
src-git luci https://github.com/jjm2473/luci.git;istoreos-24.10
src-git routing https://github.com/openwrt/routing.git;openwrt-24.10
src-git telephony https://github.com/openwrt/telephony.git;openwrt-24.10
# istore
src-git store https://github.com/linkease/istore.git;main
# argon, etc.
src-git third https://github.com/jjm2473/openwrt-third.git;main
# nas-packages-luci
src-git linkease_nas https://github.com/linkease/nas-packages.git;master
src-git linkease_nas_luci https://github.com/linkease/nas-packages-luci.git;main
# OpenAppFilter
src-git oaf https://github.com/jjm2473/OpenAppFilter.git;dev4
EOF

#-------------------------------------------------
# 3. 强制更新并安装所有 Feed（确保包加载完整）
#-------------------------------------------------
echo "===== 更新并安装所有 Feed ====="
./scripts/feeds update -a -f  # -f 强制更新，忽略缓存
./scripts/feeds install -a     # 安装所有 Feed 包

#-------------------------------------------------
# 4. 拉取额外定制包（主题、限速插件等）
#-------------------------------------------------
echo "===== 拉取额外定制包 ====="
# Argon 主题 + 配置
git clone --depth=1 -b 18.06 https://github.com/jerrykuku/luci-theme-argon package/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config package/luci-app-argon-config
# 补充 luci-theme-design 主题（如需）
merge_package master https://github.com/coolsnowwolf/luci feeds/luci/themes themes/luci-theme-design
# 定时限速插件
git clone --depth=1 https://github.com/sirpdboy/luci-app-eqosplus package/luci-app-eqosplus
# istore 前端（兜底，避免 Feed 拉取不全）
git_sparse_clone main https://github.com/linkease/istore-ui app-store-ui

#-------------------------------------------------
# 强制生效配置（拉齐所有依赖）
make defconfig

#-------------------------------------------------
# 6. 系统个性化定制
#-------------------------------------------------
echo "===== 系统个性化定制 ====="
# 固件版本添加作者签名
author="xiaomeng9597"
sed -i "s/DISTRIB_DESCRIPTION.*/DISTRIB_DESCRIPTION='%D %V %C by ${author}'/g" package/base-files/files/etc/openwrt_release
sed -i "s/OPENWRT_RELEASE.*/OPENWRT_RELEASE=\"%D %V %C by ${author}\"/g" package/base-files/files/usr/lib/os-release

# 最大连接数优化
sed -i '/customized in this file/a net.netfilter.nf_conntrack_max=65535' package/base-files/files/etc/sysctl.conf

# 集成 CPU 跑分脚本（带路径检查，避免报错）
if [ -f "$GITHUB_WORKSPACE/configfiles/coremark/coremark-arm64" ] && [ -f "$GITHUB_WORKSPACE/configfiles/coremark/coremark-arm64.sh" ]; then
  mkdir -p package/base-files/files/bin
  cp -f $GITHUB_WORKSPACE/configfiles/coremark/coremark-arm64  package/base-files/files/bin/
  cp -f $GITHUB_WORKSPACE/configfiles/coremark/coremark-arm64.sh package/base-files/files/bin/coremark.sh
  chmod 755 package/base-files/files/bin/coremark*
else
  echo "提示：未找到 coremark 跑分脚本，跳过集成"
fi

# 修复第三方包 Makefile 路径（避免编译报错）
find package/*/ -maxdepth 2 -name Makefile | \
  xargs sed -i 's|\.\./\.\./luci.mk|$(TOPDIR)/feeds/luci/luci.mk|g'
find package/*/ -maxdepth 2 -name Makefile | \
  xargs sed -i 's|\.\./\.\./lang/golang/golang-package.mk|$(TOPDIR)/feeds/packages/lang/golang/golang-package.mk|g'
find package/*/ -maxdepth 2 -name Makefile | \
  xargs sed -i 's|PKG_SOURCE_URL:=@GHREPO|PKG_SOURCE_URL:=https://github.com|g'
find package/*/ -maxdepth 2 -name Makefile | \
  xargs sed -i 's|PKG_SOURCE_URL:=@GHCODELOAD|PKG_SOURCE_URL:=https://codeload.github.com|g'

# 可选：修改 Argon 主题背景（取消注释并放置图片）
# rm -rf feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/background/*
# cp -f $GITHUB_WORKSPACE/images/bg1.jpg feeds/luci/themes/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg

#=================================================
# 脚本执行完成
#=================================================
