#! /bin/bash
openstack endpoint create --region RegionOne ec2api public http://controller:8788/
openstack endpoint create --region RegionOne ec2api admin http://controller:8788/
openstack endpoint create --region RegionOne ec2api internal http://controller:8788/
read -sp "Enter the password for the openstack ec2api account (EC2_PASS):" EC2_PASS
echo ""
openstack user create --domain default --password $ec2_pass ec2api
sed -i "s/SERVICE_PASSWORD=.*$/SERVICE_PASSWORD=$EC2_PASS/g" install.sh
