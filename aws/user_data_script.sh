#!/bin/bash

MYENV=ghcr.io/anyakichi/myenv

cat <<EOF >/etc/profile.d/myenv.sh
if [ "x\${BASH_VERSION-}" != x -a "x\${PS1-}" != x ]; then
    myenv()
    {
        if [[ -z "\$(docker ps -q --filter "name=^myenv$")" ]]; then
            din -d --name myenv \
                -v /var/run/docker.sock:/var/run/docker.sock \
                "\$@" \
                $MYENV
        fi
        docker attach myenv
    }
fi
EOF

curl -LsS -o /usr/local/bin/din \
    https://raw.githubusercontent.com/anyakichi/docker-buildenv/master/din.sh
chmod +x /usr/local/bin/din

yum update -y
amazon-linux-extras install docker
mkdir -p /etc/systemd/system/docker.socket.d
printf "[Socket]\nSocketGroup=ec2-user" >/etc/systemd/system/docker.socket.d/override.conf
systemctl daemon-reload
service docker start

amazon-linux-extras install epel
yum install -y s3fs-fuse

mkdir ~ec2-user/.docker
echo '{"detachKeys": "ctrl-\\,ctrl-x"}' >~ec2-user/.docker/config.json
chown ec2-user: ~ec2-user/.docker

docker pull $MYENV
