#!/bin/bash -xe
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# This script is executed inside post_test_hook function in devstack gate.

sudo chown -R $USER:stack $BASE/new/tempest
sudo chown -R $USER:stack $BASE/data/tempest
sudo chmod -R o+rx $BASE/new/devstack/files

# Import devstack functions 'iniset'.
source $BASE/new/devstack/functions

export TEMPEST_CONFIG=$BASE/new/tempest/etc/tempest.conf

# === Handle script arguments ===
# The script arguments as detailed here in the manila CI job
# template,
# https://github.com/openstack-infra/project-config/commit/6ae99cee70a33d6cc312a7f9a83aa6db8b39ce21
# Handle the relevant ones.

# First argument is the type of backend configuration that is setup. It can
# either be 'singlebackend' or 'multiplebackend'.
MANILA_BACKEND_TYPE=$1
MANILA_BACKEND_TYPE=${MANILA_BACKEND_TYPE:-singlebackend}

# Second argument is the type of the cephfs driver that is setup. Currently,
# 'cephfsnative' is the only possibility.
MANILA_CEPH_DRIVER=$2
MANILA_CEPH_DRIVER=${MANILA_CEPH_DRIVER:-cephfsnative}

# Third argument is the type of Tempest tests to be run, 'api' or 'scenario'.
MANILA_TEST_TYPE=$3
MANILA_TEST_TYPE=${MANILA_TEST_TYPE:-api}

if [[ $MANILA_CEPH_DRIVER == 'cephfsnative' ]]; then
    export BACKEND_NAME="CEPHFSNATIVE1"
    iniset $TEMPEST_CONFIG share enable_protocols cephfs
    iniset $TEMPEST_CONFIG share storage_protocol CEPHFS

    # Disable tempest config option that enables creation of 'ip' type access
    # rules by default during tempest test runs.
    iniset $TEMPEST_CONFIG share enable_ip_rules_for_protocols
    iniset $TEMPEST_CONFIG share enable_cert_rules_for_protocols
    iniset $TEMPEST_CONFIG share enable_cephx_rules_for_protocols cephfs
    iniset $TEMPEST_CONFIG share capability_snapshot_support False
    iniset $TEMPEST_CONFIG share backend_names $BACKEND_NAME

    # Disable manage/unmanage tests
    # CephFSNative driver does not yet support manage and unmanage operations of shares.
    RUN_MANILA_MANAGE_TESTS=${RUN_MANILA_MANAGE_TESTS:-False}
    iniset $TEMPEST_CONFIG share run_manage_unmanage_tests $RUN_MANILA_MANAGE_TESTS
elif [[ $MANILA_CEPH_DRIVER == 'cephfsnfs' ]]; then
    iniset $TEMPEST_CONFIG share enable_protocols nfs
    iniset $TEMPEST_CONFIG share capability_storage_protocol NFS
    iniset $TEMPEST_CONFIG share enable_ip_rules_for_protocols nfs
fi

# If testing a stable branch, we need to ensure we're testing with supported
# API micro-versions; so set the versions from code if we're not testing the
# master branch. If we're testing master, we'll allow manila-tempest-plugin
# (which is branchless) tell us what versions it wants to test.
if [[ $ZUUL_BRANCH != "master" ]]; then
    # Grab the supported API micro-versions from the code
    _API_VERSION_REQUEST_PATH=$BASE/new/manila/manila/api/openstack/api_version_request.py
    _DEFAULT_MIN_VERSION=$(awk '$0 ~ /_MIN_API_VERSION = /{print $3}' $_API_VERSION_REQUEST_PATH)
    _DEFAULT_MAX_VERSION=$(awk '$0 ~ /_MAX_API_VERSION = /{print $3}' $_API_VERSION_REQUEST_PATH)
    # Override the *_api_microversion tempest options if present
    MANILA_TEMPEST_MIN_API_MICROVERSION=${MANILA_TEMPEST_MIN_API_MICROVERSION:-$_DEFAULT_MIN_VERSION}
    MANILA_TEMPEST_MAX_API_MICROVERSION=${MANILA_TEMPEST_MAX_API_MICROVERSION:-$_DEFAULT_MAX_VERSION}
    # Set these options in tempest.conf
    iniset $TEMPEST_CONFIG share min_api_microversion $MANILA_TEMPEST_MIN_API_MICROVERSION
    iniset $TEMPEST_CONFIG share max_api_microversion $MANILA_TEMPEST_MAX_API_MICROVERSION
fi

# Set two retries for CI jobs.
iniset $TEMPEST_CONFIG share share_creation_retry_number 2

# Suppress errors in cleanup of resources.
SUPPRESS_ERRORS=${SUPPRESS_ERRORS_IN_CLEANUP:-True}
iniset $TEMPEST_CONFIG share suppress_errors_in_cleanup $SUPPRESS_ERRORS


if [[ $MANILA_BACKEND_TYPE == 'multibackend' ]]; then
    RUN_MANILA_MULTI_BACKEND_TESTS=True
elif [[ $MANILA_BACKEND_TYPE == 'singlebackend' ]]; then
    RUN_MANILA_MULTI_BACKEND_TESTS=False
fi
iniset $TEMPEST_CONFIG share multi_backend $RUN_MANILA_MULTI_BACKEND_TESTS

# Enable extend tests.
RUN_MANILA_EXTEND_TESTS=${RUN_MANILA_EXTEND_TESTS:-True}
iniset $TEMPEST_CONFIG share run_extend_tests $RUN_MANILA_EXTEND_TESTS

# Enable shrink tests.
RUN_MANILA_SHRINK_TESTS=${RUN_MANILA_SHRINK_TESTS:-True}
iniset $TEMPEST_CONFIG share run_shrink_tests $RUN_MANILA_SHRINK_TESTS

# Disable multi_tenancy tests.
iniset $TEMPEST_CONFIG share multitenancy_enabled False

# CephFS does not yet suppport cloning of snapshots required to create Manila
# shares from snapshots.
# Disable snapshot tests
RUN_MANILA_SNAPSHOT_TESTS=${RUN_MANILA_SNAPSHOT_TESTS:-False}
iniset $TEMPEST_CONFIG share run_snapshot_tests $RUN_MANILA_SNAPSHOT_TESTS

# Disable consistency group tests. The lone cephfs driver, cephfs native,
# does not yet (2nd Feb, 2016)  support,
# 'create_consistency_group_from_snapshot' API.
RUN_MANILA_CG_TESTS=${RUN_MANILA_CG_TESTS:-False}
iniset $TEMPEST_CONFIG share run_consistency_group_tests $RUN_MANILA_CG_TESTS

# NOTE(gouthamr): extra rules are needed to allow VMs to mount storage from
# the host.
TCP_PORTS=(2049 111 32803 892 875 662)
UDP_PORTS=(111 32769 892 875 662)
for ipcmd in iptables ip6tables; do
    sudo $ipcmd -N manila-nfs
    sudo $ipcmd -I INPUT 1 -j manila-nfs
    for port in ${TCP_PORTS[*]}; do
        sudo $ipcmd -A manila-nfs -m tcp -p tcp --dport $port -j ACCEPT
    done
    for port in ${UDP_PORTS[*]}; do
        sudo $ipcmd -A manila-nfs -m udp -p udp --dport $port -j ACCEPT
    done
done

# Let us control if we die or not.
set +o errexit
cd $BASE/new/tempest


# Workaround for Tempest architectural changes
# See bugs:
# 1) https://bugs.launchpad.net/manila/+bug/1531049
# 2) https://bugs.launchpad.net/tempest/+bug/1524717
ADMIN_TENANT_NAME=${ADMIN_TENANT_NAME:-"admin"}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-"secretadmin"}
iniset $TEMPEST_CONFIG auth admin_username ${ADMIN_USERNAME:-"admin"}
iniset $TEMPEST_CONFIG auth admin_password $ADMIN_PASSWORD
iniset $TEMPEST_CONFIG auth admin_tenant_name $ADMIN_TENANT_NAME
iniset $TEMPEST_CONFIG auth admin_domain_name ${ADMIN_DOMAIN_NAME:-"Default"}
iniset $TEMPEST_CONFIG identity username ${TEMPEST_USERNAME:-"demo"}
iniset $TEMPEST_CONFIG identity password $ADMIN_PASSWORD
iniset $TEMPEST_CONFIG identity tenant_name ${TEMPEST_TENANT_NAME:-"demo"}
iniset $TEMPEST_CONFIG identity alt_username ${ALT_USERNAME:-"alt_demo"}
iniset $TEMPEST_CONFIG identity alt_password $ADMIN_PASSWORD
iniset $TEMPEST_CONFIG identity alt_tenant_name ${ALT_TENANT_NAME:-"alt_demo"}
iniset $TEMPEST_CONFIG validation ip_version_for_ssh 4
iniset $TEMPEST_CONFIG validation ssh_timeout $BUILD_TIMEOUT
iniset $TEMPEST_CONFIG validation network_for_ssh ${PRIVATE_NETWORK_NAME:-"private"}

_DEFAULT_TEST_CONCURRENCY=8
echo "Running tempest manila test suites"
if [[ $MANILA_TEST_TYPE == 'api' ]]; then
    export MANILA_TESTS='manila_tempest_tests.tests.api'
    _DEFAULT_TEST_CONCURRENCY=12
elif [[ $MANILA_TEST_TYPE == 'scenario' ]]; then
    export MANILA_TESTS='manila_tempest_tests.tests.scenario'
else
    export MANILA_TESTS='manila_tempest_tests.tests'
fi
export MANILA_TEMPEST_CONCURRENCY=${MANILA_TEMPEST_CONCURRENCY:-$_DEFAULT_TEST_CONCURRENCY}

sudo -H -u $USER tempest list-plugins
sudo -H -u $USER tempest run -r $MANILA_TESTS --concurrency=$MANILA_TEMPEST_CONCURRENCY
