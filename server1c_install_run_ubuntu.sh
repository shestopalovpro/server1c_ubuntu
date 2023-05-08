#!/bin/bash
# Устанавливаем локаль
locale-gen en_US.UTF-8 ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# Нужно указать свой часовой пояс (это мой рабочий, если не подходит меняйте на свой)
timedatectl set-timezone Asia/Irkutsk

#Добавляю репозиторий т.к. пакета libenchant1c2a нет в репах 22 убунты (надо сделать проверку версии Ubuntu)
sudo add-apt-repository -y 'deb http://cz.archive.ubuntu.com/ubuntu focal main universe'

# Прописал, чтобы не вылезало окно согласия с лицензией EULA 
echo msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections

# Ставим зависимости
sudo apt -y install ttf-mscorefonts-installer
sudo apt -y install imagemagick
sudo apt -y install unixodbc
sudo apt -y install libgsf-1-114
sudo apt -y install libenchant1c2a