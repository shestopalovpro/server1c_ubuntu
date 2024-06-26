wget https://repo.postgrespro.ru/pg1c-14/keys/pgpro-repo-add.sh
sh pgpro-repo-add.sh

apt-get install postgrespro-1c-14 postgrespro-1c-14-dev -y

#Добавляем нужную локаль для 1С (обязательно, иначе поймаем ошибку локали в 1С)
locale-gen ru_RU.UTF-8
localectl set-locale LANG=ru_RU.UTF-8 LC_TIME=ru_RU.UTF-8 LC_COLLATE=ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

#Останавливаем службу, чтобы пересобрать кластер с локалью ru_RU.UTF-8 (при установке кластер собирается с другой локалью)
systemctl stop postgrespro-1c-14

#Создаем директорию для будущего кластера (использую директорию свою)
mkdir -p /data/postgres/
chown -R postgres. /data

# очищаем дефолтные настройки
rm -f /etc/default/postgrespro-1c-14
# инициализируем PostgreSQL
/opt/pgpro/1c-14/bin/pg-setup initdb -D /data/postgres/ --locale=ru_RU.UTF-8 
# Стартуем
systemctl start postgrespro-1c-14
systemctl enable postgrespro-1c-14
