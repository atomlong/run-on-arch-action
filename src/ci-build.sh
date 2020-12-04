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

# Add CA certificates to system
add_ca_certificates()
{
[ -n "${CA_CERT_PATH}" ] || { echo "You must set CA_CERT_PATH firstly."; return 1; }
local CA_INST_PATH=/etc/ssl/certs/ca-certificates.crt
pacman -Q awk &>/dev/null || pacman -Sy --needed --noconfirm --disable-download-timeout awk
INSTALLED=$(awk 'FNR == NR {a[$0]; next} $0 in a {delete a[$0]} END {if (length(a) == 0) {print "true"} else {print "false"}}' ${CA_CERT_PATH} ${CA_INST_PATH})
[ ${INSTALLED} == "true" ] && echo "CA CERTIFICATE Exist." || (
echo "Installing CA cert of Let's Encrypt to System......"
printf "\n# Let's Encrypt Authority X3\n" >> ${CA_INST_PATH}
cat ${CA_CERT_PATH} | sed -e '/^$/d' >> ${CA_INST_PATH}
echo "Done."
)
}

# Add custom repositories to pacman
add_custom_repos()
{
[ -n "${CUSTOM_REPOS}" ] || { echo "You must set CUSTOM_REPOS firstly."; return 1; }
local repos=(${CUSTOM_REPOS//,/ })
local repo name
for repo in ${repos[@]}; do
name=$(sed -n -r 's/\[(\w+)\].*/\1/p' <<< ${repo})
[ -n "${name}" ] || continue
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
[ -d ${ARTIFACTS_PATH} ] && {
pushd ${ARTIFACTS_PATH}
for pkg in *.pkg.tar.xz; do
expect << _EOF
spawn gpg --pinentry-mode loopback -o "${pkg}.sig" -b "${pkg}"
expect {
"Enter passphrase:" {
					send "${PGP_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
done
popd
}
}

# Import pgp private key
import_pgp_seckey()
{
[ -n "${PGP_KEY_PASSWD}" ] || { echo "You must set PGP_KEY_PASSWD firstly."; return 1; } 
[ -n "${PGP_KEY}" ] || { echo "You must set PGP_KEY firstly."; return 1; }
expect << _EOF
spawn bash -c "gpg --import --pinentry-mode loopback <<< '${PGP_KEY}'"
expect {
"Enter passphrase:" {
					send "${PGP_KEY_PASSWD}\r"
					exp_continue
					}
EOF { }
}
_EOF
}

# Build package
build_package()
{
[ -n "${ARTIFACTS_PATH}" ] || { echo "You must set ARTIFACTS_PATH firstly."; return 1; } 
(source PKGBUILD
[ -n "${makedepends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${makedepends[@]}
[ -n "${depends}" ] && pacman -S --needed --noconfirm --disable-download-timeout ${depends[@]}
)
runuser -u alarm -- makepkg --noconfirm --skippgpcheck --nocheck --syncdeps --rmdeps --cleanbuild

(ls *.pkg.tar.xz &>/dev/null) && {
mkdir -pv ${ARTIFACTS_PATH}
mv -vf *.pkg.tar.xz ${ARTIFACTS_PATH}
}
}

# deploy artifacts
deploy_artifacts()
{
[ -n "${DEPLOY_PATH}" ] || { echo "You must set DEPLOY_PATH firstly."; return 1; } 
local old_pkgs pkg file
(ls ${ARTIFACTS_PATH}/*.pkg.tar.xz &>/dev/null) || { echo "Skiped, no file to deploy"; exit 0; }
pushd ${ARTIFACTS_PATH}
echo ::set-output name=pkgfile0::$(ls *.pkg.tar.xz)
for file in ${PACMAN_REPO}.{db,files}{,.tar.xz}{,.old}; do
rclone copy ${DEPLOY_PATH}/${file} ${PWD} 2>/dev/null || true
done
old_pkgs=($(repo-add "${PACMAN_REPO}.db.tar.xz" *.pkg.tar.xz | tee /dev/stderr | grep -Po "\bRemoving existing entry '\K[^']+(?=')"))
popd
for pkg in ${old_pkgs[@]}; do
for file in ${pkg}-{${PACMAN_ARCH},any}.pkg.tar.xz{,.sig}; do
rclone delete ${DEPLOY_PATH}/${file} 2>/dev/null || true
done
done
rclone copy ${ARTIFACTS_PATH} ${DEPLOY_PATH} --copy-links
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
[ -z "${CA_CERT_PATH}" ] || add_ca_certificates
[ -z "${CUSTOM_REPOS}" ] || add_custom_repos
pacman --sync --refresh --sysupgrade --needed --noconfirm --disable-download-timeout base-devel rclone expect
grep -Pq "^alarm:" /etc/group || groupadd "alarm"
grep -Pq "^alarm:" /etc/passwd || useradd -m "alarm" -s "/bin/bash" -g "alarm"
chown -R alarm:alarm ${GITHUB_WORKSPACE}
mkdir -pv ${HOME}/.config/rclone
printf "${RCLONE_CONF}" > ${HOME}/.config/rclone/rclone.conf
import_pgp_seckey
success 'The build environment is ready successfully.'
# Build
execute 'Building packages' build_package
execute "Generating package signature" create_package_signature
success 'All packages built successfully'
execute "Deploying artifacts" deploy_artifacts
success 'All artifacts have been deployed successfully'
