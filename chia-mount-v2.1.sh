#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

##################################### User Config #####################################

# 磁盘挂载路径
Disk_Mount_Path='/mnt'

# 日志文件路径
Log_File='/var/log/chia-mount.log'

# 并发挂载数量（根据 CPU 核心数动态计算，最小10，最大50）
Concurrent_Mounts=$(($(nproc 2>/dev/null || echo 4) * 5))
[ "$Concurrent_Mounts" -lt 10 ] && Concurrent_Mounts=10
[ "$Concurrent_Mounts" -gt 50 ] && Concurrent_Mounts=50

#########################################################################################
#
# HC620 SMR 硬盘注意事项:
# - 本脚本使用 mount 自动检测文件系统，不指定 -t 参数
# - 推荐挂载选项: noatime,nodiratime (减少写操作)
# - 不推荐 btrfs: COW 特性会在 SMR 硬盘产生随机写入
# - 推荐预格式化: mkfs.xfs -f /dev/sdX
#
# Chia 耕种配置建议 (chia.yaml):
# harvester:
#   disable_disk_sync: true
#   direct_io: true
#
#########################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查是否以root身份运行
Check_Root() {
    if [ "$UID" -ne 0 ]; then
        echo -e "\n${RED}错误: 请以root身份运行此脚本!${NC}\n"
        exit 1
    fi
}

# 自动安装依赖
Install_Dependencies() {
    echo -e "${YELLOW}正在检查并安装依赖...${NC}\n"

    local packages=()
    local tools=("bc" "lsblk" "awk" "grep" "sed" "sort" "xargs" "bc")

    for tool in "${tools[@]}"; do
        if ! type "$tool" >/dev/null 2>&1; then
            case "$tool" in
                bc)
                    packages+=("bc")
                    ;;
                lsblk)
                    packages+=("mount")
                    ;;
                *)
                    ;;
            esac
        fi
    done

    if [ ${#packages[@]} -gt 0 ]; then
        echo -e "${YELLOW}需要安装以下软件包: ${packages[*]}${NC}"
        echo -e "${YELLOW}正在安装...${NC}"
        apt-get update -qq
        apt-get install -y -qq "${packages[@]}"
        echo -e "${GREEN}依赖安装完成!${NC}\n"
    else
        echo -e "${GREEN}所有依赖已满足${NC}\n"
    fi
}

# 检查依赖工具是否安装
Check_Dependencies() {
    local missing=()

    # 必需的命令
    local required=("lsblk" "awk" "grep" "sed" "sort" "bc" "mktemp")

    for cmd in "${required[@]}"; do
        if ! type "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少必需命令: ${missing[*]}${NC}"
        echo -e "${YELLOW}正在尝试自动安装...${NC}\n"
        Install_Dependencies

        # 再次检查
        for cmd in "${required[@]}"; do
            if ! type "$cmd" >/dev/null 2>&1; then
                echo -e "${RED}错误: 命令 '$cmd' 未找到，请手动运行: sudo apt install ${missing[*]}${NC}\n"
                exit 1
            fi
        done
    fi

    # 可选的命令（figlet 用于显示大字，可选）
    if type figlet >/dev/null 2>&1; then
        FIGLET_AVAILABLE=true
    else
        FIGLET_AVAILABLE=false
        echo -e "${YELLOW}提示: figlet 未安装，将跳过大字显示 (sudo apt install figlet)${NC}"
    fi
}

# 全局变量，缓存lsblk输出
LSBLK_OUTPUT=""

# 获取符合条件的磁盘信息
Get_Disk_Info() {
    # 查找大于3.6TB的磁盘，只执行一次lsblk命令以提高性能
    LSBLK_OUTPUT=$(lsblk -l)

    # 提取磁盘信息
    local disk_raw=$(echo "$LSBLK_OUTPUT" | grep -i "disk" | awk '$4 ~ /T/' | sed 's/T//g' | awk '$4+0 > 3.6' | sort -k 4 -r | awk '{print $1}')
    if [ -n "$disk_raw" ]; then
        # 将换行替换为空格，兼容 bash 3.2
        Disk_Temp_Device_Arr=($(echo "$disk_raw" | tr '\n' ' '))
    else
        Disk_Temp_Device_Arr=()
    fi

    unset Disk_Total_Device_Arr
    for i in ${Disk_Temp_Device_Arr[*]}; do
        # 检查是否有分区，使用已缓存的输出
        if [[ -n "$(echo "$LSBLK_OUTPUT" | awk '$4 ~ /T/' | sed 's/T//g' | awk '$4+0 > 3.6' | grep -i "^${i}p[1-4]")" ]]; then
            # 使用最后一个分区
            Disk_Total_Device_Arr[${#Disk_Total_Device_Arr[@]}]=$(echo "$LSBLK_OUTPUT" | awk '$4 ~ /T/' | sed 's/T//g' | awk '$4+0 > 3.6' | grep -i "^${i}p[1-4]" | tail -n 1 | awk '{print $1}')
        else
            # 使用整个磁盘
            Disk_Total_Device_Arr[${#Disk_Total_Device_Arr[@]}]="$i"
        fi
    done
}

# 检查磁盘是否可挂载
Check_Disk_Validity() {
    local device="$1"

    # 检查设备是否存在
    if [ ! -b "/dev/$device" ]; then
        echo "错误: 设备 /dev/$device 不存在"
        return 1
    fi

    # 检查设备是否已挂载
    if df -h | grep -q "^/dev/${device} "; then
        echo "信息: 设备 /dev/$device 已经挂载"
        return 1
    fi

    return 0
}

# 挂载磁盘
Mount_Disk() {
    local device="$1"
    local mount_point="$2"
    local index="$3"
    local status_file="$4"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 开始: 尝试挂载 /dev/$device 到 $mount_point" >> "$Log_File"

    # 检查磁盘有效性
    if ! Check_Disk_Validity "$device"; then
        echo "$index:失败" > "$status_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 磁盘 /dev/$device 无效，跳过挂载" >> "$Log_File"
        return 1
    fi

    # 创建挂载点
    if ! mkdir -p "$mount_point" >/dev/null 2>&1; then
        echo "$index:失败" > "$status_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法创建挂载点 $mount_point" >> "$Log_File"
        return 1
    fi

    # 尝试挂载（使用 noatime,nodiratime 减少写操作，适合 SMR 硬盘）
    # 不指定文件系统类型 (-t)，让系统自动检测
    if mount -o noatime,nodiratime "/dev/$device" "$mount_point" >/dev/null 2>&1; then
        echo "$index:成功" > "$status_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 成功: 挂载 /dev/$device 到 $mount_point" >> "$Log_File"
        return 0
    else
        local error_msg=$(mount -o noatime,nodiratime "/dev/$device" "$mount_point" 2>&1)
        echo "$index:失败" > "$status_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 挂载 /dev/$device 到 $mount_point 失败 - $error_msg" >> "$Log_File"
        return 1
    fi
}

# 显示进度条
Show_Progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r${CYAN}进度: [${GREEN}"
    for ((i=0; i<filled; i++)); do printf "#"; done
    for ((i=0; i<empty; i++)); do printf "-"; done
    printf "${CYAN}] ${percentage}%% (${current}/${total})${NC}"
}

# 生成硬盘矩阵
Generate_Matrix() {
    local total="$1"
    local mounted=("$2")

    # 计算矩阵大小
    local size=$(echo "sqrt($total)" | bc)
    ((size++))

    echo -e "\n${BLUE}硬盘挂载矩阵:${NC}"
    echo -e "${BLUE}=====================================${NC}"

    local count=1
    for ((i=0; i<size; i++)); do
        for ((j=0; j<size; j++)); do
            if ((count <= total)); then
                if [[ " ${mounted[*]} " =~ " $count " ]]; then
                    printf "${GREEN}● ${NC}"
                else
                    printf "${RED}○ ${NC}"
                fi
                ((count++))
            else
                printf "  "
            fi
        done
        echo
    done

    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}● ${NC}: 已挂载   ${RED}○ ${NC}: 未挂载"
}

# 主函数
Main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Chia 磁盘批量挂载脚本${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${CYAN}并发数: ${GREEN}${Concurrent_Mounts}${NC}"
    echo ""

    # 检查root权限
    Check_Root

    # 检查并安装依赖
    Check_Dependencies

    # 确保日志文件存在
    if ! mkdir -p "$(dirname "$Log_File")" 2>/dev/null; then
        echo -e "${RED}错误: 无法创建日志目录$(dirname "$Log_File")${NC}"
        exit 1
    fi
    touch "$Log_File"

    echo "$(date '+%Y-%m-%d %H:%M:%S') 开始执行磁盘挂载脚本" >> "$Log_File"

    # 获取磁盘信息
    Get_Disk_Info

    local total_disks=${#Disk_Total_Device_Arr[@]}

    if [ "$total_disks" -eq 0 ]; then
        echo -e "${YELLOW}警告: 未找到大于3.6TB的磁盘${NC}\n"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告: 未找到大于3.6TB的磁盘" >> "$Log_File"
        exit 0
    fi

    echo -e "${GREEN}找到以下符合条件的磁盘:${NC}"
    echo "序号  容量    设备路径           挂载点"
    echo "------------------------------------------"

    # 列出所有待挂载磁盘
    for i in ${!Disk_Total_Device_Arr[*]}; do
        local device="${Disk_Total_Device_Arr[$i]}"
        local size=$(echo "$LSBLK_OUTPUT" | awk -v dev="^${device}$" '$1 ~ dev {print $4}')
        local mount_point="${Disk_Mount_Path}/$((i + 1))"

        echo "$((i+1))    $size  /dev/${device}      ${mount_point}"
    done

    echo -e "\n${BLUE}开始挂载 ${total_disks} 个磁盘...${NC}"

    # 创建临时目录存储状态
    local temp_dir=$(mktemp -d)
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 无法创建临时目录${NC}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法创建临时目录" >> "$Log_File"
        exit 1
    fi

    local status_files=()
    local mounted_disks=()
    local current=0

    # 多线程挂载 - 使用bash后台进程
    for i in ${!Disk_Total_Device_Arr[*]}; do
        local index=$((i+1))
        local device="${Disk_Total_Device_Arr[$i]}"
        local mount_point="${Disk_Mount_Path}/${index}"
        local status_file="${temp_dir}/status_${index}"
        status_files+=("$status_file")

        # 控制并发数
        while [ "$(jobs -r | wc -l)" -ge "$Concurrent_Mounts" ]; do
            # 显示进度
            current=0
            for sf in "${status_files[@]}"; do
                if [ -f "$sf" ]; then
                    ((current++))
                fi
            done
            Show_Progress "$current" "$total_disks"
            sleep 0.5
        done

        Mount_Disk "$device" "$mount_point" "$index" "$status_file" &
    done

    # 等待所有进程完成并显示进度
    while [ "$(jobs -r | wc -l)" -gt 0 ]; do
        current=0
        for sf in "${status_files[@]}"; do
            if [ -f "$sf" ]; then
                ((current++))
            fi
        done
        Show_Progress "$current" "$total_disks"
        sleep 0.5
    done

    # 确保进度条显示100%
    Show_Progress "$total_disks" "$total_disks"
    echo

    # 收集挂载结果
    local success_count=0
    local failure_count=0

    for sf in "${status_files[@]}"; do
        if [ -f "$sf" ]; then
            local result=$(cat "$sf")
            local index="${result%%:*}"
            local status="${result#*:}"

            if [ "$status" = "成功" ]; then
                mounted_disks+=("$index")
                ((success_count++))
            else
                ((failure_count++))
            fi
        else
            ((failure_count++))
            echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 未找到状态文件，挂载失败" >> "$Log_File"
        fi
    done

    # 显示硬盘矩阵
    Generate_Matrix "$total_disks" "${mounted_disks[*]}"

    # 清理临时目录
    rm -rf "$temp_dir" 2>/dev/null

    # 显示最终结果
    echo -e "\n${GREEN}挂载完成!${NC}"
    echo -e "${GREEN}成功挂载: ${success_count} 个磁盘${NC}"
    echo -e "${RED}失败挂载: ${failure_count} 个磁盘${NC}"

    # 使用figlet显示大字（如果可用）
    if [ "$FIGLET_AVAILABLE" = true ]; then
        echo ""
        figlet "挂载完成"
        echo ""
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 磁盘挂载脚本执行完成，成功: ${success_count}, 失败: ${failure_count}" >> "$Log_File"
}

# 执行主函数
Main

exit 0
