#!/bin/bash
# Укажите логин и пароль на сайт 1с
export ONEC_USERNAME=$1
export ONEC_PASSWORD=$2

sudo apt update && sudo apt upgrade -y

# Репо нужен для установки базовых компонентов PG-14
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
# Нужен для установки ключа ниже
apt -y install gnupg2
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

#apt update

# Устанавливаем локаль
locale-gen en_US.UTF-8 ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# Нужно указать свой часовой пояс (это мой рабочий, если не подходит меняйте на свой)
timedatectl set-timezone Asia/Irkutsk


apt -y install postgresql-client-common postgresql-common libxslt1.1 ssl-cert libllvm6.0


wget http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.0.0_1.0.2g-1ubuntu4.20_amd64.deb
dpkg -i libssl1.0.0_1.0.2g-1ubuntu4.20_amd64.deb
apt-mark hold libssl1.0.0


wget http://security.ubuntu.com/ubuntu/pool/main/i/icu/libicu60_60.2-3ubuntu3.2_amd64.deb
apt -y install ./libicu60_60.2-3ubuntu3.2_amd64.deb
apt-mark hold libicu60

wget http://mirrors.kernel.org/ubuntu/pool/main/r/readline/libreadline7_7.0-3_amd64.deb
apt -y install ./libreadline7_7.0-3_amd64.deb


wget https://github.com/v8platform/oneget/releases/download/v0.5.2/oneget_Linux_x86_64.tar.gz

tar xfz oneget_Linux_x86_64.tar.gz

./oneget get --path ./tmp/dist/ pg:deb.x64@$3

ph=$(echo "$3" | tr 'C' 'c')

cd ~/tmp/dist/addcomppostgre/$ph

ph2=$(echo "$3" | tr '-' '_')

tar xjf postgresql_${ph2}_amd64_deb.tar.bz2

cd postgresql-${3}_amd64_deb

apt -y install ./libpq5_$3_amd64.deb
apt -y install ./postgresql-14_$3_amd64.deb
apt -y install ./postgresql-client-14_$3_amd64.deb

echo "listen_addresses = '*'" >> /etc/postgresql/14/main/postgresql.conf
# Если оставить scram-sha-256, то при подключении ловим ошибку аутентификации
echo "password_encryption = md5" >> /etc/postgresql/14/main/postgresql.conf

mv /etc/postgresql/14/main/pg_hba.conf /etc/postgresql/14/main/pg_hba_backup.conf

touch /etc/postgresql/14/main/pg_hba.conf


echo "local   all             postgres                             trust" >> /etc/postgresql/14/main/pg_hba.conf
echo "local   all             all                                  md5" >> /etc/postgresql/14/main/pg_hba.conf
echo "host    all             all             0.0.0.0/0            md5" >> /etc/postgresql/14/main/pg_hba.conf

service postgresql restart