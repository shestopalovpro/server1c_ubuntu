#!/bin/bash
set -e

# === Настройки ===
DOWNLOAD_URL="https://f1.atoldriver.ru/1c/latest.zip"   # Я сам выкладываю последнюю DEBx64 версию сервера 1с, прямой ссылки от вендора нет. Можете пользоваться моим сервером, либо реализуйте свое хранение.
WORKDIR="/opt/install-1c"                               # Временная папка для установки
LOGFILE="/var/log/1c_install.log"                       # Лог-файл установки

# === Логирование ===
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

# === Парсинг аргументов ===
TIMEZONE_PARAM=""
for arg in "$@"; do
    case $arg in
        --timezone=*)
            TIMEZONE_PARAM="${arg#*=}"
            ;;
        -h|--help)
            echo "Использование: $0 [--timezone=<zone>]"
            echo "Пример: $0 --timezone=Asia/Irkutsk"
            exit 0
            ;;
    esac
done

echo "🚀 Запуск установки/обновления 1С сервера"
echo "📄 Лог: $LOGFILE"
echo

# === Обновление системы ===
sudo apt update && sudo apt upgrade -y

# === Установка локали ===
sudo apt -y install locales
sudo locale-gen en_US.UTF-8 ru_RU.UTF-8
sudo update-locale LANG=ru_RU.UTF-8

# === Настройка часового пояса ===
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
            1)
                NEW_TZ="$CURRENT_TZ"; break;;
            2|3|4|5|6|7)
                NEW_TZ="$opt"; break;;
            8)
                read -rp "Введите свой часовой пояс (например, Europe/Samara): " NEW_TZ; break;;
            *)
                echo "❌ Неверный выбор, попробуйте снова.";;
        esac
    done
fi

echo "⏳ Устанавливаю часовой пояс: $NEW_TZ"
sudo timedatectl set-timezone "$NEW_TZ"
echo "✅ Часовой пояс установлен: $(timedatectl show -p Timezone --value)"
echo

# === Предотвращаем EULA popup ===
echo msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections

# === Установка зависимостей ===
sudo apt -y install ttf-mscorefonts-installer imagemagick unixodbc libgsf-bin t1utils unzip wget

# === Работаем в рабочей директории ===
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# === Скачиваем последнюю версию ===
echo "📦 Скачиваю последнюю версию 1С..."
wget -q -O deb64_latest.zip "$DOWNLOAD_URL"

# === Определяем версию из архива ===
FILENAME=$(unzip -l deb64_latest.zip | grep "deb64_" | head -1 | awk '{print $4}')
NEW_VERSION=$(echo "$FILENAME" | sed -E 's/.*deb64_([0-9_]+)\.tar\.gz/\1/' | tr '_' '.')
echo "🔍 Найдена версия для установки: $NEW_VERSION"

# === Проверяем, установлена ли 1С ===
if [ -d /opt/1cv8/x86_64 ]; then
    CURRENT_VERSION=$(ls /opt/1cv8/x86_64 | sort -V | tail -n1)
    echo "💡 Текущая установленная версия: $CURRENT_VERSION"
else
    CURRENT_VERSION="0.0.0.0"
    echo "ℹ️  1С не установлена, будет выполнена чистая установка."
fi

# === Функция сравнения версий ===
vercmp() {
    # Возвращает: 0 — равны, 1 — первая >, 2 — вторая >
    [ "$1" = "$2" ] && return 0
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=0; i<${#ver1[@]}; i++)); do
        [[ -z ${ver2[i]} ]] && ver2[i]=0
        ((10#${ver1[i]} > 10#${ver2[i]})) && return 1
        ((10#${ver1[i]} < 10#${ver2[i]})) && return 2
    done
    return 0
}

# === Сравнение версий ===
vercmp "$NEW_VERSION" "$CURRENT_VERSION"
cmp_result=$?

if [ "$cmp_result" -eq 0 ]; then
    echo "✅ Установлена та же версия ($CURRENT_VERSION). Обновление не требуется."
    exit 0
elif [ "$cmp_result" -eq 2 ]; then
    echo "✅ Установлена более новая версия ($CURRENT_VERSION). Обновление не требуется."
    exit 0
else
    echo "⬇️  Будет установлена новая версия: $NEW_VERSION (старше чем $CURRENT_VERSION)"
fi

# === Останавливаем старую службу ===
if systemctl list-units --full -all | grep -q "srv1cv8-${CURRENT_VERSION}@default.service"; then
    echo "⏹ Останавливаю текущую службу 1С..."
    sudo systemctl stop "srv1cv8-${CURRENT_VERSION}@default.service" || true
    sudo systemctl disable "srv1cv8-${CURRENT_VERSION}@default.service" || true
fi

# === Распаковываем новую версию ===
echo "📦 Распаковка архива..."
unzip -o deb64_latest.zip
tar xfz deb64_*.tar.gz

# === Устанавливаем пакеты ===
echo "⚙️  Устанавливаю пакеты 1С версии $NEW_VERSION..."
sudo dpkg -i 1c-enterprise-*-common_*_amd64.deb
sudo dpkg -i 1c-enterprise-*-server_*_amd64.deb
sudo dpkg -i 1c-enterprise-*-ws_*_amd64.deb

# === Настройка службы ===
SERVICE_PATH="/opt/1cv8/x86_64/$NEW_VERSION/srv1cv8-$NEW_VERSION@.service"

if [ -f "$SERVICE_PATH" ]; then
    echo "🔗 Настраиваю systemd для новой версии..."
    sudo systemctl link "$SERVICE_PATH"
    sudo systemctl enable "srv1cv8-$NEW_VERSION@default.service"
    sudo systemctl start "srv1cv8-$NEW_VERSION@default.service"
    echo "✅ 1С сервер версии $NEW_VERSION успешно установлен и запущен!"
else
    echo "❌ Файл службы не найден: $SERVICE_PATH"
    exit 1
fi

echo "🎉 Установка завершена успешно!"