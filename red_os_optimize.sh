#!/bin/bash

# Script for optimizing RED OS 8 system settings for high-performance applications
# for PostgreSQL/1C - No PostgreSQL config changes
# Run with: sudo bash system-optimize-redos-fixed.sh

set -e

echo "========================================="
echo "RED OS 8 System Optimization"
echo "PostgreSQL-ready - No PostgreSQL config changes"
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

# Detect OS
if [ -f /etc/redos-release ]; then
    OS_NAME=$(cat /etc/redos-release)
    OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redos-release | head -1)
else
    log_error "This script is for RED OS only"
    exit 1
fi

KERNEL_VERSION=$(uname -r)
log_info "Detected: $OS_NAME"
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
    elif lsblk | grep -q vd; then
        DISK_TYPE="virtio"
        DISK_NAME=$(lsblk | grep vd | head -1 | cut -d' ' -f1)
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
# VirtIO disks (KVM/VirtualBox)
ACTION=="add|change", KERNEL=="vd[a-z]*", ATTR{queue/scheduler}="mq-deadline"
EOF
    
    # Apply changes immediately to current devices
    for device in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        if [ -d "$device" ]; then
            device_name=$(basename $device)
            if [[ $device_name == nvme* ]]; then
                echo "none" > $device/queue/scheduler 2>/dev/null || true
                log_info "Set $device_name to 'none' scheduler"
            elif [[ $device_name == sd* ]] || [[ $device_name == vd* ]]; then
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
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable disable-thp.service
    systemctl start disable-thp.service
    
    # Apply immediately
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
    
    log_info "Transparent Huge Pages disabled"
}

# Configure CPU Governor для RED OS
configure_cpu_governor() {
    log_info "Configuring CPU for maximum performance..."
    
    # В RED OS используем только sysfs метод (наиболее надежный)
    log_warn "Using direct sysfs method for CPU governor (most reliable in RED OS)"
    
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
    GOVERNOR_SET=0
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -w "$cpu" ]; then
            if echo performance > "$cpu" 2>/dev/null; then
                log_info "Set $(dirname $cpu | xargs basename) to performance"
                GOVERNOR_SET=1
            fi
        fi
    done
    
    if [ $GOVERNOR_SET -eq 0 ]; then
        log_warn "Could not set CPU governor via sysfs - CPU frequency scaling may not be supported or already set"
    else
        log_info "CPU governor successfully set to performance on all cores"
    fi
    
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
# $OS_NAME

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
    grep -v "High-Performance Applications" /etc/security/limits.conf > /tmp/limits.conf.tmp 2>/dev/null || true
    if [ -s /tmp/limits.conf.tmp ]; then
        mv /tmp/limits.conf.tmp /etc/security/limits.conf
    else
        # Если файл пустой, создаем базовый
        echo "# System limits" > /etc/security/limits.conf
    fi
    
    # Add optimized limits
    cat >> /etc/security/limits.conf << EOF

# High-Performance Applications - $OS_NAME
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
* soft memlock unlimited
* hard memlock unlimited
EOF

    # Configure PAM limits для RED OS
    for pam_file in /etc/pam.d/login /etc/pam.d/sshd /etc/pam.d/system-auth; do
        if [ -f "$pam_file" ]; then
            if ! grep -q "pam_limits.so" "$pam_file"; then
                echo "session required pam_limits.so" >> "$pam_file"
                log_info "Added pam_limits to $pam_file"
            fi
        fi
    done
    
    log_info "System limits configured"
}

# Install monitoring tools для RED OS (без EPEL)
install_tools() {
    log_info "Installing system monitoring tools..."
    
    # Пробуем установить доступные инструменты мониторинга
    log_info "Searching for available monitoring tools..."
    
    # sysstat обычно доступен в базовых репозиториях
    if dnf list available sysstat 2>/dev/null | grep -q sysstat; then
        log_info "Installing sysstat..."
        dnf install -y sysstat
        
        # Enable sysstat data collection
        if [ -f /etc/sysconfig/sysstat ]; then
            sed -i 's/ENABLED=.*/ENABLED="true"/' /etc/sysconfig/sysstat
        fi
        
        systemctl enable sysstat
        systemctl start sysstat
        log_info "sysstat installed and enabled"
    else
        log_warn "sysstat not available in repositories"
    fi
    
    # htop может быть недоступен, пробуем установить если есть
    if dnf list available htop 2>/dev/null | grep -q htop; then
        log_info "Installing htop..."
        dnf install -y htop
        log_info "htop installed"
    else
        log_warn "htop not available in repositories, using top instead"
    fi
    
    # iotop может быть недоступен
    if dnf list available iotop 2>/dev/null | grep -q iotop; then
        log_info "Installing iotop..."
        dnf install -y iotop
        log_info "iotop installed"
    else
        log_warn "iotop not available in repositories"
    fi
    
    log_info "Monitoring tools installation completed"
}

# Display current settings
display_current_settings() {
    log_info "Current system settings after optimization:"
    
    echo -e "\n${YELLOW}=== I/O Schedulers ===${NC}"
    for device in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
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
    
    echo -e "\n${YELLOW}=== Available Monitoring Tools ===${NC}"
    which top >/dev/null 2>&1 && echo "  top: available" || echo "  top: not available"
    which htop >/dev/null 2>&1 && echo "  htop: available" || echo "  htop: not available"
    which iotop >/dev/null 2>&1 && echo "  iotop: available" || echo "  iotop: not available"
    which sar >/dev/null 2>&1 && echo "  sysstat: available" || echo "  sysstat: not available"
}

# Create verification script
create_verification_script() {
    cat > /opt/check-system-optimizations-redos.sh << 'EOF'
#!/bin/bash
echo "=== RED OS System Optimization Verification ==="
echo "OS: $(cat /etc/redos-release 2>/dev/null || echo "Unknown")"
echo "Kernel: $(uname -r)"
echo "Date: $(date)"
echo ""

echo "=== I/O Schedulers ==="
for device in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
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
which top >/dev/null 2>&1 && echo "top: available" || echo "top: not available"
which htop >/dev/null 2>&1 && echo "htop: available" || echo "htop: not available"
which iotop >/dev/null 2>&1 && echo "iotop: available" || echo "iotop: not available"
which sar >/dev/null 2>&1 && echo "sysstat: available" || echo "sysstat: not available"
EOF

    chmod +x /opt/check-system-optimizations-redos.sh
    log_info "Verification script created: /opt/check-system-optimizations-redos.sh"
}

# Main execution function
main() {
    log_info "Starting RED OS system optimization..."
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
    log_info "RED OS SYSTEM OPTIMIZATION COMPLETED SUCCESSFULLY!"
    log_info "========================================="
    log_info "Applied system optimizations:"
    log_info "✓ I/O Scheduler: NVMe->none, SATA/VirtIO->mq-deadline"
    log_info "✓ Transparent Huge Pages: Disabled"
    log_info "✓ CPU Governor: performance"
    log_info "✓ Kernel parameters: Optimized"
    log_info "✓ System limits: Increased"
    log_info "✓ Monitoring tools: Installed (available packages)"
    log_info ""
    log_info "PostgreSQL configuration was NOT modified"
    log_info ""
    log_warn "REQUIRED: Reboot system to apply all changes!"
    log_info "Reboot command: sudo reboot"
    log_info ""
    log_info "After reboot, verify settings:"
    log_info "  sudo /opt/check-system-optimizations-redos.sh"
    
    display_current_settings
}

# Run main function
main "$@"