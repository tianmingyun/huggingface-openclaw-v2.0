
本项目是基于 OpenClaw 2026.4.2 架构重构的 v2 版本部署方案。支持多供应商大模型热插拔、主从 Agent 任务分发，以及容器重启状态持久化。

---

## 1. 架构总览：v2 版本升级了什么？

比起之前的 v1 版本 (https://github.com/tianmingyun/huggingface-openclaw)，当前的 v2 版本进行了底层重构，彻底解决了数据丢失和代理冲突问题。

### 核心功能
*   **多 Agent 协同工作流**：设置了一个 Team Leader (assistant) 作为主调度，它可以自主将编程任务委派给 Engineer (coder)，将设计任务委派给 Creator (designer)。
*   **多供应商模型热插拔**：支持 Google Gemini, DeepSeek, SiliconFlow 等 8 家模型供应商，只需填写对应环境变量即可激活。
*   **HF 数据集持久化**：每 3 小时自动打包容器内的运行数据并备份到 Hugging Face Dataset，即使免费容器休眠重启，数据也不会丢失。

### 相比 v1 版本消除的缺陷
1.  **删除了全局 HTTPS 代理**：v1 版本强制接管 HTTP_PROXY，经常导致特定 API（如飞书）连接失败或出现 500 错误，还需要手动配 no_proxy 黑名单。v2 放弃了全局代理，改为使用飞书channel，不再使用Discord等channel。
2.  **解决了 Agent 目录冲突**：v1 中默认的 `/agents/main` 经常导致多个 Agent 抢占同一个配置文件，而且因为 `openclaw.json` 是在 shell 里用 heredoc 强行覆盖的，很容易引发冲突。v2 明确划分了 `agents/assistant`、`agents/coder` 等隔离目录，解决了 "Pairing Required" 死锁报错。
3.  **修复了持久化数据丢失**：v1 的备份脚本 `sync.py` 写死了只备份一个叫 `workspace` 的文件夹，导致真正干活的 `workspace-assistant` 等实际工作区根本没被备份，一重启数据全丢。v2 对整个工作根目录进行无死角备份。

---

## 2. 项目目录结构设计

本项目没有把所有代码像 v1 一样全塞进一个巨大的 `Dockerfile` 里，而是采用了**“三权分立”**的优雅设计：

| 文件名 | 职责 | 为什么这样设计？（优势） |
| :--- | :--- | :--- |
| `configs/models_config.json` | **静态模型账本** | 专门存放各家 AI 模型库的网址和名称。这样如果要换个新模型，只需改这个 JSON 文件，不用去改复杂的代码逻辑，适合小白维护。 |
| `sync.py` | **云端时光机** | 专门负责和 Hugging Face 交互，把数据打包传到云端。把它独立出来，它就可以在后台默默每 3 小时运行一次，不会卡住主程序的启动。 |
| `start.sh` | **启动大总管** | 每次容器开机时，它负责把你的私密密码（环境变量）塞进配置里，然后唤醒所有 Agent。 |

---

## 3. 环境变量 (Secret) 设置指南

环境变量就像是你给这个专属机器人的“接头暗号”。在 HF Spaces 中，你需要把它们配置在 **Settings -> Variables and secrets** 中。

### 🔑 必须填写的 Secret（缺一不可）
*   `HF_TOKEN`: **你的 Hugging Face 通行证**。在你的 HF 个人设置里生成（需 Read/Write 权限）。没有它，程序就没法把数据备份到你的号上。
*   `HF_DATASET`: **你的云端网盘名字**。填入你创建的 Dataset 的名字（格式为 `你的用户名/你的Dataset名`）。

### 🤖 AI 供应商密码（按需填写，至少填一个）
如果你想用哪家的 AI，就填哪家的密码（API Key）：
*   `GGL_KEY`: 谷歌 Gemini 的密钥。
*   `DS_KEY`: DeepSeek 的密钥。
*   `SF_KEY`: SiliconFlow (硅基流动) 的密钥。
*   `NVD_KEY`: NVIDIA 的密钥。
*   `OPR_KEY`: OpenRouter 的密钥。
*   `ZHP_KEY`: 智谱 GLM 的密钥。

---

## 4. 核心代码块详细拆解

如果你好奇底层是怎么运作的，这里是 `start.sh` 最关键部分的白话解释：

### 4.1 模型动态注入 (Provider 配置)
```bash
# start.sh 会读取你的环境变量，如果发现你有 GGL_KEY
if [ -n "$GGL_KEY" ]; then
    # 就会把谷歌的模型能力激活，塞入配置清单
    models_data="{\"google\": {\"apiKey\": \"$GGL_KEY\"}, ...}"
fi
```

### 4.2 突破网关封锁 (Gateway 配置)
在 OpenClaw 4.1/4.2 中，内部 Agent 通信非常严格，容易报 `1008 pairing required` 错误。我们用这三行代码完美破解：
*   `"exemptLoopback": true`: 告诉保安（网关），只要是本机（127.0.0.1）发起的访问，直接放行，不需要再扫码验证设备了。
*   `"dangerouslyDisableDeviceAuth": true`: 彻底关闭界面的设备强制配对，因为 HF Space 是内网穿透环境。
*   `"profile": "full"`: 给主 Agent 直接开通“超级管理员”权限，自带拉起子 Agent 的所有内置工具（`sessions_spawn`, `subagents` 等）。

### 4.3 多 Agent 调度体系 (Agent & Exec 配置)
在 `openclaw.json` 的 agents 列表中：
```json
{
  "id": "assistant",
  "subagents": { "allowAgents": ["coder", "designer"] }
}
```
这赋予了 Assistant **“召唤权”**。当它觉得任务需要写代码时，它会使用内置的 `sessions_spawn` 工具，在后台唤醒 `coder` 独立会话工作。

而在物理权限 `exec-approvals.json` 中：
```json
"trust": { "assistant": ["coder", "designer"] }
```
这赋予了 Assistant **“绝对信任权”**。底层系统允许它不经你同意，直接使唤这两名下属去执行任务。

---

## 5. 傻瓜式部署流程 (5步搞定)

1.  **准备“云盘”**：登录 Hugging Face，点击新建一个 **Dataset**。名字随便起（比如 `my-openclaw-data`），**必须设为 Private（私有）**。
2.  **创建 Space**：新建一个 **Space**。命名后，SDK 选择 **Docker**，模板选择 **Blank**。同样**必须设为 Private（私有）**。
3.  **填写暗号**：进入你刚建好的 Space，点击 **Settings** -> **Variables and secrets**。把你准备好的 `HF_TOKEN`, `HF_DATASET` 和你的大模型 Key（比如 `GGL_KEY`）添加进去。
4.  **上传文件**：把本项目的 `Dockerfile`, `start.sh`, `sync.py`, `project_intro.txt` 和 `configs` 文件夹，全部传到 Space 的 **Files** 页面里。
5.  **喝杯茶等待**：Hugging Face 会自动开始 Building（构建），大概两三分钟后状态变成 Running（运行中），你的专属 AI 团队就上线了！

---

## 6. ⚠️ 极其重要的注意事项

1.  **绝对不能公开 (Private Only)**：你的 Space 和 Dataset 必须是 Private 的。如果公开，任何人都可以直接调用你绑定的 API Key 消耗你的额度，或者偷走你存好的资料。
2.  **重启会丢数据吗？**：免费的 HF Space 没人访问时会“睡觉”。一旦睡觉，容器内的文件会被清零。但别慌，我们的 `sync.py` 已经把数据打包传到你的 Dataset 了。下次被唤醒时，`start.sh` 会在启动服务前，先静悄悄地把 Dataset 里的数据拉回来解压，实现**完全无损复活**。
## 7. 进阶玩法：添加新模型与新技能

随着 AI 的发展，你可能想接入最新的模型，或者让 Agent 掌握新的技能（比如查天气、发邮件）。下面是详细的操作步骤。

### 7.1 如何添加新的模型供应商（以 Anthropic 为例）

如果你想接入一家新的 AI 公司（例如提供 Claude 模型的 Anthropic），只需要简单 4 步：

**第一步：修改 `configs/models_config.json`**
在这个文件里，找到 `"providers"` 大括号，在里面加上新公司的网址和你想用的模型名字。
```json
{
  "providers": {
    "anthropic": {
      "url": "https://api.anthropic.com/v1",
      "main": "claude-sonnet-4-20250514",
      "code": "claude-sonnet-4-20250514"
    }
  }
}
```

**第二步：修改 `start.sh` 关联环境变量**
打开 `start.sh`，找到大概第 27 行的 `key_map`，把你的新公司名字和你打算在 HF 里设置的密码变量名（比如 `ANTHROPIC_KEY`）对应起来加进去：
```python
# 修改前：
key_map = {"google":"GGL_KEY", "nvidia":"NVD_KEY", ...}
# 修改后（加在最后面）：
key_map = {"google":"GGL_KEY", "nvidia":"NVD_KEY", ..., "anthropic":"ANTHROPIC_KEY"}
```

**第三步：在 Hugging Face 里设置密码**
去你的 Space 的 **Settings -> Variables and secrets** 里，新建一个 Secret，名字填 `ANTHROPIC_KEY`，值填入你真实的 Claude API Key。

**第四步：切换主模型**
如果你想让系统立刻用上新模型，把环境变量中的 `CHAT_MODEL` 改成 `claude-sonnet-4-20250514`，然后重启 Space 即可！

---

### 7.2 如何从 ClawHub 安装并分配新技能 (Skills)

OpenClaw 支持像给手机装 APP 一样给 Agent 装技能。所有的技能都可以在官方的 ClawHub 插件库里找到。

**第一步：在终端安装技能**
你可以在 OpenClaw 的前端对话框里，直接让 Assistant 帮你运行安装命令，或者如果你有终端权限，直接执行以下命令：
```bash
# 比如你想装一个叫 calendar (日历) 的技能
openclaw skills install calendar

# 如果你想看看有哪些好玩的技能，可以先搜一下
openclaw skills search "天气"
```
安装好的技能会自动下载到容器里，并且通过我们的 `sync.py` 永久备份，重启也不怕丢。

**第二步：把技能分配给特定的 Agent**
技能装好后，你该怎么决定谁能用它呢？

默认情况下，由于我们在 `start.sh` 里给 Assistant 设置了 `"profile": "full"`，它能**自动获得所有已安装技能**的使用权。

如果你想给下属 Agent（比如 `coder`）单独分配特定的技能，你可以修改 `start.sh` 中生成 `openclaw.json` 的部分，给 coder 加一个 `skills` 数组：

```json
{ 
    "id": "coder", 
    "name": "Engineer", 
    "workspace": f"{base}/workspace/coder", 
    "agentDir": f"{base}/agents/coder",
    "model": { "primary": f"google/{chat_model}" },
    "skills": ["calendar", "weather"]  // 👈 在这里写上你想分配给它的技能名字
}
```
### 7.3 如何接入飞书 (Feishu/Lark) 机器人

本项目自带了飞书官方 SDK 支持，你可以让 Assistant 变成你飞书群里的 AI 助手。

**第一步：在飞书开放平台创建应用**
1. 登录 [飞书开放平台](https://open.feishu.cn/)，点击“创建企业自建应用”。
2. 在“凭证与基础信息”中，记录下你的 `App ID` 和 `App Secret`。
3. 在“添加应用能力”中，添加“机器人”能力。
4. 记录下机器人设置页面里的 `Encrypt Key` (加密 Key) 和 `Verification Token` (验证 Token)。

**关于加密密钥的说明**：
- 如果你的飞书应用没有启用事件订阅的加密策略，**无需填写**这两个密钥
- 默认配置为 WebSocket 模式，数据不加密传输，飞书官方不要求加密密钥
- 如需在飞书后台启用加密，参考上面的"获取加密密钥"步骤

**第二步：在 HF Spaces 填写环境变量**
回到你的 Hugging Face Space，在 Settings -> Variables and secrets 里，添加以下 2 个**必须的** Secret 和 2 个**可选的** Secret：

**必须填写（基础功能）：**
*   `FEISHU_APP_ID`: 填入你的飞书 App ID
*   `FEISHU_APP_SECRET`: 填入你的飞书 App Secret

**可选填写（高级加密）：**
*   `FEISHU_ENCRYPT_KEY`: 飞书事件加密密钥（仅在飞书后台启用了"加密策略"时才需要）
*   `FEISHU_VERIFICATION_TOKEN`: 飞书事件验证令牌（同上）



**第三步：在飞书后台绑定回调 URL**
填写好上面的环境变量并重启 Space 后，回到飞书开放平台：
1. 在"事件订阅"页面，配置请求地址 URL：
   `https://你的HF用户名-你的Space名字.hf.space/feishu/events`
   *(注意：把前面替换成你真实的 Space 网址)*
2. 点击保存，飞书会往这个网址发一个测试请求。如果提示成功，说明通道打通了！
3. 在"权限管理"中，申请 `接收群聊消息` 和 `获取单聊消息` 权限，然后发布版本。

**如何获取加密密钥（可选）**：
如果你需要在飞书后台启用事件加密（一般不需要）：
1. 在飞书开放平台的"事件订阅"页面，找到"加密策略"设置
2. 选择"开启加密"，系统会自动生成 `Encrypt Key` (加密密钥)
3. 复制这个密钥，添加到 HF Spaces 的环境变量 `FEISHU_ENCRYPT_KEY` 中
4. 同时记录下`Verification Token`，添加到 `FEISHU_VERIFICATION_TOKEN`

现在，你就可以在飞书里直接 @ 你的机器人，让主调度 Agent 帮你干活了！

---

## 8. 常见问题排查 (Troubleshooting)

基于实际部署经验，整理以下常见问题：

### Q1: 容器启动失败，提示 "Config invalid: Unrecognized key..."

**问题**：配置项包含 OpenClaw 4.2 不支持的字段  
**解决**：检查 `start.sh`，确保没有使用 `methods`、`dangerouslyApproveAllPairingRequests` 等 4.2 版本已移除的配置项

### Q2: 飞书机器人提示 "access not configured" 要求配对

**问题**：默认私信策略 `dmPolicy: "pairing"` 需要手动批准  
**解决**：本文档已配置 `dmPolicy: "open"`，允许所有用户直接访问，无需配对

### Q3: 飞书连接失败，提示需要 verificationToken

**问题**：Webhook 模式需要提供 `verificationToken` 和 `encryptKey`  
**解决**：本文档使用 `connectionMode: "websocket"`，只需填写 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`

### Q4: 报错 "Cannot find module 'grammy' / '@slack/bolt'"

**问题**：OpenClaw 4.2 npm 包缺少部分运行时依赖  
**解决**：`Dockerfile` 中已添加 `npm install grammy @slack/web-api`，重新构建容器即可

### Q5:子 Agent (coder/designer) 不响应或不可见

**问题**：可能缺少 `model` 配置或 `tools` 权限不足  
**解决**：
- 检查所有 Agent 都配置了 `"model": { "primary": ... }`
- 确认 `tools.profile` 设置为 `"full"`
- 确认 `exec-approvals.json` 中有 `"trust": { "assistant": ["coder", "designer"] }`

---

## 9. 版本更新记录

### v2.0 (2026-04-03)
- ✅ 升级到 OpenClaw 4.2 架构
- ✅ 多 Agent 协同系统 (assistant + coder + designer)
- ✅ 移除全局 HTTPS 代理，改用路由层配置
- ✅ HF Dataset 自动备份/恢复机制
- ✅ 飞书 WebSocket 模式 (dmPolicy: open)
- ✅ 修复 4.2 版本配对机制变更问题
- ✅ 修复 npm 依赖缺失

---

## 写在最后

恭喜你成功部署 OpenClaw 4.2 多智能体系统！🎉

**Happy Hacking!** 🚀
