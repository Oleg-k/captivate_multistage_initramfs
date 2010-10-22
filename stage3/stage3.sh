#!/bin/sh
PATH=/bin:/sbin:/usr/bin/:/usr/sbin:/system/bin:/system/sbin
set -x
status=0
data_partition="/dev/block/mmcblk0p2"
sdcard_partition="/dev/block/mmcblk0p1"
sdcard_ext_partition="/dev/block/mmcblk1"
sdcard='/sdcard'
sdcard_ext='/sdcard/sdcard_ext'
data_archive="$sdcard/user-data.tar"

dbdata_partition="/dev/block/stl10"

alias check_dbdata="fsck_msdos -y $dbdata_partition"
alias make_backup="tar cvf $data_archive /data /dbdata"

mount_() {
    case $1 in
	cache)
	    mount -t rfs -o nosuid,nodev,check=no /dev/block/stl11 /cache
	    ;;
	dbdata)
	    mount -t rfs -o nosuid,nodev,check=no $dbdata_partition /dbdata
	    ;;
	data_rfs)
	    mount -t rfs -o nosuid,nodev,check=no $data_partition /data
	    ;;
	data_ext4)
	    mount -t ext4 -o noatime,nodiratime,barrier=0,noauto_da_alloc $data_partition /data
	    ;;
	sdcard)
	    mount -t vfat -o utf8 $sdcard_partition $sdcard
	    ;;
	sdcard_ext)
	    mount -t vfat -o utf8 $sdcard_ext_partition $sdcard_ext
	    ;;
    esac
}

log() {
    log="stage3.sh: $1"
    echo -e "\n  ###  $log\n" >> /stage3.log
    echo `date '+%Y-%m-%d %H:%M:%S'` $log >> /stage3.log
}

check_free() {
    # FIXME: add the check if we have enough space based on the
    # space lost with Ext4 conversion with offset
	
    # read free space on internal SD
    target_free=`df $sdcard | cut -d' ' -f 6 | cut -d K -f 1`

    # read space used by data we need to save
    mount
    df /data
    df /dbdata
    space_needed=$((`df /data | cut -d' ' -f 4 | cut -d K -f 1` + \
	`df /dbdata | cut -d' ' -f 4 | cut -d K -f 1`))

    log "free space : $target_free"
    log "space needed : $space_needed"
    
    # more than 100MB on /data, talk to the user
    test $data_space_needed -gt 102400 && say "wait"

    # FIXME: get a % of security
    test $target_free -ge $space_needed
}

wipe_data_filesystem() {
    # ext4 is very hard to wipe due to it's superblock which provide
    # much security, so we wipe the start of the partition (3MB)
    # wich does enouch to prevent blkid to detect Ext4.
    # RFS is also seriously hit by 3MB of zeros ;)
    dd if=/dev/zero of=$data_partition bs=1024 count=$((3 * 1024))
    sync
}

restore_backup() {
    # clean any previous false dbdata partition
    rm -r /dbdata/*
    umount /dbdata
    check_dbdata
    mount_ dbdata
    # extract from the backup,
    # with dirty workaround to fix battery level inaccuracy
    # then remove the backup file if everything went smooth
    tar xvf $data_archive && rm $data_archive
    rm /data/system/batterystats.bin
}

say() {
    # play !
    madplay -A -4 -o wave:- "/res/voices/$1.mp3" | \
	aplay -Dpcm.AndroidPlayback_Speaker --buffer-size=4096
}

ext4_check() {
    log "ext4 filesystem detection"
    if /usr/sbin/tune2fs -l $data_partition; then
	# we found an ext2/3/4 partition. but is it real ?
	# if the data partition mounts as rfs, it means
	# that this ext4 partition is just lost bits still here
	if mount_ data_rfs; then
	    log "ext4 bits found but from an invalid and corrupted filesystem"
	    return 1
	fi
	log "ext4 filesystem detected"
	return 0
    fi
    log "no ext4 filesystem detected"
    return 1
}

install_scripts() {
    if ! cmp /res/scripts/fat.format_wrapper.sh /system/bin/fat.format_wrapper.sh; then

	if ! test -L /system/bin/fat.format; then

	    # if fat.format is not a symlink, it means that it's
	    # Samsung's binary. Let's rename it
	    mv /system/bin/fat.format /system/bin/fat.format.real
	    log "fat.format renamed to fat.format.real"
	fi

	cat /res/scripts/fat.format_wrapper.sh > /system/bin/fat.format_wrapper.sh
	chmod 755 /system/bin/fat.format_wrapper.sh

	ln -s /system/bin/fat.format_wrapper.sh /system/bin/fat.format
	log "fat.format wrapper installed"
    else
	log "fat.format wrapper already installed"
    fi
}

letsgo() {
    # paranoid security: prevent any data leak
    test -f $data_archive && rm -v $data_archive

    install_scripts

    # remove voices from memory
    rm -r /res/voices

    rm -r /etc
    rm -r /usr
    rm /lib/* # remove the libs we installed, leave modules

    exit $status
}

do_rfs() {
    if ext4_check; then
	log "lag fix disabled and Ext4 detected"
	# ext4 partition detected, let's convert it back to rfs :'(
	# mount resources
	mount_ data_ext4
	mount_ dbdata
	say "to-rfs"

	log "run backup of Ext4 /data"
	
	# check if there is enough free space for migration or cancel
	# and boot
	if ! check_free; then
	    log "not enough space to migrate from ext4 to rfs"
	    say "cancel-no-replace"
	    mount_ data_ext4
	    status=1
	    return $status
	fi

	say "step1"&
	make_backup
	
	# umount data because we will wipe it
	/sbin/umount /data

	# wipe Ext4 filesystem
	log "wipe Ext4 filesystem before formating $data_partition as RFS"
	wipe_data_filesystem

	# format as RFS
	# for some obsure reason, fat.format really won't want to
	# work in this pre-init. That's why we use an alternative technique
	/sbin/zcat /res/configs/rfs_filesystem_data_16GB.gz > $data_partition
	fsck_msdos -y $data_partition

	# restore the data archived
	log "restore backup on rfs /data"
	say "step2"
	mount_ data_rfs
	restore_backup
	
	/bin/umount /dbdata
	say "success"

	status=0

    else
	# in this case, we did not detect any valid ext4 partition
	# hopefully this is because $data_partition contains a valid rfs /data
	log "lag fix disabled, rfs present"
	log "mount /data as rfs"
	mount_ data_rfs
	status=0
    fi

    return $status
}

do_lagfix()
{
    if ! ext4_check ; then
	log "no ext4 partition detected"
	
	# mount ressources we need
	log "mount resources to backup"
	say "to-ext4"
	mount_ data_rfs
	mount_ dbdata

	# check if there is enough free space for migration or cancel
	# and boot
	if ! check_free; then
		log "not enough space to migrate from rfs to ext4"
		say "cancel-no-space"
		mount_ data_rfs
		umount /dbdata
		status=1
		return $status
	fi

	# run the backup operation
	log "run the backup operation"
	make_backup
	
	# umount mmcblk0 ressources
	umount /sdcard
	umount /data
	umount /dbdata

	# build the ext4 filesystem
	log "build the ext4 filesystem"
	
	# Ext4 DATA 
	# (empty) /etc/mtab is required for this mkfs.ext4
	cat /etc/mke2fs.conf
	/usr/sbin/mkfs.ext4 -F -O sparse_super $data_partition
	# force check the filesystem after 100 mounts or 100 days
	/usr/sbin/tune2fs -c 100 -i 100d -m 0 $data_partition

	mount_ data_ext4
	mount_ dbdata

	mount_ sdcard

	# restore the data archived
	say "step2"
	restore_backup

	# clean all these mounts but leave /data mounted
	log "umount what will be re-mounted by Samsung's Android init"
	umount /dbdata
	umount /sdcard
	say "success"
	status=0
    else
	# seems that we have a ext4 partition ;) just mount it
	log "protected ext4 detected, mounting ext4 /data !"
	/usr/sbin/e2fsck -p $data_partition

	#leave /data mounted
	mount_ data_ext4
	status=0
    fi

    return $status
}

create_devices() {
    mkdir -p /dev/snd

    # soundcard
    mknod /dev/snd/controlC0 c 116 0
    mknod /dev/snd/controlC1 c 116 32
    mknod /dev/snd/pcmC0D0c c 116 24
    mknod /dev/snd/pcmC0D0p c 116 16
    mknod /dev/snd/pcmC1D0c c 116 56
    mknod /dev/snd/pcmC1D0p c 116 48
    mknod /dev/snd/timer c 116 33

    # we will need these directories
    mkdir -p /cache 2> /dev/null
    mkdir -p /dbdata 2> /dev/null 
    mkdir -p /data 2> /dev/null 

    # copy the sound configuration
    cat /system/etc/asound.conf > /etc/asound.conf
}

insert_modules() {
    # insert the ext4 modules
    insmod /lib/modules/jbd2.ko
    insmod /lib/modules/ext4.ko
}

create_devices

insert_modules

# detect the MASTER_CLEAR intent command
# this append when you choose to wipe everything from the phone settings,
# or when you type *2767*3855# (Factory Reset, datas + SDs wipe)
mount_ cache
if test -f /cache/recovery/command; then

    if test `cat /cache/recovery/command | cut -d '-' -f 3` = 'wipe_data'; then
	log "MASTER_CLEAR mode"
	say "factory-reset"

	# if we are in this mode, we still have to wipe ext4 partition start
	wipe_data_filesystem
	umount /cache
	letsgo
    fi
fi
umount /cache

mount_ sdcard
if test -e $sdcard/init/disable-lagfix; then
    do_rfs
else
    do_lagfix
fi

letsgo

exit $status
