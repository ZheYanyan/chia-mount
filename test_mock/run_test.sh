#!/bin/bash
###############################################################################
# 模拟测试运行器
# 使用 mock 环境测试 chia-mount-v2.1.sh
###############################################################################

# 获取脚本所在目录
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$CURRENT_DIR"
MOCK_BIN="$SCRIPT_DIR/bin"
MOCK_DEV_DIR="$SCRIPT_DIR/dev"
SCRIPT_DIR_PARENT="$(dirname "$SCRIPT_DIR")"
SCRIPT="$SCRIPT_DIR_PARENT/chia-mount-v2.1.sh"
TEST_SCRIPT="$SCRIPT_DIR/chia-mount-test.sh"

# 清理之前的测试状态
rm -rf "$SCRIPT_DIR/mnt"/* 2>/dev/null || true
rm -f "$SCRIPT_DIR/.mock_mounts" 2>/dev/null || true
rm -rf "$MOCK_DEV_DIR" 2>/dev/null || true
mkdir -p "$MOCK_DEV_DIR"

# 创建200个模拟设备文件
echo "创建200个模拟设备文件..."
for i in $(seq 1 200); do
    num=$(printf "%03d" $i)
    touch "$MOCK_DEV_DIR/sd${num}"
done
echo "模拟设备文件创建完成"

echo "========================================"
echo "Chia Mount 脚本 - 模拟环境测试"
echo "========================================"
echo ""

# 使用 Python 进行文本替换
python3 - "$SCRIPT" "$TEST_SCRIPT" "$MOCK_DEV_DIR" "$SCRIPT_DIR/mnt" "$SCRIPT_DIR/chia-mount.log" << PYEOF
import sys
import re

script_path = sys.argv[1]
test_script = sys.argv[2]
mock_dev = sys.argv[3]
mock_mnt = sys.argv[4]
mock_log = sys.argv[5]

with open(script_path, "r") as f:
    lines = f.readlines()

output = []
skip_func = None

for i, line in enumerate(lines):
    # 跳过 Install_Dependencies 函数
    if re.match(r'^\s*Install_Dependencies\(\)', line):
        skip_func = "Install_Dependencies"
        output.append("# Install_Dependencies # DISABLED\n")
        continue

    # 跳过 Check_Dependencies 函数
    if re.match(r'^\s*Check_Dependencies\(\)', line):
        skip_func = "Check_Dependencies"
        output.append("# Check_Dependencies # DISABLED\n")
        continue

    # 跳过 Check_Root 函数
    if re.match(r'^\s*Check_Root\(\)', line):
        skip_func = "Check_Root"
        output.append("# Check_Root # DISABLED\n")
        continue

    # 如果在跳过函数中
    if skip_func:
        if re.match(r'^\s*\}', line):
            skip_func = None
        continue

    # 跳过 root 检查 if 块
    if 'if [ "$UID" -ne 0 ]; then' in line:
        output.append("    if false; then  # ROOT CHECK DISABLED\n")
        continue
    if 'echo -e "\\n${RED}错误: 请以root身份运行此脚本!${NC}"' in line:
        continue
    if 'exit 1' in line and len(output) >= 2 and 'if false' in output[-2]:
        continue

    # 跳过 Check_Root 调用（无括号形式）
    if re.match(r'^\s*Check_Root\s*$', line):
        output.append("    # Check_Root  # DISABLED\n")
        continue

    # 跳过 Check_Dependencies 调用（无括号形式）
    if re.match(r'^\s*Check_Dependencies\s*$', line):
        output.append("    # Check_Dependencies  # DISABLED\n")
        continue

    # 替换挂载路径
    line = line.replace("Disk_Mount_Path='/mnt'", f"Disk_Mount_Path='{mock_mnt}'")

    # 替换日志路径
    line = line.replace("Log_File='/var/log/chia-mount.log'", f"Log_File='{mock_log}'")

    # 替换 /dev/ 为 mock 路径（跳过 /dev/null）
    if '/dev/' in line and '/dev/null' not in line and not line.strip().startswith('#'):
        line = line.replace('/dev/', f'{mock_dev}/')
        # 将 [ ! -b "/dev/... ] 替换为 [ ! -f "..." ] (检查普通文件而非块设备)
        if ' -b "' in line:
            line = line.replace(' -b "', ' -f "')

    output.append(line)

with open(test_script, "w") as f:
    f.writelines(output)

print("测试脚本已生成")
PYEOF

# 设置 PATH，让 mock 命令优先
export PATH="$MOCK_BIN:$PATH"

# 将 mock 命令加入 hash 表
hash -p "$MOCK_BIN/lsblk" lsblk 2>/dev/null || true
hash -p "$MOCK_BIN/df" df 2>/dev/null || true
hash -p "$MOCK_BIN/blkid" blkid 2>/dev/null || true
hash -p "$MOCK_BIN/mount" mount 2>/dev/null || true
hash -p "$MOCK_BIN/mkdir" mkdir 2>/dev/null || true
hash -p "$MOCK_BIN/chown" chown 2>/dev/null || true
hash -p "$MOCK_BIN/mktemp" mktemp 2>/dev/null || true
hash -p "$MOCK_BIN/bc" bc 2>/dev/null || true
hash -p "$MOCK_BIN/sleep" sleep 2>/dev/null || true

# 设置测试环境变量
export TEST_MOCK_DIR="$SCRIPT_DIR"
export SUDO_USER="$(whoami)"
export Concurrent_Mounts=10

echo "环境配置:"
echo "  Disk_Mount_Path: $SCRIPT_DIR/mnt"
echo "  Log_File: $SCRIPT_DIR/chia-mount.log"
echo "  Concurrent_Mounts: $Concurrent_Mounts"
echo ""

echo "验证 mock 命令:"
echo "  lsblk: $(which lsblk)"
echo "  mount: $(which mount)"
echo "  df: $(which df)"
echo ""

echo "========================================"
echo "开始测试..."
echo "========================================"
echo ""

# 执行脚本
bash "$TEST_SCRIPT"
TEST_EXIT_CODE=$?

echo ""
echo "测试脚本已保存至: $TEST_SCRIPT"
echo "测试退出码: $TEST_EXIT_CODE"

echo ""
echo "测试完成"
