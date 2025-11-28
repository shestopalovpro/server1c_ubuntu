#!/bin/bash

# Script for optimizing Ubuntu Server system settings for high-performance applications
# Does NOT modify PostgreSQL configuration - only system settings
# Run with: sudo bash system-optimize-final.sh

set -e

echo "========================================="
echo "Ubuntu System Optimization (PostgreSQL-ready)"
echo "No PostgreSQL config changes - system only"
echo "========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Detect Ubuntu version and kernel
UBUNTU_VERSION=$(lsb_release -rs)
KERNEL_VERSION=$(uname -r)
log_info "Detected Ubuntu Server $UBUNTU_VERSION"
log_info "Kernel version: $KERNEL_VERSION"

# Detect hardware
detect_hardware() {
    log_info "Detecting hardware..."
    
    # Detect disk type
    if lsblk | grep -q nvme; then
        DISK_TYPE="nvme"
        DISK_NAME=$(lsblk | grep nvme | head -1 | cut -d' ' -f1)
        SCHEDULER="none"
    elif lsblk | grep -q sd; then
        DISK_TYPE="sata"
        DISK_NAME=$(lsblk | grep sd | head -1 | cut -d' ' -f1)
        SCHEDULER="mq-deadline"
    else
        log_error "Cannot detect disk type"
        exit 1
    fi
    
    # Detect RAM
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
    
    # Detect CPU cores
    CPU_CORES=$(nproc)
    
    log_info "Hardware: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores, Disk: ${DISK_NAME} (${DISK_TYPE})"
}

# Configure I/O Scheduler
configure_io_scheduler() {
    log_info "Configuring I/O scheduler for better disk performance..."
    
    # Create udev rules file
    cat > /etc/udev/rules.d/60-ioschedulers.rules << EOF
# Optimized I/O schedulers for database workloads
# SATA SSDs and HDDs
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
# NVMe SSDs
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
    
    # Apply changes immediately to current devices
    for device in /sys/block/sd* /sys/block/nvme*; do
        if [ -d "$device" ]; then
            device_name=$(basename $device)
            if [[ $device_name == nvme* ]]; then
                echo "none" > $device/queue/scheduler 2>/dev/null || true
                log_info "Set $device_name to 'none' scheduler"
            elif [[ $device_name == sd* ]]; then
                echo "mq-deadline" > $device/queue/scheduler 2>/dev/null || true
                log_info "Set $device_name to 'mq-deadline' scheduler"
            fi
        fi
    done
    
    # Apply udev rules
    udevadm control --reload-rules
    udevadm trigger
    
    log_info "I/O scheduler configuration completed"
}

# Disable Transparent Huge Pages
disable_thp() {
    log_info "Disabling Transparent Huge Pages for database workloads..."
    
    # Create systemd service
    cat > /etc/systemd/system/disable-thp.service << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=false
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "never" > /sys/kernel/mm/transparent_hugepage/enabled && echo "never" > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable disable-thp.service
    systemctl start disable-thp.service
    
    # Apply immediately
    echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
    echo "never" > /sys/kernel/mm/transparent_hugepage/defrag
    
    log_info "Transparent Huge Pages disabled"
}

# Configure CPU Governor - исправленная версия
configure_cpu_governor() {
    log_info "Configuring CPU for maximum performance..."
    
    # Проверяем, доступен ли уже cpupower
    if ! which cpupower > /dev/null 2>&1; then
        log_info "Installing CPU management tools for kernel $KERNEL_VERSION..."
        
        # Обновляем пакеты
        apt-get update
        
        # Пробуем установить общие пакеты first
        log_info "Attempting to install generic CPU tools..."
        if apt-get install -y linux-tools-generic cpufrequtils; then
            log_info "Generic CPU tools installed successfully"
        else
            log_warn "Generic packages not available, trying alternative approach..."
        fi
        
        # Пробуем установить специфичные для ядра пакеты
        log_info "Attempting to install kernel-specific tools..."
        KERNEL_TOOLS_PACKAGE="linux-tools-${KERNEL_VERSION}"
        if apt-cache show "$KERNEL_TOOLS_PACKAGE" > /dev/null 2>&1; then
            log_info "Installing $KERNEL_TOOLS_PACKAGE"
            apt-get install -y "$KERNEL_TOOLS_PACKAGE"
        else
            log_warn "Package $KERNEL_TOOLS_PACKAGE not available"
        fi
    fi
    
    # Пробуем установить governor через cpupower если доступен
    if which cpupower > /dev/null 2>&1; then
        log_info "Setting CPU governor to performance using cpupower..."
        if cpupower frequency-set -g performance; then
            log_info "CPU governor successfully set to performance using cpupower"
        else
            log_warn "cpupower failed to set governor, using fallback method"
        fi
    else
        log_warn "cpupower not available, using direct sysfs method"
    fi
    
    # Основной метод через systemd service (работает всегда)
    log_info "Creating systemd service for CPU performance..."
    cat > /etc/systemd/system/cpu-performance.service << EOF
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "\$gov" ] && echo performance > "\$gov" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable cpu-performance.service
    
    # Пробуем запустить сервис
    if systemctl start cpu-performance.service; then
        log_info "CPU performance service started successfully"
    else
        log_warn "CPU performance service could not be started, but is enabled for next boot"
    fi
    
    # Прямая установка governor через sysfs (немедленный эффект)
    log_info "Setting CPU governor directly via sysfs..."
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -w "$cpu" ]; then
            echo performance > "$cpu" 2>/dev/null && log_info "Set $(dirname $cpu | xargs basename) to performance" || true
        fi
    done
    
    log_info "CPU governor configuration completed"
}

# Configure kernel parameters
configure_kernel_params() {
    log_info "Optimizing kernel parameters..."
    
    # Calculate swappiness based on RAM
    if [ $TOTAL_RAM_GB -lt 8 ]; then
        SWAPPINESS=10
    elif [ $TOTAL_RAM_GB -lt 16 ]; then
        SWAPPINESS=5
    else
        SWAPPINESS=1
    fi
    
    # Backup original sysctl.conf
    cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)
    
    # Add optimized parameters
    cat >> /etc/sysctl.conf << EOF

# System Optimizations for High-Performance Applications
# Applied on $(date)
# Ubuntu $UBUNTU_VERSION, Kernel $KERNEL_VERSION

# Memory Management
vm.swappiness=$SWAPPINESS
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 6000
vm.vfs_cache_pressure = 50

# System Limits
kernel.sem = 256 32000 100 1280
fs.file-max = 6815744
fs.aio-max-nr = 1048576

# Network Performance
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096

# IPv4 TCP Settings
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 400000
net.ipv4.tcp_max_orphans = 60000
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_fin_timeout = 30

# Security and Performance
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 9
EOF
    
    # Apply immediately
    log_info "Applying kernel parameters..."
    sysctl -p
    
    log_info "Kernel parameters optimized (swappiness=$SWAPPINESS)"
}

# Configure system limits
configure_limits() {
    log_info "Configuring system limits..."
    
    # Remove existing limits for our application if present
    grep -v "High-Performance Applications" /etc/security/limits.conf > /tmp/limits.conf.tmp
    mv /tmp/limits.conf.tmp /etc/security/limits.conf
    
    # Add optimized limits
    cat >> /etc/security/limits.conf << EOF

# High-Performance Applications - Ubuntu $UBUNTU_VERSION
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
* soft memlock unlimited
* hard memlock unlimited
EOF

    # Configure PAM limits
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [ -f "$pam_file" ]; then
            if ! grep -q "pam_limits.so" "$pam_file"; then
                echo "session required pam_limits.so" >> "$pam_file"
                log_info "Added pam_limits to $pam_file"
            fi
        fi
    done
    
    log_info "System limits configured"
}

# Install monitoring tools
install_tools() {
    log_info "Installing system monitoring tools..."
    
    apt-get update
    apt-get install -y htop iotop sysstat
    
    # Enable sysstat data collection
    if [ -f /etc/default/sysstat ]; then
        sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        log_info "Sysstat enabled for data collection"
    fi
    
    # Try to enable sysstat service
    if systemctl list-unit-files | grep -q sysstat; then
        systemctl enable sysstat
        systemctl start sysstat
        log_info "Sysstat service enabled"
    else
        log_info "Sysstat service not available, data collection still enabled"
    fi
    
    log_info "Monitoring tools installed: htop, iotop, sysstat"
}

# Display current settings
display_current_settings() {
    log_info "Current system settings after optimization:"
    
    echo -e "\n${YELLOW}=== I/O Schedulers ===${NC}"
    for device in /sys/block/sd* /sys/block/nvme*; do
        if [ -d "$device" ]; then
            device_name=$(basename $device)
            scheduler=$(cat $device/queue/scheduler 2>/dev/null | grep -o '\[.*\]' || true)
            echo "  $device_name: $scheduler"
        fi
    done
    
    echo -e "\n${YELLOW}=== THP Status ===${NC}"
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "  Enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    else
        echo "  THP control not available"
    fi
    
    echo -e "\n${YELLOW}=== CPU Governor ===${NC}"
    # Проверяем текущий governor
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo "  Current governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    else
        echo "  CPU frequency scaling not available"
    fi
    
    echo -e "\n${YELLOW}=== Memory Settings ===${NC}"
    echo "  Swappiness: $(cat /proc/sys/vm/swappiness)"
    echo "  Dirty ratio: $(cat /proc/sys/vm/dirty_ratio)"
    echo "  Dirty background ratio: $(cat /proc/sys/vm/dirty_background_ratio)"
    
    echo -e "\n${YELLOW}=== System Limits ===${NC}"
    echo "  Max open files: $(ulimit -n)"
    echo "  Max processes: $(ulimit -u)"
}

# Create verification script
create_verification_script() {
    cat > /opt/check-system-optimizations.sh << 'EOF'
#!/bin/bash
echo "=== System Optimization Verification ==="
echo "Ubuntu $(lsb_release -rs) - Kernel $(uname -r)"
echo "Date: $(date)"
echo ""

echo "=== I/O Schedulers ==="
for device in /sys/block/sd* /sys/block/nvme*; do
    if [ -d "$device" ]; then
        echo "$(basename $device): $(cat $device/queue/scheduler | grep -o '\[.*\]')"
    fi
done

echo ""
echo "=== THP Status ==="
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo "Enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
else
    echo "THP control not available"
fi

echo ""
echo "=== CPU Governor ==="
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    echo "Current: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "Available: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo 'N/A')"
else
    echo "CPU frequency scaling not available"
fi

echo ""
echo "=== Memory Settings ==="
echo "Swappiness: $(cat /proc/sys/vm/swappiness)"
echo "Dirty ratio: $(cat /proc/sys/vm/dirty_ratio)"
echo "Dirty background ratio: $(cat /proc/sys/vm/dirty_background_ratio)"

echo ""
echo "=== System Limits ==="
echo "Max open files: $(ulimit -n)"
echo "Max processes: $(ulimit -u)"

echo ""
echo "=== Monitoring Tools ==="
which htop >/dev/null 2>&1 && echo "htop: installed" || echo "htop: not installed"
which iotop >/dev/null 2>&1 && echo "iotop: installed" || echo "iotop: not installed"
which sar >/dev/null 2>&1 && echo "sysstat: installed" || echo "sysstat: not installed"
EOF

    chmod +x /opt/check-system-optimizations.sh
    log_info "Verification script created: /opt/check-system-optimizations.sh"
}

# Main execution function
main() {
    log_info "Starting system optimization..."
    log_info "NOTE: PostgreSQL configuration will NOT be modified"
    
    detect_hardware
    configure_io_scheduler
    disable_thp
    configure_cpu_governor
    configure_kernel_params
    configure_limits
    install_tools
    create_verification_script
    
    echo ""
    log_info "========================================="
    log_info "SYSTEM OPTIMIZATION COMPLETED SUCCESSFULLY!"
    log_info "========================================="
    log_info "Applied system optimizations:"
    log_info "✓ I/O Scheduler: NVMe->none, SATA->mq-deadline"
    log_info "✓ Transparent Huge Pages: Disabled"
    log_info "✓ CPU Governor: performance"
    log_info "✓ Kernel parameters: Optimized"
    log_info "✓ System limits: Increased"
    log_info "✓ Monitoring tools: Installed"
    log_info ""
    log_info "PostgreSQL configuration was NOT modified"
    log_info ""
    log_warn "REQUIRED: Reboot system to apply all changes!"
    log_info "Reboot command: sudo reboot"
    log_info ""
    log_info "After reboot, verify settings:"
    log_info "  sudo /opt/check-system-optimizations.sh"
    
    display_current_settings
}

# Run main function
main "$@"
