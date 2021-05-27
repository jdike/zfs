#!/bin/ksh -p
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2020 Akamai Technologies.  All rights reserved.
#

. $STF_SUITE/tests/functional/cache/cache.cfg
. $STF_SUITE/tests/functional/cache/cache.kshlib

#
# DESCRIPTION:
#	On Linux, 'echo 3 > /proc/sys/vm/drop_caches' should cause the
#	ARC cache to drop to close to its minimum size.
#
# STRATEGY:
#	1. Create pool
#	2. Set zfs_arc_max to something large and zfs_arc_min to
#	   something small
#	3. Mount the pool and create a file in it, and sync it
#	4. echo 3 > /proc/sys/vm/drop_caches
#	5. Verify that the ARC cache size has dropped to its minimum

verify_runnable "global"

log_assert "Writes to /proc/sys/vm/drop_caches are respected"

is_linux || log_pass "This test is Linux-specific"
log_onexit cleanup_testenv

SAVED_ZFS_ARC_MAX=
# Set Arc Cache Max to 8G=
TEST_ARC_MAX_SIZE=$((8 * 1024 * 1024 * 1024))

SAVED_ZFS_ARC_MIN=
TEST_ARC_MIN_SIZE=$((64 * 1024 * 1024))
T=testtank
TANK=$T/test
TEST_VDEV=/tmp/zfs-test
MOUNT=/tmp/zfs
TEST_REDIRECT_FILE="$MOUNT/testfile"

function cleanup_testenv {
    log_note "cleanup: restore zfs_arc_max and zfs_arc_min"
    set_tunable32 ARC_MAX $SAVED_ZFS_ARC_MAX
    set_tunable32 ARC_MIN $SAVED_ZFS_ARC_MIN

    log_must zpool destroy $T
}

units=`grep -i 'MemTotal' /proc/meminfo | awk '{print $3}'`
if [ "$units" == "kB" ]; then
    mult=1024
elif [ "$units" == "mB" ]; then
    mult=1048576
fi

memsize=`grep 'MemTotal:' /proc/meminfo | awk '{print $2}'`
memsize=$(($memsize * $mult))

if [ "$memsize" -le "$TEST_ARC_MAX_SIZE" ]; then
    log_fail "Machine needs more than 8GB of memory to run this test"
fi

if [ "`zpool list`" ne "no pools available" ]; then
    log_fail "There should be no pools already created"
fi

SAVED_ZFS_ARC_MAX=$(get_tunable ARC_MAX)
set_tunable32 ARC_MAX $TEST_ARC_MAX_SIZE

SAVED_ZFS_ARC_MIN=$(get_tunable ARC_MIN)
set_tunable32 ARC_MIN $TEST_ARC_MIN_SIZE

# Need a sleep before we can read cache value
sleep 3

C_MAX=$(get_arcstat c_max)
if [ "$C_MAX" != "$TEST_ARC_MAX_SIZE" ]; then
    log_fail "arc max size=$C_MAX expected=$TEST_ARC_MAX_SIZE"
fi

dd if=/dev/zero of=$TEST_VDEV seek=1024 bs=$((1024 * 1024)) count=1
log_must zpool create -f $T $TEST_VDEV
log_must zfs create -o mountpoint=$MOUNT $TANK

data=$(cat <<EOF
012345678901234567890123456789012345678
012345678901234567890123456789012345678
012345678901234567890123456789012345678
012345678901234567890123456789012345678
EOF
)

ARC_SIZE=$(get_arcstat '^size')
log_note "starting ARC size=$ARC_SIZE"
while [ "$ARC_SIZE" -lt $((500 * 1000 * 1000)) ]; do
    for i in `seq $((150000000 / 160))`; do
	echo $data >> $TEST_REDIRECT_FILE
    done
    ARC_SIZE=$(get_arcstat '^size')
done

sync -f $TEST_REDIRECT_FILE

ARC_SIZE=$(get_arcstat '^size')
MIN_SIZE=$(get_arcstat c_min)
log_note "current ARC size is $ARC_SIZE, min ARC size=$MIN_SIZE"

log_note "force drop_caches"
echo 3 > /proc/sys/vm/drop_caches

NEW_ARC_SIZE=$(get_arcstat '^size')
log_note "get new ARC size=$NEW_ARC_SIZE"

log_must test "$NEW_ARC_SIZE" -le "$ARC_SIZE"
log_must test "$NEW_ARC_SIZE" -le "$MIN_SIZE"

log_pass  "arc size at min size"
