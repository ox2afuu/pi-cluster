#!/bin/bash -e
# stage-ivalice-common/prerun.sh
#
# Standard pi-gen prerun: copy the previous stage's rootfs to this stage's
# work directory, so subsequent sub-stages build on top of it.

if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi
