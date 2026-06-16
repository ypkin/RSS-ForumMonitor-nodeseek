#!/bin/bash
#
# RSS Monitor 服务安装与管理脚本
# V3.0 增强版：完美解决 CF 拦截、PushPlus 业务防漏报、以及【顶贴/重启重复推送】问题
#

set -euo pipefail

# --- 全局常量与配置 ---
readonly SERVICE="rss_monitor"
readonly INSTALL_DIR="/opt/${SERVICE}"
readonly VENV_DIR="${INSTALL_DIR}/venv"
readonly BIN_FILE="/usr/local/bin/rssctl"
readonly RK_FILE="/usr/local/bin/rk"
readonly BASH_COMPLETION_DIR="/etc/bash_completion.d"
readonly ZSH_COMPLETION_DIR="/usr/share/zsh/site-functions"
readonly CONFIG_FILE="${INSTALL_DIR}/config.json"
readonly MONITOR_SCRIPT="${INSTALL_DIR}/rss_monitor.py"
readonly UNINSTALLER_SCRIPT="${INSTALL_DIR}/uninstall.sh"

# --- 辅助函数 ---
info() { echo -e "\033[32m[信息]\033[0m $1"; }
warn() { echo -e "\033[33m[警告]\033[0m $1" >&2; }
error() { echo -e "\033[31m[错误]\033[0m $1" >&2; exit 1; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "此脚本必须以 root 权限 (sudo) 运行。"
    fi
}

# --- 核心安装功能 ---

install_dependencies() {
    info "=== [1/9] 安装系统依赖 ==="
    if ! apt-get update -qq 2>/dev/null || ! apt-get install -y -qq python3 python3-pip python3-venv bash-completion >/dev/null 2>&1; then
        error "依赖安装失败。请尝试手动运行 'apt-get update' 后重试。"
    fi
}

setup_directories_and_venv() {
    info "=== [2/9] 配置程序目录与 Python 虚拟环境 ==="
    if ! id -u "${SERVICE}" &>/dev/null; then
        info "创建专用的系统用户 '${SERVICE}'..."
        useradd -r -s /bin/false -d "${INSTALL_DIR}" "${SERVICE}"
    fi

    mkdir -p "${INSTALL_DIR}"
    
    info "创建 Python 虚拟环境..."
    python3 -m venv "${VENV_DIR}"

    info "安装 Python 依赖库 (requests, feedparser)..."
    if ! "${VENV_DIR}/bin/pip" install -q --upgrade pip || \
       ! "${VENV_DIR}/bin/pip" install -q "requests[security]" feedparser; then
        error "在虚拟环境中安装 Python 依赖失败。"
    fi
    
    chown -R "${SERVICE}:${SERVICE}" "${INSTALL_DIR}"
}

create_config_file() {
    info "=== [3/9] 写入示例配置文件 ==="
    if [ ! -f "${CONFIG_FILE}" ]; then
        cat > "${CONFIG_FILE}" <<EOF
{
  "interval": 15,
  "keywords": ["AI", "ChatGPT", "开源"],
  "pushplus_token": "请在这里填写你的pushplus token"
}
EOF
        chown "${SERVICE}:${SERVICE}" "${CONFIG_FILE}"
        info "配置文件已创建于: ${CONFIG_FILE}"
        warn "请记得修改配置文件，填入你自己的 PushPlus Token！"
    else
        info "配置文件已存在，跳过创建以保留原有配置。"
    fi
}

create_monitor_script() {
    info "=== [4/9] 写入主监控脚本 (rss_monitor.py) ==="
    cat > "${MONITOR_SCRIPT}" <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os
import json
import time
import signal
import requests
import feedparser
import sys
import re
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# --- 全局常量 ---
CONFIG_FILE = "/opt/rss_monitor/config.json"
CACHE_FILE = "/opt/rss_monitor/seen_ids.json"
RSS_URL = "https://rss.nodeseek.com"
MAX_CACHE_SIZE = 1000

# --- 全局状态变量 ---
running = True
reload_config_flag = False

def log(message):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{timestamp}] {message}", flush=True)

def load_config():
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log(f"错误：无法加载或解析配置文件: {e}")
        return None

def extract_post_id(link):
    """从 NodeSeek 链接中精准提取唯一的帖子数字 ID，彻底防止顶贴和翻页导致的重复推送"""
    match = re.search(r'post-(\d+)', link)
    if match:
        return match.group(1)
    return link  # 如果解析失败，降级退回到使用完整链接字符串

def load_seen_ids():
    """从本地文件加载已推送的帖子 ID 历史"""
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, list):
                    return data
        except Exception as e:
            log(f"警告：无法加载持久化去重缓存: {e}")
    return []

def save_seen_ids(ids_list):
    """将已推送的帖子 ID 历史保存到本地文件"""
    try:
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump(ids_list, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log(f"错误：保存去重缓存文件失败: {e}")

def send_pushplus(token, title, content):
    if not token or token == "请在这里填写你的pushplus token":
        log("警告：PushPlus token 未配置，跳过发送。")
        return

    url = "https://www.pushplus.plus/send"
    data = {
        "token": token,
        "title": title,
        "content": content,
        "template": "markdown",
    }

    session = requests.Session()
    retry_strategy = Retry(
        total=3,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["POST"],
        backoff_factor=1
    )
    adapter = HTTPAdapter(max_retries=retry_strategy)
    session.mount("https://", adapter)
    session.mount("http://", adapter)

    try:
        response = session.post(url, json=data, timeout=15)
        response.raise_for_status() 
        
        result = response.json()
        if result.get("code") == 200:
            log(f"成功发送通知: {title}")
        else:
            log(f"错误：PushPlus 拒绝发送。错误码: {result.get('code')}, 原因: {result.get('msg', '未知')}")
            
    except requests.exceptions.RequestException as e:
        log(f"错误：PushPlus 通知网络发送失败 (已重试3次): {e}")

def sigterm_handler(signum, frame):
    global running
    log("收到 SIGTERM 信号，服务准备停止...")
    running = False

def sighup_handler(signum, frame):
    global reload_config_flag
    log("收到 SIGHUP 信号，将重新加载配置...")
    reload_config_flag = True

signal.signal(signal.SIGTERM, sigterm_handler)
signal.signal(signal.SIGHUP, sighup_handler)

def main():
    global reload_config_flag
    
    log("RSS Monitor 服务已启动。")
    config = load_config()
    if not config:
        log("错误：启动时无法加载配置，服务退出。")
        sys.exit(1)
        
    # 初始化去重缓存（结合内存 Set 和持久化 List）
    seen_ids_list = load_seen_ids()
    seen_ids = set(seen_ids_list)
    
    if seen_ids:
        log(f"成功从本地文件载入 {len(seen_ids)} 条历史去重记录。")

    while running:
        try:
            if reload_config_flag:
                new_config = load_config()
                if new_config:
                    config = new_config
                    log("配置已成功重新加载。")
                else:
                    log("警告：尝试重载配置失败，继续使用旧配置。")
                reload_config_flag = False

            # 伪装 Header 绕过 Cloudflare
            headers = {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
            try:
                rss_resp = requests.get(RSS_URL, headers=headers, timeout=15)
                rss_resp.raise_for_status()
                feed = feedparser.parse(rss_resp.text)
            except Exception as e:
                log(f"错误：获取或解析 RSS 源失败 (可能是CF拦截或网络问题): {e}")
                time.sleep(60)
                continue

            if feed.bozo:
                log(f"警告：RSS feed 解析可能存在格式问题: {feed.bozo_exception}")

            keywords = {kw.lower() for kw in config.get("keywords", [])}
            has_new_data = False

            for entry in reversed(feed.entries):
                post_id = extract_post_id(entry.link)
                
                if post_id not in seen_ids:
                    seen_ids.add(post_id)
                    seen_ids_list.append(post_id)
                    has_new_data = True
                    
                    entry_title_lower = entry.title.lower()
                    if any(kw in entry_title_lower for kw in keywords):
                        log(f"发现关键词匹配: '{entry.title}' (帖子ID: {post_id})")
                        summary_text = entry.get("summary", "(无摘要)")
                        content = f"**摘要**: {summary_text[:150]}...\n\n[点击查看原文]({entry.link})"
                        send_pushplus(config.get("pushplus_token"), entry.title, content)
            
            # 定期维护缓存文件大小
            if has_new_data:
                if len(seen_ids_list) > MAX_CACHE_SIZE:
                    seen_ids_list = seen_ids_list[-MAX_CACHE_SIZE:]
                    seen_ids = set(seen_ids_list)
                save_seen_ids(seen_ids_list)
            
            time.sleep(config.get("interval", 15))

        except Exception as e:
            log(f"错误：主循环发生未知异常: {e}")
            time.sleep(60)

    log("RSS Monitor 服务已停止。")

if __name__ == "__main__":
    main()
EOF
    chmod +x "${MONITOR_SCRIPT}"
}

create_control_tool() {
    info "=== [5/9] 安装管理工具 (rssctl) ==="
    cat > "${BIN_FILE}" <<'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import os
import json
import subprocess

# --- 全局常量 ---
SERVICE_NAME_CONST = "rss_monitor"
CONFIG_FILE = f"/opt/{SERVICE_NAME_CONST}/config.json"
UNINSTALLER_SCRIPT = f"/opt/{SERVICE_NAME_CONST}/uninstall.sh"
SERVICE_FILE = f"{SERVICE_NAME_CONST}.service"

class C:
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    RED = "\033[31m"
    RESET = "\033[0m"

def run_system_command(command, **kwargs):
    try:
        result = subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)
        return result.stdout.strip()
    except FileNotFoundError:
        print(f"{C.RED}[错误]{C.RESET} 命令 '{command[0]}' 未找到。", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"{C.RED}[错误]{C.RESET} 执行命令 '{' '.join(command)}' 失败:", file=sys.stderr)
        print(e.stderr, file=sys.stderr)
        sys.exit(1)

def reload_service():
    print("正在通知服务重新加载配置...")
    run_system_command(["systemctl", "kill", "-s", "HUP", SERVICE_FILE])
    print(f"{C.GREEN}服务已收到重载指令。{C.RESET}")

def load_config():
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"{C.RED}[错误]{C.RESET} 配置文件 '{CONFIG_FILE}' 未找到。", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError:
        print(f"{C.RED}[错误]{C.RESET} 配置文件 '{CONFIG_FILE}' 格式无效。", file=sys.stderr)
        sys.exit(1)

def save_config(cfg):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except IOError as e:
        print(f"{C.RED}[错误]{C.RESET} 无法写入配置文件: {e}", file=sys.stderr)
        sys.exit(1)

def list_keywords(cfg):
    keywords = sorted(cfg.get("keywords", []))
    if not keywords:
        print(f"{C.YELLOW}当前没有配置任何关键词。{C.RESET}")
    else:
        print(f"{C.GREEN}当前关键词列表:{C.RESET}")
        for i, kw in enumerate(keywords, 1):
            print(f"  {i}. {kw}")
    return keywords

def add_keyword(cfg, keyword):
    keywords = set(cfg.get("keywords", []))
    if keyword in keywords:
        print(f"{C.YELLOW}关键词 '{keyword}' 已存在。{C.RESET}")
        return
    keywords.add(keyword)
    cfg["keywords"] = sorted(list(keywords))
    save_config(cfg)
    print(f"{C.GREEN}成功添加关键词: {keyword}{C.RESET}")
    reload_service()

def add_keywords(cfg, keywords_to_add):
    current_keywords = set(cfg.get("keywords", []))
    added, existed = [], []
    for kw in keywords_to_add:
        if kw not in current_keywords:
            current_keywords.add(kw)
            added.append(kw)
        else:
            existed.append(kw)
    if added:
        cfg["keywords"] = sorted(list(current_keywords))
        save_config(cfg)
        print(f"\n{C.GREEN}成功添加 {len(added)} 个新关键词: {', '.join(added)}{C.RESET}")
        reload_service()
    else:
        print(f"\n{C.YELLOW}没有新的关键词被添加。{C.RESET}")
    if existed:
        print(f"{C.YELLOW}下列 {len(existed)} 个关键词已存在，已跳过: {', '.join(existed)}{C.RESET}")

def remove_keyword(cfg, keyword):
    keywords = cfg.get("keywords", [])
    if keyword not in keywords:
        print(f"{C.YELLOW}关键词 '{keyword}' 不存在。{C.RESET}")
        return
    keywords.remove(keyword)
    cfg["keywords"] = keywords
    save_config(cfg)
    print(f"{C.GREEN}成功删除关键词: {keyword}{C.RESET}")
    reload_service()

def remove_keywords(cfg, keywords_to_remove):
    current_keywords = set(cfg.get("keywords", []))
    removed_set = current_keywords.intersection(set(keywords_to_remove))
    current_keywords.difference_update(removed_set)
    if removed_set:
        cfg["keywords"] = sorted(list(current_keywords))
        save_config(cfg)
        print(f"\n{C.GREEN}成功删除 {len(removed_set)} 个关键词: {', '.join(sorted(list(removed_set)))}{C.RESET}")
        reload_service()
    else:
        print(f"\n{C.YELLOW}没有关键词被删除。{C.RESET}")

def set_token(cfg, token):
    if not token:
        print(f"{C.RED}[错误]{C.RESET} token 不能为空。")
        return
    cfg['pushplus_token'] = token
    save_config(cfg)
    print(f"{C.GREEN}PushPlus token 已成功更新。{C.RESET}")
    reload_service()

def set_interval(cfg, interval_str):
    try:
        interval = int(interval_str)
        if interval < 10:
            print(f"\n{C.RED}[错误]{C.RESET} 检索间隔不能低于10秒，以避免对目标网站造成过高负载。")
            return
        cfg['interval'] = interval
        save_config(cfg)
        print(f"\n{C.GREEN}检索时间间隔已成功更新为 {interval} 秒。{C.RESET}")
        reload_service()
    except ValueError:
        print(f"\n{C.RED}[错误]{C.RESET} 输入无效，请输入一个纯数字。")

def uninstall_service():
    if os.geteuid() != 0:
        print(f"{C.RED}[错误]{C.RESET} 卸载操作需要 root 权限。")
        print(f"{C.YELLOW}请使用 'sudo rkm' 或 'sudo rssctl menu' 再次运行此命令。{C.RESET}")
        return
    print(f"\n{C.RED}" + "="*50)
    print("!!! 危险操作警告 !!!")
    print(f"您即将彻底卸载 '{SERVICE_NAME_CONST}' 服务。")
    print("此操作将会：\n- 停止并禁用服务\n- 删除所有程序文件、配置文件和日志\n- 删除专为此服务创建的系统用户")
    print("此操作一旦执行，将无法撤销！")
    print("="*50 + f"{C.RESET}\n")
    try:
        confirm = input(f"{C.YELLOW}为防止误操作，请输入服务的名称 '{SERVICE_NAME_CONST}' 来确认卸载: {C.RESET}").strip()
        if confirm == SERVICE_NAME_CONST:
            print("正在执行卸载脚本...")
            subprocess.run(['bash', UNINSTALLER_SCRIPT, 'uninstall'], check=True)
            print(f"{C.GREEN}服务已成功卸载。{C.RESET}")
        else:
            print(f"{C.YELLOW}输入不匹配，卸载操作已取消。{C.RESET}")
    except (KeyboardInterrupt, EOFError):
        print(f"\n{C.YELLOW}操作已取消。{C.RESET}")

def show_menu():
    while True:
        print(f"\n{C.GREEN}=== RSS Monitor 服务管理菜单 ===")
        print("1. 查看关键词列表")
        print("2. 添加关键词")
        print("3. 删除关键词")
        print("4. 修改 PushPlus Token")
        print("5. 修改检索间隔")
        print("-------------------------------")
        print("6. 查看服务状态")
        print("7. 重启服务")
        print("8. 查看实时日志")
        print("-------------------------------")
        print(f"{C.YELLOW}9. 卸载服务 (危险操作){C.GREEN}")
        print("0. 退出菜单")
        print("===============================" + C.RESET)
        
        choice = input(f"{C.GREEN}请输入选项序号: {C.RESET}").strip()

        if choice == '1':
            list_keywords(load_config())
        elif choice == '2':
            cfg = load_config()
            list_keywords(cfg)
            user_input = input("\n请输入一个或多个要添加的关键词 (用空格分隔, 例如: 科技 财经): ").strip()
            if user_input:
                keywords = [kw for kw in user_input.split(' ') if kw]
                if keywords: add_keywords(cfg, keywords)
        elif choice == '3':
            cfg = load_config()
            keywords_list = list_keywords(cfg)
            if not keywords_list: continue
            user_input = input("\n请输入一个或多个要删除的关键词编号 (用空格分隔, 例如: 1 3 5): ").strip()
            if not user_input:
                print(f"{C.YELLOW}操作已取消。{C.RESET}")
                continue
            nums_to_delete, invalid_inputs = set(), []
            for num_str in user_input.split(' '):
                if not num_str: continue
                try:
                    num = int(num_str)
                    if 1 <= num <= len(keywords_list): nums_to_delete.add(num)
                    else: invalid_inputs.append(num_str)
                except ValueError:
                    invalid_inputs.append(num_str)
            if invalid_inputs: print(f"\n{C.RED}[错误]{C.RESET} 以下输入是无效的或超出范围: {', '.join(invalid_inputs)}")
            if not nums_to_delete: continue
            keywords_to_delete = [keywords_list[i-1] for i in sorted(list(nums_to_delete))]
            print("\n你确定要删除以下关键词吗?")
            for kw in keywords_to_delete: print(f"- {kw}")
            confirm = input(f"{C.YELLOW}请输入 'y' 确认: {C.RESET}").strip().lower()
            if confirm == 'y': remove_keywords(cfg, keywords_to_delete)
            else: print(f"{C.YELLOW}删除操作已取消。{C.RESET}")
        elif choice == '4':
            token = input("请输入新的 PushPlus Token: ").strip()
            if token: set_token(load_config(), token)
        elif choice == '5':
            cfg = load_config()
            current_interval = cfg.get('interval', 15)
            print(f"当前检索间隔为: {current_interval} 秒 (约 {current_interval/60:.2f} 分钟)")
            new_interval = input(f"请输入新的检索间隔 (秒, {C.YELLOW}最低10秒, 请谨慎设置{C.RESET}): ").strip()
            if new_interval: set_interval(cfg, new_interval)
        elif choice == '6':
            os.system(f"systemctl status {SERVICE_FILE}")
        elif choice == '7':
            print("正在重启服务...")
            run_system_command(["systemctl", "restart", SERVICE_FILE])
            print(f"{C.GREEN}服务已重启。{C.RESET}")
        elif choice == '8':
            print("按 Ctrl+C 退出日志查看。")
            try:
                os.system(f"journalctl -u {SERVICE_FILE} -f -n 50")
            except KeyboardInterrupt:
                print("\n已退出日志查看。")
        elif choice == '9':
            uninstall_service()
        elif choice == '0':
            print("已退出管理菜单。")
            break
        else:
            print(f"{C.RED}[错误]{C.RESET} 无效输入，请输入菜单中的数字。")

def usage():
    print(f"{C.GREEN}用法: {os.path.basename(sys.argv[0])} [命令] [参数]")
    print("\n可用命令:")
    print("  list-keywords         - 列出所有关键词")
    print("  add-keyword <关键词>    - 添加一个关键词")
    print("  remove-keyword <关键词> - (非交互模式) 按名称删除一个关键词")
    print("  set-token <Token>       - 设置 PushPlus token")
    print("  set-interval <秒数>   - 设置检索时间间隔")
    print("  reload                  - 重新加载服务配置")
    print(f"  menu                    - 显示交互式管理菜单{C.RESET}")

def main():
    if len(sys.argv) == 1 or (len(sys.argv) == 2 and sys.argv[1] in ['-h', '--help']):
        show_menu()
        sys.exit(0)
    cmd = sys.argv[1]
    if cmd == "menu": show_menu()
    elif cmd == "reload": reload_service()
    elif cmd in ["list-keywords", "add-keyword", "remove-keyword", "set-token", "set-interval"]:
        cfg = load_config()
        if cmd == "list-keywords": list_keywords(cfg)
        elif cmd in ["add-keyword", "remove-keyword", "set-token", "set-interval"]:
            if len(sys.argv) != 3: 
                print(f"{C.RED}[错误]{C.RESET} 命令 '{cmd}' 需要一个参数。"); usage(); sys.exit(1)
            arg = sys.argv[2]
            if cmd == "add-keyword": add_keyword(cfg, arg)
            elif cmd == "remove-keyword": remove_keyword(cfg, arg)
            elif cmd == "set-token": set_token(cfg, arg)
            elif cmd == "set-interval": set_interval(cfg, arg)
    else:
        usage()

if __name__ == "__main__":
    main()
EOF
    chmod +x "${BIN_FILE}"
}

create_systemd_service() {
    info "=== [6/9] 创建 systemd 服务 ==="
    cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=RSS Monitor Service
After=network.target

[Service]
Type=simple
User=${SERVICE}
Group=${SERVICE}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python3 ${MONITOR_SCRIPT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    info "重新加载 systemd 配置并启动服务..."
    systemctl daemon-reload
    systemctl enable "${SERVICE}.service"
    systemctl restart "${SERVICE}.service"
}

setup_shell_integration() {
    info "=== [7/9] 配置 Shell 自动补全与快捷别名 ==="
    cat > "${BASH_COMPLETION_DIR}/rssctl" <<'EOF'
_rssctl_completion() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "list-keywords add-keyword remove-keyword set-token set-interval reload menu" -- "${cur}") )
        return 0
    fi
    if [[ ${prev} == "remove-keyword" ]]; then
        local keywords=$(rssctl list-keywords 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed -E 's/^\s+[0-9]+\. //')
        COMPREPLY=( $(compgen -W "${keywords}" -- "${cur}") )
    fi
}
complete -F _rssctl_completion rssctl rk
EOF

    mkdir -p "${ZSH_COMPLETION_DIR}"
    ln -sf "${BASH_COMPLETION_DIR}/rssctl" "${ZSH_COMPLETION_DIR}/_rssctl"

    info "=== [8/9] 创建快捷命令 (rk) 与别名 ==="
    ln -sf "${BIN_FILE}" "${RK_FILE}"
    
    local aliases_snippet
    aliases_snippet=$(cat <<'EOF'

# RSS Monitor 快捷别名
alias rk='rssctl'
alias rkl='rssctl list-keywords'
alias rka='rssctl add-keyword'
alias rkr='rssctl remove-keyword'
alias rkm='rssctl menu'
EOF
)
    for homedir in "/root" "${HOME:-/root}"; do
        for rc_file in "${homedir}/.bashrc" "${homedir}/.zshrc"; do
            if [ -f "${rc_file}" ] && ! grep -q "# RSS Monitor 快捷别名" "${rc_file}"; then
                info "添加别名到 ${rc_file}..."
                echo "${aliases_snippet}" >> "${rc_file}"
            fi
        done
    done
}

backup_uninstaller() {
    info "=== [9/9] 备份卸载程序以便管理 ==="
    cp "$0" "${UNINSTALLER_SCRIPT}"
    chmod +x "${UNINSTALLER_SCRIPT}"
}

# --- 完整安装流程 ---
install_all() {
    check_root
    info "开始安装/更新 RSS Monitor 服务..."
    
    install_dependencies
    setup_directories_and_venv
    create_config_file
    create_monitor_script
    create_control_tool
    create_systemd_service
    setup_shell_integration
    backup_uninstaller
    
    # 修正可能存在的文件所有权（针对覆盖升级场景）
    chown -R "${SERVICE}:${SERVICE}" "${INSTALL_DIR}"

    info "=========================================="
    info "🎉 RSS Monitor 升级/安装完成！"
    info "=========================================="
    echo ""
    info "请执行 'source ~/.bashrc' 或 'source ~/.zshrc' 让别名生效（如已配置可无视）。"
    echo ""
    info "常用管理指令:"
    info "  rk 或 rkm              - 进入交互式管理菜单"
    info "  journalctl -u ${SERVICE} -f - 查看实时过滤与持久化载入日志"
    echo ""
    
    "${BIN_FILE}" menu
}

# --- 卸载功能 ---
uninstall_all() {
    check_root
    warn "即将彻底卸载 RSS Monitor 服务！"
    if [[ $- == *i* ]]; then
        read -p "这将删除所有配置文件、去重缓存、脚本和专用用户，确定要继续吗？(y/N): " choice
        if [[ "${choice,,}" != "y" ]]; then
            info "操作已取消。"
            exit 0
        fi
    fi

    info "停止并禁用 systemd 服务..."
    systemctl stop "${SERVICE}.service" &>/dev/null || true
    systemctl disable "${SERVICE}.service" &>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    systemctl daemon-reload

    info "删除程序目录: ${INSTALL_DIR}..."
    rm -rf "${INSTALL_DIR}"

    info "删除命令、软链接和自动补全脚本..."
    rm -f "${BIN_FILE}" "${RK_FILE}" "${BASH_COMPLETION_DIR}/rssctl" "${ZSH_COMPLETION_DIR}/_rssctl"

    info "从 shell 配置文件中移除别名..."
    for homedir in "/root" "${HOME:-/root}"; do
        for rc_file in "${homedir}/.bashrc" "${homedir}/.zshrc"; do
            if [ -f "${rc_file}" ]; then
                sed -i '/# RSS Monitor 快捷别名/,+5d' "${rc_file}"
            fi
        done
    done
    
    if id -u "${SERVICE}" &>/dev/null; then
        info "删除专用用户 '${SERVICE}'..."
        userdel "${SERVICE}"
    fi

    info "卸载完成。"
}

# --- 脚本入口 ---
usage() {
    echo "用法: $0 [install|uninstall]"
    echo "  install:   安装或更新 RSS Monitor 服务"
    echo "  uninstall: 卸载 RSS Monitor 服务"
    exit 1
}

main() {
    if [ "$#" -ne 1 ]; then
        usage
    fi

    case "$1" in
        install)
            install_all
            ;;
        uninstall)
            uninstall_all
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
