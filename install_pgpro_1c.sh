#!/bin/bash
set -e

# === Функция вывода помощи ===
show_help() {
  echo "Использование: sudo ./install_pgpro_1c.sh [версия] [--data-dir ПУТЬ]"
  echo
  echo "Примеры:"
  echo "  sudo ./install_pgpro_1c.sh 15"
  echo "  sudo ./install_pgpro_1c.sh 16 --data-dir /mnt/dbdata"
  echo
  echo "Допустимые версии: 14, 15, 16, 17, 18"
  exit 0
}

# === Если передан флаг помощи ===
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  show_help
fi

# === Получаем версию ===
if [[ -n "$1" && ! "$1" =~ ^-- ]]; then
  VERSION="$1"
else
  echo "Выберите версию PostgreSQL Pro 1C (14-18):"
  read -p "Введите номер версии (например, 15): " VERSION
fi

# === Проверка корректности версии ===
if [[ ! $VERSION =~ ^1[4-8]$ ]]; then
  echo "❌ Ошибка: допустимые версии — 14, 15, 16, 17, 18"
  exit 1
fi

# === Определяем путь к данным ===
DATA_DIR="/data/postgres/"
if [[ "$2" == "--data-dir" && -n "$3" ]]; then
  DATA_DIR="$3"
fi

echo "=== Устанавливается PostgreSQL Pro 1C версии $VERSION ==="
echo "📁 Каталог данных: $DATA_DIR"

# === Проверка существующего каталога ===
if [[ -d "$DATA_DIR" && "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
  echo "⚠️  Внимание: каталог $DATA_DIR не пуст."
  read -p "Удалить содержимое и инициализировать заново? (y/N): " CONFIRM
  case "$CONFIRM" in
    [yY][eE][sS]|[yY])
      echo "🗑️  Удаляем содержимое каталога..."
      rm -rf "$DATA_DIR"/*
      ;;
    *)
      echo "❌ Операция отменена пользователем."
      exit 1
      ;;
  esac
fi

# === Добавляем репозиторий ===
wget -q https://repo.postgrespro.ru/1c-$VERSION/keys/pgpro-repo-add.sh -O pgpro-repo-add.sh
bash pgpro-repo-add.sh

# === Установка PostgreSQL ===
apt-get update -y
apt-get install -y postgrespro-1c-$VERSION postgrespro-1c-$VERSION-dev

# === Настройка локали для 1С ===
locale-gen ru_RU.UTF-8
localectl set-locale LANG=ru_RU.UTF-8 LC_TIME=ru_RU.UTF-8 LC_COLLATE=ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8

# === Останавливаем службу, чтобы пересобрать кластер ===
systemctl stop postgrespro-1c-$VERSION

# === Создаем директорию для базы ===
mkdir -p "$DATA_DIR"
chown -R postgres:postgres "$(dirname "$DATA_DIR")"

# === Удаляем дефолтные настройки ===
rm -f /etc/default/postgrespro-1c-$VERSION

# === Инициализация кластера ===
/opt/pgpro/1c-$VERSION/bin/pg-setup initdb -D "$DATA_DIR" --locale=ru_RU.UTF-8

# === Запуск и автозапуск ===
systemctl start postgrespro-1c-$VERSION
systemctl enable postgrespro-1c-$VERSION

echo
echo "✅ PostgreSQL Pro 1C версии $VERSION успешно установлена!"
echo "📦 Данные расположены в: $DATA_DIR"
