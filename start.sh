#!/bin/bash

# ==========================================
# OpenClaw 4.1 (2026.4.1) 极简稳定版
# 策略：JSON 保持最简，权限交给 exec-approvals.json
# ==========================================

OC_HOME="/home/node/.openclaw"
CONF_FILE="/home/node/app/configs/models_config.json"
HF_ORIGIN="https://${HF_SPACE_OWNER:-tianmingyun999}-${HF_SPACE_NAME:-openclaw2}.hf.space"

echo "--- 📂 1. 环境清洗 ---"
rm -rf "$OC_HOME/agents/main"
rm -rf "$OC_HOME/index.db"
mkdir -p "$OC_HOME/agents/assistant" "$OC_HOME/agents/coder" "$OC_HOME/agents/designer"
mkdir -p "$OC_HOME/workspace/assistant" "$OC_HOME/workspace/coder" "$OC_HOME/workspace/designer"

echo "--- ⚙️ 2. 解析模型配置 ---"
export MODELS_JSON=$(python3 << 'PYTHON_EOF'
import os, json
try:
    with open('/home/node/app/configs/models_config.json', 'r') as f:
        cfg = json.load(f)
except:
    cfg = {"providers": {}}

key_map = {"google":"GGL_KEY", "nvidia":"NVD_KEY", "openrouter":"OPR_KEY", "deepseek":"DS_KEY", "siliconflow":"SF_KEY", "zhipu":"GLM_KEY", "mistral":"MST_KEY", "moonshot":"KIM_KEY"}
output = {"providers": {}}
for p_id, p_info in cfg.get('providers', {}).items():
    api_key = os.getenv(key_map.get(p_id, ""))
    if api_key:
        models_list = [{"id": p_info[role], "name": f"{p_id}-{role}"} for role in ['main', 'code', 'image'] if role in p_info]
        output["providers"][p_id] = {"baseUrl": p_info['url'], "apiKey": api_key, "models": models_list}
print(json.dumps(output) if output["providers"] else '{"providers": {}}')
PYTHON_EOF
)

echo "--- 🛠️ 3. 构建 4.1 兼容 JSON (无额外 Key) ---"
python3 << 'PYTHON_EOF'
import json, os

models_data = json.loads(os.getenv('MODELS_JSON', '{"providers":{}}'))
base = "/home/node/.openclaw"
hf_origin = os.getenv('HF_ORIGIN', '')
chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')

config = {
    "logging": { "level": "info" },
    "models": models_data,
    "channels": {
        "feishu": {
            "enabled": True,
            "dmPolicy": "open",
            "accounts": {
                "default": {
                    "appId": os.getenv("FEISHU_APP_ID", ""),
                    "appSecret": os.getenv("FEISHU_APP_SECRET", ""),
                    "name": "OpenClaw Assistant"
                }
            }
        }
    },
    "tools": {
        "profile": "full",
        "deny": ["cron"]
    },
    "agents": {
        "defaults": { 
            "model": { "primary": f"google/{chat_model}" },
            "params": {}
        },
        "list": [
            {
                "id": "assistant",
                "name": "Team Leader",
                "default": True,
                "workspace": f"{base}/workspace/assistant",
                "agentDir": f"{base}/agents/assistant",
                "model": { "primary": f"google/{chat_model}" },
                "subagents": { 
                    "allowAgents": ["coder", "designer"],
                    "model": { "primary": f"google/{chat_model}" }
                }
            },
            { 
                "id": "coder", 
                "name": "Engineer", 
                "workspace": f"{base}/workspace/coder", 
                "agentDir": f"{base}/agents/coder",
                "model": { "primary": f"google/{chat_model}" }
            },
            { 
                "id": "designer", 
                "name": "Creator", 
                "workspace": f"{base}/workspace/designer", 
                "agentDir": f"{base}/agents/designer",
                "model": { "primary": f"google/{chat_model}" }
            }
        ]
    },
    "gateway": {
        "mode": "local", "port": 7860, "bind": "custom", "customBindHost": "0.0.0.0",
        "auth": {
            "mode": "token",
            "token": os.getenv("OPENCLAW_GATEWAY_TOKEN", "openclaw-hf-space-token-2026"),
            "rateLimit": {
                "exemptLoopback": True
            }
        },
        "controlUi": {
            "enabled": True,
            "dangerouslyDisableDeviceAuth": True,
            "dangerouslyAllowHostHeaderOriginFallback": True,
            "allowedOrigins": [hf_origin, "https://*.hf.space"]
        }
    }
}

with open(f"{base}/openclaw.json", 'w') as f:
    json.dump(config, f, indent=2)
PYTHON_EOF

echo "--- 🛡️ 4. 强制物理授权 (解决 4.1 配对拦截) ---"
# 4.1 会自动读取此文件，将 127.0.0.1 (内部调用) 设为最高信任
cat > "$OC_HOME/exec-approvals.json" << EOF
{
  "allow": {
    "127.0.0.1": ["*"],
    "localhost": ["*"]
  },
  "trust": {
    "assistant": ["coder", "designer"]
  }
}
EOF

echo "--- 💾 5. 同步与启动 ---"
# 注意：先执行同步，再启动。防止同步回来的旧配置覆盖了我们刚刚生成的干净配置
python3 sync.py restore || echo "[SYNC] Starting fresh."
(while true; do sleep 10800; python3 sync.py backup; done) &

exec openclaw gateway run --port 7860 --token "openclaw-hf-space-token-2026" --allow-unconfigured