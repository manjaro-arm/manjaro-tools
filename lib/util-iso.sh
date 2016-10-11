#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

import ${LIBDIR}/util-iso-image.sh
import ${LIBDIR}/util-iso-boot.sh
import ${LIBDIR}/util-yaml.sh

error_function() {
    if [[ -p $logpipe ]]; then
        rm "$logpipe"
    fi
    # first exit all subshells, then print the error
    if (( ! BASH_SUBSHELL )); then
        error "A failure occurred in %s()." "$1"
        plain "Aborting..."
    fi
    umount_image
    exit 2
}

# $1: function
run_log(){
    local func="$1"
    local tmpfile=${tmp_dir}/$func.ansi.log logfile=${log_dir}/$(gen_iso_fn).$func.log
    logpipe=$(mktemp -u "${tmp_dir}/$func.pipe.XXXXXXXX")
    mkfifo "$logpipe"
    tee "$tmpfile" < "$logpipe" &
    local teepid=$!
    $func &> "$logpipe"
    wait $teepid
    rm "$logpipe"
    cat $tmpfile | perl -pe 's/\e\[?.*?[\@-~]//g' > $logfile
    rm "$tmpfile"
}

run_safe() {
    local restoretrap func="$1"
    set -e
    set -E
    restoretrap=$(trap -p ERR)
    trap 'error_function $func' ERR

    if ${verbose};then
        run_log "$func"
    else
        "$func"
    fi

    eval $restoretrap
    set +E
    set +e
}

trap_exit() {
    local sig=$1; shift
    error "$@"
    umount_image
    trap -- "$sig"
    kill "-$sig" "$$"
}

# $1: image path
make_sfs() {
    if [[ ! -d "$1" ]]; then
        error "$1 is not a directory"
        retrun 1
    fi
    local timer=$(get_timer) path=${iso_root}/${iso_name}/${target_arch}
    local name=${1##*/}
    local sq_img="${path}/$name.sfs"
    mkdir -p ${path}
    msg "Generating SquashFS image for %s" "${1}"
    if [[ -f "${sq_img}" ]]; then
        local has_changed_dir=$(find ${1} -newer ${sq_img})
        msg2 "Possible changes for %s ..." "${1}"  >> ${tmp_dir}/buildiso.debug
        msg2 "%s" "${has_changed_dir}" >> ${tmp_dir}/buildiso.debug
        if [[ -n "${has_changed_dir}" ]]; then
            msg2 "SquashFS image %s is not up to date, rebuilding..." "${sq_img}"
            rm "${sq_img}"
        else
            msg2 "SquashFS image %s is up to date, skipping." "${sq_img}"
            return
        fi
    fi

    msg2 "Creating SquashFS image. This may take some time..."
    local used_kernel=${kernel:5:1} mksfs_args=(${1} ${sq_img} -noappend)
    local highcomp="-b 256K -Xbcj x86"
    [[ "${iso_compression}" != "xz" ]] && highcomp=""

    if [[ "$name" == "mhwdfs" && ${used_kernel} < "4" ]]; then
        mksfs_args+=(-comp lz4)
        if ${verbose};then
            mksquashfs "${mksfs_args[@]}" >/dev/null
        else
            mksquashfs "${mksfs_args[@]}"
        fi
    else
        mksfs_args+=(-comp ${iso_compression} ${highcomp})
        if ${verbose};then
            mksquashfs "${mksfs_args[@]}" >/dev/null
        else
            mksquashfs "${mksfs_args[@]}"
        fi
    fi

    show_elapsed_time "${FUNCNAME}" "${timer_start}"
}

mount_persistentfs() {
    mkdir -p "${work_dir}/mnt/cowfs"
    info "Mounting %s on %s" "${work_dir}/cowfs.img" "${work_dir}/mnt/cowfs"
    mount "${work_dir}/cowfs.img" "${work_dir}/mnt/cowfs"
}

umount_persistentfs() {
    info "Unmounting %s" "${work_dir}/mnt/cowfs"
    umount -d "${work_dir}/mnt/cowfs"
    rm -r "${work_dir}/mnt/cowfs"
}

# Makes a ext4 filesystem inside a SquashFS from a source directory.
make_persistent_img () {
    msg "Creating ext4 image of 32GiB..."
    truncate -s 32G "${work_dir}/cowfs.img"
    local _qflag=""
    if ${verbose}; then
        _qflag="-q"
    fi
    mkfs.ext4 ${_qflag} -O ^has_journal,^resize_inode -E lazy_itable_init=0 -m 0 -F "${work_dir}/cowfs.img"
    tune2fs -c 0 -i 0 "${work_dir}/cowfs.img" &> /dev/null
    mount_persistentfs
    msg2 "Copying %s to %s..." "${work_dir}/cowfs/" "${work_dir}/mnt/cowfs/"
    cp -aT "${work_dir}/cowfs/" "${work_dir}/mnt/cowfs/"
    umount_persistentfs
    make_sfs "${work_dir}/cowfs.img"
    rm ${work_dir}/cowfs.img
}

assemble_iso(){
    msg "Creating ISO image..."
    local efi_boot_args=()
    if [[ -f "${iso_root}/EFI/miso/efiboot.img" ]]; then
        msg2 "Setting efi args. El Torito detected."
        efi_boot_args=("-eltorito-alt-boot"
                "-e EFI/miso/efiboot.img"
                "-isohybrid-gpt-basdat"
                "-no-emul-boot")
    fi

    xorriso -as mkisofs \
        -iso-level 3 -rock -joliet \
        -max-iso9660-filenames -omit-period \
        -omit-version-number \
        -relaxed-filenames -allow-lowercase \
        -volid "${iso_label}" \
        -appid "${iso_app_id}" \
        -publisher "${iso_publisher}" \
        -preparer "Prepared by manjaro-tools/${0##*/}" \
        -eltorito-boot syslinux/isolinux.bin \
        -eltorito-catalog syslinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${iso_root}/syslinux/isohdpfx.bin" \
        ${efi_boot_args[@]} \
        -output "${iso_dir}/${iso_file}" \
        "${iso_root}/"
}

# Build ISO
make_iso() {
    msg "Start [Build ISO]"
    touch "${iso_root}/.miso"
    for d in $(find "${work_dir}" -maxdepth 1 -type d); do
        if [[ "$d" != "${work_dir}" ]]; then
            make_sfs "$d"
        fi
    done

    msg "Making bootable image"
    # Sanity checks
    [[ ! -d "${iso_root}" ]] && return 1
    if [[ -f "${iso_dir}/${iso_file}" ]]; then
        msg2 "Removing existing bootable image..."
        rm -rf "${iso_dir}/${iso_file}"
    fi
    assemble_iso
    msg "Done [Build ISO]"
}

gen_iso_fn(){
    local vars=() name
    vars+=("${iso_name}")
    if ! ${chrootcfg};then
        [[ -n ${profile} ]] && vars+=("${profile}")
    fi
    [[ ${initsys} == 'openrc' ]] && vars+=("${initsys}")
    vars+=("${dist_release}")
    vars+=("${target_branch}")
    vars+=("${target_arch}")
    for n in ${vars[@]};do
        name=${name:-}${name:+-}${n}
    done
    echo $name
}

reset_pac_conf(){
    info "Restoring [%s/etc/pacman.conf] ..." "$1"
    sed -e 's|^.*HoldPkg.*|HoldPkg      = pacman glibc manjaro-system|' \
        -e "s|^.*#CheckSpace|CheckSpace|" \
        -i "$1/etc/pacman.conf"
}

# Base installation (rootfs)
make_image_root() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Base installation] (rootfs)"
        local path="${work_dir}/rootfs"
        mkdir -p ${path}

        chroot_create "${path}" "${packages}" || die

        pacman -Qr "${path}" > "${path}/rootfs-pkgs.txt"
        copy_overlay "${profile_dir}/root-overlay" "${path}"

        reset_pac_conf "${path}"

        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Base installation] (rootfs)"
    fi
}

make_image_custom() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Desktop installation] (%s-image)" "${profile}"
        local path="${work_dir}/desktop-image"
        mkdir -p ${path}

        mount_image "${path}"

        chroot_create "${path}" "${packages}"

        pacman -Qr "${path}" > "${path}/desktop-image-pkgs.txt"
        cp "${path}/desktop-image-pkgs.txt" ${iso_dir}/$(gen_iso_fn)-pkgs.txt
        [[ -e ${profile_dir}/${profile}-overlay ]] && copy_overlay "${profile_dir}/${profile}-overlay" "${path}"

        reset_pac_conf "${path}"

        umount_image
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Desktop installation] (%s-image)" "${profile}"
    fi
}

mount_image_select(){
    if [[ -f "${packages_custom}" ]]; then
        mount_image_custom "$1"
    else
        mount_image "$1"
    fi
}

make_image_live() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [Live installation] (livefs)"
        local path="${work_dir}/livefs"
        mkdir -p ${path}

        mount_image_select "${path}"

        chroot_create "${path}" "${packages}"

        pacman -Qr "${path}" > "${path}/livefs-pkgs.txt"
        copy_overlay "${profile_dir}/live-overlay" "${path}"
        configure_live_image "${path}"

        reset_pac_conf "${path}"

        umount_image

        # Clean up GnuPG keys
        rm -rf "${path}/etc/pacman.d/gnupg"
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [Live installation] (livefs)"
    fi
}

make_image_mhwd() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [drivers repository] (mhwdfs)"
        local path="${work_dir}/mhwdfs"
        mkdir -p ${path}${mhwd_repo}

        mount_image_select "${path}"

        reset_pac_conf "${path}"

        copy_from_cache "${path}" "${packages}"

        if [[ -n "${packages_cleanup}" ]]; then
            for mhwd_clean in ${packages_cleanup}; do
                rm ${path}${mhwd_repo}/${mhwd_clean}
            done
        fi
        cp ${DATADIR}/pacman-mhwd.conf ${path}/opt
        make_repo "${path}"
        configure_mhwd_drivers "${path}"

        umount_image
        clean_up_image "${path}"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [drivers repository] (mhwdfs)"
    fi
}

make_image_boot() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [/iso/%s/boot]" "${iso_name}"
        local path_iso="${iso_root}/${iso_name}/boot"
        mkdir -p ${path_iso}/${target_arch}
        cp ${work_dir}/rootfs/boot/memtest86+/memtest.bin ${path_iso}/${target_arch}/memtest
        cp ${work_dir}/rootfs/boot/vmlinuz* ${path_iso}/${target_arch}/vmlinuz
        local path="${work_dir}/boot-image"
        mkdir -p ${path}

        mount_image_live "${path}"
        configure_plymouth "${path}"

        copy_initcpio "${profile_dir}" "${path}"

        gen_boot_image "${path}"

        mv ${path}/boot/initramfs.img ${path_iso}/${target_arch}/initramfs.img
        [[ -f ${path}/boot/intel-ucode.img ]] && copy_ucode "${path}" "${path_iso}"

        umount_image

        rm -R ${path}
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [/iso/%s/boot]" "${iso_name}"
    fi
}

# Prepare /EFI
make_efi_usb() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [/iso/EFI]"
        prepare_efi_loader  "${work_dir}/livefs" "${iso_root}" "usb"
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [/iso/EFI]"
    fi
}

# Prepare kernel.img::/EFI for "El Torito" EFI boot mode
make_efi_dvd() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [/efiboot/EFI]"
        local miso=${iso_root}/EFI/miso
        mkdir -p ${miso}
        truncate -s 31M ${miso}/efiboot.img
        mkfs.fat -n MISO_EFI ${miso}/efiboot.img
        mkdir -p ${work_dir}/efiboot
        mount ${miso}/efiboot.img ${work_dir}/efiboot

        prepare_efiboot_image "${work_dir}" "${iso_root}"

        prepare_efi_loader "${work_dir}/livefs" "${work_dir}/efiboot" "dvd"
        umount -d ${work_dir}/efiboot
        rm -r ${work_dir}/efiboot
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [/efiboot/EFI]"
    fi
}

make_syslinux() {
    if [[ ! -e ${work_dir}/build.${FUNCNAME} ]]; then
        msg "Prepare [/iso/syslinux]"
        local syslinux=${iso_root}/syslinux
        mkdir -p ${syslinux}
        prepare_syslinux "${work_dir}/livefs" "${syslinux}"
        mkdir -p ${syslinux}/hdt
        gzip -c -9 ${work_dir}/rootfs/usr/share/hwdata/pci.ids > ${syslinux}/hdt/pciids.gz
        gzip -c -9 ${work_dir}/livefs/usr/lib/modules/*-MANJARO/modules.alias > ${syslinux}/hdt/modalias.gz
        : > ${work_dir}/build.${FUNCNAME}
        msg "Done [/iso/syslinux]"
    fi
}

check_requirements(){
    [[ -f ${run_dir}/.buildiso ]] || die "%s is not a valid iso profiles directory!" "${run_dir}"
    if ! $(is_valid_arch_iso ${target_arch});then
        die "%s is not a valid arch!" "${target_arch}"
    fi
    if ! $(is_valid_branch ${target_branch});then
        die "%s is not a valid branch!" "${target_branch}"
    fi

    if ! is_valid_init "${initsys}";then
        die "%s is not a valid init system!" "${initsys}"
    fi

    local iso_kernel=${kernel:5:1} host_kernel=$(uname -r)

    if [[ ${iso_kernel} < "4" ]] || [[ ${host_kernel%%*.} < "4" ]];then
        use_overlayfs='false'
    fi

    if ${use_overlayfs};then
        iso_fs="overlayfs"
    else
        iso_fs="aufs"
    fi
    import ${LIBDIR}/util-iso-${iso_fs}.sh
}

sign_iso(){
    su ${OWNER} -c "signfile ${iso_dir}/$1"
}

make_torrent(){
    local fn=${iso_file}.torrent
    msg2 "Creating (%s) ..." "${fn}"
    [[ -f ${iso_dir}/${fn} ]] && rm ${iso_dir}/${fn}
    mktorrent ${mktorrent_args[*]} -o ${iso_dir}/${fn} ${iso_dir}/${iso_file}
}

# $1: file
make_checksum(){
    msg "Creating [%s] sum ..." "${iso_checksum}"
    cd ${iso_dir}
    local cs=$(${iso_checksum}sum $1)
    msg2 "%s sum: %s" "${iso_checksum}" "${cs##*/}"
    echo "${cs}" > ${iso_dir}/$1.${iso_checksum}
    msg "Done [%s] sum" "${iso_checksum}"
}

compress_images(){
    local timer=$(get_timer)
    run_safe "make_iso"
    make_checksum "${iso_file}"
    ${sign} && sign_iso "${iso_file}"
    ${torrent} && make_torrent
    user_own "${iso_dir}" "-R"
    show_elapsed_time "${FUNCNAME}" "${timer}"
}

prepare_images(){
    local timer=$(get_timer)
    load_pkgs "${profile_dir}/Packages-Root"
    run_safe "make_image_root"
    if [[ -f "${packages_custom}" ]] ; then
        load_pkgs "${packages_custom}"
        run_safe "make_image_custom"
    fi
    if [[ -f ${profile_dir}/Packages-Live ]]; then
        load_pkgs "${profile_dir}/Packages-Live"
        run_safe "make_image_live"
    fi
    if [[ -f ${packages_mhwd} ]] ; then
        load_pkgs "${packages_mhwd}"
        run_safe "make_image_mhwd"
    fi
    run_safe "make_image_boot"
    run_safe "make_syslinux"
    if [[ "${target_arch}" == "x86_64" ]]; then
        run_safe "make_efi_usb"
        run_safe "make_efi_dvd"
    fi
    show_elapsed_time "${FUNCNAME}" "${timer}"
}

archive_logs(){
    local name=$(gen_iso_fn) ext=log.tar.xz src=${tmp_dir}/archives.list
    find ${log_dir} -maxdepth 1 -name "$name*.log" -printf "%f\n" > $src
    msg2 "Archiving log files [%s] ..." "$name.$ext"
    tar -cJf ${log_dir}/$name.$ext -C ${log_dir} -T $src
    msg2 "Cleaning log files ..."
    find ${log_dir} -maxdepth 1 -name "$name*.log" -delete
}

make_profile(){
    msg "Start building [%s]" "${profile}"
    ${clean_first} && chroot_clean "${work_dir}" "${iso_root}"
    if ${iso_only}; then
        [[ ! -d ${work_dir} ]] && die "Create images: buildiso -p %s -x" "${profile}"
        compress_images
        ${verbose} && archive_logs
        exit 1
    fi
    if ${images_only}; then
        prepare_images
        ${verbose} && archive_logs
        warning "Continue compress: buildiso -p %s -zc ..." "${profile}"
        exit 1
    else
        prepare_images
        compress_images
        ${verbose} && archive_logs
    fi
    reset_profile
    msg "Finished building [%s]" "${profile}"
    show_elapsed_time "${FUNCNAME}" "${timer_start}"
}

get_pacman_conf(){
    local user_conf=${profile_dir}/user-repos.conf pac_arch='default' conf
    [[ "${target_arch}" == 'x86_64' ]] && pac_arch='multilib'
    if [[ -f ${user_conf} ]];then
        info "detected: %s" "user-repos.conf"
        check_user_repos_conf "${user_conf}"
        conf=${tmp_dir}/custom-pacman.conf
        cat ${DATADIR}/pacman-$pac_arch.conf ${user_conf} > "$conf"
    else
        conf="${DATADIR}/pacman-$pac_arch.conf"
    fi
    echo "$conf"
}

gen_webseed(){
    local webseed url project=$(get_project "${edition}")
        url=${host}/project/${project}/${dist_release}/${profile}/${iso_file}

        local mirrors=('heanet' 'jaist' 'netcologne' 'iweb' 'kent')

    for m in ${mirrors[@]};do
        webseed=${webseed:-}${webseed:+,}"http://${m}.dl.${url}"
    done
    echo ${webseed}
}

load_profile(){
    conf="${profile_dir}/profile.conf"

    info "Profile: [%s]" "${profile}"

    load_profile_config "$conf"

    pacman_conf=$(get_pacman_conf)

    mirrors_conf=$(get_pac_mirrors_conf "${target_branch}")

    iso_file=$(gen_iso_fn).iso

    mkchroot_args+=(-C ${pacman_conf} -S ${mirrors_conf} -B "${build_mirror}/${target_branch}" -K)
    work_dir=${chroots_iso}/${profile}/${target_arch}

    iso_dir="${cache_dir_iso}/${edition}/${dist_release}/${profile}"

    iso_root=${chroots_iso}/${profile}/iso

    prepare_dir "${iso_dir}"
    user_own "${iso_dir}"

    mktorrent_args=(-v -p -l ${piece_size} -a ${tracker_url} -w $(gen_webseed))
}

prepare_profile(){
    profile=$1
    edition=$(get_edition ${profile})
    profile_dir=${run_dir}/${edition}/${profile}
    check_profile
    load_profile
}

build(){
    prepare_profile "$1"
    make_profile
}
