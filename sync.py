import os, sys, tarfile
from huggingface_hub import HfApi, hf_hub_download
from datetime import datetime, timedelta

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
base = "/home/node/.openclaw"

def restore():
    try:
        if not repo_id: return False
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
        for i in range(3):
            name = f"backup_{(datetime.now()-timedelta(days=i)).strftime('%Y-%m-%d')}.tar.gz"
            if name in files:
                path = hf_hub_download(repo_id=repo_id, filename=name, repo_type="dataset", token=token)
                os.makedirs(base, exist_ok=True)
                with tarfile.open(path, "r:gz") as tar: tar.extractall(path=base)
                print(f"[SYNC] Restore Success: {name}"); return True
    except Exception as e: print(f"[SYNC] Error: {e}")
    return False

def backup():
    try:
        if not repo_id: return
        name = f"backup_{datetime.now().strftime('%Y-%m-%d')}.tar.gz"
        with tarfile.open(f"/tmp/{name}", "w:gz") as tar: 
            for t in ["sessions", "workspace", "agents"]: 
                p = f"{base}/{t}"
                if os.path.exists(p): tar.add(p, arcname=t)
        api.upload_file(path_or_fileobj=f"/tmp/{name}", path_in_repo=name, repo_id=repo_id, repo_type="dataset", token=token)
    except Exception as e: print(f"[SYNC] Backup Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup": backup()
    else: restore()