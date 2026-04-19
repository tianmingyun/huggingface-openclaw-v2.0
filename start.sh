#!/bin/bash

# ==========================================
# OpenClaw 2026.4.5 最新版
# 策略：JSON 保持最简，权限交给 exec-approvals.json
# 更新：支持 v2026.4.5 新配置格式
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

key_map = {"google":"GGL_KEY", "nvidia":"NVIDIA_API_KEY", "openrouter":"OPR_KEY", "deepseek":"DS_KEY", "siliconflow":"SF_KEY", "zhipu":"GLM_KEY", "mistral":"MST_KEY", "moonshot":"KIM_KEY", "longCat":"LONGCAT_KEY", "openai":"OPENAI_KEY", "anthropic":"ANTHROPIC_KEY"}
output = {"providers": {}}
for p_id, p_info in cfg.get('providers', {}).items():
    api_key = os.getenv(key_map.get(p_id, ""))
    if api_key:
        if 'models' in p_info:
            models_list = p_info['models']
        elif 'main' in p_info:
            models_list = [{"id": p_info[role], "name": f"{p_id}-{role}"} for role in ['main', 'code', 'image'] if role in p_info]
        else:
            models_list = []
        
        url = p_info.get('url') or p_info.get('baseUrl')
        provider_config = {"baseUrl": url, "apiKey": api_key, "models": models_list}
        if 'api' in p_info:
            provider_config['api'] = p_info['api']
        output["providers"][p_id] = provider_config
print(json.dumps(output) if output["providers"] else '{"providers": {}}')
PYTHON_EOF
)

echo "--- 🛠️ 3. 构建 4.1 兼容 JSON (无额外 Key) ---"
python3 << 'PYTHON_EOF'
import json, os, sys

models_data = json.loads(os.getenv('MODELS_JSON', '{"providers":{}}'))
base = "/home/node/.openclaw"
hf_origin = os.getenv('HF_ORIGIN', '')
chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')

default_provider = os.getenv('DEFAULT_PROVIDER', 'google')
chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')
if chat_model.startswith(f"{default_provider}/"):
    model_name = chat_model
else:
    model_name = f"{default_provider}/{chat_model}"

print(f"[配置] 使用模型: {model_name}", file=sys.stderr)

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
            "model": { "primary": model_name },
            "params": {}
        },
        "list": [
            {
                "id": "assistant",
                "name": "Team Leader",
                "default": True,
                "workspace": f"{base}/workspace/assistant",
                "agentDir": f"{base}/agents/assistant",
                "model": { "primary": model_name },
                "subagents": { 
                    "allowAgents": ["coder", "designer"],
                    "model": { "primary": model_name }
                }
            },
            { 
                "id": "coder", 
                "name": "Engineer", 
                "workspace": f"{base}/workspace/coder", 
                "agentDir": f"{base}/agents/coder",
                "model": { "primary": model_name }
            },
            { 
                "id": "designer", 
                "name": "Creator", 
                "workspace": f"{base}/workspace/designer", 
                "agentDir": f"{base}/agents/designer",
                "model": { "primary": model_name }
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

echo "--- 💾 5. 修复配置兼容性 (OpenClaw 2026.4.5) ---"
openclaw doctor --fix || echo "[DOCTOR] Config migration completed or not needed."

echo "--- 💾 6. 同步与启动 ---"
if [ -n "$RESTORE_DATE" ]; then
    echo "[SYNC] Restoring to date: $RESTORE_DATE"
    python3 sync.py restore "$RESTORE_DATE" || echo "[SYNC] Restore failed, starting fresh."
else
    echo "[SYNC] Restoring latest backup..."
    python3 sync.py restore || echo "[SYNC] Starting fresh."
fi

python3 << 'VERIFY_EOF'
import json, os, sys

base = "/home/node/.openclaw"
default_provider = os.getenv('DEFAULT_PROVIDER', 'google')
chat_model = os.getenv('CHAT_MODEL', 'gemini-2.0-flash')
if chat_model.startswith(f"{default_provider}/"):
    expected_model = chat_model
else:
    expected_model = f"{default_provider}/{chat_model}"

try:
    with open(f"{base}/openclaw.json", 'r') as f:
        config = json.load(f)
    
    actual_model = config.get('agents', {}).get('defaults', {}).get('model', {}).get('primary', 'NOT_FOUND')
    
    if actual_model != expected_model:
        print(f"[警告] 配置不匹配！期望: {expected_model}, 实际: {actual_model}", file=sys.stderr)
        print(f"[警告] 正在重新写入正确配置...", file=sys.stderr)
        
        config['agents']['defaults']['model']['primary'] = expected_model
        for agent in config['agents']['list']:
            agent['model']['primary'] = expected_model
            if 'subagents' in agent:
                agent['subagents']['model']['primary'] = expected_model
        
        with open(f"{base}/openclaw.json", 'w') as f:
            json.dump(config, f, indent=2)
        
        print(f"[修复] 配置已更正为: {expected_model}", file=sys.stderr)
    else:
        print(f"[验证] 配置正确: {actual_model}", file=sys.stderr)
except Exception as e:
    print(f"[错误] 验证配置时出错: {e}", file=sys.stderr)
VERIFY_EOF

# 启动智能备份控制器（方案B：变化检测 + 2小时强制备份）
echo "[BACKUP] Starting intelligent backup controller (Strategy B)..."
echo "[BACKUP] - Change detection: every 5 minutes"
echo "[BACKUP] - Max interval: 2 hours (forced backup)"
echo "[BACKUP] - Min interval: 5 minutes (avoid duplicates)"
echo "[BACKUP] - Retention: 180 days"
python3 /home/node/app/backup_controller.py &

exec openclaw gateway run --port 7860 --token "openclaw-hf-space-token-2026" --allow-unconfigured