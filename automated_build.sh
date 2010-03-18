## Run as sudo!

# Clear any previous build attempts
rm -rf grub-0.97
losetup -d /dev/loop1
rm -f bootp.bin

# Decompress GRUB
tar -xzvvf grub-0.97.tar.gz
cd grub-0.97

# Patch GRUB
patch -p1 <../devosl-grub.patch
patch -p1 <../grub-configure.patch

# Make GRUB
chmod +x config-devosl.sh
./config-devosl.sh
make clean
make all

# Fix GRUB build-ids
cd stage1
objcopy -R .note.gnu.build-id -O binary stage1.exec stage1
cd ../stage2
objcopy -R .note.gnu.build-id -O binary start.exec start
objcopy -R .note.gnu.build-id -O binary pre_stage2.exec pre_stage2
rm -f stage2
cat start pre_stage2 > stage2
cd ../..

# Combine DSL and GRUB into a T20 image
chmod +x build-devosl.sh
./build-devosl.sh

