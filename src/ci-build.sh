#!/bin/bash

# Github Action Continuous Integration for ArchLinuxArm
# Author: Atom Long <atom.long@hotmail.com>

# Enable colors
if [[ -t 1 ]]; then
    normal='\e[0m'
    red='\e[1;31m'
    green='\e[1;32m'
    cyan='\e[1;36m'
fi

# Basic status function
_status() {
    local type="${1}"
    local status="${package:+${package}: }${2}"
    local items=("${@:3}")
    case "${type}" in
        failure) local -n nameref_color='red';   title='[ARCH CI] FAILURE:' ;;
        success) local -n nameref_color='green'; title='[ARCH CI] SUCCESS:' ;;
        message) local -n nameref_color='cyan';  title='[ARCH CI]'
    esac
    printf "\n${nameref_color}${title}${normal} ${status}\n\n"
    printf "${items:+\t%s\n}" "${items:+${items[@]}}"
}

# Get package information
_package_info() {
    local properties=("${@}")
    for property in "${properties[@]}"; do
        local -n nameref_property="${property}"
        nameref_property=($(
            source PKGBUILD
            declare -n nameref_property="${property}"
            echo "${nameref_property[@]}"))
    done
}

# Run command with status
execute(){
    local status="${1}"
    local command="${2}"
    local arguments=("${@:3}")
	[ -n "${package}" ] && pushd ${package}
    message "${status}"
    if [[ "${command}" != *:* ]]
        then ${command} ${arguments[@]}
        else ${command%%:*} | ${command#*:} ${arguments[@]}
    fi || failure "${status} failed"
    [ -n "${package}" ] && popd
}

# Status functions
failure() { local status="${1}"; local items=("${@:2}"); _status failure "${status}." "${items[@]}"; return 1; }
success() { local status="${1}"; local items=("${@:2}"); _status success "${status}." "${items[@]}"; return 0; }
message() { local status="${1}"; local items=("${@:2}"); _status message "${status}"  "${items[@]}"; }

# Add custom repositories to pacman
add_custom_repos()
{
[ -n "${CUSTOM_REPOS}" ] || { echo "You must set CUSTOM_REPOS firstly."; return 1; }
local repos=(${CUSTOM_REPOS//,/ })
local repo name
for repo in ${repos[@]}; do
name=$(sed -n -r 's/\[(\w+)\].*/\1/p' <<< ${repo})
[ -n "${name}" ] || continue
[ -z $(sed -rn "/^\\[${name}]\s*$/p" /etc/pacman.conf) ] || continue
cp -vf /etc/pacman.conf{,.orig}
sed -r 's/]/&\nServer = /' <<< ${repo} >> /etc/pacman.conf
sed -i -r 's/^(SigLevel\s*=\s*).*/\1Never/' /etc/pacman.conf
pacman --sync --refresh --needed --noconfirm --disable-download-timeout ${name}-keyring && name="" || name="SigLevel = Never\n"
mv -vf /etc/pacman.conf{.orig,}
sed -r "s/]/&\n${name}Server = /" <<< ${repo} >> /etc/pacman.conf
done
}

# Function: Sign one or more pkgballs.
create_package_signature()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
local pkg

# signature for distrib packages.
(ls ${ARTIFACTS_PATH}/*${PKGEXT} &>/dev/null) && {
pushd ${ARTIFACTS_PATH}
for pkg in *${PKGEXT}; do
gpg --pinentry-mode loopback --passphrase "${PGP_KEY_PASSWD}" -o "${pkg}.sig" -b "${pkg}"
done
popd
}
return 0
}

# Import pgp private key
import_pgp_seckey()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
[ -n "${PGP_KEY}" ] || { echo "You must set PGP_KEY firstly."; return 1; }
gpg --import --pinentry-mode loopback --passphrase "${PGP_KEY_PASSWD}" <<< "${PGP_KEY}"
}

# Build package
build_package()
{
[ -n "${ARTIFACTS_PATH}" ] || { echo "You must set ARTIFACTS_PATH firstly."; return 1; }
local pkgname item ret=0
unset PKGEXT
_package_info depends{,_${PACMAN_ARCH}} makedepends{,_${PACMAN_ARCH}} pkgname PKGEXT
[ -n "${PKGEXT}" ] || PKGEXT=$(grep -Po "^PKGEXT=('|\")?\K[^'\"]+" /etc/makepkg.conf)
export PKGEXT=${PKGEXT}

[ ${ret} == 0 ] && [ -n "${depends}" ] && { pacman -S --needed --noconfirm --disable-download-timeout ${depends[@]} || ret=1; }
[ ${ret} == 0 ] && [ -n "$(eval echo \${depends_${PACMAN_ARCH}})" ] && { eval pacman -S --needed --noconfirm --disable-download-timeout \${depends_${PACMAN_ARCH}[@]} || ret=1; }
[ ${ret} == 0 ] && [ -n "${makedepends}" ] && { pacman -S --needed --noconfirm --disable-download-timeout ${makedepends[@]} || ret=1; }
[ ${ret} == 0 ] && [ -n "$(eval echo \${makedepends_${PACMAN_ARCH}})" ] && { eval pacman -S --needed --noconfirm --disable-download-timeout \${makedepends_${PACMAN_ARCH}[@]} || ret=1; }

[ ${ret} == 0 ] && runuser -u alarm -- makepkg --noconfirm --skippgpcheck --nocheck --syncdeps --nodeps --cleanbuild

(ls *${PKGEXT} &>/dev/null) && {
mkdir -pv ${ARTIFACTS_PATH}
mv -vf *${PKGEXT} ${ARTIFACTS_PATH}
true
} || {
for item in ${pkgname[@]}; do
export FILED_PKGS=(${FILED_PKGS[@]} ${PACMAN_REPO}/${item})
done
}
return ${ret}
}

# deploy artifacts
deploy_artifacts()
{
[ -n "${DEPLOY_PATH}" ] || { echo "You must set DEPLOY_PATH firstly."; return 1; } 
local old_pkgs pkg file
(ls ${ARTIFACTS_PATH}/*${PKGEXT} &>/dev/null) || { echo "Skiped, no file to deploy"; return 0; }
pushd ${ARTIFACTS_PATH}
export PKG_FILES=(${PKG_FILES[@]} $(ls *${PKGEXT}))
for file in ${PACMAN_REPO}.{db,files}{,.tar.xz}{,.old}; do
rclone copy ${DEPLOY_PATH}/${file} ${PWD} 2>/dev/null || true
done
old_pkgs=($(repo-add "${PACMAN_REPO}.db.tar.xz" *${PKGEXT} | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')"))
popd
for pkg in ${old_pkgs[@]}; do
for file in ${pkg}-{${PACMAN_ARCH},any}.pkg.tar.{xz,zst}{,.sig}; do
rclone delete ${DEPLOY_PATH}/${file} 2>/dev/null || true
done
done
rclone copy ${ARTIFACTS_PATH} ${DEPLOY_PATH} --copy-links
}

# create mail message
create_mail_message()
{
local message item

[ -n "${PKG_FILES}" ] && {
message="<p>Successfully created the following package archive.</p>"
for item in ${PKG_FILES[@]}; do
message=${message}"<p><font color=\"green\">${item}</font></p>"
done
}

[ -n "${FILED_PKGS}" ] && {
message=${message}"<p>Failed to build following packages. </p>"
for item in ${FILED_PKGS[@]}; do
message=${message}"<p><font color=\"red\">${item}</font></p>"
done
}

[ -n "${message}" ] && {
message=${message}"<p>Architecture: ${PACMAN_ARCH}</p>"
message=${message}"<p>Build Number: ${CI_BUILD_NUMBER}</p>"
echo ::set-output name=message::${message}
}

return 0
}

# Run from here
cd ${GITHUB_WORKSPACE}
message 'Install build environment.'
[ -z "${PACMAN_ARCH}" ] && export PACMAN_ARCH=$(sed -nr 's|^CARCH=\"(\w+).*|\1|p' /etc/makepkg.conf)
[ -z "${ARTIFACTS_PATH}" ] && export ARTIFACTS_PATH=artifacts/${PACMAN_ARCH}/${PACMAN_REPO}
[[ ${ARTIFACTS_PATH} =~ '$' ]] && eval export ARTIFACTS_PATH=${ARTIFACTS_PATH}
[ -z "${DEPLOY_PATH}" ] && { echo "Environment variable 'DEPLOY_PATH' is required."; exit 1; }
[[ ${DEPLOY_PATH} =~ '$' ]] && eval export DEPLOY_PATH=${DEPLOY_PATH}
[ -z "${RCLONE_CONF}" ] && { echo "Environment variable 'RCLONE_CONF' is required."; exit 1; }
[ -z "${PGP_KEY_PASSWD}" ] && { echo "Environment variable 'PGP_KEY_PASSWD' is required."; exit 1; }
[ -z "${PGP_KEY}" ] && { echo "Environment variable 'PGP_KEY' is required."; exit 1; }
[ -z "${CUSTOM_REPOS}" ] || {
CUSTOM_REPOS=$(sed -e 's/$arch\b/\\$arch/g' -e 's/$repo\b/\\$repo/g' <<< ${CUSTOM_REPOS})
[[ ${CUSTOM_REPOS} =~ '$' ]] && eval export CUSTOM_REPOS=${CUSTOM_REPOS}
add_custom_repos
}

pacman --sync --refresh --sysupgrade --needed --noconfirm --disable-download-timeout base-devel rclone git
[ -f /etc/default/useradd ] && {
DEFAULT_GROUP=$(grep -Po "^GROUP=\K\S+" /etc/default/useradd)
grep -Pq "^${DEFAULT_GROUP}:" /etc/group || groupadd "${DEFAULT_GROUP}"
}
grep -Pq "^alarm:" /etc/group || groupadd "alarm"
grep -Pq "^alarm:" /etc/passwd || useradd -m "alarm" -s "/bin/bash" -g "alarm"
chown -R alarm:alarm ${GITHUB_WORKSPACE}
RCLONE_CONFIG_PATH=$(rclone config file | tail -n1)
mkdir -pv $(dirname ${RCLONE_CONFIG_PATH})
[ $(awk 'END{print NR}' <<< "${RCLONE_CONF}") == 1 ] &&
base64 --decode <<< "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH} ||
printf "${RCLONE_CONF}" > ${RCLONE_CONFIG_PATH}
import_pgp_seckey
success 'The build environment is ready successfully.'
# Build
execute 'Building packages' build_package
execute "Generating package signature" create_package_signature
success 'All packages built successfully'
execute "Deploying artifacts" deploy_artifacts
create_mail_message
success 'All artifacts have been deployed successfully'
