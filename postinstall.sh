#! /bin/bash
cp services/ec2-api.service /etc/systemd/system/
cp services/ec2-api-metadata.service /etc/systemd/system/
systemctl enable ec2-api
systemctl enable ec2-api-metadata
service ec2-api start
service ec2-api-metadata start

