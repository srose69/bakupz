#!/bin/bash

# ==============================================================================
# VXPX Interactive Backup & Restore Script
# Version: 10.1 (Improved Dependencies, Non-Local Volumes, PV Progress)
#
# Запускается из любой директории. Архивирует/восстанавливает содержимое
# текущей директории (CWD).
#
# Usage (Interactive): sudo ./backup.sh
# Usage (Non-Interactive/Cron): sudo ./backup.sh --non-interactive backup project1 project2
#                               sudo ./backup.sh --non-interactive restore /path/to/archive.srvbak
#
# ПРЕДУПРЕЖДЕНИЕ: Для выполнения операций требуется запуск с правами root (sudo).
# ==============================================================================

# Строгие настройки оболочки для повышения надежности и безопасности
set -euo pipefail

# --- КОНФИГУРАЦИЯ СЕРВИСА ---
DEFAULT_LANG="RU"
NON_INTERACTIVE="N"
MAX_LOGS=10 # Максимальное количество хранимых лог-файлов

# --- ТЕХНИЧЕСКИЕ ПЕРЕМЕННЫЕ ---
BASE_DIR="$PWD"
BACKUP_DIR="$BASE_DIR/backups"
TEMP_BASE="/tmp/vpx_backup_tmp"
CONFIG_ARCHIVE_NAME="configs.tar.xz"
DOCKER_META_FILE="docker_metadata.json"
LOG_FILE_NAME="vxpx_log_$(date +%Y-%m-%d_%H-%M-%S).txt"
DOCKER_ERROR_LOG="$BACKUP_DIR/docker_errors.log" # Целевой лог для ошибок Docker

# --- ПАРАМЕТРЫ ПРОИЗВОДИТЕЛЬНОСТИ ---
XZ_COMPRESSION_LEVEL="-3"
XZ_OPTS="$XZ_COMPRESSION_LEVEL -T0"
RSYNC_OPTS="-aHAX --delete" # --delete для точного соответствия источника и приемника

# --- ДОПОЛНИТЕЛЬНЫЕ СИСТЕМНЫЕ КОНФИГИ (расширяемый список) ---
CUSTOM_CONFIG_PATHS=(
    "/etc/ufw"
    "/etc/docker/daemon.json"
)

# --- СИГНАТУРА ---
SIGNATURE_SUFFIX='vxpx-bkp'
ARCHIVE_EXTENSION=".srvbak"
ARCHIVE_PREFIX="vxpx_full_backup"
HASH_ALGO="sha256sum"

# Длина сигнатуры: 2 (Magic) + 8 (Hash Prefix) + 9 (Suffix length) = 19
SIGNATURE_LENGTH=19

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- ЛОКАЛИЗАЦИЯ (RU/EN) ---

declare -A MSGS
lang_set() {
    local lang="${1:-$DEFAULT_LANG}"
    if [ "$lang" == "EN" ]; then
        MSGS[TITLE]='VXPX Interactive Backup Manager'
        MSGS[CWD]='Working Directory'
        MSGS[COMPRESSION_LEVEL]='XZ Compression Level'
        MSGS[MENU_1]='Create Backup'
        MSGS[MENU_2]='Restore System'
        MSGS[MENU_3]='View Logs'
        MSGS[MENU_4]='Exit'
        MSGS[CHOICE_PROMPT]='Select action (1-4):'
        MSGS[ERROR_ROOT]='Error: Please run the script as root (sudo ./backup.sh)'
        MSGS[ERROR_INVALID_CHOICE]='Invalid choice. Try again.'
        MSGS[CONFIRM_PROMPT]='Are you sure you want to proceed? [y/N]:'
        MSGS[RESTORE_ABORTED]='Restoration aborted.'
        MSGS[START_BACKUP]='--- Starting Backup Process (${TIMESTAMP}) from $BASE_DIR ---'
        MSGS[BACKUP_PARAMS]='Compression: xz $XZ_OPTS. Copy: rsync -aHAX --delete.'
        MSGS[BACKUP_PROJECTS_PROMPT]='Available subdirectories in $BASE_DIR for backup (select space-separated numbers):'
        MSGS[BACKUP_ALL]='all'
        MSGS[BACKUP_SCRIPT_INCL]='backup.sh (Script itself)'
        MSGS[BACKUP_CRIT_ERROR]='--- CRITICAL ERROR during archiving! ---'
        MSGS[FINAL_HASH_CHECK_FAIL]='Error: Final file hash mismatch. File may be corrupted.'
        MSGS[START_RESTORE]='--- WARNING: RESTORATION PROCESS in $BASE_DIR ---'
        MSGS[RESTORE_OVERWRITE_WARNING]='This action will overwrite existing files and configurations!'
        MSGS[RESTORE_SELECT_ARCHIVE]='1. Select and Verify Archive...'
        MSGS[RESTORE_ARCHIVE_NOT_FOUND]='Error: Archive file not found at '"'$archive_path'"
        MSGS[RESTORE_ARCHIVE_INVALID]='Error: File is not a valid VXPX backup.'
        MSGS[RESTORE_CONTENT_HASH_FAIL]='Error: Archive content hash mismatch. Extraction aborted.'
        MSGS[RESTORE_FINAL_SUCCESS]='--- Restoration Complete! ---'
        MSGS[RESTORE_VENV_PROMPT]='Restore Python Venv? (May be slow/require internet) [y/N]:'
        MSGS[RESTORE_VENV_SKIP]='> Venv restoration skipped by user request.'
        MSGS[DOCKER_SERVICE_UP_FAIL]='Error: Docker service restart failed. Check systemctl log.'
        MSGS[LOG_TITLE]='Backup Log'
        MSGS[LOG_NOT_FOUND]='Log files not found.'
        MSGS[LOG_SELECT]='Select log number to view (1-$((${#LOG_CHOICES[@]}))):'
        MSGS[LOG_VIEW_LATEST]='Viewing log:'
        MSGS[LOG_READ_PROMPT]='Press any key to continue...'
        MSGS[DOCKER_META_COLLECT]='1. Collecting Docker Metadata...'
        MSGS[DOCKER_ARCHIVE]='2. Archiving Docker Volumes (Incremental)...'
        MSGS[SYSTEM_ARCHIVE]='3. Archiving System Configurations...'
        MSGS[MAIN_ARCHIVE]='4. Creating and Finalizing Main Archive...'
        MSGS[VENV_CHECK_FAIL]='Critical Error: System dependency '"'"'python3-venv'"'"' not found. Attempting to install...'
        MSGS[VENV_INSTALL_FAIL]='Critical Error: Failed to install '"'"'python3-venv'"'"'. Please install manually.'
        MSGS[DRY_RUN_PROMPT]='Dry-Run? [y/N]:'
        MSGS[DRY_RUN_SKIPPED]='Dry-Run skipped. Starting full backup.'
        MSGS[DRY_RUN_SUCCESS]='Dry-Run successfully verified file paths and compression settings.'
        MSGS[DOCKER_ARCHIVE_ERROR]='Error archiving Docker volume'
        MSGS[SYSTEM_ARCHIVE_ERROR]='Error copying system config'
        MSGS[DEPS_INSTALL_FAIL]='Failed to install missing dependencies. Install manually:'
        MSGS[NON_LOCAL_VOLUME_WARN]='Warning: Non-local volume detected. Backup may be incomplete or require custom handling.'
    else
        MSGS[TITLE]='VXPX Интерактивный Backup-менеджер'
        MSGS[CWD]='Рабочая директория'
        MSGS[COMPRESSION_LEVEL]='Уровень сжатия XZ'
        MSGS[MENU_1]='Создать резервную копию системы'
        MSGS[MENU_2]='Восстановить систему из резервной копии'
        MSGS[MENU_3]='Просмотреть логи'
        MSGS[MENU_4]='Выход'
        MSGS[CHOICE_PROMPT]='Выберите действие (1-4):'
        MSGS[ERROR_ROOT]='Ошибка: Пожалуйста, запустите скрипт с правами root (sudo ./backup.sh)'
        MSGS[ERROR_INVALID_CHOICE]='Неверный выбор. Повторите попытку.'
        MSGS[CONFIRM_PROMPT]='Вы уверены, что хотите продолжить? [y/N]:'
        MSGS[RESTORE_ABORTED]='Восстановление отменено.'
        MSGS[START_BACKUP]='--- Начало процесса резервного копирования (${TIMESTAMP}) из $BASE_DIR ---'
        MSGS[BACKUP_PARAMS]='Параметры сжатия: xz $XZ_OPTS. Метод копирования: rsync -aHAX --delete.'
        MSGS[BACKUP_PROJECTS_PROMPT]='Доступные поддиректории в $BASE_DIR для бэкапа (выберите через пробел):'
        MSGS[BACKUP_ALL]='все'
        MSGS[BACKUP_SCRIPT_INCL]='backup.sh (Сам скрипт)'
        MSGS[BACKUP_CRIT_ERROR]='--- Критическая ошибка при архивировании! ---'
        MSGS[FINAL_HASH_CHECK_FAIL]='Ошибка: Финальный хеш файла не соответствует ожидаемому. Файл, возможно, поврежден.'
        MSGS[START_RESTORE]='--- ВНИМАНИЕ: ПРОЦЕСС ВОССТАНОВЛЕНИЯ в $BASE_DIR ---'
        MSGS[RESTORE_OVERWRITE_WARNING]='Это действие перезапишет существующие файлы и конфигурации!'
        MSGS[RESTORE_SELECT_ARCHIVE]='1. Выбор и Проверка Архива...'
        MSGS[RESTORE_ARCHIVE_NOT_FOUND]='Ошибка: Файл архива не найден по пути '"'$archive_path'"
        MSGS[RESTORE_ARCHIVE_INVALID]='Ошибка: Файл не является валидным VXPX бэкапом.'
        MSGS[RESTORE_CONTENT_HASH_FAIL]='Ошибка: Хеш содержимого архива не соответствует ожидаемому. Распаковка отменена.'
        MSGS[RESTORE_FINAL_SUCCESS]='--- Восстановление успешно завершено! ---'
        MSGS[RESTORE_VENV_PROMPT]='Восстановить Python Venv? (Может быть долго/требует интернет) [y/N]:'
        MSGS[RESTORE_VENV_SKIP]='> Восстановление Venv пропущено по запросу пользователя.'
        MSGS[DOCKER_SERVICE_UP_FAIL]='Ошибка: Перезапуск сервиса Docker не удался. Проверьте лог systemctl.'
        MSGS[LOG_TITLE]='Журнал Резервного Копирования'
        MSGS[LOG_NOT_FOUND]='Лог-файлы не найдены.'
        MSGS[LOG_SELECT]='Выберите номер лога для просмотра (1-$((${#LOG_CHOICES[@]}))):'
        MSGS[LOG_VIEW_LATEST]='Просмотр лога:'
        MSGS[LOG_READ_PROMPT]='Нажмите любую клавишу для продолжения...'
        MSGS[DOCKER_META_COLLECT]='1. Сбор метаданных Docker...'
        MSGS[DOCKER_ARCHIVE]='2. Архивирование Docker Volumes (Инкрементально)...'
        MSGS[SYSTEM_ARCHIVE]='3. Архивирование системных конфигураций...'
        MSGS[MAIN_ARCHIVE]='4. Создание и финализация основного архива...'
        MSGS[VENV_CHECK_FAIL]='Критическая ошибка: Не найдена системная зависимость '"'"'python3-venv'"'"'. Пытаемся установить...'
        MSGS[VENV_INSTALL_FAIL]='Критическая ошибка: Не удалось установить '"'"'python3-venv'"'"'. Установите вручную.'
        MSGS[DRY_RUN_PROMPT]='Выполнить Сухой запуск (Dry-Run)? [y/N]:'
        MSGS[DRY_RUN_SKIPPED]='Сухой запуск пропущен. Начинаем полный бэкап.'
        MSGS[DRY_RUN_SUCCESS]='Сухой запуск успешно проверил пути к файлам и настройки сжатия.'
        MSGS[DOCKER_ARCHIVE_ERROR]='Ошибка архивирования тома Docker'
        MSGS[SYSTEM_ARCHIVE_ERROR]='Ошибка копирования системной конфигурации'
        MSGS[DEPS_INSTALL_FAIL]='Не удалось установить недостающие зависимости. Установите вручную:'
        MSGS[NON_LOCAL_VOLUME_WARN]='Предупреждение: Обнаружен non-local том. Бэкап может быть неполным или требовать кастомной обработки.'
    fi
}

# --- ТЕХНИЧЕСКИЕ ФУНКЦИИ ---

check_dependencies() {
    local deps=("docker" "jq" "rsync" "xz" "sha256sum" "tar" "mktemp" "find" "awk" "sort" "xargs" "pv" "du")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Попытка установки недостающих зависимостей: ${missing[*]}${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "${missing[@]}" || { echo -e "${RED}${MSGS[DEPS_INSTALL_FAIL]} ${missing[*]}${NC}"; exit 1; }
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}" || { echo -e "${RED}${MSGS[DEPS_INSTALL_FAIL]} ${missing[*]}${NC}"; exit 1; }
        else
            echo -e "${RED}${MSGS[DEPS_INSTALL_FAIL]} ${missing[*]}${NC}"
            exit 1
        fi
        echo -e "${GREEN}Зависимости успешно установлены.${NC}"
    fi
}

extract_content_hash_prefix() {
    local filename="$1"
    echo "$filename" | sed -n 's/.*_H-\([0-9a-f]\{8\}\)_F-.*/\1/p'
}

extract_final_hash_prefix() {
    local filename="$1"
    echo "$filename" | sed -n 's/.*_F-\([0-9a-f]\{8\}\).*/\1/p'
}

extract_signature() {
    local file="$1"
    head -c $SIGNATURE_LENGTH "$file"
}

log_rotate() {
    local log_count
    log_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "vxpx_log_*.txt" | wc -l)
    
    if [ "$log_count" -gt "$MAX_LOGS" ]; then
        echo " > Выполняется ротация логов: найдено $log_count, лимит $MAX_LOGS."
        find "$BACKUP_DIR" -maxdepth 1 -name "vxpx_log_*.txt" -printf '%T@\t%p\n' | sort -n | head -n $((log_count - MAX_LOGS)) | cut -f 2- | xargs rm -f
        echo " > Старые логи удалены."
    fi
}

get_file_hash() { $HASH_ALGO "$1" | awk '{print $1}'; }

generate_signature() { 
    local full_hash="$1"
    local hash_prefix="${full_hash:0:8}"
    local magic_number=0

    for (( i=0; i<8; i++ )); do
        local char="${hash_prefix:$i:1}"
        if [[ "$char" =~ ^[0-9]$ ]]; then
            magic_number=$((magic_number + char))
        fi
    done
    
    printf "%02d%s%s" "$magic_number" "$hash_prefix" "$SIGNATURE_SUFFIX"
}

check_and_install_venv() {
    if python3 -c "import venv" &> /dev/null; then
        return 0
    fi

    echo -e "${RED}${MSGS[VENV_CHECK_FAIL]}${NC}"
    
    if command -v apt-get &> /dev/null; then
        if apt-get update && apt-get install -y python3-venv; then
            echo -e "${GREEN}Пакет python3-venv успешно установлен.${NC}"
            return 0
        fi
    elif command -v yum &> /dev/null; then
        if yum install -y python3-venv; then
            echo -e "${GREEN}Пакет python3-venv успешно установлен.${NC}"
            return 0
        fi
    fi

    echo -e "${RED}${MSGS[VENV_INSTALL_FAIL]}${NC}"
    return 1
}

cleanup() {
    local exit_status=$?
    if jobs -p > /dev/null 2>&1; then
        kill $(jobs -p) 2>/dev/null || true
    fi

    rm -rf "$TEMP_DIR" 2>/dev/null
    
    if [ "$exit_status" -ne 0 ]; then
        echo -e "${RED}--- Процесс завершился с ошибкой (Exit Code: $exit_status)! Временная директория очищена. ---${NC}" 1>&2
    fi
    if command -v exec &> /dev/null; then
        exec 1>&6 6>&-
    fi
    exit "$exit_status"
}

# =================================================
# ФУНКЦИЯ РЕЗЕРВНОГО КОПИРОВАНИЯ
# =================================================
backup_system() {
    check_dependencies
    log_rotate
    
    local TIMESTAMP
    TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d -p "$TEMP_BASE")
    
    exec 6>&1
    exec 1> >(tee -a "$BACKUP_DIR/$LOG_FILE_NAME") 2> >(tee -a "$DOCKER_ERROR_LOG")
    trap 'cleanup' EXIT

    echo -e "${GREEN}${MSGS[START_BACKUP]}${NC}"
    echo "${MSGS[BACKUP_PARAMS]}"
    
    local HASHES_DIR="$TEMP_DIR/hashes"
    local VOLUMES_DIR="$TEMP_DIR/volumes"
    local CONFIGS_DIR="$TEMP_DIR/configs"
    local PROJECTS_DIR="$TEMP_DIR/projects"
    
    mkdir -p "$HASHES_DIR" "$VOLUMES_DIR" "$CONFIGS_DIR" "$PROJECTS_DIR"

    local TARGET_PROJECTS=("${@}")
    local DRY_RUN_MODE="N"

    if [ "$NON_INTERACTIVE" == "N" ]; then
        # --- Интерактивный выбор проектов ---
        local AVAILABLE_PROJECTS=()
        while IFS= read -r dir; do
            local project_name
            project_name=$(basename "$dir")
            if [ "$project_name" = "backups" ] || [ "$project_name" = "$(basename "$TEMP_BASE")" ]; then continue; fi
            AVAILABLE_PROJECTS+=("$project_name")
        done < <(find "$BASE_DIR" -maxdepth 2 \( -name 'docker-compose.yml' -o -name 'requirements.txt' \) -printf '%h\n' | sort -u)

        AVAILABLE_PROJECTS+=("backup.sh")

        echo -e "\n${YELLOW}${MSGS[BACKUP_PROJECTS_PROMPT]}${NC}"
        for idx in "${!AVAILABLE_PROJECTS[@]}"; do
            echo " $idx) ${AVAILABLE_PROJECTS[$idx]}"
        done
        
        local INPUT_INDICES
        read -p "(${MSGS[BACKUP_ALL]}): " INPUT_INDICES < /dev/tty

        if [[ "$INPUT_INDICES" =~ "all" ]]; then
            TARGET_PROJECTS=("${AVAILABLE_PROJECTS[@]}")
        else
            for index in $INPUT_INDICES; do
                if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 0 ] && [ "$index" -lt ${#AVAILABLE_PROJECTS[@]} ]; then
                    TARGET_PROJECTS+=("${AVAILABLE_PROJECTS[$index]}")
                else
                    echo -e "${RED}Неверный индекс $index пропущен.${NC}"
                fi
            done
        fi
        
        read -p "${MSGS[DRY_RUN_PROMPT]}" DRY_RUN_MODE < /dev/tty
        if [[ "$DRY_RUN_MODE" =~ ^[yY]([eE][sS])?$ ]]; then
            DRY_RUN_MODE="Y"
            echo -e "${YELLOW}!!! DRY-RUN MODE ACTIVATED. NO FINAL ARCHIVE WILL BE CREATED. !!!${NC}"
        fi
    fi

    if [ ${#TARGET_PROJECTS[@]} -eq 0 ]; then
        echo -e "${RED}Не выбрано ни одного проекта. Выход.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Проекты для архивирования: ${TARGET_PROJECTS[@]}${NC}"

    # ----------------------------------------------------
    # 1. Сбор метаданных Docker
    # ----------------------------------------------------
    echo -e "\n${YELLOW}${MSGS[DOCKER_META_COLLECT]}${NC}"
    local META_FILE_PATH="$CONFIGS_DIR/$DOCKER_META_FILE"
    echo '{"networks": [], "volumes": []}' > "$META_FILE_PATH"

    local ALL_NET_JSON
    ALL_NET_JSON=$(docker network ls -q | xargs docker network inspect 2>/dev/null || echo '[]')
    jq --argjson new_nets "$ALL_NET_JSON" '.networks += $new_nets' "$META_FILE_PATH" > /tmp/meta_temp.json && mv /tmp/meta_temp.json "$META_FILE_PATH"

    local ALL_VOL_JSON
    ALL_VOL_JSON=$(docker volume ls -q | xargs docker volume inspect 2>/dev/null || echo '[]')
    jq --argjson new_vols "$ALL_VOL_JSON" '.volumes += $new_vols' "$META_FILE_PATH" > /tmp/meta_temp.json && mv /tmp/meta_temp.json "$META_FILE_PATH"
    
    echo "   -> Метаданные сохранены."

    # ----------------------------------------------------
    # 2. Сбор и архивация Docker Volumes (Incremental rsync)
    # ----------------------------------------------------
    echo -e "\n${YELLOW}${MSGS[DOCKER_ARCHIVE]}${NC}"
    local VOLUMES_JSON
    VOLUMES_JSON=$(jq -c '.volumes[]' "$META_FILE_PATH")
    
    local FIFO_PIPE="$TEMP_DIR/archive_names_fifo"
    mkfifo "$FIFO_PIPE" || { echo -e "${RED}Ошибка: Не удалось создать FIFO pipe.${NC}"; exit 1; }
    
    local READER_PID
    exec 3<>"$FIFO_PIPE" 

    local VOL_ARCHIVES_PASSED=()
    {
        while read -r line <&3; do
            if [[ "$line" == "ARCHIVE:"* ]]; then
                 VOL_ARCHIVES_PASSED+=("${line#ARCHIVE:}")
            fi
        done
    } &
    READER_PID=$!
    
    local PARALLEL_PIDS=()

    echo "$VOLUMES_JSON" | while read -r volume_json; do
        local volume_name
        local MOUNT_POINT
        local DRIVER
        
        volume_name=$(echo "$volume_json" | jq -r '.Name')
        MOUNT_POINT=$(echo "$volume_json" | jq -r '.Mountpoint')
        DRIVER=$(echo "$volume_json" | jq -r '.Driver')
        local VOL_ARCHIVE_NAME_BASE="volume-${volume_name}-${TIMESTAMP}"
        local FINAL_VOL_ARCHIVE_DIR="$VOLUMES_DIR/$volume_name"
        local ARCHIVE_TARGET="$FINAL_VOL_ARCHIVE_DIR/${VOL_ARCHIVE_NAME_BASE}.tar.xz"
        
        if [ "$DRIVER" != "local" ]; then
            echo -e "${YELLOW}${MSGS[NON_LOCAL_VOLUME_WARN]} ('$volume_name', driver: $DRIVER). Пропускаем или используйте кастомный бэкап.${NC}"
            continue
        fi
        
        if [ -d "$MOUNT_POINT" ]; then
            
            (
                set +e 
                
                # 1. Инкрементальное копирование rsync'ом (сохранение только измененных файлов)
                # Dry-run: Если это Dry-Run, rsync будет только проверять, но не писать
                if [ "$DRY_RUN_MODE" != "Y" ]; then
                    mkdir -p "$FINAL_VOL_ARCHIVE_DIR"
                    echo " > Rsync: $MOUNT_POINT -> $FINAL_VOL_ARCHIVE_DIR"
                    if ! rsync $RSYNC_OPTS "$MOUNT_POINT/" "$FINAL_VOL_ARCHIVE_DIR/"; then
                        echo "ERROR: Ошибка rsync при копировании тома '$volume_name'. Пропускаем." >&2
                        exit 1
                    fi
                fi
                
                # 2. Архивирование с PV для прогресса
                if [ "$DRY_RUN_MODE" != "Y" ]; then
                    if command -v pv &> /dev/null; then
                        local DIR_SIZE
                        DIR_SIZE=$(du -sb "$FINAL_VOL_ARCHIVE_DIR" | awk '{print $1}')
                        if ! tar -C "$FINAL_VOL_ARCHIVE_DIR" -cf - . 2>/dev/null | pv -s "$DIR_SIZE" | xz $XZ_OPTS -c - > "$ARCHIVE_TARGET"; then
                            echo "ERROR: ${MSGS[DOCKER_ARCHIVE_ERROR]} '$volume_name'. Пропускаем." >&2
                            rm -f "$ARCHIVE_TARGET"
                            exit 1
                        fi
                    else
                        echo -e "${YELLOW}PV не найден, использую базовое архивирование без прогресс-бара.${NC}"
                        if ! tar -C "$FINAL_VOL_ARCHIVE_DIR" -cf - . 2>/dev/null | xz $XZ_OPTS -c - > "$ARCHIVE_TARGET"; then
                            echo "ERROR: ${MSGS[DOCKER_ARCHIVE_ERROR]} '$volume_name'. Пропускаем." >&2
                            rm -f "$ARCHIVE_TARGET"
                            exit 1
                        fi
                    fi
                fi

                local VOL_HASH="DRY_RUN_HASH"
                if [ "$DRY_RUN_MODE" != "Y" ]; then
                    VOL_HASH=$(get_file_hash "$ARCHIVE_TARGET")
                fi
                local HASH_FILENAME="${VOL_HASH:0:8}"
                
                local FINAL_VOL_ARCHIVE_NAME="${VOL_ARCHIVE_NAME_BASE}_H-${HASH_FILENAME}${ARCHIVE_EXTENSION}"
                
                if [ "$DRY_RUN_MODE" != "Y" ]; then
                    mv "$ARCHIVE_TARGET" "$VOLUMES_DIR/$FINAL_VOL_ARCHIVE_NAME"
                    echo "$VOL_HASH" > "$HASHES_DIR/${FINAL_VOL_ARCHIVE_NAME}.hash"
                fi
                
                echo "ARCHIVE:$FINAL_VOL_ARCHIVE_NAME" >&3
                echo "   -> Том '$volume_name' завершен. Хеш: ${VOL_HASH}"
                
            ) &
            PARALLEL_PIDS+=($!)
        else
            echo " > Точка монтирования для тома '$volume_name' не найдена. Пропускаем."
        fi
    done

    local had_error=0
    for job_pid in "${PARALLEL_PIDS[@]}"; do
        wait "$job_pid" || had_error=1
    done
    
    exec 3>&-
    wait $READER_PID
    rm -f "$FIFO_PIPE"

    if [ "$had_error" -ne 0 ]; then
        echo -e "${RED}Обнаружены ошибки при архивировании одного или нескольких томов!${NC}"
        exit 1
    fi

    # ----------------------------------------------------
    # 3. Сбор и архивация System Configs
    # ----------------------------------------------------
    echo -e "\n${YELLOW}${MSGS[SYSTEM_ARCHIVE]}${NC}"
    
    for config_path in "${CUSTOM_CONFIG_PATHS[@]}"; do
        if [ -e "$config_path" ]; then
            if ! tar -C / -cf - "${config_path#/}" | tar -C "$CONFIGS_DIR" -xf - 2>/dev/null; then
                echo -e "${RED} > ${MSGS[SYSTEM_ARCHIVE_ERROR]} $config_path. Пропускаем.${NC}"
            else
                echo " > Конфигурация $config_path скопирована."
            fi
        else
            echo " > Конфигурация $config_path не найдена. Пропускаем."
        fi
    done
    
    if find "$CONFIGS_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        if ! tar -C "$CONFIGS_DIR" -cJf "$CONFIGS_DIR/$CONFIG_ARCHIVE_NAME" . >/dev/null 2>&1; then
            echo -e "${RED} > Ошибка при создании архива конфигураций! Пропускаем конфиги.${NC}"
            rm -f "$CONFIGS_DIR/$CONFIG_ARCHIVE_NAME"
        else
            local CONFIG_ARCHIVE_HASH
            CONFIG_ARCHIVE_HASH=$(get_file_hash "$CONFIGS_DIR/$CONFIG_ARCHIVE_NAME")
            echo "$CONFIG_ARCHIVE_HASH" > "$HASHES_DIR/${CONFIG_ARCHIVE_NAME}.hash"
            echo "   -> Конфигурационный архив создан. Хеш: ${GREEN}${CONFIG_ARCHIVE_HASH}${NC}"
        fi
    else
        echo -e "${YELLOW} > Системные конфигурации для бэкапа не найдены.${NC}"
    fi

    # ----------------------------------------------------
    # 4. Копирование проектов и Финализация
    # ----------------------------------------------------
    echo -e "\n${YELLOW}${MSGS[MAIN_ARCHIVE]}${NC}"
    
    # Копирование выбранных проектов rsync'ом в projects/
    for project in "${TARGET_PROJECTS[@]}"; do
        local rsync_source=""
        local rsync_target=""
        local is_file="N"
        
        if [ "$project" == "backup.sh" ]; then
            rsync_source="$BASE_DIR/backup.sh"
            rsync_target="$PROJECTS_DIR/"
            is_file="Y"
        elif [ -d "$BASE_DIR/$project" ]; then
            rsync_source="$BASE_DIR/$project/"
            rsync_target="$PROJECTS_DIR/$project"
        elif [ -f "$BASE_DIR/$project" ]; then
            rsync_source="$BASE_DIR/$project"
            rsync_target="$PROJECTS_DIR/$project"
            is_file="Y"
        else
            echo " > Проект '$project' не найден. Пропускаем."
            continue
        fi

        if [ "$DRY_RUN_MODE" == "Y" ]; then
            echo " > Dry-Run rsync: $rsync_source -> $rsync_target"
            rsync --dry-run $RSYNC_OPTS "$rsync_source" "$rsync_target" || { echo -e "${RED}Dry-Run FAILED: Ошибка rsync для $project.${NC}"; exit 1; }
        else
            if ! rsync $RSYNC_OPTS "$rsync_source" "$rsync_target"; then
                echo -e "${RED} > Ошибка rsync при копировании проекта '$project'.${NC}"
                exit 1
            fi
        fi
        echo " > Проект '$project' скопирован."
    done

    # Dry-Run exit
    if [ "$DRY_RUN_MODE" == "Y" ]; then
        echo -e "${GREEN}${MSGS[DRY_RUN_SUCCESS]}${NC}"
        exit 0
    fi
    
    local TEMP_ARCHIVE_NAME="${ARCHIVE_PREFIX}_${TIMESTAMP}.tmp.tar.xz"
    local TEMP_ARCHIVE_PATH="$BACKUP_DIR/$TEMP_ARCHIVE_NAME"
    
    # Создание основного архива (Всегда с относительными путями от TEMP_DIR)
    cd "$TEMP_DIR"
    local FINAL_TAR_ARGS=()
    FINAL_TAR_ARGS+=( "volumes" )
    FINAL_TAR_ARGS+=( "configs" )
    FINAL_TAR_ARGS+=( "projects" )
    FINAL_TAR_ARGS+=( "hashes" )

    if ! tar -cvJpf "$TEMP_ARCHIVE_PATH" "${FINAL_TAR_ARGS[@]}"; then
        echo -e "${RED}${MSGS[BACKUP_CRIT_ERROR]}${NC}"
        exit 1
    fi
    
    # Финализация
    local CONTENT_HASH
    CONTENT_HASH=$(get_file_hash "$TEMP_ARCHIVE_PATH")
    local ARCHIVE_SIGNATURE
    ARCHIVE_SIGNATURE=$(generate_signature "$CONTENT_HASH")
    
    local FINAL_ARCHIVE_PATH_TEMP="$BACKUP_DIR/${ARCHIVE_PREFIX}_${TIMESTAMP}.sig_temp"
    
    echo -n "$ARCHIVE_SIGNATURE" > "$TEMP_DIR/signature.tmp"
    
    cat "$TEMP_DIR/signature.tmp" "$TEMP_ARCHIVE_PATH" > "$FINAL_ARCHIVE_PATH_TEMP"
    
    local FINAL_FILE_HASH
    FINAL_FILE_HASH=$(get_file_hash "$FINAL_ARCHIVE_PATH_TEMP")
    
    local FINAL_ARCHIVE_NAME_WITH_HASH="${ARCHIVE_PREFIX}_${TIMESTAMP}_H-${CONTENT_HASH:0:8}_F-${FINAL_FILE_HASH:0:8}${ARCHIVE_EXTENSION}"
    mv "$FINAL_ARCHIVE_PATH_TEMP" "$BACKUP_DIR/$FINAL_ARCHIVE_NAME_WITH_HASH"
    FINAL_ARCHIVE_PATH="$BACKUP_DIR/$FINAL_ARCHIVE_NAME_WITH_HASH"

    echo -e "\n${GREEN}--- Резервное копирование успешно завершено! ---${NC}"
    echo "Параметры сжатия: xz $XZ_OPTS"
    echo "Сигнатура:  ${GREEN}${ARCHIVE_SIGNATURE}${NC}"
    echo "Хеш содержимого:     ${GREEN}${CONTENT_HASH}${NC}"
    echo "Финальный хеш файла: ${GREEN}${FINAL_FILE_HASH}${NC}"
    echo "Архив сохранен в: ${GREEN}$FINAL_ARCHIVE_PATH${NC}"
    
    cd "$BASE_DIR"
}

# =================================================
# ФУНКЦИЯ ОСТАНОВКИ/ЗАПУСКА DOCKER-COMPOSE
# =================================================
manage_docker_services() {
    local action="$1"
    local compose_files
    
    compose_files=$(find "$BASE_DIR" -maxdepth 2 -name "docker-compose.yml" -print)
    
    if [ -z "$compose_files" ]; then
        echo " > Docker Compose файлы в $BASE_DIR не найдены. Пропускаем $action."
        return 0
    fi

    echo " > Выполнение '$action' для найденных Docker Compose файлов..."
    local success_count=0
    local fail_count=0
    
    while IFS= read -r file; do
        local dir
        dir=$(dirname "$file")
        echo "   -> $action: $file"
        
        (
            set +e 
            cd "$dir"
            local output
            if command -v docker compose &> /dev/null; then
                output=$(docker compose "$action" 2>&1)
            elif command -v docker-compose &> /dev/null; then
                output=$(docker-compose "$action" 2>&1)
            fi
            local exit_status="$?"
            
            if [ "$exit_status" -ne 0 ]; then
                echo "Docker Error: $output" >&2
                exit 1
            fi
            exit 0
        )
        
        if [ $? -eq 0 ]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            echo -e "${RED}   -> ОШИБКА: Не удалось выполнить $action для $file. Проверьте конфигурацию.${NC}"
        fi
    done < <(echo "$compose_files")
    
    sleep 3
    echo " > Управление сервисами завершено (Успешно: $success_count, С ошибками: $fail_count)."
    
    if [ "$action" == "up" ] && [ "$success_count" -gt 0 ]; then
        echo -e "\n${YELLOW}Проверка статуса контейнеров...${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep 'Up' || echo "   -> Нет запущенных контейнеров."
    fi
}


# =================================================
# ФУНКЦИЯ ВОССТАНОВЛЕНИЯ
# =================================================
restore_system() {
    check_dependencies
    
    local ARCHIVE_PATH_ARG=""
    if [ $# -gt 0 ]; then
        ARCHIVE_PATH_ARG="$1"
    fi

    local TEMP_DIR
    TEMP_DIR=$(mktemp -d -p "$TEMP_BASE")
    trap 'cleanup' EXIT

    exec 6>&1
    exec 1> >(tee -a "$BACKUP_DIR/$LOG_FILE_NAME") 2> >(tee -a "$DOCKER_ERROR_LOG")
    
    echo -e "${RED}${MSGS[START_RESTORE]}${NC}"
    echo -e "${YELLOW}${MSGS[RESTORE_OVERWRITE_WARNING]}${NC}"
    
    if [ "$NON_INTERACTIVE" == "N" ]; then
        read -p "${MSGS[CONFIRM_PROMPT]}" confirm < /dev/tty
        if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
            echo "${MSGS[RESTORE_ABORTED]}"
            exit 0
        fi
    fi
    
    # --- 1. Выбор файла и Проверка ---
    echo -e "\n${YELLOW}${MSGS[RESTORE_SELECT_ARCHIVE]}${NC}"
    local archive_path
    
    if [ "$NON_INTERACTIVE" == "Y" ]; then
        archive_path="$ARCHIVE_PATH_ARG"
    else
        local ARCHIVES=("$BACKUP_DIR"/*"$ARCHIVE_EXTENSION")
        if [ ! -d "$BACKUP_DIR" ] || [ ${#ARCHIVES[@]} -eq 0 ] || [ ! -f "${ARCHIVES[0]}" ]; then
            echo -e "${RED}Ошибка: Директория бэкапов $BACKUP_DIR пуста или не существует.${NC}"
            read -p "Введите полный путь к архиву для восстановления: " archive_path < /dev/tty
        else
            echo "Доступные архивы в $BACKUP_DIR:"
            local i=1
            local ARCHIVE_CHOICES=()
            for f in "${ARCHIVES[@]}"; do
                ARCHIVE_CHOICES+=("$f")
                echo " $i) $(basename "$f")"
                i=$((i+1))
            done
            read -p "Выберите номер архива для восстановления (1-$((${#ARCHIVES[@]}))): " selection < /dev/tty
            
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#ARCHIVES[@]}" ]; then
                archive_path="${ARCHIVE_CHOICES[$((selection-1))]}"
            else
                echo -e "${RED}Неверный выбор. Выход.${NC}"
                exit 1
            fi
        fi
    fi

    if [ ! -f "$archive_path" ] || [[ ! "$archive_path" =~ \.srvbak$ ]]; then
        echo -e "${RED}${MSGS[RESTORE_ARCHIVE_NOT_FOUND]}${NC}"
        exit 1
    fi
    
    local FILENAME
    FILENAME=$(basename "$archive_path")
    local EXPECTED_CONTENT_PREFIX
    EXPECTED_CONTENT_PREFIX=$(extract_content_hash_prefix "$FILENAME")
    
    local ACTUAL_FINAL_HASH
    ACTUAL_FINAL_HASH=$(get_file_hash "$archive_path")

    if ! [[ "$ACTUAL_FINAL_HASH" =~ ^$(extract_final_hash_prefix "$FILENAME") ]]; then
        echo -e "${RED}${MSGS[FINAL_HASH_CHECK_FAIL]}${NC}"
        exit 1
    fi
    echo -e "${GREEN}Финальный хеш файла проверен и соответствует.${NC}"

    local ACTUAL_SIGNATURE
    ACTUAL_SIGNATURE=$(extract_signature "$archive_path")
    
    local HASH_PREFIX_IN_SIG
    HASH_PREFIX_IN_SIG=$(echo "$ACTUAL_SIGNATURE" | sed -n 's/..\(........\).*/\1/p')
    
    if [ "$HASH_PREFIX_IN_SIG" != "$EXPECTED_CONTENT_PREFIX" ] || [[ ! "$ACTUAL_SIGNATURE" =~ $SIGNATURE_SUFFIX$ ]]; then
        echo -e "${RED}${MSGS[RESTORE_ARCHIVE_INVALID]}${NC}"
        exit 1
    fi
    echo -e "${GREEN}Сигнатура верна.${NC}"

    local TEMP_ARCHIVE_PATH_NO_SIG
    TEMP_ARCHIVE_PATH_NO_SIG=$(mktemp --suffix=".tmp.tar.xz")
    
    tail -c +$((SIGNATURE_LENGTH + 1)) "$archive_path" > "$TEMP_ARCHIVE_PATH_NO_SIG"

    local ACTUAL_CONTENT_HASH
    ACTUAL_CONTENT_HASH=$(get_file_hash "$TEMP_ARCHIVE_PATH_NO_SIG")

    if [[ ! "$ACTUAL_CONTENT_HASH" =~ ^$EXPECTED_CONTENT_PREFIX ]]; then
        echo -e "${RED}${MSGS[RESTORE_CONTENT_HASH_FAIL]}${NC}"
        rm "$TEMP_ARCHIVE_PATH_NO_SIG"
        exit 1
    fi
    echo -e "${GREEN}Хеш содержимого архива проверен и соответствует.${NC}"


    # --- 2. Распаковка и восстановление файлов ---
    echo -e "\n${YELLOW}2. Распаковка файлов...${NC}"
    local RESTORE_TEMP_DIR
    RESTORE_TEMP_DIR=$(mktemp -d)
    
    manage_docker_services down

    if ! tar -xvJpf "$TEMP_ARCHIVE_PATH_NO_SIG" -C "$RESTORE_TEMP_DIR"; then
        echo -e "${RED}--- Ошибка при распаковке основного архива! ---${NC}"
        exit 1
    fi

    echo "Копирование файлов проекта в $BASE_DIR, сохраняя права и владельцев (rsync -aHAX)..."
    
    if ! rsync -aHAX "$RESTORE_TEMP_DIR/projects/" "$BASE_DIR/"; then
         echo -e "${RED}--- Ошибка rsync при копировании файлов проекта! Продолжаем, чтобы восстановить Docker-конфиги.${NC}"
    fi

    
    # --- 3. Восстановление системных конфигураций ---
    echo -e "\n${YELLOW}3. Восстановление системных конфигураций...${NC}"
    
    local CONFIG_ARCHIVE_PATH_RESTORE="$RESTORE_TEMP_DIR/configs/$CONFIG_ARCHIVE_NAME"
    local DOCKER_META_PATH_RESTORE="$RESTORE_TEMP_DIR/configs/$DOCKER_META_FILE"
    
    if [ -f "$CONFIG_ARCHIVE_PATH_RESTORE" ]; then
        local ACTUAL_CONFIG_HASH
        ACTUAL_CONFIG_HASH=$(get_file_hash "$CONFIG_ARCHIVE_PATH_RESTORE")
        local EXPECTED_CONFIG_HASH
        EXPECTED_CONFIG_HASH=$(cat "$RESTORE_TEMP_DIR/hashes/${CONFIG_ARCHIVE_NAME}.hash" 2>/dev/null)

        if [ "$ACTUAL_CONFIG_HASH" != "$EXPECTED_CONFIG_HASH" ]; then
            echo -e "${RED}Ошибка: Хеш архива системных конфигураций НЕ совпадает. Пропускаем восстановление системных конфигов!${NC}"
        else
            echo -e "${GREEN}Хеш архива системных конфигураций совпадает.${NC}"
            
            echo " > Распаковка конфигураций в корень системы (/)..."
            if ! tar -xvJpf "$CONFIG_ARCHIVE_PATH_RESTORE" -C /; then
                echo -e "${RED} > Ошибка при распаковке системных конфигов!${NC}"
            fi
            
            echo " > Перезагрузка правил UFW..."
            ufw reload
            
            echo " > Перезапуск сервиса Docker (для применения daemon.json)..."
            systemctl restart docker
            if [ $? -ne 0 ]; then
                echo -e "${RED} > ${MSGS[DOCKER_SERVICE_UP_FAIL]}${NC}"
            fi
        fi
    else
        echo -e "${YELLOW} > Архив системных конфигураций не найден. Пропускаем.${NC}"
    fi

    
    # --- 4. Восстановление Docker Networks и Volumes ---
    echo -e "\n${YELLOW}4. Восстановление Docker Networks и Volumes...${NC}"
    
    # a. Восстановление Docker Networks
    echo " > Восстановление Docker Networks..."
    while IFS= read -r network_json; do
        local network_name
        network_name=$(echo "$network_json" | jq -r '.Name')
        
        if [ -n "$network_name" ]; then
            if ! docker network inspect "$network_name" &> /dev/null; then
                local driver
                driver=$(echo "$network_json" | jq -r '.Driver')
                local options
                options=$(echo "$network_json" | jq -r '.Options | to_entries | map("--opt \(.key)=\(.value)") | join(" ")')
                
                echo "   -> Создание сети '$network_name'..."
                docker network create --driver "$driver" $options "$network_name" 2>/dev/null || echo "   -> ${RED}Ошибка при создании сети '$network_name'.${NC}"
            fi
        fi
    done < <(jq -c '.networks[]' "$DOCKER_META_PATH_RESTORE" 2>/dev/null || echo "")
    
    # b. Восстановление Docker Volumes
    echo " > Восстановление Docker Volumes (данных)..."
    while IFS= read -r volume_json; do
        local VOL_NAME
        VOL_NAME=$(echo "$volume_json" | jq -r '.Name')
        
        local VOL_ARCHIVE_NAME_PATTERN
        VOL_ARCHIVE_NAME_PATTERN="volume-${VOL_NAME}-*_H-*"
        local VOL_ARCHIVE_PATH=$(find "$RESTORE_TEMP_DIR/volumes" -maxdepth 1 -type f -name "$VOL_ARCHIVE_NAME_PATTERN$ARCHIVE_EXTENSION" 2>/dev/null | head -n 1)

        if [ -z "$VOL_ARCHIVE_PATH" ]; then
            echo -e "${YELLOW} > Внимание: Архив данных для тома '$VOL_NAME' не найден. Пропускаем восстановление данных.${NC}"
            continue
        fi

        local VOL_FILENAME=$(basename "$VOL_ARCHIVE_PATH")
        local EXPECTED_VOL_HASH_PREFIX
        EXPECTED_VOL_HASH_PREFIX=$(extract_content_hash_prefix "$VOL_FILENAME")
        
        local EXPECTED_VOL_FULL_HASH
        EXPECTED_VOL_FULL_HASH=$(cat "$RESTORE_TEMP_DIR/hashes/${VOL_FILENAME}.hash" 2>/dev/null)
        
        local ACTUAL_VOL_HASH
        ACTUAL_VOL_HASH=$(get_file_hash "$VOL_ARCHIVE_PATH")
        
        if [ "$ACTUAL_VOL_HASH" == "$EXPECTED_VOL_FULL_HASH" ]; then
            echo -e "${GREEN} > Хеш архива тома '$VOL_NAME' совпадает.${NC}"

            if ! docker volume inspect "$VOL_NAME" &> /dev/null; then
                local driver
                driver=$(echo "$volume_json" | jq -r '.Driver')
                local options
                options=$(echo "$volume_json" | jq -r '.Options | to_entries | map("--opt \(.key)=\(.value)") | join(" ")')
                
                echo "   -> Создание тома '$VOL_NAME' с метаданными..."
                docker volume create --driver "$driver" $options "$VOL_NAME" 2>/dev/null || echo "   -> ${RED}Ошибка при создании тома '$VOL_NAME'.${NC}"
            fi

            echo "   -> Распаковка данных в том '$VOL_NAME'..."
            local DOCKER_IMAGE="ubuntu:22.04"
            if ! docker run --rm -v "$VOL_NAME":/target -v "$(dirname "$VOL_ARCHIVE_PATH")":/backup --entrypoint /bin/bash "$DOCKER_IMAGE" -c "tar -xvJpf /backup/$(basename "$VOL_ARCHIVE_PATH") -C /target --strip-components=1"; then
                 echo -e "${RED}   -> Ошибка при распаковке в том '$VOL_NAME'.${NC}"
            fi
        else
            echo -e "${RED} > Ошибка: Хеш архива тома '$VOL_NAME' НЕ совпадает. Том не восстановлен.${NC}"
        fi
    done < <(jq -c '.volumes[]' "$DOCKER_META_PATH_RESTORE" 2>/dev/null || echo "")

    # --- 5. Восстановление окружений и прав ---
    echo -e "\n${YELLOW}5. Восстановление окружений Python...${NC}"
    
    if check_and_install_venv; then
        local restore_venv="N"
        if [ "$NON_INTERACTIVE" == "Y" ]; then
            echo " > Пропуск интерактивного запроса Venv."
        else
            read -p "${MSGS[RESTORE_VENV_PROMPT]}" restore_venv < /dev/tty
        fi

        if [[ "$restore_venv" =~ ^[yY]([eE][sS])?$ ]]; then
            while IFS= read -r req_file; do
                local project_dir
                project_dir=$(dirname "$req_file")
                local project_name
                project_name=$(basename "$project_dir")
                local venv_path="$project_dir/venv"

                echo " > Воссоздание venv для '$project_name'..."
                if [ -f "$req_file" ]; then
                    rm -rf "$venv_path"
                    if python3 -m venv "$venv_path"; then
                        if "$venv_path/bin/pip" install -r "$req_file"; then
                            echo -e "${GREEN}   -> Venv для '$project_name' успешно воссоздан.${NC}"
                        else
                            echo -e "${RED}   -> Ошибка: Pip install не удался для '$project_name'.${NC}"
                        fi
                    else
                        echo -e "${RED}   -> Ошибка: Создание Venv не удалось для '$project_name'.${NC}"
                    fi
                fi
            done < <(find "$BASE_DIR" -maxdepth 2 -name "requirements.txt" -print)
        else
            echo -e "${YELLOW}${MSGS[RESTORE_VENV_SKIP]}${NC}"
        fi
    fi

    echo -e "\n${YELLOW}6. Установка прав на выполнение скриптов...${NC}"
    chmod +x "$BASE_DIR/backup.sh"
    
    find "$BASE_DIR" -maxdepth 2 -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null

    echo -e "\n${YELLOW}7. Запуск сервисов Docker...${NC}"
    manage_docker_services up -d

    echo -e "\n${GREEN}${MSGS[RESTORE_FINAL_SUCCESS]}${NC}"
    echo "Проверьте статус контейнеров командой: docker ps"
    
    rm "$TEMP_ARCHIVE_PATH_NO_SIG"
}

# =================================================
# ФУНКЦИЯ ПРОСМОТРА ЛОГОВ
# =================================================
view_logs() {
    clear
    echo "========================================"
    echo -e "      ${MSGS[LOG_TITLE]}"
    echo "========================================"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${YELLOW}Директория бэкапов не найдена: $BACKUP_DIR${NC}"
        read -n 1 -s -r -p "${MSGS[LOG_READ_PROMPT]}" < /dev/tty
        return 0
    fi

    local LOG_FILES_PATHS
    LOG_FILES_PATHS=$(find "$BACKUP_DIR" -maxdepth 1 -name "vxpx_log_*.txt" -exec ls -t {} + 2>/dev/null)

    if [ -z "$LOG_FILES_PATHS" ]; then
        echo -e "${YELLOW}${MSGS[LOG_NOT_FOUND]}${NC}"
        read -n 1 -s -r -p "${MSGS[LOG_READ_PROMPT]}" < /dev/tty
        return 0
    fi
    
    local LOG_CHOICES=()
    
    echo "Доступные лог-файлы (начиная с самого свежего):"
    
    local i=1
    while IFS= read -r path; do
        LOG_CHOICES+=("$path")
        echo " $i) $(basename "$path")"
        i=$((i+1))
    done < <(echo "$LOG_FILES_PATHS")

    read -p "${MSGS[LOG_SELECT]}" selection < /dev/tty

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#LOG_CHOICES[@]}" ]; then
        local log_to_view="${LOG_CHOICES[$((selection-1))]}"
        
        echo -e "\n${MSGS[LOG_VIEW_LATEST]} ${YELLOW}$(basename "$log_to_view")${NC}"
        echo "========================================"
        cat "$log_to_view"
        echo "========================================"
    else
        echo -e "${RED}Неверный выбор.${NC}"
    fi

    read -n 1 -s -r -p "${MSGS[LOG_READ_PROMPT]}" < /dev/tty
}

# =================================================
# ГЛАВНОЕ МЕНЮ
# =================================================
main_menu() {
    clear
    echo "========================================"
    echo -e "    ${MSGS[TITLE]}"
    echo "========================================"
    echo -e "1. ${MSGS[MENU_1]}"
    echo -e "2. ${MSGS[MENU_2]}"
    echo -e "3. ${MSGS[MENU_3]}"
    echo -e "4. ${MSGS[MENU_4]}"
    echo "========================================"
    read -p "${MSGS[CHOICE_PROMPT]} " choice < /dev/tty

    case $choice in
        1)
            backup_system
            ;;
        2)
            restore_system
            ;;
        3)
            view_logs
            ;;
        4)
            echo -e "${GREEN}Выход. Удачной работы!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}${MSGS[ERROR_INVALID_CHOICE]}${NC}"
            sleep 2
            ;;
    esac
}

# --- ОБРАБОТКА АРГУМЕНТОВ И ЗАПУСК ---

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}${MSGS[ERROR_ROOT]}${NC}"
    exit 1
fi

# Инициализация рабочей директории
mkdir -p "$BACKUP_DIR"
mkdir -p "$TEMP_BASE"
touch "$DOCKER_ERROR_LOG" # Создаем лог ошибок Docker

lang_set

# Проверка неинтерактивного режима
if [ $# -gt 0 ] && [ "$1" == "--non-interactive" ]; then
    NON_INTERACTIVE="Y"
    shift
    
    if [ $# -eq 0 ]; then
        echo -e "${RED}Ошибка: В неинтерактивном режиме требуется действие (backup/restore) и аргументы.${NC}"
        exit 1
    fi
    
    ACTION="$1"
    shift
    
    if [ "$ACTION" == "backup" ]; then
        backup_system "$@"
    elif [ "$ACTION" == "restore" ]; then
        if [ $# -ne 1 ]; then
             echo -e "${RED}Ошибка: Для восстановления требуется один аргумент - путь к файлу бэкапа (e.g., restore /path/to/backup.srvbak).${NC}"
             exit 1
        fi
        restore_system "$1"
    else
        echo -e "${RED}Ошибка: Неизвестное действие '$ACTION'. Используйте 'backup' или 'restore'.${NC}"
        exit 1
    fi
    exit 0
fi

while true; do
    main_menu
done