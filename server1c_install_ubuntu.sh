#!/bin/bash
# Укажите логин и пароль на сайт 1с
export ONEC_USERNAME=$1
export ONEC_PASSWORD=$2

sudo apt update && sudo apt upgrade -y

# Устанавливаем локаль
locale-gen en_US.UTF-8 ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# Нужно указать свой часовой пояс (это мой рабочий, если не подходит меняйте на свой)
timedatectl set-timezone Asia/Irkutsk

# Прописал, чтобы не вылезало окно согласия с лицензией EULA 
echo msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections

# Ставим зависимости
sudo apt -y install ttf-mscorefonts-installer
sudo apt -y install imagemagick
sudo apt -y install unixodbc
sudo apt -y install libgsf-bin
sudo apt -y install t1utils


wget https://github.com/v8platform/oneget/releases/download/v0.5.2/oneget_Linux_x86_64.tar.gz

tar xfz oneget_Linux_x86_64.tar.gz

./oneget get --path ./tmp/dist/ platform:deb.server.x64@$3

cd ~/tmp/dist/platform83/$3

ph=$(echo "$3" | tr '.' '_')

tar xfz deb64_$ph.tar.gz

dpkg -i 1c-enterprise-*-common_*_amd64.deb
dpkg -i 1c-enterprise-*-server_*_amd64.deb
dpkg -i 1c-enterprise-*-ws_*_amd64.deb

cp /opt/1cv8/x86_64/$3/srv1cv83 /etc/init.d/srv1cv83

cp /opt/1cv8/x86_64/$3/srv1cv83.conf /etc/default/srv1cv83

update-rc.d srv1cv83 defaults

service srv1cv83 start