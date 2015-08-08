#!/bin/bash -x
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

# This script is executed inside post_test_hook function in devstack gate.

# Sleep some time until all services are starting
sleep 5

sudo apt-get install euca2ools -fy

export TEST_CONFIG_DIR=$(readlink -f .)
export TEST_CONFIG="functional_tests.conf"

# save original creds(admin) for later usage
OLD_OS_PROJECT_NAME=$OS_PROJECT_NAME
OLD_OS_USERNAME=$OS_USERNAME
OLD_OS_PASSWORD=$OS_PASSWORD

# neutron CLI can parse only OS_TENANT_NAME variable
export OS_TENANT_NAME=$OS_PROJECT_NAME
# nova CLI fails with these variables
unset OS_USER_DOMAIN_ID
unset OS_PROJECT_DOMAIN_ID

if [[ ! -f $TEST_CONFIG_DIR/$TEST_CONFIG ]]; then

  openstack endpoint list --os-identity-api-version=3
  openstack service list --long
  if [[ "$?" -ne "0" ]]; then
    echo "Looks like credentials are absent."
    exit 1
  fi

  # prepare flavors
  nova flavor-create --is-public True m1.ec2api 16 512 0 1
  nova flavor-create --is-public True m1.ec2api-alt 17 256 0 1

  if [[ $RUN_LONG_TESTS == "1" ]]; then
    REGULAR_IMAGE_URL="https://cloud-images.ubuntu.com/precise/current/precise-server-cloudimg-i386-disk1.img"
    REGULAR_IMAGE_FNAME="precise"
    openstack image create --disk-format raw --container-format bare --public --location $REGULAR_IMAGE_URL $REGULAR_IMAGE_FNAME
    if [[ "$?" -ne "0" ]]; then
      echo "Creation precise image failed"
      exit 1
    fi
    sleep 60
    # find this image
    image_id_ubuntu=$(euca-describe-images --show-empty-fields | grep "precise" | grep "ami-" | head -n 1 | awk '{print $2}')
  fi

  # create separate user/project
  project_name="project-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
  eval $(openstack project create -f shell -c id $project_name)
  project_id=$id
  user_name="user-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
  eval $(openstack user create "$user_name" --project "$project_id" --password "password" --email "$user_name@example.com" -f shell -c id)
  user_id=$id
  # create network
  if [[ -n $(openstack service list | grep neutron) ]]; then
    net_id=$(neutron net-create --tenant-id $project_id "private" | grep ' id ' | awk '{print $4}')
    subnet_id=$(neutron subnet-create --tenant-id $project_id --ip_version 4 --gateway 10.0.0.1 --name "private_subnet" $net_id 10.0.0.0/24 | grep ' id ' | awk '{print $4}')
    router_id=$(neutron router-create --tenant-id $project_id "private_router" | grep ' id ' | awk '{print $4}')
    neutron router-interface-add $router_id $subnet_id
    public_net_id=$(neutron net-list | grep public | awk '{print $2}')
    neutron router-gateway-set $router_id $public_net_id
  fi
  # populate credentials
  openstack ec2 credentials create --user $user_id --project $project_id 1>&2
  line=`openstack ec2 credentials list --user $user_id | grep " $project_id "`
  read EC2_ACCESS_KEY EC2_SECRET_KEY <<<  `echo $line | awk '{print $2 " " $4 }'`
  export EC2_ACCESS_KEY
  export EC2_SECRET_KEY
  export OS_PROJECT_NAME=$project_name
  export OS_TENANT_NAME=$project_name
  export OS_USERNAME=$user_name
  export OS_PASSWORD="password"

  # find simple image
  image_id=$(euca-describe-images --show-empty-fields | grep "cirros" | grep "ami-" | head -n 1 | awk '{print $2}')

  # create EBS image
  MAX_FAIL=20
  FLAVOR_NAME="m1.tiny"
  volume_status() { cinder show $1|awk '/ status / {print $4}'; }
  instance_status() { nova show $1|awk '/ status / {print $4}'; }

  openstack_image_id=$(openstack image list --long | grep "cirros" | grep " ami " | head -1 | awk '{print $2}')
  volume_id=$(cinder create --image-id $openstack_image_id 1 | awk '/ id / {print $4}')
  fail=0
  until [[ $(volume_status $volume_id) == "available" ]]; do
    if ((fail >= MAX_FAIL)); then
      exit 1
    fi
    ((++fail)); sleep 5
    if [[ $(volume_status $volume_id) == error ]]; then
      cinder show $volume_id
    fi
  done
  instance_name="i-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
  instance_id=$(nova boot \
    --flavor "$FLAVOR_NAME" \
    --block-device-mapping "/dev/vda=$volume_id:::1" \
    "$instance_name" | awk '/ id / {print $4}')
  fail=0
  until [[ $(instance_status $instance_id) == "ACTIVE" ]]; do
    if ((fail >= MAX_FAIL)); then
      exit 1
    fi
    ((++fail))
    sleep 10
    if [[ $(instance_status $instance_id) == "ERROR" ]]; then
      nova show $instance_id
      exit 1
    fi
  done
  image_name="image-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
  nova image-create $instance_name $image_name
  if [[ "$?" -ne "0" ]]; then
    echo "Image creation from instance fails"
    exit 1
  fi
  ebs_image_id=$(euca-describe-images --show-empty-fields | grep $image_name | awk '{print $2}')
  nova delete $instance_id

  timeout="180"
  run_long_tests="False"
  if [[ $RUN_LONG_TESTS == "1" ]]; then
    timeout="600"
    run_long_tests="True"
  else
    timeout="180"
    run_long_tests="False"
  fi

  # TODO(andey-mp): make own code
  # copy some variables from tempest.conf
  tempest_conf="../tempest/etc/tempest.conf"
  if [[ -f $tempest_conf ]]; then
    s3_materials_path=`grep ^s3_materials_path $tempest_conf | awk '{split($0,a,"="); print a[2]}'`
    aki_manifest=`grep ^aki_manifest $tempest_conf | awk '{split($0,a,"="); print a[2]}'`
    ami_manifest=`grep ^ami_manifest $tempest_conf | awk '{split($0,a,"="); print a[2]}'`
    ari_manifest=`grep ^ari_manifest $tempest_conf | awk '{split($0,a,"="); print a[2]}'`
  fi

  sudo bash -c "cat > $TEST_CONFIG_DIR/$TEST_CONFIG <<EOF
[aws]
ec2_url = $EC2_URL
s3_url = $S3_URL
aws_access = $EC2_ACCESS_KEY
aws_secret = $EC2_SECRET_KEY
image_id = $image_id
image_id_ubuntu = $image_id_ubuntu
ebs_image_id = $ebs_image_id
build_timeout = $timeout
run_long_tests = $run_long_tests
instance_type = m1.ec2api
instance_type_alt = m1.ec2api-alt
s3_materials_path=$s3_materials_path
aki_manifest=$aki_manifest
ami_manifest=$ami_manifest
ari_manifest=$ari_manifest
EOF"
fi

sudo pip install -r test-requirements.txt
sudo OS_STDOUT_CAPTURE=-1 OS_STDERR_CAPTURE=-1 OS_TEST_TIMEOUT=500 OS_TEST_LOCK_PATH=${TMPDIR:-'/tmp'} \
  python -m subunit.run discover -t ./ ./ec2api/tests/functional | subunit-2to1 | tools/colorizer.py
RETVAL=$?

# Here can be some commands for log archiving, etc...

# list resources to check what left after tests
euca-describe-instances
euca-describe-images
euca-describe-volumes
euca-describe-snapshots
export OS_PROJECT_NAME=$OLD_OS_PROJECT_NAME
export OS_TENANT_NAME=$OLD_OS_PROJECT_NAME
export OS_USERNAME=$OLD_OS_USERNAME
export OS_PASSWORD=$OLD_OS_PASSWORD
nova list --all-tenants
cinder list --all-tenants
cinder snapshot-list --all-tenants
glance image-list --all-tenants

exit $RETVAL
