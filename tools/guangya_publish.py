#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
光鸭云盘发布工具：把 CloudTunes 的 APK 发布到光鸭云盘，作为国内免翻墙的更新源。

用法：
  python guangya_publish.py sendcode +8613800138000   # 第 1 步：发短信验证码
  python guangya_publish.py verify 123456             # 第 2 步：输入验证码完成登录（token 存本地）
  python guangya_publish.py ls                        # 列根目录
  python guangya_publish.py prune                     # 手动清理：同系列只留最新一版
  python guangya_publish.py upload a.apk b.apk        # 上传到「CloudTunes」文件夹（没有会自动创建）
  python guangya_publish.py url <fileId>              # 取某个文件的下载直链（验证用）

登录凭证保存在 ~/.cloudtunes_guangya.json，之后上传不用重复登录（token 自动刷新）。
接口与官方 App/OpenList 驱动一致：get_res_center_token → OSS 直传 → get_info_by_task_id 轮询。
"""

import base64
import hashlib
import hmac
import json
import os
import random
import re
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

ACCOUNT_BASE = "https://account.guangyapan.com"
API_BASE = "https://api.guangyapan.com"
DEFAULT_CLIENT_ID = "aMe-8VSlkrbQXpUR"
UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/147.0.0.0 Mobile Safari/537.36")
ORIGIN = "https://www.guangyapan.com"
TOKEN_FILE = os.path.expanduser("~/.cloudtunes_guangya.json")
UPDATE_FOLDER = "CloudTunes"   # 放安装包的文件夹（App 端按这个名字找）


def rand_hex(n):
    return "".join(random.choice("0123456789abcdef") for _ in range(n))


def load_state():
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_state(state):
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def account_headers(state, auth=False, captcha=None):
    h = {
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json",
        "X-Device-Model": "chrome%2F147.0.0.0",
        "X-Device-Name": "PC-Chrome",
        "X-Device-Sign": "wdi10." + state["device_id"] + rand_hex(32),
        "X-Net-Work-Type": "NONE",
        "X-OS-Version": "Linux armv8l",
        "X-Platform-Version": "1",
        "X-Protocol-Version": "301",
        "X-Provider-Name": "NONE",
        "X-SDK-Version": "9.0.2",
        "X-Client-Id": state.get("client_id", DEFAULT_CLIENT_ID),
        "X-Client-Version": "0.0.1",
        "X-Device-Id": state["device_id"],
        "Origin": ORIGIN,
        "Referer": ORIGIN + "/",
        "User-Agent": UA,
        "Traceparent": "00-" + rand_hex(32) + "-" + rand_hex(16) + "-01",
    }
    if auth:
        h["Authorization"] = "Bearer " + state["access_token"]
    if captcha:
        h["X-Captcha-Token"] = captcha
    return h


def api_headers(state):
    h = {
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json",
        "Did": state["device_id"],
        "Dt": "4",
        "Origin": ORIGIN,
        "Referer": ORIGIN + "/",
        "User-Agent": UA,
        "Traceparent": "00-" + rand_hex(32) + "-" + rand_hex(16) + "-01",
    }
    if state.get("access_token"):
        h["Authorization"] = "Bearer " + state["access_token"]
    return h


def post_json(url, body, headers, timeout=30):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def api_post(state, path, body):
    """带 401 自动刷新的 API 调用；同一接口 500ms 限速"""
    if not hasattr(api_post, "_last"):
        api_post._last = 0
    wait = 0.5 - (time.time() - api_post._last)
    if wait > 0:
        time.sleep(wait)
    api_post._last = time.time()

    status, text = post_json(API_BASE + path, body, api_headers(state))
    if status in (401, 403):
        refresh(state)
        status, text = post_json(API_BASE + path, body, api_headers(state))
    if status != 200:
        raise RuntimeError("HTTP %s: %s" % (status, text[:300]))
    return json.loads(text)


def refresh(state):
    headers = account_headers(state)
    headers["X-Action"] = "401"
    status, text = post_json(ACCOUNT_BASE + "/v1/auth/token", {
        "client_id": state.get("client_id", DEFAULT_CLIENT_ID),
        "grant_type": "refresh_token",
        "refresh_token": state["refresh_token"],
    }, headers)
    if status != 200:
        raise RuntimeError("token 刷新失败(HTTP %s)，请重新 sendcode 登录：%s" % (status, text[:200]))
    r = json.loads(text)
    at = r.get("access_token") or (r.get("data") or {}).get("access_token")
    if not at:
        raise RuntimeError("token 刷新失败：%s" % text[:200])
    state["access_token"] = at
    rt = r.get("refresh_token") or (r.get("data") or {}).get("refresh_token")
    if rt:
        state["refresh_token"] = rt
    save_state(state)
    print("token 已刷新")


def ensure_state():
    state = load_state()
    if "device_id" not in state:
        state["device_id"] = rand_hex(32)
        state["client_id"] = DEFAULT_CLIENT_ID
        save_state(state)
    if "access_token" not in state:
        print("未登录：先执行 sendcode <手机号>，再 verify <验证码>")
        sys.exit(1)
    return state


# ── 登录 ──

def cmd_sendcode(phone):
    state = load_state()
    if "device_id" not in state:
        state["device_id"] = rand_hex(32)
        state["client_id"] = DEFAULT_CLIENT_ID
    state["phone"] = phone
    save_state(state)

    status, text = post_json(ACCOUNT_BASE + "/v1/shield/captcha/init", {
        "client_id": state["client_id"],
        "action": "POST:/v1/auth/verification",
        "device_id": state["device_id"],
        "meta": {"phone_number": phone},
    }, account_headers(state))
    if status != 200:
        sys.exit("安全验证初始化失败：%s" % text[:300])
    r = json.loads(text)
    captcha = r.get("captcha_token") or (r.get("data") or {}).get("captcha_token")
    if not captcha:
        sys.exit("未取得 captcha_token：%s" % text[:300])

    status, text = post_json(ACCOUNT_BASE + "/v1/auth/verification", {
        "phone_number": phone, "target": "ANY", "client_id": state["client_id"],
    }, account_headers(state, captcha=captcha))
    if status != 200:
        sys.exit("发送验证码失败：%s" % text[:300])
    r = json.loads(text)
    vid = r.get("verification_id") or (r.get("data") or {}).get("verification_id")
    if not vid:
        sys.exit("未取得 verification_id：%s" % text[:300])
    state["verification_id"] = vid
    save_state(state)
    print("验证码已发送到 %s，收到的 6 位验证码用 verify 命令提交" % phone)


def cmd_verify(code):
    state = load_state()
    vid = state.get("verification_id")
    if not vid:
        sys.exit("还没有发送验证码：先执行 sendcode <手机号>")
    status, text = post_json(ACCOUNT_BASE + "/v1/auth/verification/verify", {
        "verification_id": vid, "verification_code": code, "client_id": state["client_id"],
    }, account_headers(state))
    if status != 200:
        sys.exit("验证码校验失败：%s" % text[:300])
    r = json.loads(text)
    vt = r.get("verification_token") or (r.get("data") or {}).get("verification_token")
    if not vt:
        sys.exit("未取得 verification_token：%s" % text[:300])

    status, text = post_json(ACCOUNT_BASE + "/v1/auth/signin", {
        "verification_code": code, "verification_token": vt,
        "username": state["phone"], "client_id": state["client_id"],
    }, account_headers(state))
    if status != 200:
        sys.exit("登录失败：%s" % text[:300])
    r = json.loads(text)
    data = r.get("data") or r
    at = data.get("access_token")
    if not at:
        sys.exit("未取得 access_token：%s" % text[:300])
    state["access_token"] = at
    if data.get("refresh_token"):
        state["refresh_token"] = data["refresh_token"]
    state.pop("verification_id", None)
    save_state(state)
    print("登录成功，token 已保存到 %s" % TOKEN_FILE)


# ── 文件操作 ──

def list_dir(state, parent_id=""):
    r = api_post(state, "/userres/v1/file/get_file_list", {
        "parentId": parent_id, "page": 0, "pageSize": 100, "orderBy": 3, "sortType": 1,
    })
    data = r.get("data") or {}
    return data.get("list") or []


def cmd_ls(parent_id=""):
    state = ensure_state()
    for item in list_dir(state, parent_id):
        kind = "DIR " if item.get("resType") == 2 else "FILE"
        print("%s %-12s %s" % (kind, item.get("fileId"), item.get("fileName")))


def delete_files(state, file_ids):
    """删除文件（异步任务，服务端返回 taskId）"""
    if not file_ids:
        return None
    return api_post(state, "/nd.bizuserres.s/v1/file/delete_file", {"fileIds": list(file_ids)})


def version_key(name):
    m = re.search(r"-(\d+(?:\.\d+)*)\.apk$", name or "")
    if not m:
        return None
    return tuple(int(x) for x in m.group(1).split("."))


def prune_old(state, folder_id, dry_run=False, keep_latest=1):
    """同系列安装包只保留版本号最高的 keep_latest 个，其余删除。

    云盘里堆着每个历史版本会让「该装哪个」变难，也浪费空间；
    每次发布新包后自动清掉旧包（GitHub release 里仍保留全部历史版本可回溯）。
    """
    items = list_dir(state, folder_id)
    groups = {}
    for it in items:
        if it.get("resType") == 2:          # 文件夹跳过
            continue
        name = it.get("fileName") or ""
        key = version_key(name)
        if key is None:                      # 不是带版本号的 apk，不动
            continue
        prefix = re.sub(r"-\d+(?:\.\d+)*\.apk$", "", name)
        groups.setdefault(prefix, []).append((key, name, it.get("fileId")))

    removed = []
    for prefix, entries in groups.items():
        entries.sort(key=lambda e: e[0], reverse=True)
        for _, name, fid in entries[keep_latest:]:
            if dry_run:
                print("  将删除 %s" % name)
            else:
                delete_files(state, [fid])
                print("  已删除旧版本 %s" % name)
            removed.append(name)
    return removed


def ensure_folder(state, name):
    for item in list_dir(state, ""):
        if item.get("resType") == 2 and item.get("fileName") == name:
            return item["fileId"]
    r = api_post(state, "/nd.bizuserres.s/v1/file/create_dir", {"parentId": "", "dirName": name})
    time.sleep(0.6)
    for item in list_dir(state, ""):
        if item.get("resType") == 2 and item.get("fileName") == name:
            return item["fileId"]
    raise RuntimeError("创建文件夹 %s 失败：%s" % (name, json.dumps(r, ensure_ascii=False)[:300]))


def poll_task(state, task_id):
    for _ in range(90):
        r = api_post(state, "/nd.bizuserres.s/v1/file/get_info_by_task_id", {"taskId": task_id})
        data = (r.get("data") or {})
        fid = data.get("fileId")
        if fid:
            return fid
        code = r.get("code", 0)
        if code not in (0, 145, 146, 147, 155, 163):
            raise RuntimeError("上传任务失败 code=%s msg=%s" % (code, r.get("msg")))
        time.sleep(1.0)
    raise RuntimeError("上传任务超时")


def oss_put(bucket, endpoint, object_path, token_data, data):
    ep = (endpoint or token_data.get("fullEndPoint") or "").strip()
    if not ep:
        raise RuntimeError("OSS endpoint 为空")
    if not ep.startswith("http"):
        b = (bucket or "").strip()
        if b and ep.startswith(b + "."):
            ep = "https://" + ep
        elif b:
            ep = "https://%s.%s" % (b, ep)
        else:
            ep = "https://" + ep
    key = object_path.lstrip("/")
    url = ep.rstrip("/") + "/" + key
    host = re.match(r"https?://([^/]+)", ep).group(1)

    ak = token_data.get("accessKeyID") or (token_data.get("creds") or {}).get("accessKeyID")
    sk = token_data.get("secretAccessKey") or (token_data.get("creds") or {}).get("secretAccessKey")
    st = token_data.get("sessionToken") or (token_data.get("creds") or {}).get("sessionToken")
    if not (ak and sk and st):
        raise RuntimeError("OSS 凭证缺失")

    date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    canonical_headers = "x-oss-security-token:%s\n" % st
    resource = "/%s/%s" % (bucket, key)
    string_to_sign = "PUT\n\napplication/octet-stream\n%s\n%s%s" % (date, canonical_headers, resource)
    sig = base64.b64encode(
        hmac.new(sk.encode(), string_to_sign.encode("utf-8"), hashlib.sha1).digest()
    ).decode()

    req = urllib.request.Request(url, data=data, method="PUT", headers={
        "Authorization": "OSS %s:%s" % (ak, sig),
        "Content-Type": "application/octet-stream",
        "Date": date,
        "x-oss-security-token": st,
        "Host": host,
    })
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        raise RuntimeError("OSS 直传失败 HTTP %s：%s" % (e.code, e.read()[:300]))


def cmd_upload(files):
    state = ensure_state()
    folder_id = ensure_folder(state, UPDATE_FOLDER)
    print("目标文件夹：%s (%s)" % (UPDATE_FOLDER, folder_id))
    for path in files:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            content = f.read()
        md5 = hashlib.md5(content).hexdigest()
        print("上传 %s（%.1f MB）…" % (name, size / 1048576.0))

        r = api_post(state, "/nd.bizuserres.s/v1/get_res_center_token", {
            "capacity": 2, "name": name, "parentId": folder_id,
            "res": {"fileSize": size, "md5": md5},
        })
        data = r.get("data") or {}
        task_id = data.get("taskId") or data.get("taskID")
        if not task_id:
            raise RuntimeError("取上传令牌失败：%s" % json.dumps(r, ensure_ascii=False)[:300])
        already = r.get("code") == 156 or (r.get("msg") or "").strip() in (
            "上传已完成", "秒传成功", "upload completed", "already uploaded")
        if not already and (data.get("accessKeyID") or (data.get("creds") or {}).get("accessKeyID")):
            oss_put(data.get("bucketName"), data.get("endPoint"),
                    data.get("objectPath") or name, data, content)
        fid = poll_task(state, task_id)
        print("  完成：fileId=%s" % fid)

    # 上传完顺手清掉同系列的旧包：云盘里只留最新一版，避免「该装哪个」的困扰
    removed = prune_old(state, folder_id)
    if removed:
        print("已清理 %d 个旧版本" % len(removed))


def cmd_url(file_id):
    state = ensure_state()
    r = api_post(state, "/nd.bizuserres.s/v1/get_res_download_url", {"fileId": file_id})
    data = r.get("data") or {}
    print(data.get("signedURL") or data.get("downloadURL"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "sendcode":
        cmd_sendcode(sys.argv[2])
    elif cmd == "verify":
        cmd_verify(sys.argv[2])
    elif cmd == "ls":
        cmd_ls(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "upload":
        cmd_upload(sys.argv[2:])
    elif cmd == "prune":
        state = ensure_state()
        fid = ensure_folder(state, UPDATE_FOLDER)
        removed = prune_old(state, fid, dry_run=("--dry-run" in sys.argv))
        print("清理完成，共 %d 个旧版本" % len(removed))
    elif cmd == "url":
        cmd_url(sys.argv[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
