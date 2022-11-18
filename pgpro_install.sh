wget https://repo.postgrespro.ru/pg1c-14/keys/pgpro-repo-add.sh
sh pgpro-repo-add.sh

apt-get install postgrespro-1c-14 postgrespro-1c-14-dev -y

locale-gen ru_RU.UTF-8
localectl set-locale LANG=ru_RU.UTF-8 LC_TIME=ru_RU.UTF-8 LC_COLLATE=ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

systemctl stop postgrespro-1c-14

mkdir -p /data/postgres/
chown -R postgres. /data

# очищаем дефолтные настройки
rm -f /etc/default/postgrespro-1c-14
# инициализируем PostgreSQL, создавая дефолтную пустые базы из шаблонов - указание ru-локали обязательно для дальнейшей работы 1С
/opt/pgpro/1c-14/bin/pg-setup initdb -D /data/postgres/ --locale=ru_RU.UTF-8 

systemctl start postgrespro-1c-14