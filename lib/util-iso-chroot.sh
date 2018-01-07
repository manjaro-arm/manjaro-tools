#!/bin/bash
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

copy_overlay(){
    local src="$1" dest="$2"
    if [[ -e $src ]];then
        msg2 "Copying [%s] ..." "${src##*/}"
        if [[ -L $src ]];then
            cp -a --no-preserve=ownership $src/* $dest
        else
            cp -LR $src/* $dest
        fi
    fi
}

add_svc_rc(){
    local mnt="$1" name="$2"
    if [[ -f $mnt/etc/init.d/$name ]];then
        msg2 "Setting %s ..." "$name"
        chroot $mnt rc-update add $name default &>/dev/null
    fi
}

add_svc_sd(){
    local mnt="$1" name="$2"
    if [[ -f $mnt/etc/systemd/system/$name.service ]] || \
    [[ -f $mnt/usr/lib/systemd/system/$name.service ]];then
        msg2 "Setting %s ..." "$name"
        chroot $mnt systemctl enable $name &>/dev/null
    fi
}

set_xdm(){
    if [[ -f $1/etc/conf.d/xdm ]];then
        local conf='DISPLAYMANAGER="'${displaymanager}'"'
        sed -i -e "s|^.*DISPLAYMANAGER=.*|${conf}|" $1/etc/conf.d/xdm
    fi
}

configure_mhwd_drivers(){
    local path=$1${mhwd_repo}/ \
        drv_path=$1/var/lib/mhwd/db/pci/graphic_drivers
    info "Configuring mwwd db ..."
    if  [ -z "$(ls $path | grep catalyst-utils 2> /dev/null)" ]; then
        msg2 "Disabling Catalyst driver"
        mkdir -p $drv_path/catalyst/
        touch $drv_path/catalyst/MHWDCONFIG
    fi
    if  [ -z "$(ls $path | grep nvidia-utils 2> /dev/null)" ]; then
        msg2 "Disabling Nvidia driver"
        mkdir -p $drv_path/nvidia/
        touch $drv_path/nvidia/MHWDCONFIG
        msg2 "Disabling Nvidia Bumblebee driver"
        mkdir -p $drv_path/hybrid-intel-nvidia-bumblebee/
        touch $drv_path/hybrid-intel-nvidia-bumblebee/MHWDCONFIG
    fi
    if  [ -z "$(ls $path | grep nvidia-304xx-utils 2> /dev/null)" ]; then
        msg2 "Disabling Nvidia 304xx driver"
        mkdir -p $drv_path/nvidia-304xx/
        touch $drv_path/nvidia-304xx/MHWDCONFIG
    fi
    if  [ -z "$(ls $path | grep nvidia-340xx-utils 2> /dev/null)" ]; then
        msg2 "Disabling Nvidia 340xx driver"
        mkdir -p $drv_path/nvidia-340xx/
        touch $drv_path/nvidia-340xx/MHWDCONFIG
    fi
    if  [ -z "$(ls $path | grep xf86-video-amdgpu 2> /dev/null)" ]; then
        msg2 "Disabling AMD gpu driver"
        mkdir -p $drv_path/xf86-video-amdgpu/
        touch $drv_path/xf86-video-amdgpu/MHWDCONFIG
    fi
}

configure_hosts(){
    sed -e "s|localhost.localdomain|localhost.localdomain ${hostname}|" -i $1/etc/hosts
}

configure_lsb(){
    local conf=$1/etc/lsb-release
    if [[ -e $conf ]] ; then
        msg2 "Configuring lsb-release"
        sed -i -e "s/^.*DISTRIB_RELEASE.*/DISTRIB_RELEASE=${dist_release}/" $conf
        sed -i -e "s/^.*DISTRIB_CODENAME.*/DISTRIB_CODENAME=${dist_codename}/" $conf
    fi
}

configure_logind(){
    msg2 "Configuring logind ..."
    local conf=$1/etc/$2/logind.conf
    if [[ -e $conf ]];then
        sed -i 's/#\(HandleSuspendKey=\)suspend/\1ignore/' "$conf"
        sed -i 's/#\(HandleLidSwitch=\)suspend/\1ignore/' "$conf"
        sed -i 's/#\(HandleHibernateKey=\)hibernate/\1ignore/' "$conf"
    fi
}

configure_journald(){
    msg2 "Configuring journald ..."
    local conf=$1/etc/systemd/journald.conf
    sed -i 's/#\(Storage=\)auto/\1volatile/' "$conf"
}

configure_services(){
    local mnt="$1"
    info "Configuring [%s]" "${initsys}"
    case ${initsys} in
        'openrc')
            for svc in ${enable_openrc[@]}; do
                [[ $svc == "xdm" ]] && set_xdm "$mnt"
                add_svc_rc "$mnt" "$svc"
            done
            for svc in ${enable_openrc_live[@]}; do
                add_svc_rc "$mnt" "$svc"
            done
        ;;
        'systemd')
            for svc in ${enable_systemd[@]}; do
                add_svc_sd "$mnt" "$svc"
            done
            for svc in ${enable_systemd_live[@]}; do
                add_svc_sd "$mnt" "$svc"
            done
        ;;
    esac
    info "Done configuring [%s]" "${initsys}"
}

write_live_session_conf(){
    local path=$1${SYSCONFDIR}
    [[ ! -d $path ]] && mkdir -p $path
    local conf=$path/live.conf
    msg2 "Writing %s" "${conf##*/}"
    echo '# live session configuration' > ${conf}
    echo '' >> ${conf}
    echo '# autologin' >> ${conf}
    echo "autologin=${autologin}" >> ${conf}
    echo '' >> ${conf}
    echo '# login shell' >> ${conf}
    echo "login_shell=${login_shell}" >> ${conf}
    echo '' >> ${conf}
    echo '# live username' >> ${conf}
    echo "username=${username}" >> ${conf}
    echo '' >> ${conf}
    echo '# live password' >> ${conf}
    echo "password=${password}" >> ${conf}
    echo '' >> ${conf}
    echo '# live group membership' >> ${conf}
    echo "addgroups='${addgroups}'" >> ${conf}
    if [[ -n ${smb_workgroup} ]];then
        echo '' >> ${conf}
        echo '# samba workgroup' >> ${conf}
        echo "smb_workgroup=${smb_workgroup}" >> ${conf}
    fi
}

configure_system(){
    local mnt="$1"
    case ${initsys} in
        'systemd')
            configure_logind "$mnt" "systemd"
            configure_journald "$mnt"

            # Prevent some services to be started in the livecd
            echo 'File created by manjaro-tools. See systemd-update-done.service(8).' \
            | tee "${path}/etc/.updated" >"${path}/var/.updated"

            msg2 "Disable systemd-gpt-auto-generator"
            ln -sf /dev/null "${path}/usr/lib/systemd/system-generators/systemd-gpt-auto-generator"
        ;;
        'openrc')
            configure_logind "$mnt" "elogind"
        ;;
    esac
    echo ${hostname} > $mnt/etc/hostname
}

make_repo(){
    local dest="$1"
    cp ${DATADIR}/pacman-mhwd.conf $dest/opt
    repo-add $dest${mhwd_repo}/mhwd.db.tar.gz $dest${mhwd_repo}/*pkg*z
}

clean_iso_root(){
    local dest="$1"
    msg2 "Deleting isoroot [%s] ..." "${dest##*/}"
    rm -rf --one-file-system "$dest"
}

clean_up_image(){

    local path mnt="$1"
    msg2 "Cleaning [%s]" "${mnt##*/}"
    if [[ ${1##*/} == 'mhwdfs' ]];then
        path=$mnt/var
        if [[ -d $path ]];then
            find "$path" -mindepth 0 -delete &> /dev/null
        fi
        path=$mnt/etc
        if [[ -d $path ]];then
            find "$path" -mindepth 0 -delete &> /dev/null
        fi
    else
        [[ -f "$mnt/etc/locale.gen.bak" ]] && mv "$mnt/etc/locale.gen.bak" "$mnt/etc/locale.gen"
        [[ -f "$mnt/etc/locale.conf.bak" ]] && mv "$mnt/etc/locale.conf.bak" "$mnt/etc/locale.conf"
        path=$mnt/boot
        if [[ -d "$path" ]]; then
            find "$path" -name 'initramfs*.img' -delete &> /dev/null
        fi
        path=$mnt/var/lib/pacman/sync
        if [[ -d $path ]];then
            find "$path" -type f -delete &> /dev/null
        fi
        path=$mnt/var/cache/pacman/pkg
        if [[ -d $path ]]; then
            find "$path" -type f -delete &> /dev/null
        fi
        path=$mnt/var/log
        if [[ -d $path ]]; then
            find "$path" -type f -delete &> /dev/null
        fi
        path=$mnt/var/tmp
        if [[ -d $path ]];then
            find "$path" -mindepth 1 -delete &> /dev/null
        fi
        path=$mnt/tmp
        if [[ -d $path ]];then
            find "$path" -mindepth 1 -delete &> /dev/null
        fi

        if [[ ${mnt##*/} == 'livefs' ]];then
            rm -rf "$mnt/etc/pacman.d/gnupg"
        fi
    fi

    find "$mnt" -name *.pacnew -name *.pacsave -name *.pacorig -delete
    file=$mnt/boot/grub/grub.cfg
    if [[ -f "$file" ]]; then
        rm $file
    fi
}

copy_from_cache(){
    local list="${tmp_dir}"/mhwd-cache.list mirror="${build_mirror}/${target_branch}"
    local mnt="$1"; shift
    chroot-run -B "$mirror" "$mnt" \
        pacman -v -Syw --noconfirm "$@" || return 1
    chroot-run -B "$mirror" "$mnt" \
        pacman -v -Sp --noconfirm "$@" > "$list"
    sed -ni '/.pkg.tar.xz/p' "$list"
    sed -i "s/.*\///" "$list"

    msg2 "Copying mhwd package cache ..."
    rsync -v --files-from="$list" /var/cache/pacman/pkg "$mnt${mhwd_repo}"
}

chroot_clean(){
    local dest="$1"
    for root in "$dest"/*; do
        [[ -d ${root} ]] || continue
        local name=${root##*/}
        if [[ $name != "mhwdfs" ]];then
#             lock 9 "$name.lock" "Locking chroot copy [%s]" "$name"
            delete_chroot "${root}" "$dest"
        fi
    done

    rm -rf --one-file-system "$dest"
}

prepare_initcpio(){
    msg2 "Copying initcpio ..."
    local dest="$1"
    cp /etc/initcpio/hooks/miso* $dest/etc/initcpio/hooks
    cp /etc/initcpio/install/miso* $dest/etc/initcpio/install
    cp /etc/initcpio/miso_shutdown $dest/etc/initcpio
}

prepare_initramfs(){
    local mnt="$1"
    cp ${DATADIR}/mkinitcpio.conf $mnt/etc/mkinitcpio-${iso_name}.conf
    local _kernver=$(cat $mnt/usr/lib/modules/*/version)
    if [[ -n ${gpgkey} ]]; then
        su ${OWNER} -c "gpg --export ${gpgkey} >${MT_USERCONFDIR}/gpgkey"
        exec 17<>${MT_USERCONFDIR}/gpgkey
    fi
    MISO_GNUPG_FD=${gpgkey:+17} chroot-run $mnt \
        /usr/bin/mkinitcpio -k ${_kernver} \
        -c /etc/mkinitcpio-${iso_name}.conf \
        -g /boot/initramfs.img

    if [[ -n ${gpgkey} ]]; then
        exec 17<&-
    fi
    if [[ -f ${MT_USERCONFDIR}/gpgkey ]]; then
        rm ${MT_USERCONFDIR}/gpgkey
    fi
}

prepare_boot_extras(){
    local src="$1" dest="$2"
    cp $src/boot/intel-ucode.img $dest/intel_ucode.img
    cp $src/usr/share/licenses/intel-ucode/LICENSE $dest/intel_ucode.LICENSE
    cp $src/boot/memtest86+/memtest.bin $dest/memtest
    cp $src/usr/share/licenses/common/GPL2/license.txt $dest/memtest.COPYING
}

prepare_grub(){
    local platform=i386-pc img='core.img' grub=$3/boot/grub efi=$3/efi/boot \
        lib=$1/usr/lib/grub prefix=/boot/grub theme=$2/usr/share/grub data=$1/usr/share/grub

    prepare_dir ${grub}/${platform}

    cp ${theme}/cfg/*.cfg ${grub}

    cp ${lib}/${platform}/* ${grub}/${platform}

    msg2 "Building %s ..." "${img}"

    grub-mkimage -d ${grub}/${platform} -o ${grub}/${platform}/${img} -O ${platform} -p ${prefix} biosdisk iso9660

    cat ${grub}/${platform}/cdboot.img ${grub}/${platform}/${img} > ${grub}/${platform}/eltorito.img

    case ${target_arch} in
        'i686')
            platform=i386-efi
            img=bootia32.efi
        ;;
        'x86_64')
            platform=x86_64-efi
            img=bootx64.efi
        ;;
    esac

    prepare_dir ${efi}
    prepare_dir ${grub}/${platform}

    cp ${lib}/${platform}/* ${grub}/${platform}

    msg2 "Building %s ..." "${img}"

    grub-mkimage -d ${grub}/${platform} -o ${efi}/${img} -O ${platform} -p ${prefix} iso9660

    prepare_dir ${grub}/themes
    cp -r ${theme}/themes/${iso_name}-live ${grub}/themes/
    cp ${data}/unicode.pf2 ${grub}
    cp -r ${theme}/{locales,tz} ${grub}

    local size=4M mnt="${mnt_dir}/efiboot" efi_img="$3/efi.img"
    msg2 "Creating fat image of %s ..." "${size}"
    truncate -s ${size} "${efi_img}"
    mkfs.fat -n MISO_EFI "${efi_img}" &>/dev/null
    prepare_dir "${mnt}"
    mount_img "${efi_img}" "${mnt}"
    prepare_dir ${mnt}/efi/boot
    msg2 "Building %s ..." "${img}"
    grub-mkimage -d ${grub}/${platform} -o ${mnt}/efi/boot/${img} -O ${platform} -p ${prefix} iso9660
    umount_img "${mnt}"
}
