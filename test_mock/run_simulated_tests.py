#!/usr/bin/env python3
"""
模拟测试运行器 - 支持多种磁盘型号和数量
"""
import os
import sys
import json
import random
import re
import subprocess
from datetime import datetime
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PARENT_DIR = os.path.dirname(SCRIPT_DIR)
DISK_MODELS_FILE = os.path.join(SCRIPT_DIR, "disk_models.json")
MAIN_SCRIPT = os.path.join(PARENT_DIR, "chia-mount-v2.1.sh")

def load_disk_models():
    with open(DISK_MODELS_FILE, 'r') as f:
        return json.load(f)

def create_mock_lsblk(disk_count, output_file):
    """创建模拟lsblk脚本"""
    models_data = load_disk_models()
    disk_models = models_data["disk_models"]

    output = "NAME TYPE RO SIZE MOUNTPOINT\n"
    for i in range(1, disk_count + 1):
        model = random.choice(disk_models)
        capacity = random.choice(model["capacities"])
        num = f"{i:03d}"
        output += f"sd{num} disk 0 {capacity} -\n"

    mock_script = f"""#!/bin/bash
cat << 'LSBLK_EOF'
{output}
LSBLK_EOF
"""
    with open(output_file, 'w') as f:
        f.write(mock_script)
    os.chmod(output_file, 0o755)

def create_mock_df(output_file):
    """创建模拟df脚本"""
    content = """#!/bin/bash
cat << 'DF_EOF'
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       500G   50G  450G  10% /
/dev/sdb2       200G  100G  100G  50% /boot
tmpfs            64M     0   64M   0% /run
DF_EOF
"""
    with open(output_file, 'w') as f:
        f.write(content)
    os.chmod(output_file, 0o755)

def cleanup_test_env():
    """清理测试环境"""
    dev_dir = os.path.join(SCRIPT_DIR, "dev")
    mnt_dir = os.path.join(SCRIPT_DIR, "mnt")
    log_file = os.path.join(SCRIPT_DIR, "chia-mount.log")
    mock_mounts = os.path.join(SCRIPT_DIR, ".mock_mounts")
    test_script = os.path.join(SCRIPT_DIR, "chia-mount-test.sh")

    # 清理mnt目录
    if os.path.exists(mnt_dir):
        for item in os.listdir(mnt_dir):
            item_path = os.path.join(mnt_dir, item)
            if os.path.isdir(item_path):
                shutil.rmtree(item_path)
            else:
                os.remove(item_path)

    # 清理dev目录（使用subprocess确保正确删除）
    if os.path.exists(dev_dir):
        subprocess.run(["rm", "-rf", dev_dir], shell=False)

    # 重建目录
    os.makedirs(mnt_dir, exist_ok=True)
    os.makedirs(dev_dir, exist_ok=True)

    for f in [log_file, mock_mounts, test_script]:
        if os.path.exists(f):
            os.remove(f)

def create_device_files(disk_count):
    """创建设备文件"""
    dev_dir = os.path.join(SCRIPT_DIR, "dev")
    for i in range(1, disk_count + 1):
        num = f"{i:03d}"
        dev_file = os.path.join(dev_dir, f"sd{num}")
        open(dev_file, 'w').close()

def generate_test_script(disk_count, concurrent_mounts):
    """生成测试脚本"""
    with open(MAIN_SCRIPT, 'r') as f:
        content = f.read()

    mock_dev = os.path.join(SCRIPT_DIR, "dev")
    mock_mnt = os.path.join(SCRIPT_DIR, "mnt")
    mock_log = os.path.join(SCRIPT_DIR, "chia-mount.log")

    # 替换路径
    content = content.replace("Disk_Mount_Path='/mnt'", f"Disk_Mount_Path='{mock_mnt}'")
    content = content.replace("Log_File='/var/log/chia-mount.log'", f"Log_File='{mock_log}'")

    # 禁用检查
    content = re.sub(r'^\s*Check_Root\s*$', '    # Check_Root  # DISABLED', content, flags=re.MULTILINE)
    content = re.sub(r'^\s*Check_Dependencies\s*$', '    # Check_Dependencies  # DISABLED', content, flags=re.MULTILINE)

    # 替换/dev/路径
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        if '/dev/' in line and '/dev/null' not in line and not line.strip().startswith('#'):
            line = line.replace('/dev/', f'{mock_dev}/')
            if ' -b "' in line:
                line = line.replace(' -b "', ' -f "')
        new_lines.append(line)
    content = '\n'.join(new_lines)

    test_script = os.path.join(SCRIPT_DIR, "chia-mount-test.sh")
    with open(test_script, 'w') as f:
        f.write(content)
    os.chmod(test_script, 0o755)

def run_single_test(test_num, disk_count, test_config, concurrent_mounts):
    """运行单次测试"""
    print(f"\n{'='*60}")
    print(f"测试 #{test_num}: {test_config['name']}")
    print(f"磁盘数量: {disk_count}")
    print(f"磁盘型号: {', '.join([m['model'] for m in test_config['models']])}")
    print(f"并发数: {concurrent_mounts}")
    print('='*60)

    # 清理并创建环境
    cleanup_test_env()
    create_device_files(disk_count)

    # 创建自定义mock lsblk
    custom_lsblk = os.path.join(SCRIPT_DIR, "bin", "lsblk")
    create_mock_lsblk(disk_count, custom_lsblk)
    create_mock_df(os.path.join(SCRIPT_DIR, "bin", "df"))

    # 生成测试脚本
    generate_test_script(disk_count, concurrent_mounts)

    # 设置环境变量
    env = os.environ.copy()
    env["PATH"] = f"{SCRIPT_DIR}/bin:{env['PATH']}"
    env["TEST_MOCK_DIR"] = SCRIPT_DIR
    env["SUDO_USER"] = "testuser"
    env["Concurrent_Mounts"] = str(concurrent_mounts)

    # 运行测试脚本
    result = subprocess.run(
        ["bash", os.path.join(SCRIPT_DIR, "chia-mount-test.sh")],
        capture_output=True,
        text=True,
        env=env,
        timeout=300
    )

    output = result.stdout + result.stderr

    # 提取成功/失败数量
    success_match = re.search(r'成功挂载:\s*(\d+)\s*个磁盘', output)
    failure_match = re.search(r'失败挂载:\s*(\d+)\s*个磁盘', output)

    success_count = int(success_match.group(1)) if success_match else 0
    failure_count = int(failure_match.group(1)) if failure_match else 0

    return {
        "success": failure_count == 0,
        "exit_code": result.returncode,
        "success_count": success_count,
        "failure_count": failure_count,
        "output": output,
        "test_config": test_config,
        "disk_count": disk_count,
        "concurrent_mounts": concurrent_mounts
    }

def main():
    test_configs = [
        {
            "name": "HC620 SMR专用测试",
            "description": "仅使用WD HC620型号，模拟真实场景",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 1.0}
            ],
            "disk_count": 100,
            "concurrent": 20
        },
        {
            "name": "HC620 + Gold混合测试",
            "description": "HC620与其他型号混合",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.5},
                {"model": "WD Gold", "capacities": ["18TB", "20TB"], "count_ratio": 0.5}
            ],
            "disk_count": 150,
            "concurrent": 25
        },
        {
            "name": "Seagate Exos系列测试",
            "description": "仅使用Seagate Exos系列",
            "models": [
                {"model": "Seagate Exos X18", "capacities": ["16TB", "18TB"], "count_ratio": 0.4},
                {"model": "Seagate Exos X20", "capacities": ["20TB"], "count_ratio": 0.4},
                {"model": "Seagate Exos X24", "capacities": ["24TB"], "count_ratio": 0.2}
            ],
            "disk_count": 180,
            "concurrent": 30
        },
        {
            "name": "大规模磁盘测试(200+)",
            "description": "测试200+磁盘的并发挂载",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.3},
                {"model": "WD Gold", "capacities": ["16TB", "18TB", "20TB"], "count_ratio": 0.3},
                {"model": "Seagate Exos X18", "capacities": ["18TB"], "count_ratio": 0.2},
                {"model": "Seagate Exos X20", "capacities": ["20TB"], "count_ratio": 0.2}
            ],
            "disk_count": 220,
            "concurrent": 40
        },
        {
            "name": "高并发测试",
            "description": "测试50并发挂载",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 1.0}
            ],
            "disk_count": 120,
            "concurrent": 50
        },
        {
            "name": "超大规模测试(288磁盘)",
            "description": "测试最大规模磁盘数量",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.4},
                {"model": "WD Gold", "capacities": ["18TB", "20TB"], "count_ratio": 0.3},
                {"model": "Seagate Exos X20", "capacities": ["20TB"], "count_ratio": 0.3}
            ],
            "disk_count": 288,
            "concurrent": 50
        },
        {
            "name": "全型号混合测试",
            "description": "所有品牌型号混合",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.2},
                {"model": "WD Gold", "capacities": ["16TB", "18TB", "20TB"], "count_ratio": 0.2},
                {"model": "Seagate Exos X18", "capacities": ["16TB", "18TB"], "count_ratio": 0.2},
                {"model": "Seagate Exos X20", "capacities": ["20TB"], "count_ratio": 0.2},
                {"model": "Seagate IronWolf Pro", "capacities": ["20TB", "22TB"], "count_ratio": 0.2}
            ],
            "disk_count": 200,
            "concurrent": 35
        },
        {
            "name": "极限容量测试",
            "description": "使用最大容量型号",
            "models": [
                {"model": "WD Ultrastar DC HC690", "capacities": ["32TB"], "count_ratio": 0.3},
                {"model": "WD Ultrastar DC HC590", "capacities": ["26TB"], "count_ratio": 0.3},
                {"model": "Seagate Exos X24", "capacities": ["24TB"], "count_ratio": 0.4}
            ],
            "disk_count": 160,
            "concurrent": 30
        },
        {
            "name": "CHIA专用优化测试",
            "description": "模拟CHIA农场常见配置",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.6},
                {"model": "WD Gold", "capacities": ["18TB", "20TB"], "count_ratio": 0.4}
            ],
            "disk_count": 250,
            "concurrent": 45
        },
        {
            "name": "最终全面测试",
            "description": "综合所有情况进行最终验证",
            "models": [
                {"model": "WD Ultrastar DC HC620", "capacities": ["14TB", "15TB"], "count_ratio": 0.25},
                {"model": "WD Gold", "capacities": ["16TB", "18TB", "20TB"], "count_ratio": 0.25},
                {"model": "Seagate Exos X18", "capacities": ["18TB"], "count_ratio": 0.25},
                {"model": "Seagate Exos X20", "capacities": ["20TB"], "count_ratio": 0.25}
            ],
            "disk_count": 275,
            "concurrent": 50
        }
    ]

    results = []

    print("="*60)
    print("Chia Mount 脚本 - 10次模拟测试")
    print("="*60)

    for i, config in enumerate(test_configs, 1):
        result = run_single_test(i, config["disk_count"], config, config["concurrent"])
        result["test_num"] = i
        results.append(result)

        status = "成功" if result["success"] else "失败"
        print(f"\n测试 #{i} 结果: {status}")
        print(f"  成功: {result['success_count']}, 失败: {result['failure_count']}")
        print(f"  退出码: {result['exit_code']}")

    generate_html_report(results)

    print("\n" + "="*60)
    print("所有测试完成!")
    print(f"成功: {sum(1 for r in results if r['success'])}/10")
    print(f"失败: {sum(1 for r in results if not r['success'])}/10")
    print("="*60)

def generate_html_report(results):
    """生成HTML测试报告"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Chia Mount 脚本模拟测试报告</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }}
        h1 {{
            color: #333;
            text-align: center;
            margin-bottom: 10px;
        }}
        .summary {{
            display: flex;
            justify-content: center;
            gap: 40px;
            margin: 30px 0;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 8px;
        }}
        .summary-item {{
            text-align: center;
        }}
        .summary-value {{
            font-size: 36px;
            font-weight: bold;
        }}
        .summary-label {{
            color: #666;
            margin-top: 5px;
        }}
        .success {{ color: #28a745; }}
        .failure {{ color: #dc3545; }}
        .test-card {{
            border: 1px solid #ddd;
            border-radius: 8px;
            margin: 20px 0;
            padding: 20px;
        }}
        .test-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }}
        .test-title {{
            font-size: 18px;
            font-weight: bold;
            color: #333;
        }}
        .test-status {{
            padding: 5px 15px;
            border-radius: 20px;
            font-weight: bold;
        }}
        .test-status.success {{
            background: #d4edda;
            color: #155724;
        }}
        .test-status.failure {{
            background: #f8d7da;
            color: #721c24;
        }}
        .test-info {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 15px;
        }}
        .info-item {{
            padding: 10px;
            background: #f8f9fa;
            border-radius: 5px;
        }}
        .info-label {{
            color: #666;
            font-size: 12px;
            margin-bottom: 5px;
        }}
        .info-value {{
            font-weight: bold;
            color: #333;
        }}
        .models-list {{
            margin-top: 15px;
        }}
        .model-tag {{
            display: inline-block;
            padding: 5px 10px;
            background: #e9ecef;
            border-radius: 15px;
            margin: 5px 5px 5px 0;
            font-size: 13px;
        }}
        .footer {{
            text-align: center;
            margin-top: 30px;
            color: #666;
            font-size: 14px;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Chia Mount 脚本模拟测试报告</h1>
        <p style="text-align: center; color: #666;">生成时间: {timestamp}</p>

        <div class="summary">
            <div class="summary-item">
                <div class="summary-value">{len(results)}</div>
                <div class="summary-label">总测试数</div>
            </div>
            <div class="summary-item">
                <div class="summary-value success">{sum(1 for r in results if r['success'])}</div>
                <div class="summary-label">成功</div>
            </div>
            <div class="summary-item">
                <div class="summary-value failure">{sum(1 for r in results if not r['success'])}</div>
                <div class="summary-label">失败</div>
            </div>
            <div class="summary-item">
                <div class="summary-value">{sum(r['success_count'] for r in results)}</div>
                <div class="summary-label">总成功挂载</div>
            </div>
        </div>
"""

    for result in results:
        status_class = "success" if result["success"] else "failure"
        status_text = "成功" if result["success"] else "失败"
        config = result["test_config"]

        html += f"""
        <div class="test-card">
            <div class="test-header">
                <div class="test-title">测试 #{result['test_num']}: {config['name']}</div>
                <div class="test-status {status_class}">{status_text}</div>
            </div>
            <div class="test-info">
                <div class="info-item">
                    <div class="info-label">磁盘数量</div>
                    <div class="info-value">{result['disk_count']}</div>
                </div>
                <div class="info-item">
                    <div class="info-label">成功挂载</div>
                    <div class="info-value success">{result['success_count']}</div>
                </div>
                <div class="info-item">
                    <div class="info-label">失败挂载</div>
                    <div class="info-value failure">{result['failure_count']}</div>
                </div>
                <div class="info-item">
                    <div class="info-label">并发数</div>
                    <div class="info-value">{result['concurrent_mounts']}</div>
                </div>
                <div class="info-item">
                    <div class="info-label">退出码</div>
                    <div class="info-value">{result['exit_code']}</div>
                </div>
            </div>
            <div class="models-list">
                <div class="info-label">磁盘型号配置:</div>
"""
        for model in config["models"]:
            html += f'<span class="model-tag">{model["model"]} ({", ".join(model["capacities"])}) - {int(model["count_ratio"]*100)}%</span>'

        html += f"""
            </div>
            <div class="info-label" style="margin-top: 15px;">测试描述:</div>
            <p style="color: #666; margin-top: 5px;">{config['description']}</p>
        </div>
"""

    html += f"""
        <div class="footer">
            <p>Chia Mount 脚本 - 模拟测试报告</p>
            <p>包含 WD HC620, WD Gold, Seagate Exos X18/X20/X24 等多种磁盘型号</p>
        </div>
    </div>
</body>
</html>
"""

    report_file = os.path.join(SCRIPT_DIR, "test_report.html")
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"\nHTML报告已生成: {report_file}")

if __name__ == "__main__":
    main()
