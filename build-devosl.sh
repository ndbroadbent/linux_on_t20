#! /bin/sh
# Title:
#    build-devosl.sh
#
# Author:
#    Karl Mowatt-Wilson
#    http://mowson.org/karl
#    copyright: 2007 Karl Mowatt-Wilson
#    licence: GPL v2
#
# Revisions:
#    v1.0 -    Apr 2007 - initial release
#    v1.1 -  6 May 2007 - minor tidying
#    v1.2 - 22 Jun 2007 - use more robust octal escapes
#                       - add test options
#            6 Jul 2007 - orthogonalise tool checking
#    v1.3 - 21 Jul 2007 - use getopts 
#    v1.4 - 25 Sep 2007 - simplify echo test to not use hd/tr
#    v1.5 - 29 Sep 2007 - specify vfat filesystem id, so md5sum of 
#                          bootp.bin is consistent

Usage () {
cat <<-EOF
	
	USAGE: 
	   build-devosl.sh [options...] 
	
	This script combines a standard WinNT Evo T20 image file with 
	DamnSmallLinux (DSL) kernel/initrd and patched grub files, to make 
	a T20 image which will boot DSL off an external USB flash drive.
	
	OPTIONS:
	   -d  Disable test of MBR end marker.  It is unlikely that this option
	       will help anyone, but there is an extremely slim possibility that
	       my marker test code fails on your machine, but the rest of the 
	       script works, in which case this option would be useful.
	
	   -f firmware
	       Specify alternate WinNT firmware file to use as base.
	       Default is "./U96CPQ163.bin"  (suits 96/128M T20)
	
	   -g grubdir
	       Specify an alternate location for grub files.
	       Default is "./grub-0.97"
	
	   -h
	       Help - show this usage display.
	
	   -i initrd
	       Specify alternate initrd file.  Grub must have been compiled
	       to use this filename too!  Default is "./minirt24.gz"
	
	   -k kernel
	       Specify alternate kernel file.  Grub must have been compiled
	       to use this filename too!  Default is "./linux24"
	
	   -l loopdevice
	       Specify alternate loop device.  Default is "/dev/loop1"
	
	   -o outputfile
	       Specify alternate output file.  Default is "./bootp.bin" 
	
	   -q qemufile
	       Specify filename to output disk image to (not done by default).
	       This image may be run by qemu, to test.
	       eg.  qemu -hda qemufile
	
	NOTES:
	   Shells:
	      This has been tested with dash and is hopefully posix compliant.
	      bash should work fine.   tcsh is completely unknown to me.
	   Extra Options:   
	     Throughout this script there are optional blocks preceded by the 
	     text "# OPTION:" and having a line which starts with true or false.
	     The true/false determines whether that block is executed or not.
	     These optional blocks may be useful for testing purposes.
	   Errors:
	     If this script fails with an error, the loop device may not be cleanly
	     detached, in which case you may need to use 'losetup -d' on it.
	
EOF
}
###########################################################################
# Default names of files to use:
T20_STANDARD_FIRMWARE="./U96CPQ163.bin"
GRUB_DIR="./grub-0.97"
KERNEL="./linux24"
INITRD="./minirt24.gz"

# IMAGE is the name of the file to create from combining the files above.
IMAGE="./bootp.bin"

# Temporary mountpoint - this will be created, and then deleted after use!
MNT="./mnt-DEvoSL.tmp"

# We need real echo for some things, rather than built-in shell echo, since
# this script needs predictable octal escape expansion.
ECHO="/bin/echo"
ECHOOPTIONS='-n -e'

# Specify which loop device to use - can't be one that is in use already!
LOOP="/dev/loop1"

###########################################################################
## Function to exit with error message.
## First param is return code, remaining params are lines of error message.
#
Fail() {
   ExitCode=$1
   shift
   echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
   echo "$(basename "$0"): FATAL ERROR" >&2
   while [ $# -gt 0 ]; do
      echo "$1" >&2
      shift
   done
   sleep 2
   TidyUp
   exit $ExitCode
}

###########################################################################
## Function to tidy up temp files/dirs before exit.
#
TidyUp() {
   echo "=== Tidying ========================================================="
   mount | grep -E "$MNT" >/dev/null && umount "$MNT"
   [ -d "$MNT" ] && rmdir "$MNT"
}

###########################################################################
## Function to check a list of desired tools are available.
#
Toolcheck() {
   while [ $# -gt 0 ]; do
      TOOL="$1"
      shift
      echo "Checking '$TOOL'"
      which "$TOOL" >/dev/null 2>/dev/null \
         || Fail 3 "'which' failed for '$TOOL' - can't find this command."
   done
}   


###########################################################################
#==========================================================================
# Parse command-line options.

MBR_TEST="TRUE"
while getopts "df:g:hi:k:l:o:q:" OPT; do
   case $OPT in
      d)   # Disable test of MBR end marker
           MBR_TEST=""
           ;;
      f)   # firmware
           T20_STANDARD_FIRMWARE="$OPTARG"
           ;;
      g)   # grub directory
           GRUB_DIR="$OPTARG"
           ;;
      h)   # Help
           Usage 
           exit 
           ;;
      i)   # initrd
           INITRD="$OPTARG"
           ;;
      k)   # kernel
           KERNEL="$OPTARG"
           ;;
      l)   # loop device
           LOOP="$OPTARG"
           ;;
      o)   # output filename
           IMAGE="$OPTARG"
           ;;
      q)   # qemu output filename
           QEMU_IMAGE="$OPTARG"
           ;;
      *)   Usage 
           exit 
           ;;
    esac
done
shift $(($OPTIND - 1)); OPTIND=1


# Warn if extra arguments supplied on command-line.
[ "$1" ] && {
   echo "WARNING: $# unused parameter(s) on commandline"
}

GRUB1="$GRUB_DIR/stage1/stage1"
GRUB2="$GRUB_DIR/stage2/stage2"

#==========================================================================
# Check that we have a hope of any of this working.

[ "$(id -u)" -eq 0 ] || {
   echo "WARNING: You don't seem to be root - this probably won't work..."
   sleep 4
   echo "Continuing anyway."
}

####################################################################
echo "=== Checking tools =================================================="
Toolcheck    \
   mount     \
   umount    \
   losetup   \
   dd        \
   mkfs.vfat \
   strings
   
# We need real echo rather than built-in shell echo, since we need
# predictable octal escape expansion
echo "Check that we can use real echo ($ECHO)."
which $ECHO >/dev/null 2>/dev/null \
   || Fail 3 "Couldn't find $ECHO"

echo "Check that echo handles octal escapes."
TESTECHO="$($ECHO $ECHOOPTIONS '\061\062\063')"
[ "$TESTECHO" = '123' ] \
   || Fail 3 "echo command ($ECHO $ECHOOPTIONS) did not perform as expected with octal escapes." \
             "Expected result to be '123'" \
             "but got               '$TESTECHO'"

grep '^loop ' /proc/modules >/dev/null 2>/dev/null || {
   echo "!!! Warning - you don't seem to have a loop module installed."
   echo "              This probably won't work...";
   sleep 4; 
   echo "Continuing anyway."
}

echo "Check that the chosen loop device exists."
ls "$LOOP" >/dev/null 2>/dev/null \
   || Fail 3 "Couldn't find loop device $LOOP" 

echo "Check/setup mount directory."
[ -e "$MNT" ] || {
   mkdir -p "$MNT" \
      || Fail 3 "Couldn't create mountpoint '$MNT'"
   chmod a+rwx "$MNT" \
      || Fail 3 "Couldn't chmod mountpoint '$MNT'"
}
[ -d "$MNT" ] \
   || Fail 3 "Mountpoint '$MNT' is not a directory."
[ -w "$MNT" ] \
   || Fail 3 "Mountpoint '$MNT' is not writable."

echo "Check source image exists and is readable."
[ -r "$T20_STANDARD_FIRMWARE" ] \
   || Fail 3 "Can't read from standard firmware '$T20_STANDARD_FIRMWARE'"

echo "Check grub stage1 and stage2 exist and are readable."
[ -r "$GRUB1" ] \
   || Fail 3 "Can't read grub stage1 '$GRUB1' - have you built it?"

[ -r "$GRUB2" ] \
   || Fail 3 "Can't read grub stage2 '$GRUB2' - have you built it?"


echo "Check kernel and initrd exist and are readable."
[ -r "$KERNEL" ] \
   || Fail 3 "Can't read kernel '$KERNEL'"
[ -r "$INITRD" ] \
   || Fail 3 "Can't read initrd '$INITRD'"


###########################################################################
echo "=== Start working ==================================================="
echo "Copying standard firmware '" \
      $T20_STANDARD_FIRMWARE      \
      "' to working file '$IMAGE'"
cp "$T20_STANDARD_FIRMWARE" "$IMAGE" \
   || Fail 3 "Couldn't copy '$T20_STANDARD_FIRMWARE'"

echo "Making image '$IMAGE' accessible by anyone."
chmod a+rw "$IMAGE" \
   || Fail 3 "Couldn't chmod '$IMAGE'"

###########################################################################
echo "Searching for WinNT Master Boot Record."
SEARCH_OFFSET=139
MBR_SEARCH=$(strings -n20 -td "$IMAGE" \
   | grep -Em1 "( )*[0-9]+( )+Invalid partition table$")
[ "$MBR_SEARCH" ] \
   || Fail 3 "Couldn't find MBR search string in image '$IMAGE'" \
             "Is this really a WinNT image file?"

MBR_SEARCH_LOCATION=$(echo "$MBR_SEARCH" | grep -Eo '[0-9]+')

DISK_START=$(( $MBR_SEARCH_LOCATION - $SEARCH_OFFSET ))

echo "Disk start set to $DISK_START"


###########################################################################
# OPTION: If you just want to loop the standard disk image so that you can 
# examine it, change 'false' in the next line to 'true', and then nothing 
# more after this block will be executed.

false && {
   losetup -o $DISK_START "$LOOP" "$IMAGE" \
      || Fail 3 "Couldn't setup loop."
   echo
   echo "Quitting with disk accessible at $LOOP"
   echo "You can now use tools like hexcurse to examine the disk, eg:"
   echo "   hexcurse $LOOP"
   echo "Use this to detach when you have finished looking at it:"
   echo "   losetup -d $LOOP "
   echo
   exit
}   


###########################################################################
# Define the location of the partition table, in case we want to edit it
MBR_PARTITION1_DD_SEEK=$(( $DISK_START + 446 ))
MBR_PARTITION2_DD_SEEK=$(( $MBR_PARTITION1_DD_SEEK + 16 ))
MBR_PARTITION3_DD_SEEK=$(( $MBR_PARTITION1_DD_SEEK + 32 ))
MBR_PARTITION4_DD_SEEK=$(( $MBR_PARTITION1_DD_SEEK + 48 ))

# Partition-type byte is 4 bytes on from beginning of partition record.
PART_TYPE_OFFSET=4

# Define where to look for the partition sector marker
# (which looks like 0x55AA at the end of the sector)
PART_ID_DD_SKIP=$(( $DISK_START + 510 ))

PART_START=$(( $DISK_START + 512 ))
echo "Partition start set to $PART_START"


###########################################################################
# Test that partition table has the correct marker bytes at the end.
# If this test fails, it is very likely that nothing is going to work
# properly.
# This test is optional - controlled by a command-line switch - see USAGE.

[ "$MBR_TEST" ] && {
   echo "Checking MBR has expected ID of 0x55 0xAA at end."
   # Set marker to 0x55 0xAA (octal bytes 125 252).
   MARKER="$($ECHO $ECHOOPTIONS '\125\252' | tail -c2)"
   
   # Extract marker from where we think it should be.
   EXTRACT="$(dd if="$IMAGE" skip=$PART_ID_DD_SKIP bs=1 count=2)"
   
   # Check that the marker is correct.
   [ "$MARKER" = "$EXTRACT" ] \
      || Fail 3 "Couldn't find marker - MBR search failed."
   
   echo "MBR 'confirmed' at $DISK_START"
}


echo "=== Tweak partitioning =============================================="
echo "Setting the partition type as FAT (standard was NTFS)."
# Tweak byte at 0x1C2 offset from start of disk - change it to 6.
# Grub seems to want this to know how to handle the disk (most other things don't care).
PART_TYPE_DD_SEEK=$(( $MBR_PARTITION1_DD_SEEK + $PART_TYPE_OFFSET ))
$ECHO $ECHOOPTIONS '\006' \
   | dd of="$IMAGE" bs=1 count=1 conv=notrunc seek=$PART_TYPE_DD_SEEK \
      || Fail 3 "Couldn't set partition type."


###########################################################################
# OPTION: use sfdisk to find out disk size - this information is only
# used when extracting a disk image for testing with qemu

false && {
   echo "=== Get 'disk' image size ========================================="
   echo "Setting up loop for unknown-size drive (start at $DISK_START)."
   losetup -o $DISK_START "$LOOP" "$IMAGE" \
      || Fail 3 "Couldn't setup loop."
   
   DISK_SIZE_IN_UNITS=$(sfdisk -s "$LOOP") \
      || Fail 3 "Problem getting disk size."
      
   [ $DISK_SIZE_IN_UNITS -gt 10000 ] \
      || echo "WARNING: Disk size of '$DISK_SIZE_IN_UNITS' units is improbably small."
   
   echo "Disk size appears to be $DISK_SIZE_IN_UNITS k."
   
   # sfdisk seems to report in units of 1k
   DISK_SIZE_IN_SECTORS=$(( $DISK_SIZE_IN_UNITS * 2 ))
   
   # partition is going to be everything except the MBR (which is 1 sector)
   #PART_SIZE=$(( $DISK_SIZE - 512 ))
   #echo "WARNING: PART_SIZE is not correctly defined if you are mounting"
   #echo "partition 2 - expect it to fail if you use PART_SIZE"
   #sleep 3
   
   echo "Detaching disk loop."
   losetup -d "$LOOP" \
      || Fail 3 "Couldn't detach disk loop."
}


###########################################################################
echo "=== Setup bootloader ================================================"
# It seems that the '-s' option of losetup is not standard (it might be part
# of the version with loop-aes, but I haven't checked).
#
#echo "Setting up loop for partition (start at $PART_START, length $PART_SIZE)."
#losetup -o $PART_START -s $PART_SIZE "$LOOP" "$IMAGE" \
echo "Setting up loop for partition (start at $PART_START, length unconstrained)."
losetup -o $PART_START "$LOOP" "$IMAGE" \
   || Fail 3 "Couldn't setup loop."


###########################################################################
# OPTION: If you want to zero out the disk image, change 'false' in the 
# next line to 'true'
# Note that this is a bad idea if the size of the loop device has not been 
# constrained with the '-s' option of losetup.

false && {
   echo "Cleaning the partition, for tidiness."
   dd if=/dev/zero of="$LOOP" bs=512 2>/dev/null
}


###########################################################################
echo "Creating FAT filesystem, with large reserved space for grub."
# Grub probably doesn't need anywhere near this much space - I've not checked.
# Specify volume-id so that we get do md5sum of bootp.bin and have a 
# consistent result for consistent input data.
mkfs.vfat -i 0d510d51 -R 200 "$LOOP" \
   || Fail 3 "Couldn't create filesystem."

echo "Installing grub stage1 (part1)."
# Copy JMP from stage1
dd if="$GRUB1" of="$LOOP" bs=1 seek=0 skip=0 count=3 \
   || Fail 3 "Couldn't copy first part of stage1"

# Leave FAT boot parameter block alone - grub stage1 fits 'around' it.

# Copy the remainder of stage1
echo "Installing grub stage1 (part2)."
dd if="$GRUB1" of="$LOOP" bs=1 seek=62 skip=62 \
   || Fail 3 "Couldn't copy second part of stage1"

echo "Installing grub stage2."
dd if="$GRUB2" of="$LOOP" bs=512 seek=1 \
   || Fail 3 "Couldn't copy stage2"

echo "=== Copy files ======================================================"
echo "Mounting image."
mount "$LOOP" "$MNT" -t vfat \
   || Fail 3 "Couldn't mount loop '$LOOP'"

echo "Copying kernel."
cp "$KERNEL" "$MNT" \
   || Fail 3 "Couldn't copy kernel '$KERNEL'"

echo "Copying initrd."
cp "$INITRD" "$MNT" \
   || Fail 3 "Couldn't copy initrd '$INITRD'"


###########################################################################
echo "=== Close up ========================================================"
echo "Unmounting image"
umount "$MNT" \
   || Fail 3 "Couldn't unmount loop."

echo "Detaching loop."
losetup -d "$LOOP" \
   || Fail 3 "Couldn't detach loop."


###########################################################################
# Optionally create an image of the 'disk' embedded within the
# T20 image file.  This will be an image of the whole drive including 
# partition table.  If you have qemu installed, you can boot it by doing: 
#    qemu -hda <ImageFileName>
# Or you can loop-mount it (but you need to specify the partition offsets
# for that to work)

[ "$QEMU_IMAGE" ] && {
   echo "=== Create qemu test image =========================================="
   echo "Writing disk image to '$QEMU_IMAGE' for testing."
   losetup -o $DISK_START "$LOOP" "$IMAGE" \
      || Fail 3 "Couldn't setup loop."
   #dd if="$LOOP" of="$QEMU_IMAGE" bs=512 count=$DISK_SIZE_IN_SECTORS conv=notrunc \
   dd if="$LOOP" of="$QEMU_IMAGE" bs=512 conv=notrunc \
         || Fail 3 "Couldn't write image $QEMU_IMAGE"
   chmod a+rw "$QEMU_IMAGE" \
      || echo "WARNING: Couldn't chmod image $QEMU_IMAGE"
   echo "Detaching disk loop."
   losetup -d "$LOOP" \
      || Fail 3 "Couldn't detach disk loop."
   echo "To test image with qemu, do:"
   echo "   qemu -hda $QEMU_IMAGE"
}

###########################################################################
TidyUp

echo "=== Finished! ======================================================="
echo
echo "Done!  You should now flash the T20 with '$IMAGE'"
echo
