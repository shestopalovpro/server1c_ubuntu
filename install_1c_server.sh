#!/bin/bash
# Copyright (c) 2025 Sergey Shestopalov
#
# Установка и обновление сервера 1С:Предприятие (8.3 или 8.5) на Ubuntu/Debian.
#
# Что делает скрипт:
#   1. Спрашивает, какую платформу ставить: 8.3 или 8.5 (или берёт из --version).
#   2. При первой установке (или с --force-setup) готовит систему:
#      обновление пакетов, локали ru_RU.UTF-8, часовой пояс, шрифты и зависимости.
#   3. Скачивает последний дистрибутив выбранной ветки с сервера
#      (latest_83.zip или latest_85.zip), определяет по DEB-пакетам его версию.
#   4. Сравнивает с уже установленной версией той же ветки и обновляет,
#      только если скачанная версия новее.
#   5. Устанавливает пакеты, регистрирует и запускает службу srv1cv8 в systemd.
#      Службы других установленных версий 1С останавливаются, чтобы не было
#      конфликта портов (1540/1541/1560-1591).

set -e

# === Настройки ===
DOWNLOAD_BASE_URL="https://f1.atoldriver.ru/1c"   # Сервер с дистрибутивами
WORKDIR="/opt/install-1c"                         # Временная рабочая папка
LOGFILE="/var/log/1c_install.log"                 # Журнал установки
ARCHIVE_STORAGE="/opt/1c-archives"                # Хранилище скачанных архивов
PACKAGE_STORAGE="/opt/1c-packages"                # Хранилище распакованных DEB-пакетов
INSTALL_ROOT="/opt/1cv8/x86_64"                   # Куда 1С ставит версии платформы

# === Справка ===
show_help() {
    cat <<EOF
Использование: sudo $0 [параметры]

Параметры:
  --version=8.3|8.5    Ветка платформы 1С. Без параметра скрипт спросит интерактивно.
                         8.3 — скачивается ${DOWNLOAD_BASE_URL}/latest_83.zip
                         8.5 — скачивается ${DOWNLOAD_BASE_URL}/latest_85.zip
  --timezone=<zone>    Часовой пояс при первичной настройке (пример: Asia/Irkutsk).
                       Без параметра будет предложен выбор из списка.
  --keep-archive       Не удалять скачанный zip-архив после установки
                       (DEB-пакеты сохраняются всегда).
  --force-setup        Выполнить первичную настройку системы, даже если 1С уже стоит.
  -y, --yes            Не задавать подтверждающих вопросов (смена ветки 8.3 <-> 8.5).
  -h, --help           Показать эту справку.

Примеры:
  sudo $0                                 # интерактивный выбор версии
  sudo $0 --version=8.3                   # установить/обновить последнюю 8.3
  sudo $0 --version=8.5 --timezone=Europe/Moscow --keep-archive
EOF
}

# === Парсинг аргументов ===
BRANCH=""
TIMEZONE_PARAM=""
KEEP_ARCHIVE=false
FORCE_SETUP=false
ASSUME_YES=false
for arg in "$@"; do
    case $arg in
        --version=*)    BRANCH="${arg#*=}" ;;
        --timezone=*)   TIMEZONE_PARAM="${arg#*=}" ;;
        --keep-archive) KEEP_ARCHIVE=true ;;
        --force-setup)  FORCE_SETUP=true ;;
        -y|--yes)       ASSUME_YES=true ;;
        -h|--help)      show_help; exit 0 ;;
        *)
            echo "❌ Неизвестный параметр: $arg"
            echo "ℹ️  Справка: $0 --help"
            exit 1
            ;;
    esac
done

# === Проверка прав ===
if [ "$EUID" -ne 0 ]; then
    echo "❌ Скрипт нужно запускать от root: sudo $0 $*"
    exit 1
fi

# === Логирование ===
mkdir -p "$(dirname "$LOGFILE")"
exec 3>&1   # исходный терминал: сюда рисуется прогресс-бар, минуя журнал
exec > >(tee -a "$LOGFILE") 2>&1

echo "🚀 Установка/обновление сервера 1С:Предприятие"
echo "📄 Журнал: $LOGFILE"
echo

# === Выбор ветки платформы ===
if [ -z "$BRANCH" ]; then
    echo "Какую платформу 1С установить?"
    PS3="Введите номер варианта: "
    options=(
        "8.3 — последняя версия 8.3 с сервера (latest_83.zip)"
        "8.5 — последняя версия 8.5 с сервера (latest_85.zip)"
    )
    select opt in "${options[@]}"; do
        case $REPLY in
            1) BRANCH="8.3"; break ;;
            2) BRANCH="8.5"; break ;;
            *) echo "❌ Неверный выбор, введите 1 или 2." ;;
        esac
    done
fi

case "$BRANCH" in
    8.3|83) BRANCH="8.3" ;;
    8.5|85) BRANCH="8.5" ;;
    *)
        echo "❌ Неподдерживаемая версия: $BRANCH (допустимо 8.3 или 8.5)"
        exit 1
        ;;
esac

DOWNLOAD_URL="$DOWNLOAD_BASE_URL/latest_${BRANCH//./}.zip"

echo "🎯 Выбрана платформа: $BRANCH"
echo "🌐 Источник дистрибутива: $DOWNLOAD_URL"
echo "💾 Хранилище архивов: $ARCHIVE_STORAGE"
echo "📦 Хранилище пакетов: $PACKAGE_STORAGE"
echo

mkdir -p "$ARCHIVE_STORAGE" "$PACKAGE_STORAGE" "$WORKDIR"

# === Что уже установлено ===
# Все версии платформы в /opt/1cv8/x86_64 (вида 8.3.27.1786), по возрастанию
INSTALLED_VERSIONS=$(ls "$INSTALL_ROOT" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V || true)

if [ -z "$INSTALLED_VERSIONS" ]; then
    IS_FIRST_INSTALL=true
    echo "ℹ️  1С на сервере не найдена — будет выполнена чистая установка."
else
    IS_FIRST_INSTALL=false
    echo "💡 Установленные версии платформы:"
    echo "$INSTALLED_VERSIONS" | sed 's/^/     - /'
fi

# Последняя установленная версия выбранной ветки (пусто, если ветки ещё нет)
CURRENT_VERSION=$(echo "$INSTALLED_VERSIONS" | grep -E "^${BRANCH//./\\.}\." | tail -n1 || true)
# Версии других веток (например, 8.3 при установке 8.5)
OTHER_BRANCH_VERSIONS=$(echo "$INSTALLED_VERSIONS" | grep -vE "^${BRANCH//./\\.}\." | grep -v '^$' || true)

if [ -n "$CURRENT_VERSION" ]; then
    echo "💡 Текущая версия ветки $BRANCH: $CURRENT_VERSION"
elif [ "$IS_FIRST_INSTALL" = false ]; then
    echo "ℹ️  Ветка $BRANCH ещё не установлена — будет добавлена рядом с имеющимися."
fi
echo

# === Предупреждение о смене ветки ===
if [ -z "$CURRENT_VERSION" ] && [ -n "$OTHER_BRANCH_VERSIONS" ] && [ "$ASSUME_YES" = false ]; then
    echo "⚠️  На сервере уже стоит 1С другой ветки: $(echo $OTHER_BRANCH_VERSIONS)"
    echo "   После установки $BRANCH её служба будет остановлена и отключена,"
    echo "   а запущен будет сервер $BRANCH (порты у них общие)."
    read -rp "Продолжить? (y/N): " CONFIRM
    case "$CONFIRM" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "❌ Операция отменена пользователем."; exit 1 ;;
    esac
    echo
fi

# === Первичная настройка системы (только при первой установке или --force-setup) ===
if [ "$IS_FIRST_INSTALL" = true ] || [ "$FORCE_SETUP" = true ]; then
    echo "🔧 Первичная настройка системы..."

    echo "🔄 Обновление списка пакетов и установленных пакетов..."
    apt-get update
    apt-get upgrade -y

    echo "🌐 Установка локалей ru_RU.UTF-8 и en_US.UTF-8..."
    apt-get install -y locales
    locale-gen en_US.UTF-8 ru_RU.UTF-8
    update-locale LANG=ru_RU.UTF-8

    echo "🕒 Настройка часового пояса..."
    CURRENT_TZ=$(timedatectl show -p Timezone --value)

    if [ -n "$TIMEZONE_PARAM" ]; then
        NEW_TZ="$TIMEZONE_PARAM"
        echo "Используется часовой пояс из параметра: $NEW_TZ"
    else
        echo "Текущий часовой пояс: $CURRENT_TZ"
        echo
        echo "Выберите новый часовой пояс или оставьте текущий:"
        PS3="Введите номер варианта: "
        options=(
            "Оставить текущий ($CURRENT_TZ)"
            "Europe/Moscow"
            "Asia/Yekaterinburg"
            "Asia/Novosibirsk"
            "Asia/Irkutsk"
            "Asia/Vladivostok"
            "Asia/Krasnoyarsk"
            "Указать вручную"
        )
        select opt in "${options[@]}"; do
            case $REPLY in
                1) NEW_TZ="$CURRENT_TZ"; break ;;
                2|3|4|5|6|7) NEW_TZ="$opt"; break ;;
                8) read -rp "Введите часовой пояс (например, Europe/Samara): " NEW_TZ; break ;;
                *) echo "❌ Неверный выбор, попробуйте снова." ;;
            esac
        done
    fi

    timedatectl set-timezone "$NEW_TZ"
    echo "✅ Часовой пояс: $(timedatectl show -p Timezone --value)"
    echo

    # Автоматически принимаем EULA шрифтов Microsoft, чтобы установка не остановилась на диалоге
    echo msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections

    echo "📦 Установка зависимостей 1С (шрифты, imagemagick, unixodbc и др.)..."
    apt-get install -y ttf-mscorefonts-installer imagemagick unixodbc libgsf-bin t1utils unzip wget
else
    echo "🔧 Первичная настройка системы пропущена (1С уже установлена)."
    echo "ℹ️  Чтобы выполнить её повторно, запустите с --force-setup"
fi
echo

# === Скачивание дистрибутива ===
echo "⬇️  Скачиваю последнюю версию 1С $BRANCH..."
ARCHIVE_PATH="$ARCHIVE_STORAGE/latest_${BRANCH//./}_$(date +%Y%m%d_%H%M%S).zip"

# Вывод идёт через tee в журнал, поэтому wget не видит терминал и печатает
# каждое обновление прогресса новой строкой. Если скрипт запущен в терминале,
# рисуем однострочный прогресс-бар (0–100%) прямо в него, мимо журнала.
# Без терминала (cron, перенаправление в файл) скачиваем молча.
if [ -t 3 ]; then
    WGET_PROGRESS=(--show-progress --progress=bar:force:noscroll)
else
    WGET_PROGRESS=()
fi

if ! wget -q "${WGET_PROGRESS[@]}" -O "$ARCHIVE_PATH" "$DOWNLOAD_URL" 2>&3; then
    echo "❌ Не удалось скачать $DOWNLOAD_URL"
    echo "   Проверьте доступ в интернет: wget --spider $DOWNLOAD_URL"
    rm -f "$ARCHIVE_PATH"
    exit 1
fi

if [ ! -s "$ARCHIVE_PATH" ]; then
    echo "❌ Архив не скачался или пустой: $ARCHIVE_PATH"
    rm -f "$ARCHIVE_PATH"
    exit 1
fi
echo "✅ Архив скачан: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | cut -f1))"

# === Распаковка и поиск DEB-пакетов ===
TEMP_EXTRACT="$WORKDIR/extract_$$"
trap 'rm -rf "$TEMP_EXTRACT"' EXIT
mkdir -p "$TEMP_EXTRACT"

echo "📦 Распаковка архива..."
unzip -q -o "$ARCHIVE_PATH" -d "$TEMP_EXTRACT"

DEB_FILES=$(find "$TEMP_EXTRACT" -name "*.deb" -type f | sort)
if [ -z "$DEB_FILES" ]; then
    echo "❌ В архиве не найдено DEB-пакетов. Содержимое архива:"
    find "$TEMP_EXTRACT" -maxdepth 3 | sed "s|$TEMP_EXTRACT|  .|"
    exit 1
fi

echo "✅ Найдены пакеты:"
echo "$DEB_FILES" | xargs -n1 basename | sed 's/^/     - /'

# === Определение версии дистрибутива ===
# Имя пакета вида 1c-enterprise-8.3.27.1786-common_8.3.27-1786_amd64.deb
FIRST_DEB=$(basename "$(echo "$DEB_FILES" | head -1)")
NEW_VERSION=$(echo "$FIRST_DEB" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$NEW_VERSION" ]; then
    # Запасной вариант для формата 8.3.27-1786
    NEW_VERSION=$(echo "$FIRST_DEB" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -1 | tr '-' '.' || true)
fi

if [ -z "$NEW_VERSION" ]; then
    echo "❌ Не удалось определить версию по имени пакета: $FIRST_DEB"
    exit 1
fi

# Защита от перепутанного архива на сервере (например, 8.3 в latest_85.zip)
if [[ "$NEW_VERSION" != "$BRANCH".* ]]; then
    echo "❌ В архиве $DOWNLOAD_URL версия $NEW_VERSION, а ожидалась ветка $BRANCH."
    echo "   Проверьте содержимое архива на сервере."
    exit 1
fi

echo "🔍 Версия дистрибутива: $NEW_VERSION"

# Даём архиву понятное имя с номером версии
FINAL_ARCHIVE_PATH="$ARCHIVE_STORAGE/1c_server_${NEW_VERSION}.zip"
mv -f "$ARCHIVE_PATH" "$FINAL_ARCHIVE_PATH"
ARCHIVE_PATH="$FINAL_ARCHIVE_PATH"

# === Нужно ли обновление ===
if [ -n "$CURRENT_VERSION" ]; then
    echo "🔍 Сравнение версий ветки $BRANCH: установлена $CURRENT_VERSION, на сервере $NEW_VERSION"
    HIGHER_VERSION=$(printf '%s\n%s\n' "$CURRENT_VERSION" "$NEW_VERSION" | sort -V | tail -n1)
    if [ "$HIGHER_VERSION" = "$CURRENT_VERSION" ]; then
        echo "✅ Установлена актуальная версия ($CURRENT_VERSION). Обновление не требуется."
        [ "$KEEP_ARCHIVE" = false ] && rm -f "$ARCHIVE_PATH"
        exit 0
    fi
    echo "⬆️  Будет выполнено обновление $CURRENT_VERSION → $NEW_VERSION"
else
    echo "⬇️  Будет установлена версия $NEW_VERSION"
fi
echo

# === Сохранение пакетов для повторного использования ===
PACKAGE_VERSION_DIR="$PACKAGE_STORAGE/$NEW_VERSION"
mkdir -p "$PACKAGE_VERSION_DIR"
cp -r "$TEMP_EXTRACT"/. "$PACKAGE_VERSION_DIR/"
echo "💾 Пакеты сохранены в: $PACKAGE_VERSION_DIR"

# === Установка пакетов ===
# Порядок важен: common → server → ws (и их -nls), затем остальные.
# apt-get сам доустановит недостающие зависимости из репозиториев.
echo "⚙️  Установка пакетов 1С $NEW_VERSION..."
ORDERED_DEBS=()
for pattern in "*-common_*" "*-common-nls_*" "*-server_*" "*-server-nls_*" "*-ws_*" "*-ws-nls_*"; do
    while IFS= read -r deb; do
        [ -n "$deb" ] && ORDERED_DEBS+=("$deb")
    done < <(find "$TEMP_EXTRACT" -name "$pattern.deb" -type f | sort)
done
# Прочие пакеты из архива (если есть), которые не попали в шаблоны выше
while IFS= read -r deb; do
    [[ " ${ORDERED_DEBS[*]} " == *" $deb "* ]] || ORDERED_DEBS+=("$deb")
done <<< "$DEB_FILES"

for deb in "${ORDERED_DEBS[@]}"; do
    echo "   📦 $(basename "$deb")"
done
apt-get install -y "${ORDERED_DEBS[@]}"

# === Остановка служб других версий 1С ===
# На сервере может работать только один srv1cv8 на стандартных портах
for unit in $(systemctl list-units --all --plain --no-legend 'srv1cv8*' | awk '{print $1}'); do
    if [[ "$unit" != *"-$NEW_VERSION@"* ]]; then
        echo "⏹  Останавливаю и отключаю службу $unit"
        systemctl stop "$unit" || true
        systemctl disable "$unit" || true
    fi
done

# === Регистрация и запуск службы ===
SERVICE_PATH=$(find "$INSTALL_ROOT/$NEW_VERSION" -maxdepth 1 -name "srv1cv8*@.service" -type f 2>/dev/null | head -1)
if [ -z "$SERVICE_PATH" ]; then
    SERVICE_PATH=$(find /opt/1cv8 -name "srv1cv8*$NEW_VERSION@.service" -type f 2>/dev/null | head -1)
fi

if [ -z "$SERVICE_PATH" ]; then
    echo "❌ Файл службы для версии $NEW_VERSION не найден."
    echo "ℹ️  Найдите его вручную: find /opt/1cv8 -name 'srv1cv8*.service'"
    exit 1
fi

SERVICE_TEMPLATE=$(basename "$SERVICE_PATH")      # srv1cv8-8.3.27.1786@.service
SERVICE_NAME="${SERVICE_TEMPLATE/@/@default}"      # srv1cv8-8.3.27.1786@default.service

echo "🔗 Регистрирую службу $SERVICE_NAME ($SERVICE_PATH)"
systemctl link "$SERVICE_PATH"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "✅ Служба $SERVICE_NAME запущена"
else
    echo "⚠️  Служба $SERVICE_NAME не запустилась. Подробности:"
    echo "     systemctl status $SERVICE_NAME"
    echo "     journalctl -u $SERVICE_NAME -n 50"
fi

# === Уборка ===
if [ "$KEEP_ARCHIVE" = false ]; then
    rm -f "$ARCHIVE_PATH"
    echo "🧹 Архив удалён (пакеты остаются в $PACKAGE_VERSION_DIR)"
else
    echo "💾 Архив сохранён: $ARCHIVE_PATH"
fi

echo
echo "📊 Итог:"
echo "   Платформа:          1С:Предприятие $NEW_VERSION"
echo "   Каталог установки:  $INSTALL_ROOT/$NEW_VERSION"
echo "   Служба:             $SERVICE_NAME"
echo "   Сохранённые пакеты: $(ls "$PACKAGE_STORAGE" | sort -V | tr '\n' ' ')"
echo
echo "🎉 Установка завершена!"
