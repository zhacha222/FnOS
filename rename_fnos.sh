#!/bin/bash
#
# 脚本名称: rename_fnos.sh
# 描述: 修改飞牛OS中外接存储的共享名称（基于挂载点 /vol00 识别）
# 用法:
#   sudo ./rename_fnos.sh              # 只显示挂载在 /vol00 下的设备（外接盘）
#   sudo ./rename_fnos.sh -a           # 显示所有设备（含系统盘，谨慎）
#

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认模式：只显示挂载在 /vol00 下的设备
MODE="external"

# 解析命令行参数
for arg in "$@"; do
    case $arg in
        -a|--all)
            MODE="all"
            shift
            ;;
    esac
done

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 sudo 或以 root 用户执行此脚本。${NC}"
    exit 1
fi

# 检查 jq（必需）
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}未找到 jq，尝试安装...${NC}"
    apt update && apt install -y jq || {
        echo -e "${RED}安装 jq 失败，请手动安装。${NC}"
        exit 1
    }
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   飞牛OS 外接存储共享名称修改工具   ${NC}"
echo -e "${GREEN}========================================${NC}"
case $MODE in
    all)
        echo -e "${YELLOW}（显示所有设备，包含系统盘，请谨慎选择）${NC}"
        ;;
    external)
        echo -e "${BLUE}（只显示挂载在 /vol00 下的外接存储）${NC}"
        ;;
esac

# 获取所有块设备信息（包括分区）
FIELDS="NAME,TYPE,MOUNTPOINT,UUID,FSTYPE,SIZE,RM,MODEL,LABEL,TRAN"
lsblk_json=$(lsblk -J -o "$FIELDS" 2>/dev/null)

# 递归提取所有块设备（包括 children）
extract_devices() {
    jq -c '
        def recurse:
            .[] 
            | ., 
              (if .children then .children | recurse else empty end);
        [.blockdevices | recurse] | .[]
    '
}

# 主循环
while true; do
    # 构建设备列表数组（每次重新构建，以便反映最新状态）
    declare -a DEVICES=()
    while IFS= read -r line; do
        name=$(jq -r '.name // empty' <<<"$line")
        type=$(jq -r '.type // empty' <<<"$line")
        mountpoint=$(jq -r '.mountpoint // empty' <<<"$line")
        uuid=$(jq -r '.uuid // empty' <<<"$line")
        fstype=$(jq -r '.fstype // empty' <<<"$line")
        size=$(jq -r '.size // empty' <<<"$line")
        rm=$(jq -r '.rm // false' <<<"$line")
        model=$(jq -r '.model // empty' <<<"$line")
        label=$(jq -r '.label // empty' <<<"$line")
        tran=$(jq -r '.tran // empty' <<<"$line")

        # 必须有 UUID
        if [[ -z "$uuid" ]]; then
            continue
        fi

        # 跳过不需要的设备类型
        if [[ "$type" == "loop" || "$type" == "rom" || "$type" == "ram" ]]; then
            continue
        fi

        # 跳过 LVM/RAID 成员
        if [[ "$fstype" == "LVM2_member" || "$fstype" == "linux_raid_member" ]]; then
            continue
        fi

        # 跳过 swap
        if [[ "$fstype" == "swap" ]]; then
            continue
        fi

        # 根据 MODE 过滤设备
        case $MODE in
            external)
                # 只保留挂载点以 /vol00/ 开头的设备
                if [[ -n "$mountpoint" && "$mountpoint" == /vol00/* ]]; then
                    :
                else
                    continue
                fi
                ;;
            all)
                # 不过滤
                ;;
        esac

        # 存储设备信息
        DEVICES+=("$name|$fstype|$mountpoint|$uuid|$size|$model|$rm|$label|$tran")

    done < <(echo "$lsblk_json" | extract_devices)

    if [[ ${#DEVICES[@]} -eq 0 ]]; then
        echo -e "${RED}没有符合条件的设备。${NC}"
        exit 1
    fi

    # 显示设备列表
    echo -e "\n${BLUE}请选择要改名的设备（输入 0 退出）：${NC}"
    for i in "${!DEVICES[@]}"; do
        IFS='|' read -r name fstype mountpoint uuid size model rm label tran <<< "${DEVICES[$i]}"
        uuid_short=${uuid:0:8}
        mountpoint_disp=${mountpoint:-未挂载}
        model_disp=${model:-未知型号}
        rm_flag=""
        if [[ "$rm" == "true" ]]; then
            rm_flag="[可移动]"
        fi
        tran_flag=""
        if [[ -n "$tran" ]]; then
            tran_flag="[$tran]"
        fi
        fstype_disp=${fstype:-未知}
        label_disp=${label:+(${label})}
        printf "%2d) %s %s %s %s [%s] %s 挂载: %s UUID: %s... 型号: %s\n" \
            $((i+1)) "$name" "$label_disp" "$rm_flag" "$tran_flag" "$size" "$fstype_disp" "$mountpoint_disp" "$uuid_short" "$model_disp"
    done

    # 用户选择
    echo ""
    read -p "请选择设备序号 (1-${#DEVICES[@]}, 0 退出): " choice
    if [[ "$choice" == "0" ]]; then
        echo "退出。"
        exit 0
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DEVICES[@]} )); then
        echo -e "${RED}无效选择，请重新输入。${NC}"
        continue
    fi

    selected="${DEVICES[$((choice-1))]}"
    IFS='|' read -r DEV_NAME FS_TYPE CURRENT_MOUNT DEVICE_UUID DEV_SIZE DEV_MODEL RM_FLAG LABEL TRAN <<< "$selected"

    echo -e "\n${GREEN}已选择: $DEV_NAME${NC}"
    echo "  文件系统: $FS_TYPE"
    echo "  当前挂载点: ${CURRENT_MOUNT:-未挂载}"
    echo "  传输类型: ${TRAN:-未知}"
    echo "  型号: ${DEV_MODEL:-未知}"
    echo "  UUID: $DEVICE_UUID"
    echo "  标签: ${LABEL:-无}"

    # 确认步骤：提供返回选项
    echo ""
    read -p "按 Enter 继续修改名称，输入 b 返回重新选择，输入 q 退出: " confirm
    case "$confirm" in
        b|B|返回)
            continue
            ;;
        q|Q|退出)
            echo "操作取消。"
            exit 0
            ;;
        *)
            # 继续修改
            ;;
    esac

    # 输入新共享名
    echo ""
    read -p "请输入新的共享名称（仅用字母、数字、下划线）: " NEW_NAME
    if [[ ! "$NEW_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo -e "${RED}错误：新名称只能包含字母、数字和下划线。${NC}"
        continue
    fi

    # 确定挂载基目录
    if [[ -d "/vol00" ]]; then
        BASE_DIR="/vol00"
    elif [[ -d "/mnt" ]]; then
        BASE_DIR="/mnt"
    else
        echo -e "${RED}错误：未找到合适的挂载基目录（/vol00 或 /mnt）。${NC}"
        exit 1
    fi
    NEW_MOUNT="${BASE_DIR}/${NEW_NAME}"
    echo -e "新挂载点: ${GREEN}$NEW_MOUNT${NC}"

    # 检查新目录
    if [[ -e "$NEW_MOUNT" ]]; then
        read -p "目录 $NEW_MOUNT 已存在，是否覆盖？(y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "操作取消。"
            continue
        fi
        if mountpoint -q "$NEW_MOUNT"; then
            umount "$NEW_MOUNT" 2>/dev/null || true
        fi
    else
        mkdir -p "$NEW_MOUNT"
    fi

    # 卸载原挂载点（如果已挂载）
    if [[ -n "$CURRENT_MOUNT" ]] && [[ "$CURRENT_MOUNT" != "未挂载" ]] && mountpoint -q "$CURRENT_MOUNT"; then
        echo "正在卸载原挂载点 $CURRENT_MOUNT ..."
        if ! umount "$CURRENT_MOUNT" 2>/dev/null; then
            echo -e "${YELLOW}普通卸载失败，尝试强制卸载（lazy umount）...${NC}"
            umount -l "$CURRENT_MOUNT" 2>/dev/null || {
                echo -e "${RED}卸载原挂载点失败，可能正在使用中。请关闭相关程序后再试。${NC}"
                continue
            }
        fi
    fi

    # 备份 fstab
    FSTAB="/etc/fstab"
    BACKUP="/etc/fstab.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$FSTAB" "$BACKUP"
    echo -e "已备份 fstab 到 ${YELLOW}$BACKUP${NC}"

    # 清理 fstab 中该 UUID 的旧条目（注释掉）
    sed -i "s|^\(.*UUID=${DEVICE_UUID}.*\)|# \1 # commented by rename script|g" "$FSTAB"

    # 添加新条目（根据文件系统类型调整选项）
    MOUNT_OPTS="defaults,nofail,noatime"
    if [[ "$FS_TYPE" == "ntfs" || "$FS_TYPE" == "ntfs-3g" ]]; then
        MOUNT_OPTS="defaults,nofail,noatime,uid=1000,gid=1000,umask=000,utf8"
        FS_TYPE="ntfs-3g"
    elif [[ "$FS_TYPE" == "exfat" ]]; then
        MOUNT_OPTS="defaults,nofail,noatime,uid=1000,gid=1000,umask=000,iocharset=utf8"
    fi

    {
        echo "# Added by rename script on $(date)"
        echo "UUID=$DEVICE_UUID $NEW_MOUNT $FS_TYPE $MOUNT_OPTS 0 0"
    } >> "$FSTAB"
    echo -e "${GREEN}新挂载条目已添加到 /etc/fstab。${NC}"

    # 挂载测试
    echo "正在挂载新目录..."
    if mount -a; then
        echo -e "${GREEN}挂载成功！${NC}"
    else
        echo -e "${RED}挂载失败，请检查 /etc/fstab 语法或手动执行 mount -a。${NC}"
        read -p "是否恢复之前的 fstab 备份？(y/N): " recover
        if [[ "$recover" =~ ^[Yy]$ ]]; then
            cp "$BACKUP" "$FSTAB"
            echo "已恢复备份。"
        fi
        continue
    fi

    chmod 777 "$NEW_MOUNT"
    echo -e "目录权限已设置为 777。"

    echo ""
    echo -e "${GREEN}设备 $DEV_NAME 改名完成！${NC}"
    echo "新挂载点：$NEW_MOUNT"

    # 询问是否继续
    echo ""
    read -p "是否继续修改其他设备？(y/N): " again
    if [[ ! "$again" =~ ^[Yy]$ ]]; then
        break
    fi
done

echo -e "${GREEN}脚本执行完毕。${NC}"
exit 0
