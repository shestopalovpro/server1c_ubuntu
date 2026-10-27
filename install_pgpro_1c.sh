#!/bin/bash
# Copyright (c) 2025 Sergey Shestopalov
#
# Установка PostgreSQL Pro для 1С на Ubuntu/Debian:
# репозиторий postgrespro-1c, пакеты, локаль ru_RU.UTF-8, новый кластер,
# пароль пользователя postgres, автозапуск службы.

set -e

# === Функция вывода помощи ===
show_help() {
  cat <<EOF
Использование: sudo ./install_pgpro_1c.sh [версия] [--data-dir ПУТЬ] [параметры пароля]

Параметры:
  версия                    14, 15, 16, 17 или 18. Без параметра — спросит.
  --data-dir ПУТЬ           Каталог данных кластера (по умолчанию /data/postgres/).

Пароль пользователя postgres (без этих параметров скрипт спросит его в начале):
  --password-file ФАЙЛ      Взять пароль из первой строки файла.
  PGPRO_PASSWORD=...        Взять пароль из переменной окружения.
  --no-password             Не задавать пароль (останется только локальный вход).

Примеры:
  sudo ./install_pgpro_1c.sh 16
  sudo ./install_pgpro_1c.sh 17 --data-dir /mnt/pgdata
  sudo ./install_pgpro_1c.sh 17 --password-file /root/pg.pass
  sudo --preserve-env=PGPRO_PASSWORD ./install_pgpro_1c.sh 17   # переменная задана заранее
EOF
  exit 0
}

# === Разбор параметров ===
need_value() {
  if [[ $# -lt 2 || "$2" == -* ]]; then
    echo "❌ Для $1 нужно указать значение (справка: --help)"
    exit 1
  fi
}

VERSION=""
DATA_DIR="/data/postgres/"
PASSWORD_FILE=""
NO_PASSWORD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       show_help ;;
    --data-dir)      need_value "$@"; DATA_DIR="$2"; shift ;;
    --data-dir=*)    DATA_DIR="${1#*=}" ;;
    --password-file) need_value "$@"; PASSWORD_FILE="$2"; shift ;;
    --password-file=*) PASSWORD_FILE="${1#*=}" ;;
    --no-password)   NO_PASSWORD=true ;;
    --password|--password=*)
      echo "❌ Пароль в командной строке не принимается: он виден в истории и списке процессов."
      echo "   Используйте --password-file ФАЙЛ, переменную PGPRO_PASSWORD или ввод по запросу."
      exit 1
      ;;
    -*)
      echo "❌ Неизвестный параметр: $1 (справка: --help)"
      exit 1
      ;;
    *)               VERSION="$1" ;;
  esac
  shift
done

if [[ -z "$DATA_DIR" ]]; then
  echo "❌ Не указан путь для --data-dir"
  exit 1
fi

# === Проверка прав ===
if [[ $EUID -ne 0 ]]; then
  echo "❌ Скрипт нужно запускать от root: sudo $0"
  exit 1
fi

# === Получаем версию ===
if [[ -z "$VERSION" ]]; then
  echo "Выберите версию PostgreSQL Pro 1C (14-18):"
  read -p "Введите номер версии (например, 17): " VERSION
fi

# === Проверка корректности версии ===
if [[ ! $VERSION =~ ^1[4-8]$ ]]; then
  echo "❌ Ошибка: допустимые версии — 14, 15, 16, 17, 18"
  exit 1
fi

# === Пароль пользователя postgres ===
# Спрашиваем в самом начале, чтобы дальше установка шла без участия человека
PG_PASSWORD=""
if [[ "$NO_PASSWORD" == true ]]; then
  echo "ℹ️  Пароль postgres задаваться не будет (--no-password)."
elif [[ -n "$PASSWORD_FILE" ]]; then
  if [[ ! -r "$PASSWORD_FILE" ]]; then
    echo "❌ Файл с паролем не найден или недоступен: $PASSWORD_FILE"
    exit 1
  fi
  IFS= read -r PG_PASSWORD < "$PASSWORD_FILE" || true
  PG_PASSWORD="${PG_PASSWORD%$'\r'}"
  echo "🔑 Пароль postgres взят из файла $PASSWORD_FILE"
elif [[ -n "$PGPRO_PASSWORD" ]]; then
  PG_PASSWORD="$PGPRO_PASSWORD"
  echo "🔑 Пароль postgres взят из переменной PGPRO_PASSWORD"
else
  while true; do
    read -rsp "Придумайте пароль для пользователя postgres: " PG_PASSWORD; echo
    read -rsp "Повторите пароль: " PG_PASSWORD2; echo
    if [[ -z "$PG_PASSWORD" ]]; then
      echo "❌ Пароль не может быть пустым."
    elif [[ "$PG_PASSWORD" != "$PG_PASSWORD2" ]]; then
      echo "❌ Пароли не совпадают, попробуйте ещё раз."
    else
      break
    fi
  done
  unset PG_PASSWORD2
fi
unset PGPRO_PASSWORD

if [[ "$NO_PASSWORD" == false && -z "$PG_PASSWORD" ]]; then
  echo "❌ Пароль пустой. Укажите пароль или используйте --no-password."
  exit 1
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

# === Установка пароля postgres ===
if [[ "$NO_PASSWORD" == false ]]; then
  PG_BIN="/opt/pgpro/1c-$VERSION/bin"
  echo "⏳ Ожидаю запуска PostgreSQL..."
  for i in {1..30}; do
    sudo -u postgres "$PG_BIN/pg_isready" -q && break
    sleep 1
  done

  # SQL передаётся через stdin, а не аргументом: так пароль не виден в списке процессов.
  # Одинарные кавычки в пароле экранируются удвоением.
  printf "ALTER USER postgres PASSWORD '%s';\n" "${PG_PASSWORD//\'/\'\'}" \
    | sudo -u postgres "$PG_BIN/psql" -q -v ON_ERROR_STOP=1 -d postgres
  unset PG_PASSWORD
  echo "🔑 Пароль пользователя postgres установлен."
fi

echo
echo "✅ PostgreSQL Pro 1C версии $VERSION успешно установлена!"
echo "📦 Данные расположены в: $DATA_DIR"
if [[ "$NO_PASSWORD" == false ]]; then
  echo "👤 Пользователь для 1С: postgres (пароль задан при установке)"
fi
