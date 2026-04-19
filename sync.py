#!/usr/bin/env python3
"""
OpenClaw 180天记忆恢复系统
支持多备份管理、时间点恢复、7天数据合并
"""

import os
import sys
import tarfile
import json
import shutil
from pathlib import Path
from datetime import datetime, timedelta
from huggingface_hub import HfApi, hf_hub_download

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
base = "/home/node/.openclaw"
manifest_file = "manifest.json"

def get_backup_files(days=180):
    """获取所有备份文件列表（默认180天内）"""
    try:
        if not repo_id:
            return []
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
        backups = []
        cutoff = datetime.now() - timedelta(days=days)
        
        for f in files:
            if f.startswith("backup_") and f.endswith(".tar.gz"):
                date_str = f[7:-7]  # 提取 YYYY-MM-DD
                try:
                    backup_date = datetime.strptime(date_str, "%Y-%m-%d")
                    if backup_date >= cutoff:
                        backups.append({"filename": f, "date": date_str, "date_obj": backup_date})
                except:
                    pass
        return sorted(backups, key=lambda x: x["date_obj"], reverse=True)
    except Exception as e:
        print(f"[ERROR] {e}")
        return []

def restore(target_date=None, merge_days=7):
    """
    恢复备份
    target_date: YYYY-MM-DD 格式，None表示恢复最近merge_days天的所有数据
    merge_days: 合并天数，默认7天
    """
    try:
        if not repo_id:
            print("[RESTORE] Error: HF_DATASET not set")
            return False
        
        backups = get_backup_files(days=180)
        if not backups:
            print("[RESTORE] No backups found")
            return False
        
        # 确定要恢复的备份列表
        if target_date:
            # 指定日期：只恢复该日期
            target = next((b for b in backups if b["date"] == target_date), None)
            if not target:
                print(f"[RESTORE] Backup not found: {target_date}")
                print(f"[RESTORE] Available: {[b['date'] for b in backups[:10]]}")
                return False
            backups_to_restore = [target]
            print(f"[RESTORE] Restoring specific date: {target_date}")
        else:
            # 默认：恢复最近merge_days天的所有备份
            cutoff_date = datetime.now() - timedelta(days=merge_days)
            backups_to_restore = [b for b in backups if b["date_obj"] >= cutoff_date]
            
            if not backups_to_restore:
                # 如果7天内没有备份，至少恢复最新的一个
                backups_to_restore = [backups[0]]
                print(f"[RESTORE] No backups in last {merge_days} days, restoring latest: {backups[0]['date']}")
            else:
                print(f"[RESTORE] Restoring last {merge_days} days: {[b['date'] for b in backups_to_restore]}")
        
        # 备份 openclaw.json（如果存在）
        config_path = Path(base) / "openclaw.json"
        config_backup = None
        if config_path.exists():
            with open(config_path, 'r') as f:
                config_backup = f.read()
            print("[RESTORE] Backed up config")
        
        # 清理现有数据（如果是全新恢复）
        if os.path.exists(base):
            print(f"[RESTORE] Clearing existing data...")
            shutil.rmtree(base)
        os.makedirs(base, exist_ok=True)
        
        # 按日期从旧到新恢复（确保最新的数据覆盖旧的）
        backups_to_restore.reverse()
        
        for backup in backups_to_restore:
            print(f"[RESTORE] Downloading {backup['filename']}...")
            
            try:
                backup_path = hf_hub_download(
                    repo_id=repo_id,
                    filename=backup["filename"],
                    repo_type="dataset",
                    token=token
                )
                
                print(f"[RESTORE] Extracting {backup['date']}...")
                
                with tarfile.open(backup_path, "r:gz") as tar:
                    # 获取备份中的所有文件
                    for member in tar.getmembers():
                        # 检查文件是否已存在（保留最新的）
                        target_path = Path(base) / member.name
                        
                        if member.isdir():
                            target_path.mkdir(parents=True, exist_ok=True)
                        elif member.isfile():
                            # 如果文件已存在，跳过（保留之前恢复的新版本）
                            if not target_path.exists():
                                # 确保父目录存在
                                target_path.parent.mkdir(parents=True, exist_ok=True)
                                # 提取文件
                                with tar.extractfile(member) as src:
                                    with open(target_path, 'wb') as dst:
                                        dst.write(src.read())
                
                print(f"[RESTORE] Merged: {backup['date']}")
                
            except Exception as e:
                print(f"[RESTORE] Warning: Failed to restore {backup['date']}: {e}")
                continue
        
        # 恢复配置
        if config_backup:
            with open(config_path, 'w') as f:
                f.write(config_backup)
            print("[RESTORE] Restored config")
        
        restored_dates = [b['date'] for b in backups_to_restore]
        print(f"[RESTORE] Success! Restored {len(backups_to_restore)} backup(s): {restored_dates}")
        return True
        
    except Exception as e:
        print(f"[RESTORE] Error: {e}")
        import traceback
        traceback.print_exc()
        return False

def backup():
    """创建备份（保留180天）"""
    try:
        if not repo_id:
            print("[BACKUP] Error: HF_DATASET not set")
            return
        
        # 清理180天前的旧备份
        cleanup_old_backups()
        
        # 创建新备份
        name = f"backup_{datetime.now().strftime('%Y-%m-%d')}.tar.gz"
        print(f"[BACKUP] Creating: {name}")
        
        with tarfile.open(f"/tmp/{name}", "w:gz") as tar:
            for d in ["sessions", "workspace", "agents"]:
                p = Path(base) / d
                if p.exists():
                    tar.add(p, arcname=d)
        
        # 上传
        api.upload_file(
            path_or_fileobj=f"/tmp/{name}",
            path_in_repo=name,
            repo_id=repo_id,
            repo_type="dataset",
            token=token
        )
        
        print(f"[BACKUP] Success: {name}")
        
    except Exception as e:
        print(f"[BACKUP] Error: {e}")

def cleanup_old_backups():
    """清理180天前的备份"""
    try:
        cutoff = datetime.now() - timedelta(days=180)
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
        
        for f in files:
            if f.startswith("backup_") and f.endswith(".tar.gz"):
                date_str = f[7:-7]
                try:
                    backup_date = datetime.strptime(date_str, "%Y-%m-%d")
                    if backup_date < cutoff:
                        api.delete_file(
                            path_in_repo=f,
                            repo_id=repo_id,
                            repo_type="dataset",
                            token=token
                        )
                        print(f"[CLEANUP] Deleted: {f}")
                except:
                    pass
    except Exception as e:
        print(f"[CLEANUP] Error: {e}")

def list_backups():
    """列出所有备份"""
    backups = get_backup_files(days=180)
    print(f"\n📦 Found {len(backups)} backups (180 days retention):
")
    for b in backups:
        print(f"  📅 {b['date']} - {b['filename']}")
    return backups

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: sync.py <backup|restore [date]|list>")
        print("       sync.py restore         # Restore last 7 days")
        print("       sync.py restore 2026-04-10  # Restore specific date")
        sys.exit(1)
    
    cmd = sys.argv[1]
    if cmd == "backup":
        backup()
    elif cmd == "restore":
        date = sys.argv[2] if len(sys.argv) > 2 else None
        restore(date)
    elif cmd == "list":
        list_backups()
    else:
        print(f"Unknown command: {cmd}")