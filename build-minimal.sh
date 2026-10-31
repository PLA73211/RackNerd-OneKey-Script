#!/bin/bash
# build-minimal.sh —— 从零一键自搭最小版
# 版本号：sb-update 靠它判断仓库有没有新版
VERSION="1.1.1"
# 目标：只保移动 + 电信稳定，不泄露真实 IP，DNS / WebRTC 不泄露，分流统一，Wi-Fi 通话能用
# base 最基本两个（先确保 VPS 出口）：VMess-WS 2052（Argo → VPS直连）、VLESS-Reality（电信直连 → VPS直连）
# 住宅 IP 是后续加的：填了住宅信息才加 VMess-resi 2053（Argo → 住宅），不填就只有上面两个 VPS 直连节点
# 出口 2 个主 + 1 个规则出口：direct（VPS）、residential（住宅）、warp-out（仅 google.com）
# 防泄露：STUN 拦截，QUIC 走代理，DNS 走代理，客户端全局代理
# Wi-Fi 通话：VPS 不管，客户端 / 路由器旁路 UDP 500/4500 直连 AT&T，其他 UDP 走代理
# 用法（全新 Ubuntu VPS，root）：bash build-minimal.sh
# 密码只在运行时输入，不打印、不记日志，只写进 sb.json

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行"
  exit 1
fi

SB_DIR="/etc/s-box"
SB_BIN="$SB_DIR/sing-box"
SB_JSON="$SB_DIR/sb.json"
CF_BIN="$SB_DIR/cloudflared"

case "$(uname -m)" in
  x86_64) CPU="amd64" ;;
  aarch64) CPU="arm64" ;;
  *) echo "不支持的架构：$(uname -m)"; exit 1 ;;
esac

echo "=== 1/7 填住宅代理（可选，两个都走移动 Argo）==="
echo "美国住宅（移动 Argo 用）："
read -p "美国住宅 IP（可选，不填就先只装 VPS 直连）： " RESI_IP
if [[ -n "$RESI_IP" ]]; then
  read -p "美国住宅端口： " RESI_PORT
  read -p "美国住宅账号： " RESI_USER
  read -s -p "美国住宅密码（输入不显示）： " RESI_PASS
  echo ""
  if [[ -z "$RESI_PORT" || -z "$RESI_USER" || -z "$RESI_PASS" ]]; then
    echo "美国住宅信息没填全，这次先不加美国住宅。"
    RESI_IP=""; RESI_PORT=""; RESI_USER=""; RESI_PASS=""
  fi
else
  echo "这次不加美国住宅，只装 VPS 直连，住宅以后用 add-resi 加。"
fi
echo "英国住宅（移动 Argo 用）："
read -p "英国住宅 IP（可选，不填就没有英国节点）： " UK_IP
if [[ -n "$UK_IP" ]]; then
  read -p "英国住宅端口： " UK_PORT
  read -p "英国住宅账号： " UK_USER
  read -s -p "英国住宅密码（输入不显示）： " UK_PASS
  echo ""
  if [[ -z "$UK_PORT" || -z "$UK_USER" || -z "$UK_PASS" ]]; then
    echo "英国住宅信息没填全，这次不加英国节点。"
    UK_IP=""; UK_PORT=""; UK_USER=""; UK_PASS=""
  fi
else
  echo "这次不加英国住宅。"
fi
read -p "前置域名（回车默认 cloudflare-ech.com）： " FRONT_DOMAIN
FRONT_DOMAIN=${FRONT_DOMAIN:-cloudflare-ech.com}
read -p "CDN 优选 IP（可选，填你测过最快的 Cloudflare IP，不填就用前置域名）： " CDN_IP
# 注意：最好是在你自己的手机/电脑网络上测，不是在 VPS 上测。VPS 上测的快慢不代表手机上快。
# 留空就用前置域名，填了 IP 就用 IP 当 add（host/sni 还是 Argo 域名）
read -p "Acme 真证书域名（可选，有自己域名且 DNS 已指向 VPS IP 才填，不填就只用 Reality）： " ACME_DOMAIN
read -p "Acme 邮箱（填了域名才需要，用于 Let's Encrypt 通知）： " ACME_EMAIL
read -p "VLESS 端口（回车随机）： " PORT_VLESS
PORT_VLESS=${PORT_VLESS:-$(shuf -i 10000-65535 -n 1)}
read -p "VMess-Argo 端口（回车默认 2052）： " PORT_VM
PORT_VM=${PORT_VM:-2052}
if [[ -n "$RESI_IP" ]]; then
  read -p "VMess-resi 端口（回车默认 2053）： " PORT_RESI
  PORT_RESI=${PORT_RESI:-2053}
else
  PORT_RESI=2053
fi
if [[ -n "$UK_IP" ]]; then
  read -p "英国 Argo 端口（回车默认 2054）： " PORT_UK
  PORT_UK=${PORT_UK:-2054}
else
  PORT_UK=2054
fi

echo "=== 2/7 装依赖 ==="
apt update -y
apt install -y jq curl wget openssl qrencode python3 xxd iproute2 cron 2>/dev/null || apt install -y jq curl wget openssl python3 xxd iproute2 cron
mkdir -p "$SB_DIR"

# 查住宅 IP 归属地转中文名：US->美国，GB->英国，JP->日本，KR->韩国，DE->德国，FR->法国，CA->加拿大，AU->澳大利亚，SG->新加坡，HK->香港，TW->台湾，查不到就用国家代码
country_cn() {
  local ip="$1"
  local code=""
  code=$(curl -s -m 5 "http://ip-api.com/json/$ip?fields=countryCode" 2>/dev/null | grep -oP '"countryCode":"\K[A-Z]{2}' || true)
  case "$code" in
    US) echo "美国" ;;
    GB|UK) echo "英国" ;;
    JP) echo "日本" ;;
    KR) echo "韩国" ;;
    DE) echo "德国" ;;
    FR) echo "法国" ;;
    CA) echo "加拿大" ;;
    AU) echo "澳大利亚" ;;
    SG) echo "新加坡" ;;
    HK) echo "香港" ;;
    TW) echo "台湾" ;;
    NL) echo "荷兰" ;;
    "") echo "" ;;
    *) echo "$code" ;;
  esac
}
echo "=== 开 BBR 加速 ==="
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
  sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  echo "BBR：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
else
  echo "内核不支持 BBR，跳过（不影响使用，只是速度没优化）"
fi

echo "=== 3/7 装 sing-box（官方）==="
SB_VER=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
if [[ -z "$SB_VER" ]]; then
  echo "取不到最新版，请检查 VPS 能不能上 GitHub"
  exit 1
fi
echo "sing-box 版本：$SB_VER"
SB_NAME="sing-box-$SB_VER-linux-$CPU"
curl -L -o /tmp/sing-box.tar.gz --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$SB_VER/$SB_NAME.tar.gz"
tar xzf /tmp/sing-box.tar.gz -C /tmp
cp "/tmp/$SB_NAME/sing-box" "$SB_BIN"
chmod +x "$SB_BIN"
"$SB_BIN" version || { echo "sing-box 装失败"; exit 1; }

echo "=== 4/7 装 cloudflared（官方）==="
if [[ ! -x "$CF_BIN" ]]; then
  curl -L -o "$CF_BIN" --retry 2 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CPU"
  chmod +x "$CF_BIN"
fi
"$CF_BIN" version 2>/dev/null | head -n 1

echo "=== 5/7 生成 UUID 和 Reality 密钥 ==="
UUID=$(cat /proc/sys/kernel/random/uuid)
KEYPAIR=$("$SB_BIN" generate reality-keypair)
REALITY_PRIV=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
REALITY_PUB=$(echo "$KEYPAIR" | awk '/PublicKey/{print $2}')
# 2026-10-30 教训：Reality 密钥解析失败时不能继续，否则生成的 VLESS 链接 pbk 为空、节点导不进客户端
[[ -z "$REALITY_PRIV" || -z "$REALITY_PUB" ]] && { echo "错误：Reality 密钥生成/解析失败，退出"; exit 1; }
SHORT_ID=$("$SB_BIN" generate rand --hex 4)
echo "UUID 已生成（不打印），Reality 公钥已生成"

echo "=== 6/7 注册 WARP（只给 google.com 用，失败也不停）==="
WARP_OK=false
WARP_PVK=""
WARP_V6="2606:4700:110:860e:738f:b37:f15:d38d"
WARP_RES="[0, 0, 0]"
WARP_TMP=$(mktemp)
if python3 - "$WARP_TMP" <<'PYEOF'
import subprocess, json, base64, sys, urllib.request, datetime
def run(cmd):
    return subprocess.check_output(cmd, text=True).strip()
try:
    kp = subprocess.check_output(["openssl", "genpkey", "-algorithm", "X25519"], text=True)
    txt = subprocess.check_output(["openssl", "pkey", "-text", "-noout"], input=kp, text=True)
    priv_hex = ""
    pub_hex = ""
    flag = ""
    for line in txt.splitlines():
        if line.strip().startswith("priv:"):
            flag = "priv"
            continue
        if line.strip().startswith("pub:"):
            flag = "pub"
            continue
        if flag == "priv":
            priv_hex += line.strip().replace(":", "").replace(" ", "")
        if flag == "pub":
            pub_hex += line.strip().replace(":", "").replace(" ", "")
    priv = base64.b64encode(bytes.fromhex(priv_hex)).decode()
    pub = base64.b64encode(bytes.fromhex(pub_hex)).decode()
    body = json.dumps({"key": pub, "tos": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.000Z")}).encode()
    req = urllib.request.Request("https://api.cloudflareclient.com/v0a2158/reg", data=body, headers={"CF-Client-Version": "a-7.21-0721", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        d = json.load(r)
    cfg = d.get("config", {})
    iface = cfg.get("interface", {})
    addrs = iface.get("addresses", {})
    v6 = addrs.get("v6", "")
    cid = cfg.get("client_id", "")
    if not v6 or not cid:
        sys.exit(2)
    raw = base64.b64decode(cid)
    res = list(raw[:3])
    out = {"pvk": priv, "v6": v6, "res": res}
    with open(sys.argv[1], "w") as f:
        json.dump(out, f)
except Exception as e:
    sys.exit(1)
PYEOF
then
  WARP_PVK=$(python3 -c "import json; print(json.load(open('$WARP_TMP'))['pvk'])")
  WARP_V6=$(python3 -c "import json; print(json.load(open('$WARP_TMP'))['v6'])")
  WARP_RES=$(python3 -c "import json; print(json.load(open('$WARP_TMP'))['res'])")
  WARP_OK=true
  echo "WARP 注册成功"
else
  echo "WARP 注册失败，google.com 会改走 direct / residential，不停装。装完可重试。"
fi
rm -f "$WARP_TMP"

VPS_IP=$(curl -s4m5 icanhazip.com || curl -s6m5 icanhazip.com)
HOSTNAME_S=$(hostname)

# Acme 真证书（可选）：有自己域名才做，没填就跳过，只用 Reality
TLS_INBOUND_JSON=""
TLS_ROUTE_JSON=""
PORT_TLS=""
if [[ -n "${ACME_DOMAIN:-}" ]]; then
  echo "=== Acme 发证：$ACME_DOMAIN ==="
  PORT_TLS=443
  # 443 被占就随机一个端口
  if ss -tlnp 2>/dev/null | grep -q ":443 "; then PORT_TLS=$(shuf -i 10000-65535 -n 1); fi
  echo "VLESS-TLS 端口：$PORT_TLS"
  if [[ ! -x ~/.acme.sh/acme.sh ]]; then
    curl -s https://get.acme.sh | sh -s email="${ACME_EMAIL:-}" >/dev/null 2>&1 || true
  fi
  # 80 端口要空出来给 standalone 验证，临时放行 80
  if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp >/dev/null 2>&1 || true; else iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true; fi
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  if ~/.acme.sh/acme.sh --issue --standalone -d "$ACME_DOMAIN" --keylength ec-256 >/dev/null 2>&1; then
    ~/.acme.sh/acme.sh --install-cert -d "$ACME_DOMAIN" --ecc --key-file "$SB_DIR/key.pem" --fullchain-file "$SB_DIR/cert.pem" --reloadcmd "systemctl reload sing-box 2>/dev/null || systemctl restart sing-box" >/dev/null 2>&1
    echo "Acme 证书已签好：$SB_DIR/cert.pem"
    TLS_INBOUND_JSON=",
    {
      \"type\": \"vless\",
      \"tag\": \"vless-tls\",
      \"listen\": \"::\",
      \"listen_port\": $PORT_TLS,
      \"users\": [{\"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"$ACME_DOMAIN\",
        \"certificate_path\": \"$SB_DIR/cert.pem\",
        \"key_path\": \"$SB_DIR/key.pem\"
      }
    }"
    TLS_ROUTE_JSON="      {\"inbound\": [\"vless-tls\"], \"outbound\": \"residential\"},"
  else
    echo "Acme 发证失败（可能是 DNS 没指向 VPS、80 端口被占），跳过真证书，只用 Reality，不停装"
    TLS_INBOUND_JSON=""; TLS_ROUTE_JSON=""; PORT_TLS=""
  fi
fi

echo "=== 7/7 写最小配置 ==="
if [[ -f "$SB_JSON" ]]; then
  cp "$SB_JSON" "$SB_JSON.bak.build-$(date +%Y%m%d-%H%M%S)"
  echo "旧配置已备份"
fi

if [[ "$WARP_OK" == "true" ]]; then
  WARP_ENDPOINT_JSON="{
      \"type\": \"wireguard\",
      \"tag\": \"warp-out\",
      \"address\": [\"172.16.0.2/32\", \"$WARP_V6/128\"],
      \"private_key\": \"$WARP_PVK\",
      \"peers\": [{\"address\": \"162.159.192.1\", \"port\": 2408, \"public_key\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\", \"allowed_ips\": [\"0.0.0.0/0\", \"::/0\"], \"reserved\": $WARP_RES}]
    }"
  WARP_RULE_JSON="{\"domain_suffix\": [\"google.com\"], \"outbound\": \"warp-out\"},"
  WARP_RESOLVE_JSON="{\"action\": \"resolve\", \"domain_suffix\": [\"google.com\"], \"strategy\": \"prefer_ipv6\"},"
else
  WARP_ENDPOINT_JSON=""
  WARP_RULE_JSON=""
  WARP_RESOLVE_JSON=""
fi

# 住宅是后续加的：填了才有 residential 出站和 vmess-resi 入站，不填就没有
if [[ -n "${RESI_IP:-}" ]]; then
  RESI_OUTBOUND_JSON="    {\"type\": \"socks\", \"tag\": \"residential\", \"server\": \"$RESI_IP\", \"server_port\": $RESI_PORT, \"username\": \"$RESI_USER\", \"password\": \"$RESI_PASS\", \"version\": \"5\"},"
  RESI_INBOUND_JSON=",
    {
      \"type\": \"vmess\",
      \"tag\": \"vmess-resi\",
      \"listen\": \"::\",
      \"listen_port\": $PORT_RESI,
      \"users\": [{\"uuid\": \"$UUID\", \"alterId\": 0}],
      \"transport\": {\"type\": \"ws\", \"path\": \"$UUID-resi\", \"max_early_data\": 2048, \"early_data_header_name\": \"Sec-WebSocket-Protocol\"},
      \"tls\": {\"enabled\": false, \"server_name\": \"www.bing.com\"}
    }"
  RESI_ROUTE_JSON="      {\"inbound\": [\"vmess-resi\"], \"protocol\": [\"dns\"], \"outbound\": \"direct\"},
      {\"inbound\": [\"vmess-resi\"], \"outbound\": \"residential\"},"
else
  RESI_OUTBOUND_JSON=""
  RESI_INBOUND_JSON=""
  RESI_ROUTE_JSON=""
fi

# 英国住宅：填了才有 residential-uk 出站和 vless-resi-uk 入站
if [[ -n "${UK_IP:-}" ]]; then
  UK_OUTBOUND_JSON="    {\"type\": \"socks\", \"tag\": \"residential-uk\", \"server\": \"$UK_IP\", \"server_port\": $UK_PORT, \"username\": \"$UK_USER\", \"password\": \"$UK_PASS\", \"version\": \"5\"},"
  UK_INBOUND_JSON=",
    {
      \"type\": \"vmess\",
      \"tag\": \"vmess-resi-uk\",
      \"listen\": \"::\",
      \"listen_port\": $PORT_UK,
      \"users\": [{\"uuid\": \"$UUID\", \"alterId\": 0}],
      \"transport\": {\"type\": \"ws\", \"path\": \"$UUID-resi-uk\", \"max_early_data\": 2048, \"early_data_header_name\": \"Sec-WebSocket-Protocol\"},
      \"tls\": {\"enabled\": false, \"server_name\": \"www.bing.com\"}
    }"
  UK_ROUTE_JSON="      {\"inbound\": [\"vmess-resi-uk\"], \"protocol\": [\"dns\"], \"outbound\": \"direct\"},
      {\"inbound\": [\"vmess-resi-uk\"], \"outbound\": \"residential-uk\"},"
else
  UK_OUTBOUND_JSON=""
  UK_INBOUND_JSON=""
  UK_ROUTE_JSON=""
fi

cat > "$SB_JSON" <<EOF
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "tcp", "tag": "dns-remote", "server": "8.8.8.8", "detour": "direct"},
      {"type": "tcp", "tag": "dns-local", "server": "1.1.1.1", "detour": "direct"}
    ],
    "final": "dns-remote"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-sb",
      "listen": "::",
      "listen_port": $PORT_VLESS,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "apple.com", "server_port": 443},
          "private_key": "$REALITY_PRIV",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-sb",
      "listen": "::",
      "listen_port": $PORT_VM,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": {"type": "ws", "path": "$UUID-vm", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"},
      "tls": {"enabled": false, "server_name": "www.bing.com"}
    }$RESI_INBOUND_JSON$UK_INBOUND_JSON$TLS_INBOUND_JSON
  ],
  "endpoints": [$WARP_ENDPOINT_JSON],
  "outbounds": [
    {"type": "direct", "tag": "direct", "domain_resolver": "dns-remote"},
$RESI_OUTBOUND_JSON
$UK_OUTBOUND_JSON
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "default_domain_resolver": "dns-remote",
    "rules": [
      {"action": "sniff"},
      {"protocol": ["dns"], "outbound": "direct"},
      {"protocol": ["stun"], "outbound": "block"},
      $WARP_RESOLVE_JSON
      $WARP_RULE_JSON
$RESI_ROUTE_JSON
$UK_ROUTE_JSON
$TLS_ROUTE_JSON
      {"outbound": "direct", "network": "udp,tcp"}
    ]
  }
}
EOF

# WARP 没注册成功时，endpoints 会是空数组，上面已处理；如果 WARP_ENDPOINT_JSON 为空，需要把空行清掉，jq 会校验
"$SB_BIN" check -c "$SB_JSON" || { echo "配置校验失败，停在写配置这步，没启动"; exit 1; }

cat > /etc/systemd/system/sing-box.service <<'EOF_SVC'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF_SVC

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
systemctl is-active sing-box || { echo "sing-box 没起来，看日志：journalctl -u sing-box -n 50"; exit 1; }

# 只开 VLESS 直连端口，2052/2053 只走 Argo，不对外开
if command -v ufw >/dev/null 2>&1; then
  ufw allow "$PORT_VLESS"/tcp >/dev/null 2>&1 || true
else
  iptables -I INPUT -p tcp --dport "$PORT_VLESS" -j ACCEPT 2>/dev/null || true
fi

echo "起 Argo 临时隧道（VPS 出口那条一定起，住宅那条填了住宅才起）……"
pkill -f "cloudflared tunnel --url http://localhost:$PORT_VM" 2>/dev/null || true
nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_VM" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo.log" 2>&1 &
ARGO_RESI=""
ARGO_UK=""
if [[ -n "${RESI_IP:-}" ]]; then
  pkill -f "cloudflared tunnel --url http://localhost:$PORT_RESI" 2>/dev/null || true
  nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_RESI" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-resi.log" 2>&1 &
fi
if [[ -n "${UK_IP:-}" ]]; then
  pkill -f "cloudflared tunnel --url http://localhost:$PORT_UK" 2>/dev/null || true
  nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_UK" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-uk.log" 2>&1 &
fi
sleep 20
ARGO=$(grep -a trycloudflare.com "$SB_DIR/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
if [[ -n "${RESI_IP:-}" ]]; then
  ARGO_RESI=$(grep -a trycloudflare.com "$SB_DIR/argo-resi.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
fi
if [[ -n "${UK_IP:-}" ]]; then
  ARGO_UK=$(grep -a trycloudflare.com "$SB_DIR/argo-uk.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
fi
echo "Argo（2052）：${ARGO:-没取到，等下看 argo.log}"
if [[ -n "${RESI_IP:-}" ]]; then echo "Argo-resi（2053）：${ARGO_RESI:-没取到，等下看 argo-resi.log}"; fi
if [[ -n "${UK_IP:-}" ]]; then echo "Argo-uk（2054）：${ARGO_UK:-没取到，等下看 argo-uk.log}"; fi

# 开机自启：sing-box 靠 systemd，cloudflared 靠 crontab
(crontab -l 2>/dev/null | grep -v "cloudflared tunnel --url"; echo "@reboot sleep 10 && nohup $CF_BIN tunnel --url http://localhost:$PORT_VM --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo.log 2>&1 &"; if [[ -n "${RESI_IP:-}" ]]; then echo "@reboot sleep 15 && nohup $CF_BIN tunnel --url http://localhost:$PORT_RESI --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo-resi.log 2>&1 &"; fi; if [[ -n "${UK_IP:-}" ]]; then echo "@reboot sleep 20 && nohup $CF_BIN tunnel --url http://localhost:$PORT_UK --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo-uk.log 2>&1 &"; fi) | crontab -

# 装住宅 IP 菜单：resi
cat > /usr/local/bin/resi <<'EOF_RESI'
#!/bin/bash
# resi 菜单：只改 residential 出站
SB_BIN="/etc/s-box/sing-box"
SB_JSON="/etc/s-box/sb.json"
if [[ $EUID -ne 0 ]]; then echo "请用 root 运行"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "缺 jq"; exit 1; fi
show_current() {
  echo "--- 当前住宅出口 ---"
  jq -r '.outbounds[] | select(.tag=="residential") | "IP：\(.server)\n端口：\(.server_port)\n账号：\(.username // "未填")"' "$SB_JSON"
  echo "sing-box：$(systemctl is-active sing-box 2>/dev/null)"
}
change_resi() {
  show_current
  read -p "新 IP： " nip
  read -p "新端口： " nport
  read -p "新账号： " nuser
  read -s -p "新密码（不显示）： " npass; echo ""
  if [[ -z "$nip" && -z "$nport" && -z "$nuser" && -z "$npass" ]]; then echo "没填，没改"; return; fi
  bak="/etc/s-box/sb.json.bak.resi-$(date +%Y%m%d-%H%M%S)"
  cp "$SB_JSON" "$bak"; echo "已备份：$bak"
  jq --arg ip "$nip" --arg port "$nport" --arg user "$nuser" --arg pass "$npass" '.outbounds |= map(if .tag == "residential" then (if $ip != "" then .server = $ip else . end) | (if $port != "" then .server_port = ($port | tonumber) else . end) | (if $user != "" then .username = $user else . end) | (if $pass != "" then .password = $pass else . end) else . end)' "$SB_JSON" > /tmp/sb.json.new
  if ! "$SB_BIN" check -c /tmp/sb.json.new >/dev/null 2>&1; then echo "校验失败，已恢复"; cp "$bak" "$SB_JSON"; rm -f /tmp/sb.json.new; return; fi
  mv /tmp/sb.json.new "$SB_JSON"
  systemctl restart sing-box; sleep 2; echo "已重启：$(systemctl is-active sing-box 2>/dev/null)"; show_current
}
while true; do
  echo ""; echo "=== 住宅 IP 菜单 ==="; echo "1. 查看当前住宅出口"; echo "2. 更换住宅 IP"; echo "0. 退出"
  read -p "选： " m
  case "$m" in
    1) show_current ;;
    2) change_resi ;;
    0) exit 0 ;;
    *) echo "输入不对" ;;
  esac
done
EOF_RESI
chmod +x /usr/local/bin/resi
echo "住宅 IP 菜单已装好，以后在 VPS 上打 resi 就能换 IP"

# 装后续加住宅：add-resi（base 只有 VPS 直连时用，填住宅信息就加 vm-resi 节点）
cat > /usr/local/bin/add-resi <<'EOF_ADDRESI'
#!/bin/bash
# add-resi：后续加住宅 IP - 加 residential 出站 + vmess-resi 入口 + Argo 隧道 + 链接
# 用法：add-resi，按提示填住宅 IP/端口/账号/密码；VLESS 想走住宅的话，加完再单独选
SB_DIR="/etc/s-box"
SB_BIN="$SB_DIR/sing-box"
SB_JSON="$SB_DIR/sb.json"
CF_BIN="$SB_DIR/cloudflared"
META="$SB_DIR/meta.json"
if [[ $EUID -ne 0 ]]; then echo "请用 root 运行"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "缺 jq"; exit 1; fi
if jq -e '.outbounds[] | select(.tag=="residential")' "$SB_JSON" >/dev/null 2>&1; then echo "住宅已经加过了，要换 IP 打 resi，不要重复加"; exit 0; fi
read -p "住宅 IP： " RESI_IP
read -p "住宅端口： " RESI_PORT
read -p "住宅账号： " RESI_USER
read -s -p "住宅密码（不显示）： " RESI_PASS; echo ""
if [[ -z "$RESI_IP" || -z "$RESI_PORT" || -z "$RESI_USER" || -z "$RESI_PASS" ]]; then echo "没填全，没加"; exit 1; fi
read -p "VMess-resi 端口（回车默认 2053）： " PORT_RESI
PORT_RESI=${PORT_RESI:-2053}
UUID=$(jq -r '.inbounds[] | select(.tag=="vmess-sb") | .users[0].uuid' "$SB_JSON" 2>/dev/null)
if [[ -z "$UUID" || "$UUID" == "null" ]]; then echo "UUID 读不到，没加"; exit 1; fi
FRONT_DOMAIN=$(jq -r '.front_domain' "$META" 2>/dev/null)
[[ -z "$FRONT_DOMAIN" || "$FRONT_DOMAIN" == "null" ]] && FRONT_DOMAIN="cloudflare-ech.com"
VM_ADD=$(jq -r '.vm_add' "$META" 2>/dev/null)
[[ -z "$VM_ADD" || "$VM_ADD" == "null" ]] && VM_ADD="$FRONT_DOMAIN"
HOSTNAME_S=$(jq -r '.hostname' "$META" 2>/dev/null)
[[ -z "$HOSTNAME_S" || "$HOSTNAME_S" == "null" ]] && HOSTNAME_S=$(hostname)
bak="$SB_DIR/sb.json.bak.addresi-$(date +%Y%m%d-%H%M%S)"
PS_RESI=$(jq -r '.ps_resi' "$META" 2>/dev/null)
if [[ -z "$PS_RESI" || "$PS_RESI" == "null" ]]; then
  # 没存过就按住宅 IP 归属地现查
  RESI_COUNTRY=$(curl -s -m 5 "http://ip-api.com/json/$RESI_IP?fields=countryCode" 2>/dev/null | grep -oP '"countryCode":"\K[A-Z]{2}' || true)
  case "$RESI_COUNTRY" in US) PS_RESI="移动ARGO美国住宅" ;; GB|UK) PS_RESI="移动ARGO英国住宅" ;; JP) PS_RESI="移动ARGO日本住宅" ;; *) PS_RESI="移动ARGO住宅" ;; esac
fi
cp "$SB_JSON" "$bak"; echo "已备份：$bak"
jq --arg ip "$RESI_IP" --argjson port "$RESI_PORT" --arg user "$RESI_USER" --arg pass "$RESI_PASS" --argjson rport "$PORT_RESI" --arg uuid "$UUID" '
  .outbounds += [{"type":"socks","tag":"residential","server":$ip,"server_port":$port,"username":$user,"password":$pass,"version":"5"}]
  | .inbounds += [{"type":"vmess","tag":"vmess-resi","listen":"::","listen_port":$rport,"users":[{"uuid":$uuid,"alterId":0}],"transport":{"type":"ws","path":($uuid+"-resi"),"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"},"tls":{"enabled":false,"server_name":"www.bing.com"}}]
  | .route.rules |= [{"inbound":["vmess-resi"],"protocol":["dns"],"outbound":"direct"},{"inbound":["vmess-resi"],"outbound":"residential"}] + .
' "$SB_JSON" > /tmp/sb.json.new
if ! "$SB_BIN" check -c /tmp/sb.json.new >/dev/null 2>&1; then echo "校验失败，已恢复"; cp "$bak" "$SB_JSON"; rm -f /tmp/sb.json.new; exit 1; fi
mv /tmp/sb.json.new "$SB_JSON"
systemctl restart sing-box; sleep 2
echo "sing-box：$(systemctl is-active sing-box 2>/dev/null)"
nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_RESI" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-resi.log" 2>&1 &
sleep 15
ARGO_RESI=$(grep -a trycloudflare.com "$SB_DIR/argo-resi.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
if [[ -z "$ARGO_RESI" ]]; then echo "Argo-resi 域名没取到，看 $SB_DIR/argo-resi.log"; exit 1; fi
VM_RESI_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_RESI','id':'$UUID','net':'ws','path':'$UUID-resi','port':'443','ps':'$PS_RESI','tls':'tls','sni':'$ARGO_RESI','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
echo "$VM_RESI_JSON" > "$SB_DIR/vm_ws_argoresi.txt"
echo "【VMess-resi-Argo，移动 + 银行住宅出口】"
echo "$VM_RESI_JSON"
{
  grep -v "^Argo-resi 2053:" "$SB_DIR/nodes.txt" 2>/dev/null
  echo "VMess-resi: $VM_RESI_JSON"
  echo "Argo-resi 2053: $ARGO_RESI"
} > /tmp/nodes.txt.new && mv /tmp/nodes.txt.new "$SB_DIR/nodes.txt"
SUB_NAME_M=$(python3 -c "import json; print(json.load(open('$META')).get('sub_name') or 'sub')" 2>/dev/null || echo sub)
{
  cat "$SB_DIR/$SUB_NAME_M.txt" 2>/dev/null | grep -v '^$'
  echo "$VM_RESI_JSON"
} | grep -v '^$' > /tmp/sub.txt.new && mv /tmp/sub.txt.new "$SB_DIR/$SUB_NAME_M.txt"
base64 -w0 "$SB_DIR/$SUB_NAME_M.txt" > "$SB_DIR/$SUB_NAME_M.b64"
jq '.has_resi = "true"' "$META" > /tmp/meta.json.new && mv /tmp/meta.json.new "$META"
(crontab -l 2>/dev/null | grep -v "argo-resi.log"; echo "@reboot sleep 15 && nohup $CF_BIN tunnel --url http://localhost:$PORT_RESI --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo-resi.log 2>&1 &") | crontab -
echo "住宅已加上，客户端更新订阅就能看到 vm-resi，不用手动一个一个改"
EOF_ADDRESI
chmod +x /usr/local/bin/add-resi
echo "后续加住宅已装好：以后在 VPS 上打 add-resi，按提示填住宅信息"

# 装自动维护：sb-maintain（每天 03:00 + 重启后自动跑，也可手动跑）
cat > /usr/local/bin/sb-maintain <<'EOF_MAINTAIN'
#!/bin/bash
# sb-maintain：自动维护 - 健康检查 + 版本更新 + Argo 域名变化重生成链接 + 备份
# 不打印密码，不改住宅 IP，不改端口，只做：备份、重启挂掉的服务、更新 sing-box/cloudflared、重生成链接
SB_DIR="/etc/s-box"
SB_BIN="$SB_DIR/sing-box"
SB_JSON="$SB_DIR/sb.json"
CF_BIN="$SB_DIR/cloudflared"
LOG="/var/log/sb-maintain.log"
META="$SB_DIR/meta.json"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
if [[ $EUID -ne 0 ]]; then echo "请用 root 运行"; exit 1; fi
touch "$LOG" 2>/dev/null || true
log "=== 自动维护开始 ==="
case "$(uname -m)" in
  x86_64) CPU="amd64" ;;
  aarch64) CPU="arm64" ;;
  *) log "不支持的架构：$(uname -m)"; exit 1 ;;
esac
# 1. 备份配置，留最近 7 份
if [[ -f "$SB_JSON" ]]; then
  cp "$SB_JSON" "$SB_DIR/sb.json.bak.maintain-$(date +%Y%m%d-%H%M%S)"
  ls -t "$SB_DIR"/sb.json.bak.maintain-* 2>/dev/null | tail -n +8 | xargs -r rm -f
  log "配置已备份"
fi
# 2. sing-box 健康检查，挂了就重启
if ! systemctl is-active --quiet sing-box 2>/dev/null; then
  log "sing-box 没在跑，尝试重启"
  systemctl restart sing-box; sleep 2
  log "sing-box 重启后：$(systemctl is-active sing-box 2>/dev/null)"
else
  log "sing-box 正常"
fi
# 3. cloudflared 健康检查，挂了就重启（端口从配置里读，英国隧道也管）
PORT_VM=$(jq -r '.inbounds[] | select(.tag=="vmess-sb") | .listen_port' "$SB_JSON" 2>/dev/null)
PORT_RESI=$(jq -r '.inbounds[] | select(.tag=="vmess-resi") | .listen_port' "$SB_JSON" 2>/dev/null)
PORT_UK=$(jq -r '.inbounds[] | select(.tag=="vmess-resi-uk") | .listen_port' "$SB_JSON" 2>/dev/null)
for PORT in "$PORT_VM" "$PORT_RESI" "$PORT_UK"; do
  [[ -z "$PORT" || "$PORT" == "null" ]] && continue
  case "$PORT" in
    "$PORT_VM") TUN_LOG="$SB_DIR/argo.log" ;;
    "$PORT_RESI") TUN_LOG="$SB_DIR/argo-resi.log" ;;
    *) TUN_LOG="$SB_DIR/argo-uk.log" ;;
  esac
  if pgrep -f "cloudflared tunnel --url http://localhost:$PORT" >/dev/null 2>&1; then
    log "cloudflared $PORT 正常"
  else
    log "cloudflared $PORT 没在跑，尝试重起"
    nohup "$CF_BIN" tunnel --url "http://localhost:$PORT" --edge-ip-version auto --no-autoupdate --protocol http2 > "$TUN_LOG" 2>&1 &
    sleep 15
    log "cloudflared $PORT 重起后：$(pgrep -f "cloudflared tunnel --url http://localhost:$PORT" >/dev/null && echo 运行中 || echo 仍没起来)"
  fi
done
# 3.5 订阅托管没在跑就重起（http 服务 + 订阅隧道）
if ! pgrep -f "http.server 8000" >/dev/null 2>&1; then
  nohup python3 -m http.server 8000 --directory "$SB_DIR" > "$SB_DIR/sub-http.log" 2>&1 &
  echo "$(date '+%F %T') http 服务重起" >> "$LOG"
fi
if ! pgrep -f "cloudflared tunnel --url http://localhost:8000" >/dev/null 2>&1; then
  nohup "$CF_BIN" tunnel --url "http://localhost:8000" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-sub.log" 2>&1 &
  sleep 15
  SUB_NEW=$(grep -a trycloudflare.com "$SB_DIR/argo-sub.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
  if [[ -n "$SUB_NEW" ]]; then
    SUB_NAME_M=$(python3 -c "import json; print(json.load(open('$SB_DIR/meta.json')).get('sub_name') or 'sub')" 2>/dev/null || echo sub)
    echo "https://$SUB_NEW/$SUB_NAME_M.b64" > "$SB_DIR/sub-url.txt"
    echo "$(date '+%F %T') 订阅隧道重起，新域名：$SUB_NEW" >> "$LOG"
  fi
fi
# 4. Argo 域名变了就重生成链接（只换 host/sni，UUID、端口、前置域名都不变；英国节点也一起处理）
sleep 2
ARGO_NEW=$(grep -a trycloudflare.com "$SB_DIR/argo.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
ARGO_RESI_NEW=$(grep -a trycloudflare.com "$SB_DIR/argo-resi.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
ARGO_UK_NEW=$(grep -a trycloudflare.com "$SB_DIR/argo-uk.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
ARGO_OLD=$(grep "^Argo 2052:" "$SB_DIR/nodes.txt" 2>/dev/null | awk '{print $3}')
ARGO_RESI_OLD=$(grep "^Argo-resi 2053:" "$SB_DIR/nodes.txt" 2>/dev/null | awk '{print $3}')
ARGO_UK_OLD=$(grep "^Argo-uk 2054:" "$SB_DIR/nodes.txt" 2>/dev/null | awk '{print $3}')
HAS_UK=$(jq -r '.inbounds[] | select(.tag=="vmess-resi-uk") | .tag' "$SB_JSON" 2>/dev/null)
NEED_REGEN=0
[[ -n "$ARGO_NEW" && "$ARGO_NEW" != "$ARGO_OLD" ]] && NEED_REGEN=1
[[ -n "$ARGO_RESI_NEW" && "$ARGO_RESI_NEW" != "$ARGO_RESI_OLD" ]] && NEED_REGEN=1
[[ -n "$HAS_UK" && -n "$ARGO_UK_NEW" && "$ARGO_UK_NEW" != "$ARGO_UK_OLD" ]] && NEED_REGEN=1
if [[ "$NEED_REGEN" == "1" ]]; then
  if [[ -z "$ARGO_NEW" || -z "$ARGO_RESI_NEW" ]]; then
    log "Argo 域名没取到，不重生成链接"
  else
    log "Argo 域名变了，重新生成链接：$ARGO_OLD -> $ARGO_NEW，$ARGO_RESI_OLD -> $ARGO_RESI_NEW"
    UUID=$(jq -r '.inbounds[1].users[0].uuid' "$SB_JSON" 2>/dev/null)
    FRONT_DOMAIN=$(jq -r '.front_domain' "$META" 2>/dev/null)
    [[ -z "$FRONT_DOMAIN" || "$FRONT_DOMAIN" == "null" ]] && FRONT_DOMAIN="cloudflare-ech.com"
    VM_ADD=$(jq -r '.vm_add' "$META" 2>/dev/null)
    [[ -z "$VM_ADD" || "$VM_ADD" == "null" ]] && VM_ADD="$FRONT_DOMAIN"
    PS_RESI=$(jq -r '.ps_resi' "$META" 2>/dev/null)
    [[ -z "$PS_RESI" || "$PS_RESI" == "null" ]] && PS_RESI="移动ARGO住宅"
    PS_UK=$(jq -r '.ps_uk' "$META" 2>/dev/null)
    [[ -z "$PS_UK" || "$PS_UK" == "null" ]] && PS_UK="移动ARGO住宅"
    if [[ -n "$UUID" && "$UUID" != "null" ]]; then
      VM_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_NEW','id':'$UUID','net':'ws','path':'$UUID-vm','port':'443','ps':'移动ARGO','tls':'tls','sni':'$ARGO_NEW','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
      VM_RESI_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_RESI_NEW','id':'$UUID','net':'ws','path':'$UUID-resi','port':'443','ps':'$PS_RESI','tls':'tls','sni':'$ARGO_RESI_NEW','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
      echo "$VM_JSON" > "$SB_DIR/vm_ws_argols.txt"
      echo "$VM_RESI_JSON" > "$SB_DIR/vm_ws_argoresi.txt"
      VM_UK_JSON=""
      if [[ -n "$HAS_UK" ]]; then
        if [[ -n "$ARGO_UK_NEW" ]]; then
          VM_UK_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_UK_NEW','id':'$UUID','net':'ws','path':'$UUID-resi-uk','port':'443','ps':'$PS_UK','tls':'tls','sni':'$ARGO_UK_NEW','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
          echo "$VM_UK_JSON" > "$SB_DIR/vm_ws_argouk.txt"
        else
          VM_UK_JSON=$(grep "^VMess-UK:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-)
          [[ -n "$VM_UK_JSON" ]] && log "英国 Argo 域名没取到，沿用旧链接"
        fi
      fi
      VLESS_LINK=$(grep "^VLESS:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-)
      {
        echo "VLESS: $VLESS_LINK"
        echo "VMess-Argo: $VM_JSON"
        echo "VMess-resi: $VM_RESI_JSON"
        [[ -n "$VM_UK_JSON" ]] && echo "VMess-UK: $VM_UK_JSON"
        echo "Argo 2052: $ARGO_NEW"
        echo "Argo-resi 2053: $ARGO_RESI_NEW"
        if [[ -n "$VM_UK_JSON" ]]; then
          if [[ -n "$ARGO_UK_NEW" ]]; then echo "Argo-uk 2054: $ARGO_UK_NEW"; else echo "Argo-uk 2054: $ARGO_UK_OLD"; fi
        fi
      } > "$SB_DIR/nodes.txt"
      # 订阅文件也跟着重生成
      SUB_NAME_M=$(python3 -c "import json; print(json.load(open('$SB_DIR/meta.json')).get('sub_name') or 'sub')" 2>/dev/null || echo sub)
      {
        grep "^VLESS:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-
        echo "$VM_JSON"
        echo "$VM_RESI_JSON"
        [[ -n "$VM_UK_JSON" ]] && echo "$VM_UK_JSON"
        grep "^VLESS-TLS:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-
      } | grep -v '^$' > "$SB_DIR/$SUB_NAME_M.txt"
      base64 -w0 "$SB_DIR/$SUB_NAME_M.txt" > "$SB_DIR/$SUB_NAME_M.b64" 2>/dev/null || true
      log "链接已重生成，见 $SB_DIR/nodes.txt，订阅文件已同步，客户端重新导入订阅或链接即可"
    else
      log "UUID 读不到，没重生成链接"
    fi
  fi
else
  log "Argo 域名没变，不用重生成链接"
fi
# 4.5 推送订阅到 GitHub Gist（内容变了才推；没配 token/gist id 就跳过）
GIST_TOKEN_F="/etc/s-box/gist-token"
GIST_ID_F="/etc/s-box/gist-id"
GIST_HASH_F="/etc/s-box/sub.b64.sha256"
if [[ -f "$GIST_TOKEN_F" && -f "$GIST_ID_F" && -f "$SB_DIR/sub.b64" ]]; then
  GIST_TOKEN=$(cat "$GIST_TOKEN_F")
  GIST_ID=$(cat "$GIST_ID_F")
  CUR_HASH=$(sha256sum "$SB_DIR/sub.b64" | awk '{print $1}')
  OLD_HASH=$(cat "$GIST_HASH_F" 2>/dev/null || echo "")
  if [[ "$CUR_HASH" != "$OLD_HASH" ]]; then
    SUB_NAME_M=$(python3 -c "import json; print(json.load(open('$SB_DIR/meta.json')).get('sub_name') or 'sub')" 2>/dev/null || echo sub)
    PUSH_JSON=$(python3 -c "import json; print(json.dumps({'files': {'$SUB_NAME_M.b64': {'content': open('$SB_DIR/$SUB_NAME_M.b64').read()}}}))")
    HTTP_CODE=$(curl -s -o /tmp/gist-push.json -w "%{http_code}" -X PATCH -H "Authorization: Bearer $GIST_TOKEN" -H "Accept: application/vnd.github+json" --data "$PUSH_JSON" "https://api.github.com/gists/$GIST_ID")
    if [[ "$HTTP_CODE" == "200" ]]; then
      echo "$CUR_HASH" > "$GIST_HASH_F"
      log "订阅已推送到 Gist（$SUB_NAME_M.b64）"
    else
      log "Gist 推送失败，HTTP $HTTP_CODE，见 /tmp/gist-push.json"
    fi
  else
    log "订阅内容没变，不用推 Gist"
  fi
else
  log "Gist 未配置（缺 token 或 gist id），跳过推送"
fi
# 5. 更新 sing-box（有新版才更新，校验失败就回滚）
SB_CUR=$("$SB_BIN" version 2>/dev/null | head -n 1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
SB_LATEST=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
if [[ -n "$SB_LATEST" && -n "$SB_CUR" && "$SB_LATEST" != "$SB_CUR" ]]; then
  log "sing-box 有新版：$SB_CUR -> $SB_LATEST，开始更新"
  cp "$SB_BIN" "$SB_BIN.bak.$SB_CUR"
  SB_NAME="sing-box-$SB_LATEST-linux-$CPU"
  if curl -L -o /tmp/sing-box-maintain.tar.gz --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$SB_LATEST/$SB_NAME.tar.gz" 2>/dev/null; then
    tar xzf /tmp/sing-box-maintain.tar.gz -C /tmp
    systemctl stop sing-box 2>/dev/null || true
    cp "/tmp/$SB_NAME/sing-box" "$SB_BIN"; chmod +x "$SB_BIN"
    if "$SB_BIN" check -c "$SB_JSON" >/dev/null 2>&1; then
      systemctl restart sing-box; sleep 2
      log "sing-box 已更新到 $SB_LATEST，状态：$(systemctl is-active sing-box 2>/dev/null)"
    else
      log "新版校验失败，回滚到 $SB_CUR"
      cp "$SB_BIN.bak.$SB_CUR" "$SB_BIN"; systemctl restart sing-box
    fi
    rm -f /tmp/sing-box-maintain.tar.gz
  else
    log "sing-box 下载失败，这次不更新"
  fi
else
  log "sing-box 已是最新（$SB_CUR）或取不到新版，不更新"
fi
# 6. 更新 cloudflared（有新版才更新，更新后重起隧道）
CF_CUR=$("$CF_BIN" version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
CF_LATEST=$(curl -Ls https://github.com/cloudflare/cloudflared/releases/latest 2>/dev/null | grep -oP 'tag/\K[0-9.]+' | head -n 1)
if [[ -n "$CF_LATEST" && -n "$CF_CUR" && "$CF_LATEST" != "$CF_CUR" ]]; then
  log "cloudflared 有新版：$CF_CUR -> $CF_LATEST，开始更新"
  cp "$CF_BIN" "$CF_BIN.bak.$CF_CUR"
  if curl -L -o "$CF_BIN.new" --retry 2 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CPU" 2>/dev/null; then
    chmod +x "$CF_BIN.new"
    pkill -f "cloudflared tunnel --url" 2>/dev/null || true; sleep 2
    mv "$CF_BIN.new" "$CF_BIN"
    nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_VM" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo.log" 2>&1 &
    nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_RESI" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-resi.log" 2>&1 &
    if [[ -n "$PORT_UK" && "$PORT_UK" != "null" ]]; then
      nohup "$CF_BIN" tunnel --url "http://localhost:$PORT_UK" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-uk.log" 2>&1 &
    fi
    sleep 15
    log "cloudflared 已更新到 $CF_LATEST，隧道已重起，域名可能变了，下次维护会重生成链接"
  else
    log "cloudflared 下载失败，这次不更新"
  fi
else
  log "cloudflared 已是最新（$CF_CUR）或取不到新版，不更新"
fi
# 7. BBR 检查，重启后确认还在
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
  CUR_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$CUR_BBR" != "bbr" ]]; then
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    log "BBR 掉了，已重新开启：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  else
    log "BBR 正常"
  fi
fi
log "=== 自动维护结束 ==="
EOF_MAINTAIN
chmod +x /usr/local/bin/sb-maintain
# 自动维护定时：每天 03:00 跑一次，重启后 30 秒跑一次（Argo 换域名自动重生成链接）
(crontab -l 2>/dev/null | grep -v "sb-maintain"; echo "0 3 * * * /usr/local/bin/sb-maintain >> /var/log/sb-maintain.log 2>&1"; echo "@reboot sleep 30 && /usr/local/bin/sb-maintain >> /var/log/sb-maintain.log 2>&1") | crontab -
echo "自动维护已装好：每天 03:00 自动检查更新 + 健康 + 备份，重启后自动重生成链接，日志在 /var/log/sb-maintain.log，手动跑打 sb-maintain"

# 脚本自更新：仓库里的 build-minimal.sh 更新了，VPS 自动拉新版，只更新工具，不动配置
cat > /usr/local/bin/sb-update <<'EOF_UPDATE'
#!/bin/bash
# sb-update —— 从 GitHub 仓库拉取最新 build-minimal.sh，只更新工具脚本，不动配置
# 用法：sb-update（手动跑）或每天 03:30 自动跑（cron）
# 只更新 /usr/local/bin 下的工具：sb-maintain、resi、add-resi、cdn-test、cdn-change、sb-update 自身
# 不动：/etc/s-box/sb.json、meta.json、public.key、私钥、gist-token、gist-id、节点信息、订阅文件
# 防自更新冲突：先把自己拷到 /tmp 再执行，/usr/local/bin/sb-update 才能被安全替换
if [[ "${SB_UPDATE_RUN:-}" != "1" ]]; then
  export SB_UPDATE_RUN=1
  cp "$0" /tmp/sb-update.run 2>/dev/null && exec bash /tmp/sb-update.run "$@"
fi
SB_DIR=/etc/s-box
BIN_DIR=/usr/local/bin
LOG=/var/log/sb-update.log
REPO_RAW="https://raw.githubusercontent.com/PLA73211/RackNerd-OneKey-Script/main/build-minimal.sh"
VER_FILE="$SB_DIR/script-version"
TMP_SCRIPT=/tmp/build-minimal.sh.new
log(){ echo "$(date '+%F %T') $*"; }
log "=== sb-update 开始 ==="
if ! curl -fsSL --retry 2 "$REPO_RAW" -o "$TMP_SCRIPT" 2>/dev/null; then
  log "下载仓库脚本失败，这次不更新"
  exit 0
fi
if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
  log "仓库脚本语法检查没过，这次不更新"
  rm -f "$TMP_SCRIPT"
  exit 0
fi
NEW_VER=$(grep -m1 '^VERSION=' "$TMP_SCRIPT" 2>/dev/null | cut -d'"' -f2)
CUR_VER=$(cat "$VER_FILE" 2>/dev/null || echo "")
if [[ -z "$NEW_VER" ]]; then
  log "仓库脚本里没读到版本号，这次不更新"
  rm -f "$TMP_SCRIPT"
  exit 0
fi
if [[ "$NEW_VER" == "$CUR_VER" ]]; then
  log "已是最新版（$CUR_VER），不用更新"
  rm -f "$TMP_SCRIPT"
  exit 0
fi
log "有新版：${CUR_VER:-无} -> $NEW_VER，开始更新工具"
python3 - "$TMP_SCRIPT" "$BIN_DIR" <<'PYEOF'
import sys, os
src, bindir = sys.argv[1], sys.argv[2]
tools = {
  'EOF_RESI': 'resi',
  'EOF_ADDRESI': 'add-resi',
  'EOF_MAINTAIN': 'sb-maintain',
  'EOF_CDN': 'cdn-test',
  'EOF_CDNCHANGE': 'cdn-change',
  'EOF_UPDATE': 'sb-update',
}
lines = open(src, encoding='utf-8').read().splitlines()
out = {}
cur = None
for line in lines:
  if cur is None:
    for marker in tools:
      if line.startswith('cat > ') and ("<<'%s'" % marker) in line:
        cur = marker
        out[cur] = []
        break
  else:
    if line == cur:
      cur = None
    else:
      out[cur].append(line)
for marker, name in tools.items():
  if marker in out and out[marker]:
    p = os.path.join(bindir, name)
    if os.path.exists(p):
      os.replace(p, p + '.bak')
    with open(p, 'w', encoding='utf-8') as f:
      f.write('\n'.join(out[marker]) + '\n')
    os.chmod(p, 0o755)
    print('已更新 %s（%d 行）' % (name, len(out[marker])))
  else:
    print('没找到 %s，保持旧版' % name)
PYEOF
OK=1
for t in resi add-resi sb-maintain cdn-test cdn-change sb-update; do
  if ! bash -n "$BIN_DIR/$t" 2>/dev/null; then
    log "$t 语法检查没过，回滚"
    if [[ -f "$BIN_DIR/$t.bak" ]]; then mv -f "$BIN_DIR/$t.bak" "$BIN_DIR/$t"; else rm -f "$BIN_DIR/$t"; fi
    OK=0
  fi
done
if [[ "$OK" == "1" ]]; then
  echo "$NEW_VER" > "$VER_FILE"
  rm -f "$BIN_DIR/resi.bak" "$BIN_DIR/add-resi.bak" "$BIN_DIR/sb-maintain.bak" "$BIN_DIR/cdn-test.bak" "$BIN_DIR/cdn-change.bak" "$BIN_DIR/sb-update.bak"
  log "工具已更新到 $NEW_VER，配置没动；sb-update 自身下次运行用新版"
else
  log "有工具更新失败，已回滚，版本号保持 ${CUR_VER:-无}"
fi
rm -f "$TMP_SCRIPT"
log "=== sb-update 结束 ==="
EOF_UPDATE
chmod +x /usr/local/bin/sb-update
# 记下当前脚本版本，sb-update 靠它判断有没有新版
echo "$VERSION" > "$SB_DIR/script-version"
# 自更新定时：每天 03:30 检查仓库，有新版就自动更新工具（不动配置）
(crontab -l 2>/dev/null | grep -v "sb-update"; echo "30 3 * * * /usr/local/bin/sb-update >> /var/log/sb-update.log 2>&1") | crontab -
echo "脚本自更新已装好：每天 03:30 自动检查仓库，有新版就更新工具（不动配置），日志在 /var/log/sb-update.log，手动跑打 sb-update"

# CDN 优选生效：填了 IP 就用 IP 当 add，否则用前置域名
VM_ADD=${CDN_IP:-$FRONT_DOMAIN}
# 住宅节点名动态生成：前置是 Argo（移动）+ 住宅 IP 归属地
if [[ -n "${RESI_IP:-}" ]]; then
  RESI_COUNTRY=$(country_cn "$RESI_IP")
  [[ -z "$RESI_COUNTRY" ]] && RESI_COUNTRY="住宅"
  PS_RESI="移动ARGO${RESI_COUNTRY}住宅"
else
  PS_RESI="移动ARGO住宅"
fi
if [[ -n "${UK_IP:-}" ]]; then
  UK_COUNTRY=$(country_cn "$UK_IP")
  [[ -z "$UK_COUNTRY" ]] && UK_COUNTRY=""
  PS_UK="移动ARGO${UK_COUNTRY}住宅"
else
  PS_UK="移动ARGO住宅"
fi
echo "=== 生成节点链接 ==="
echo "$REALITY_PUB" > "$SB_DIR/public.key"
VLESS_LINK="vless://$UUID@$VPS_IP:$PORT_VLESS?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID&type=tcp&headerType=none#%E7%94%B5%E4%BF%A1%2F%E8%81%94%E9%80%9AVLESS"
# 2026-10-30 教训：链接写盘前必须验 pbk 非空，否则节点导不进客户端
[[ "$VLESS_LINK" == *"pbk=&"* ]] && { echo "错误：VLESS 链接 pbk 为空，退出"; exit 1; }
echo "$VLESS_LINK" > "$SB_DIR/vl_direct.txt"
echo "【VLESS-Reality 直连 → VPS直连，电信处用】"
echo "$VLESS_LINK"
echo ""
if [[ -n "$ARGO" ]]; then
  VM_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO','id':'$UUID','net':'ws','path':'$UUID-vm','port':'443','ps':'移动ARGO','tls':'tls','sni':'$ARGO','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
  echo "$VM_JSON" > "$SB_DIR/vm_ws_argols.txt"
  echo "【VMess-Argo，移动用】"
  echo "$VM_JSON"
  echo ""
fi
if [[ -n "${RESI_IP:-}" && -n "$ARGO_RESI" ]]; then
  VM_RESI_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_RESI','id':'$UUID','net':'ws','path':'$UUID-resi','port':'443','ps':'$PS_RESI','tls':'tls','sni':'$ARGO_RESI','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
  echo "$VM_RESI_JSON" > "$SB_DIR/vm_ws_argoresi.txt"
  echo "【VMess-resi-Argo，移动 + 银行住宅出口】"
  echo "$VM_RESI_JSON"
  echo ""
fi
if [[ -n "${UK_IP:-}" && -n "$ARGO_UK" ]]; then
  VM_UK_JSON=$(python3 -c "import json,base64; d={'add':'$VM_ADD','aid':'0','host':'$ARGO_UK','id':'$UUID','net':'ws','path':'$UUID-resi-uk','port':'443','ps':'$PS_UK','tls':'tls','sni':'$ARGO_UK','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
  echo "$VM_UK_JSON" > "$SB_DIR/vm_ws_argouk.txt"
  echo "【VMess-Argo 英国住宅，移动用】"
  echo "$VM_UK_JSON"
  echo ""
fi
if [[ -n "${ACME_DOMAIN:-}" && -n "$PORT_TLS" && -f "$SB_DIR/cert.pem" ]]; then
  VLESS_TLS_LINK="vless://$UUID@$VPS_IP:$PORT_TLS?encryption=none&flow=xtls-rprx-vision&security=tls&sni=$ACME_DOMAIN&fp=chrome&type=tcp&headerType=none#vl-tls-$HOSTNAME_S"
  echo "$VLESS_TLS_LINK" > "$SB_DIR/vl_tls.txt"
  echo "【VLESS-TLS 真证书 → 住宅，电信处用】"
  echo "$VLESS_TLS_LINK"
  echo ""
fi
if command -v qrencode >/dev/null 2>&1; then
  echo "二维码：用小火箭扫下面链接的二维码，或直接粘贴链接导入"
  qrencode -o - -t ANSIUTF8 "$(cat "$SB_DIR/vl_direct.txt")" 2>/dev/null || true
fi
{
  echo "VLESS: $VLESS_LINK"
  echo "VMess-Argo: ${VM_JSON:-}"
  [[ -n "${VM_RESI_JSON:-}" ]] && echo "VMess-resi: $VM_RESI_JSON"
  [[ -n "${VM_UK_JSON:-}" ]] && echo "VMess-UK: $VM_UK_JSON"
  [[ -n "${VLESS_TLS_LINK:-}" ]] && echo "VLESS-TLS: $VLESS_TLS_LINK"
  echo "Argo 2052: ${ARGO:-}"
  [[ -n "${ARGO_RESI:-}" ]] && echo "Argo-resi 2053: $ARGO_RESI"
  [[ -n "${ARGO_UK:-}" ]] && echo "Argo-uk 2054: $ARGO_UK"
} > "$SB_DIR/nodes.txt"

# 保存元信息，供自动维护脚本读（不含密码、UUID、密钥）
cat > "$SB_DIR/meta.json" <<EOF_META
{
  "front_domain": "$FRONT_DOMAIN",
  "sub_name": "${SUB_NAME:-sub}",
  "ps_resi": "$PS_RESI",
  "ps_uk": "$PS_UK",
  "has_resi": "$([[ -n "${RESI_IP:-}" ]] && echo true || echo false)",
  "acme_domain": "${ACME_DOMAIN:-}",
  "port_tls": "${PORT_TLS:-0}",
  "cdn_ip": "${CDN_IP:-}",
  "vm_add": "$VM_ADD",
  "port_vless": $PORT_VLESS,
  "port_vm": $PORT_VM,
  "port_resi": $PORT_RESI,
  "port_uk": $PORT_UK,
  "vps_ip": "$VPS_IP",
  "hostname": "$HOSTNAME_S"
}
EOF_META

# 订阅文件名固定为 sub，不再自定义。
# 注意：这只是服务端订阅文件的文件名，不决定客户端里显示的分组名；
# 小火箭里分组名是添加订阅时填的 Alias（别名），不填就默认显示域名
SUB_NAME="sub"
# 生成订阅文件：三条链接放一起，base64 编码，客户端订阅一次拿到全部节点
{
  echo "$VLESS_LINK"
  [[ -n "${VM_JSON:-}" ]] && echo "$VM_JSON"
  [[ -n "${VM_RESI_JSON:-}" ]] && echo "$VM_RESI_JSON"
  [[ -n "${VM_UK_JSON:-}" ]] && echo "$VM_UK_JSON"
  [[ -n "${VLESS_TLS_LINK:-}" ]] && echo "$VLESS_TLS_LINK"
} > "$SB_DIR/$SUB_NAME.txt"
base64 -w0 "$SB_DIR/$SUB_NAME.txt" > "$SB_DIR/$SUB_NAME.b64"
echo "订阅文件已生成：$SB_DIR/$SUB_NAME.txt（明文）、$SB_DIR/$SUB_NAME.b64（base64，给客户端订阅用）"

# 起订阅托管：本地 8000 端口 http 服务 + 第三条 Argo 隧道，手机走 Argo 拉订阅（直连 VPS IP 在移动上被封）
nohup python3 -m http.server 8000 --directory "$SB_DIR" --bind 127.0.0.1 > "$SB_DIR/sub-http.log" 2>&1 &
sleep 2
nohup "$CF_BIN" tunnel --url "http://localhost:8000" --edge-ip-version auto --no-autoupdate --protocol http2 > "$SB_DIR/argo-sub.log" 2>&1 &
sleep 15
SUB_ARGO=$(grep -a trycloudflare.com "$SB_DIR/argo-sub.log" 2>/dev/null | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
if [[ -n "$SUB_ARGO" ]]; then
  SUB_URL="https://$SUB_ARGO/$SUB_NAME.b64"
  echo "$SUB_URL" > "$SB_DIR/sub-url.txt"
  echo "订阅链接：$SUB_URL"
  echo "订阅链接（base64）：$SUB_URL" >> "$SB_DIR/nodes.txt"
else
  echo "订阅 Argo 域名没取到，等下看 $SB_DIR/argo-sub.log，订阅文件本身在 $SB_DIR/$SUB_NAME.b64，手动传到 GitHub Gist 也能用"
fi
# 订阅托管自启：http 服务 + 订阅隧道
(crontab -l 2>/dev/null | grep -v "http.server 8000" | grep -v "argo-sub.log"; echo "@reboot sleep 20 && nohup python3 -m http.server 8000 --directory $SB_DIR --bind 127.0.0.1 > $SB_DIR/sub-http.log 2>&1 &"; echo "@reboot sleep 25 && nohup $CF_BIN tunnel --url http://localhost:8000 --edge-ip-version auto --no-autoupdate --protocol http2 > $SB_DIR/argo-sub.log 2>&1 &") | crontab -

# 装 CDN 优选测试：cdn-test（测几个常见 Cloudflare IP 到 Argo 的延迟，挑最快的 3 个）
cat > /usr/local/bin/cdn-test <<'EOF_CDN'
#!/bin/bash
# cdn-test：测 Cloudflare IP 到 Argo 域名的延迟，挑最快的 3 个
# 注意：最好是在你自己的手机/电脑网络上测，不是在 VPS 上测。VPS 上测的快慢不代表手机上快。
# 用法：cdn-test [Argo域名]，不填就读 /etc/s-box/nodes.txt 里第一个 Argo 域名
ARGO_DOMAIN="${1:-$(grep '^Argo 2052:' /etc/s-box/nodes.txt 2>/dev/null | awk '{print $3}')}"
if [[ -z "$ARGO_DOMAIN" ]]; then echo "没找到 Argo 域名，用法：cdn-test <Argo域名>"; exit 1; fi
echo "测 $ARGO_DOMAIN，IP 列表是常见 Cloudflare 任播 IP"
for IP in 104.16.0.1 104.17.0.1 104.18.0.1 104.19.0.1 104.20.0.1 104.21.0.1 104.22.0.1 104.23.0.1 104.24.0.1 104.25.0.1 104.26.0.1 104.27.0.1 172.67.0.1 172.67.1.1; do
  T=$(curl -s -o /dev/null -w "%{time_total}" --max-time 5 --resolve "$ARGO_DOMAIN:443:$IP" "https://$ARGO_DOMAIN/" 2>/dev/null || echo "超时")
  echo "$IP $T"
done | sort -k2 -n | head -n 3
echo "上面最快的 3 个，填到 build 脚本的 CDN 优选 IP 里，或者直接改客户端 add"
EOF_CDN
chmod +x /usr/local/bin/cdn-test
echo "CDN 测试已装好，手动跑打 cdn-test"

# 装换 CDN 优选 IP：cdn-change（填了新 IP，自动重生成 VMess 链接和订阅，客户端更新订阅就行）
cat > /usr/local/bin/cdn-change <<'EOF_CDNCHANGE'
#!/bin/bash
# cdn-change：换 CDN 优选 IP，自动重生成 VMess 链接和订阅
# 用法：cdn-change，提示里填新 IP；留空就恢复成前置域名
SB_DIR="/etc/s-box"
SB_JSON="$SB_DIR/sb.json"
META="$SB_DIR/meta.json"
if [[ $EUID -ne 0 ]]; then echo "请用 root 运行"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "缺 jq"; exit 1; fi
CUR_ADD=$(jq -r '.vm_add' "$META" 2>/dev/null)
FRONT_DOMAIN=$(jq -r '.front_domain' "$META" 2>/dev/null)
[[ -z "$FRONT_DOMAIN" || "$FRONT_DOMAIN" == "null" ]] && FRONT_DOMAIN="cloudflare-ech.com"
echo "当前 add：${CUR_ADD:-$FRONT_DOMAIN}"
echo "前置域名：$FRONT_DOMAIN（留空就恢复成这个）"
read -p "新 CDN IP（留空恢复前置域名）： " NEW_IP
if [[ -z "$NEW_IP" ]]; then
  NEW_ADD="$FRONT_DOMAIN"
  NEW_CDN=""
else
  if ! [[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "不是合法 IPv4，没改"; exit 1; fi
  NEW_ADD="$NEW_IP"
  NEW_CDN="$NEW_IP"
fi
if [[ "$NEW_ADD" == "${CUR_ADD:-$FRONT_DOMAIN}" ]]; then echo "跟现在一样，没改"; exit 0; fi
UUID=$(jq -r '.inbounds[1].users[0].uuid' "$SB_JSON" 2>/dev/null)
ARGO=$(grep "^Argo 2052:" "$SB_DIR/nodes.txt" 2>/dev/null | awk '{print $3}')
ARGO_RESI=$(grep "^Argo-resi 2053:" "$SB_DIR/nodes.txt" 2>/dev/null | awk '{print $3}')
HOSTNAME_S=$(jq -r '.hostname' "$META" 2>/dev/null)
[[ -z "$HOSTNAME_S" || "$HOSTNAME_S" == "null" ]] && HOSTNAME_S=$(hostname)
PS_RESI=$(jq -r '.ps_resi' "$META" 2>/dev/null)
[[ -z "$PS_RESI" || "$PS_RESI" == "null" ]] && PS_RESI="移动ARGO住宅"
if [[ -z "$UUID" || "$UUID" == "null" || -z "$ARGO" ]]; then echo "UUID 或 Argo 域名读不到，没改"; exit 1; fi
jq --arg cdn "$NEW_CDN" --arg add "$NEW_ADD" '.cdn_ip = $cdn | .vm_add = $add' "$META" > /tmp/meta.json.new && mv /tmp/meta.json.new "$META"
VM_JSON=$(python3 -c "import json,base64; d={'add':'$NEW_ADD','aid':'0','host':'$ARGO','id':'$UUID','net':'ws','path':'$UUID-vm','port':'443','ps':'移动ARGO','tls':'tls','sni':'$ARGO','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
VM_RESI_JSON=""
if [[ -n "$ARGO_RESI" ]]; then
  VM_RESI_JSON=$(python3 -c "import json,base64; d={'add':'$NEW_ADD','aid':'0','host':'$ARGO_RESI','id':'$UUID','net':'ws','path':'$UUID-resi','port':'443','ps':'$PS_RESI','tls':'tls','sni':'$ARGO_RESI','fp':'chrome','type':'none','v':'2'}; print('vmess://'+base64.b64encode(json.dumps(d).encode()).decode())")
fi
echo "$VM_JSON" > "$SB_DIR/vm_ws_argols.txt"
[[ -n "$VM_RESI_JSON" ]] && echo "$VM_RESI_JSON" > "$SB_DIR/vm_ws_argoresi.txt"
VLESS_LINK=$(grep "^VLESS:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-)
VLESS_TLS_LINK=$(grep "^VLESS-TLS:" "$SB_DIR/nodes.txt" 2>/dev/null | cut -d' ' -f2-)
{
  echo "VLESS: $VLESS_LINK"
  echo "VMess-Argo: $VM_JSON"
  echo "VMess-resi: $VM_RESI_JSON"
  [[ -n "$VLESS_TLS_LINK" ]] && echo "VLESS-TLS: $VLESS_TLS_LINK"
  echo "Argo 2052: $ARGO"
  echo "Argo-resi 2053: $ARGO_RESI"
} > "$SB_DIR/nodes.txt"
SUB_NAME_M=$(python3 -c "import json; print(json.load(open('$SB_DIR/meta.json')).get('sub_name') or 'sub')" 2>/dev/null || echo sub)
{
  echo "$VLESS_LINK"
  echo "$VM_JSON"
  echo "$VM_RESI_JSON"
  [[ -n "$VLESS_TLS_LINK" ]] && echo "$VLESS_TLS_LINK"
} | grep -v '^$' > "$SB_DIR/$SUB_NAME_M.txt"
base64 -w0 "$SB_DIR/$SUB_NAME_M.txt" > "$SB_DIR/$SUB_NAME_M.b64"
echo "已换成：$NEW_ADD"
echo "VMess 链接和订阅已重生成，客户端点一下更新订阅就行，不用手动一个一个改"
echo "订阅链接见：$(cat $SB_DIR/sub-url.txt 2>/dev/null)"
EOF_CDNCHANGE
chmod +x /usr/local/bin/cdn-change
echo "换 CDN IP 已装好，手动跑打 cdn-change"

echo ""
echo "=== 装完了，核对三件事 ==="
echo "1. 移动：小火箭选 移动ARGO（Argo → VPS直连），UDP 转发开着"
echo "2. 电信/联通：小火箭选 电信/联通VLESS（VLESS直连 → VPS直连）"
echo "3. Wi-Fi 通话：小火箭加 UDP 500/4500 直连规则，路由器设 udp_no_redir_ports=500,4500，其他 UDP 走代理"
echo "4. 防泄露自测：ipleak.net、dnsleaktest.com、browserleaks.com，应只见住宅 / WARP IP，不见家里 IP"
if [[ -n "${RESI_IP:-}" ]]; then echo "5. 住宅节点：vm-resi（Argo → 住宅）"; else echo "5. 住宅以后加：在 VPS 上打 add-resi，按提示填住宅 IP/端口/账号/密码，就能加 vm-resi 节点"; fi
echo "6. 换住宅 IP：以后在 VPS 上打 resi，按提示填 IP/端口/账号/密码"
echo "7. 自动维护：每天 03:00 自动检查 sing-box/cloudflared 更新、健康、备份，Argo 换域名自动重生成链接，日志在 /var/log/sb-maintain.log，手动跑打 sb-maintain；已配 Gist（/etc/s-box/gist-token + gist-id）时订阅内容变了会自动推到 Gist"
echo "8. 订阅：$SB_DIR/$SUB_NAME.b64，订阅链接见 $SB_DIR/sub-url.txt，Argo 换域名自动重生成订阅"
echo "9. BBR：已开，重启后自动维护会检查；CDN 优选：手动跑 cdn-test 挑最快 IP，跑 cdn-change 换 IP，自动重生成链接和订阅，客户端更新订阅就行；Acme：填了域名才发证，自动续期后重载 sing-box"
echo "注意：Argo 是临时隧道，VPS 重启会换域名，链接要重新生成（跑一遍 resi 菜单外的节点链接在 $SB_DIR/nodes.txt，重启后要重新取域名）"
