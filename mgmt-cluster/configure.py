#!/usr/bin/env python3
"""
NKP Management Cluster — Interactive Config Wizard

Generates config.json for the mgmt-cluster deployment scripts.
Connects to Prism Central v4 API to pull available PE clusters, subnets, images, and storage containers 


Flow:
  1. Connect to Prism Central (env vars PC_URL/PC_USER/PC_PASS or prompt)
  2. Pick deployment type (connected / airgap)
  3. Cluster name, hostname, license tier
  4. Select PE cluster, subnet, image, storage from PC API
  5. Networking (VIP, MetalLB range, DNS, NTP, CIDRs)
  6. Node sizing with license-based defaults + validation
  7. Registry config (airgap: both registry-url and mirror-url)
  8. Proxy, SSH, CSI options
  9. Review JSON and save

Tries multiple API versions per endpoint (v4.0.b2, v4.0.b1, v4.0.a1, v4.0)
because different PC releases expose different versions. First hit wins.
"""

import json
import ssl
import getpass
import urllib.request
import urllib.error
import urllib.parse
import base64
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config.json")

# Prism Central APIv4 wrapper uses globals PC_URL, PC_USER, PC_PASS (set below)
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

def pc_get(endpoint, quiet=False):
    """GET from Prism Central v4 API"""

    url = f"{PC_URL}/api/{endpoint}"
    request = urllib.request.Request(url, method="GET")
    creds = base64.b64encode(f"{PC_USER}:{PC_PASS}".encode()).decode()
    request.add_header("Authorization", f"Basic {creds}")
    request.add_header("Accept", "application/json")
    request.add_header("X-Nutanix-Client-Type", "ui")
    try:
        with urllib.request.urlopen(request, context=SSL_CTX, timeout=30) as resp:
            return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        if not quiet:
            print(f"API error: {e.code} {e.reason}")
        return None, e.code
    except Exception as e:
        if not quiet:
            print(f"API error: {e}")
        return None, 0

def pc_get_first(*endpoints):
    """Try multiple API paths"""
    last_code = 0
    for ep in endpoints:
        result, code = pc_get(ep, quiet=True)
        last_code = code
        if result and "data" in result:
            return result
    if last_code == 401:
        print("API error: 401 Unauthorized — check credentials")
    elif last_code == 404:
        print(" API error: 404  endpoint not available on this PC version")
    elif last_code:
        print(f"API error: {last_code}")
    return None

def ask(prompt, default=""):
    d = f" [{default}]" if default else ""
    val = input(f"  {prompt}{d}: ").strip()
    return val or default

def ask_int(prompt, default):
    val = ask(prompt, str(default))
    try:
        return int(val)
    except ValueError:
        print(f" Invalid number '{val}', using default {default}")
        return int(default)

def ask_yn(prompt, default=True):
    """Ask yes/no and return bool"""
    hint = "Y/n" if default else "y/N"
    val = input(f"  {prompt} [{hint}]: ").strip().lower()
    if val in ("y", "yes"): return True
    if val in ("n", "no"): return False
    return default

def is_valid_ip(ip):
    """Is real IP ?"""
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit() or not 0 <= int(p) <= 255:
            return False
    return True

def ask_ip(prompt, default="", required=True):
    """Ask for an IP, validate, retry on bad input"""
    while True:
        val = ask(prompt, default)
        if not val:
            if required:
                print("  Required field, please enter an IP address.")
                continue
            return ""
        if is_valid_ip(val):
            return val
        print(f"  Invalid IP: {val} expected format: x.x.x.x")

def ask_ip_range(prompt, default=""):
    """Ask for IP range (start-end), validate both IPs"""
    while True:
        val = ask(prompt, default)
        if not val:
            print("  Required field.")
            continue
        if "-" not in val:
            print(" Expected format: start_ip-end_ip")
            continue
        start, end = val.split("-", 1)
        if is_valid_ip(start.strip()) and is_valid_ip(end.strip()):
            return val.strip()
        print(f"  Invalid IP range: {val} — both must be valid IPs")

def pick(items, name_key="name", label="item", fmt=None, default=""):
    """Let user pick from a list"""
    if not items:
        print(f"  No {label}s found.")
        return None
    for i, item in enumerate(items, 1):
        display = fmt(item) if fmt else item.get(name_key, "unknown")
        marker = " *" if str(i) == default else ""
        print(f"    {i}) {display}{marker}")
    choice = ask(f"Pick {label} (number)", default)
    if not choice.isdigit() or int(choice) < 1 or int(choice) > len(items):
        print("  Invalid choice.")
        return None
    return items[int(choice) - 1]

def header(title):
    print(f"\n{'═' * 60}\n  {title}\n{'═' * 60}")

# Load existing config
PREV = {}
if os.path.isfile(CONFIG_FILE):
    try:
        with open(CONFIG_FILE) as f:
            PREV = json.load(f)
        print(f"  Loaded existing config.json  values will be used as defaults")
    except (json.JSONDecodeError, OSError):
        pass

def cfg(path, fallback=""):
    """Get a value from existing config by dot-path"""
    obj = PREV
    for key in path.split("."):
        if isinstance(obj, dict):
            obj = obj.get(key, None)
        else:
            return fallback
    if obj is None:
        return fallback
    return obj


# Start run

print("\n  NKP Management Cluster | Configuration Wizard\n")
# Step 0: Prism Central connection
# env vars: PC_URL, PC_USER, PC_PASS
header("Prism Central Connection")
PC_URL = os.environ.get("PC_URL", "")
PC_USER = os.environ.get("PC_USER", "")
PC_PASS = os.environ.get("PC_PASS", "")

prev_url = cfg("nutanix.endpoint", "")
if prev_url and cfg("nutanix.port"):
    prev_url = f"https://{prev_url}:{cfg('nutanix.port')}"

if PC_URL:
    print(f"  Using PC_URL from env: {PC_URL}")
else:
    PC_URL = ask("Prism Central URL (https://ip:9440)", prev_url)
if not PC_URL.startswith("http"):
    PC_URL = f"https://{PC_URL}:9440"
PC_URL = PC_URL.rstrip("/")

if PC_USER:
    print(f"  Using PC_USER from env: {PC_USER}")
else:
    PC_USER = ask("Username", cfg("nutanix.username", "admin"))

if PC_PASS:
    print("  Using PC_PASS from env.")
else:
    PC_PASS = getpass.getpass("  Password: ")

# Auth test with retry on 401
# LAB with multiples Prism versions, 
# TODO Autodetect API Schema version
PC_OK = False
for _ in range(3):
    print("  Testing connection...")
    result, code = pc_get("clustermgmt/v4.0.b2/config/clusters?$limit=1", quiet=True)
    if result is None and code != 401:
        result, code = pc_get("clustermgmt/v4.0/config/clusters?$limit=1", quiet=True)
    if result and "data" in result:
        print("  Connected OK.")
        PC_OK = True
        break
    if code == 401:
        print("  401 Unauthorized — bad credentials.")
        retry = ask("Re-enter credentials? (yes/no)", "yes")
        if retry.lower() not in ("yes", "y"):
            break
        PC_USER = ask("Username", PC_USER)
        PC_PASS = getpass.getpass("  Password: ")
    else:
        print(f"  Could not connect (HTTP {code}).")
        break

if not PC_OK:
    print("  WARNING: No PC connection. You can still fill config manually.")

# Step 1: Deployment type
header("Deployment Type")
dtype = ask("Deployment type (connected/airgap)", cfg("deployment_type", "connected"))

# Airgap method: bundle (internal registry) vs external (pre-pushed to Harbor etc.)
airgap_method = ""
if dtype == "airgap":
    print("")
    print("  Air-gapped methods:")
    print("    bundle   — NKP creates internal registry from local tar files (recommended)")
    print("    external — You pre-push images to your own registry (Harbor, Nexus, etc.)")
    print("  These are mutually exclusive. Cannot use both.")
    print("")
    airgap_method = ask("Airgap method (bundle/external)", cfg("airgap_method", "external"))

# Step 2: Cluster basics
header("Cluster")
cluster_name = ask("Cluster name", cfg("cluster.name", "nkp-mgmt"))
cluster_hostname = ask("Cluster hostname (FQDN)", cfg("cluster.hostname", f"{cluster_name}.example.com"))
extra_sans = ask("Extra SANs for API cert (optional, comma-separated)", cfg("cluster.extra_sans", ""))

# Step 3: License
header("License")
license_type = ask("License tier (starter/pro/ultimate)", cfg("license.type", "starter"))

ntx_insecure = ask_yn("Skip PC TLS verification? (--insecure)", default=cfg("nutanix.insecure", True))
trust_bundle = ""
if not ntx_insecure:
    trust_bundle = ask("PC CA trust bundle path (--additional-trust-bundle)", cfg("nutanix.additional_trust_bundle", ""))

# Step 4: PE cluster
header("Prism Element Cluster")
prev_pe = cfg("nutanix.prism_element_cluster", "")
pe_name = ""
pe_uuid = ""
cluster_uuid_to_name = {}  # UUID → name for display in later steps

clusters = pc_get_first(
    "clustermgmt/v4.0.b2/config/clusters",
    "clustermgmt/v4.0/config/clusters",
)
if clusters and "data" in clusters:
    all_clusters = clusters["data"]
    # Build UUID→name map for all clusters
    for c in all_clusters:
        cid = c.get("extId", "")
        cname = c.get("name", "")
        if cid and cname:
            cluster_uuid_to_name[cid] = cname
    # Filter to AOS clusters only
    aos = [c for c in all_clusters if "AOS" in (c.get("config", {}).get("clusterFunction", []))]
    if aos:
        # Pre-select previous choice
        prev_idx = ""
        for i, c in enumerate(aos, 1):
            if c.get("name") == prev_pe:
                prev_idx = str(i)
        if prev_pe:
            print(f"  Previous: {prev_pe}")
        print("  Available PE clusters:")
        chosen = pick(aos, label="PE cluster", default=prev_idx)
        if chosen:
            pe_name = chosen["name"]
            pe_uuid = chosen.get("extId", "")
if not pe_name:
    pe_name = ask("PE cluster name (manual)", prev_pe)

# Step 5: Subnet (filtered to selected PE cluster)
header("Subnet")
prev_subnet = cfg("nutanix.subnet", "")
subnet_name = ""
subnets = pc_get_first(
    "networking/v4.0.b1/config/subnets",
    "networking/v4.0.a1/config/subnets",
    "networking/v4.0/config/subnets",
)
if subnets and "data" in subnets:
    subs = subnets["data"]
    if pe_uuid:
        subs = [s for s in subs if s.get("clusterReference") == pe_uuid]
    if subs:
        prev_idx = ""
        for i, s in enumerate(subs, 1):
            if s.get("name") == prev_subnet:
                prev_idx = str(i)
        def fmt_subnet(s):
            cname = cluster_uuid_to_name.get(s.get("clusterReference", ""), "?")
            return f"{s.get('name', '?')}  (cluster: {cname})"
        print(f"  Available subnets on {pe_name}:")
        chosen = pick(subs, label="subnet", fmt=fmt_subnet, default=prev_idx)
        if chosen:
            subnet_name = chosen["name"]
if not subnet_name:
    subnet_name = ask("Subnet name (manual)", prev_subnet)

# Step 6: Image (filtered to selected PE cluster)
header("Node Image (NIB)")
prev_image = cfg("images.nib_image", "")
nib_image = ""
images = pc_get_first(
    "vmm/v4.0.b1/content/images",
    "vmm/v4.0/content/images",
    "vmm/v4.0.a1/content/images",
)
if images and "data" in images:
    all_imgs = images["data"]
    if pe_uuid:
        all_imgs = [i for i in all_imgs if pe_uuid in (i.get("clusterLocationExtIds") or [])]
    nkp_imgs = [i for i in all_imgs if "nkp" in i.get("name", "").lower()]
    show = nkp_imgs if nkp_imgs else all_imgs
    if show:
        prev_idx = ""
        for i, img in enumerate(show, 1):
            if img.get("name") == prev_image:
                prev_idx = str(i)
        def fmt_image(img):
            locs = img.get("clusterLocationExtIds") or []
            names = [cluster_uuid_to_name.get(u, u[:8]) for u in locs]
            return f"{img.get('name', '?')}  (on: {', '.join(names)})"
        label = f"image on {pe_name}" if pe_uuid else "image"
        print(f"  Available images ({len(show)} shown):")
        chosen = pick(show, label=label, fmt=fmt_image, default=prev_idx)
        if chosen:
            nib_image = chosen["name"]
if not nib_image:
    nib_image = ask("Image name (manual)", prev_image or "nkp-rocky-9.5-release-cis-1.34.2-20250430150550.qcow2")

# Worker image defaults to same as CP
prev_w_image = cfg("images.worker_image", "")
if prev_w_image and prev_w_image != nib_image:
    worker_image = ask("Worker image (different from CP)", prev_w_image)
elif ask_yn("Use same image for workers?"):
    worker_image = nib_image
else:
    worker_image = ask("Worker image name", nib_image)

# Step 7: Storage container (filtered to selected PE cluster)
header("Storage Container")
prev_storage = cfg("nutanix.storage_container", "")
storage_name = ""
storage = pc_get_first(
    "storage/v4.0.a3/config/storage-containers",
    "storage/v4.0/config/storage-containers",
)
if storage and "data" in storage:
    conts = storage["data"]
    if pe_uuid:
        conts = [c for c in conts if c.get("clusterExtId") == pe_uuid]
    if conts:
        prev_idx = ""
        for i, c in enumerate(conts, 1):
            if c.get("name") == prev_storage:
                prev_idx = str(i)
        def fmt_storage(s):
            cname = cluster_uuid_to_name.get(s.get("clusterExtId", ""), "?")
            return f"{s.get('name', '?')}  (cluster: {cname})"
        print(f"  Available storage containers on {pe_name}:")
        chosen = pick(conts, label="storage container", fmt=fmt_storage, default=prev_idx)
        if chosen:
            storage_name = chosen["name"]
if not storage_name:
    storage_name = ask("Storage container name (manual)", prev_storage)

# Step 8: Networking
header("Networking")
vip = ask_ip("Control plane VIP", cfg("networking.control_plane_vip", ""))
lb_range = ask_ip_range("MetalLB IP range (start-end)", cfg("networking.metallb_ip_range", ""))
dns = ask_ip("DNS server (optional)", cfg("networking.dns_server", ""), required=False)
ntp = ask("NTP server (optional)", cfg("networking.ntp_server", ""))
pod_cidr = ask("Pod network CIDR", cfg("networking.pod_cidr", "192.168.0.0/16"))
service_cidr = ask("Service network CIDR", cfg("networking.service_cidr", "10.96.0.0/12"))

# Step 9: Node sizing license-based defaults & minimums
header("Node Sizing")
LICENSE_REQS = {
    "starter":  {"cp": 3, "cp_cpu": 4, "cp_mem": 8,  "cp_disk": 80, "w": 4, "w_cpu": 4,  "w_mem": 16, "w_disk": 80,
                 "min_cp": 1, "min_w": 2, "min_w_cpu": 4, "min_w_mem": 8},
    "pro":      {"cp": 3, "cp_cpu": 4, "cp_mem": 16, "cp_disk": 80, "w": 4, "w_cpu": 8,  "w_mem": 32, "w_disk": 80,
                 "min_cp": 3, "min_w": 4, "min_w_cpu": 8, "min_w_mem": 16},
    "ultimate": {"cp": 3, "cp_cpu": 8, "cp_mem": 16, "cp_disk": 80, "w": 6, "w_cpu": 8,  "w_mem": 32, "w_disk": 80,
                 "min_cp": 3, "min_w": 4, "min_w_cpu": 8, "min_w_mem": 32},
}
DEF = LICENSE_REQS.get(license_type, LICENSE_REQS["starter"])

print(f"  License: {license_type}")
print(f"  Recommended: CP {DEF['cp']}x ({DEF['cp_cpu']}vCPU/{DEF['cp_mem']}GB/{DEF['cp_disk']}GB) "
      f"| Workers {DEF['w']}x ({DEF['w_cpu']}vCPU/{DEF['w_mem']}GB/{DEF['w_disk']}GB)")
if ask_yn("Use recommended node sizing?"):
    cp_count, cp_vcpus, cp_mem, cp_disk = DEF["cp"], DEF["cp_cpu"], DEF["cp_mem"], DEF["cp_disk"]
    w_count, w_vcpus, w_mem, w_disk = DEF["w"], DEF["w_cpu"], DEF["w_mem"], DEF["w_disk"]
else:
    cp_count = ask_int("Control plane count (1/3/5)", DEF["cp"])
    cp_vcpus = ask_int("Control plane vCPUs", DEF["cp_cpu"])
    cp_mem = ask_int("Control plane memory GB", DEF["cp_mem"])
    cp_disk = ask_int("Control plane disk GB", DEF["cp_disk"])
    w_count = ask_int("Worker count", DEF["w"])
    w_vcpus = ask_int("Worker vCPUs", DEF["w_cpu"])
    w_mem = ask_int("Worker memory GB", DEF["w_mem"])
    w_disk = ask_int("Worker disk GB", DEF["w_disk"])


# Validate against license minimums
warnings = []
if cp_count < DEF["min_cp"]:
    warnings.append(f"CP count {cp_count} < minimum {DEF['min_cp']} for {license_type}")
if cp_count > 1 and cp_count % 2 == 0:
    warnings.append(f"CP count {cp_count} is even — must be odd (1/3/5/7) for etcd quorum")
if w_count < DEF["min_w"]:
    warnings.append(f"Worker count {w_count} < minimum {DEF['min_w']} for {license_type}")
if w_vcpus < DEF["min_w_cpu"]:
    warnings.append(f"Worker vCPUs {w_vcpus} < minimum {DEF['min_w_cpu']} for {license_type}")
if w_mem < DEF["min_w_mem"]:
    warnings.append(f"Worker memory {w_mem}GB < minimum {DEF['min_w_mem']}GB for {license_type}")
if warnings:
    print("")
    for w in warnings:
        print(f"  WARNING: {w}")
    if not ask_yn("Continue with these values anyway?", default=False):
        print("  Aborted. Re-run to fix sizing.")
        raise SystemExit(1)


# Step 10: Registry
header("Registry")
mirror_url = mirror_user = mirror_ca = reg_url = reg_user = reg_ca = ""
bundle_dir = ""

if dtype == "airgap" and airgap_method == "bundle":
    # Internal registry  NKP creates it from bundles, no registry flags needed
    print("  Bundle mode: NKP will create an internal registry from local tar files.")
    print("  No registry-mirror flags needed. Pass --bundle to nkp create cluster.")
    default_bundle = cfg("bundle_dir", os.path.join(SCRIPT_DIR, "..", "nkp-airgap-bundle"))
    bundle_dir = ask("Bundle directory", default_bundle)

elif dtype == "airgap" and airgap_method == "external":
    # External registry push first, then use --registry-mirror-url
    print("  External registry: images must be pre-pushed (0_push-airgap-bundle.sh).")
    print("  NKP will use --registry-mirror-url to pull from your registry.")
    mirror_url = ask("Registry mirror URL (where NKP pulls images from)", cfg("registry.mirror_url", ""))
    mirror_user = ask("Mirror username", cfg("registry.mirror_username", ""))
    mirror_ca = ask("Mirror CA cert path (optional)", cfg("registry.mirror_ca_cert_path", ""))
    # registry_url is for push scripts, not used by nkp create in airgap
    reg_url = ask("Registry URL (for push scripts, can be same as mirror)", cfg("registry.registry_url", mirror_url))
    reg_user = ask("Registry push username (Enter if same)", cfg("registry.registry_username", mirror_user))
    reg_ca = ask("Registry CA cert path (Enter if same)", cfg("registry.ca_cert_path", mirror_ca))

elif ask_yn("Configure a registry mirror? (avoids Docker Hub rate limits)", default=bool(cfg("registry.mirror_url"))):
    mirror_url = ask("Registry mirror URL", cfg("registry.mirror_url", "registry-1.docker.io"))
    mirror_user = ask("Mirror username (optional)", cfg("registry.mirror_username", ""))
    mirror_ca = ask("Mirror CA cert path (optional)", cfg("registry.mirror_ca_cert_path", ""))

# Step 11: Proxy
header("Proxy")
proxy_http = proxy_https = proxy_no = ""
has_prev_proxy = bool(cfg("proxy.http_proxy") or cfg("proxy.https_proxy"))
if ask_yn("Configure proxy?", default=has_prev_proxy):
    proxy_http = ask("HTTP proxy", cfg("proxy.http_proxy", ""))
    proxy_https = ask("HTTPS proxy", cfg("proxy.https_proxy", ""))
    proxy_no = ask("No-proxy list", cfg("proxy.no_proxy", ""))

# Step 12: Options
header("Options")
ssh_user = ask("SSH username", cfg("options.ssh_username", "konvoy"))
ssh_key = ask("SSH public key file", cfg("options.ssh_public_key_file", "~/.ssh/id_rsa.pub"))
prev_self = cfg("options.self_managed", True)
self_managed = ask_yn("Self-managed cluster?", default=prev_self)
cp_cats = ask("CP PC categories (optional)", cfg("options.cp_categories", ""))
w_cats = ask("Worker PC categories (optional)", cfg("options.worker_categories", ""))

# CSI options
header("CSI Storage")
prev_csi = cfg("options.csi_hypervisor_attached", True)
csi_hv = ask_yn("CSI hypervisor-attached volumes?", default=prev_csi)
csi_fs = ask("CSI filesystem (ext4/xfs)", cfg("options.csi_file_system", "ext4"))
csi_reclaim = ask("CSI reclaim policy (Delete/Retain)", cfg("options.csi_reclaim_policy", "Delete"))
csi_flash = ask_yn("CSI flash mode?", default=cfg("options.csi_flash_mode", False))

# Bootstrap image
kind_image = ""
if dtype == "airgap" and airgap_method == "external":
    # External registry --kind-cluster-image pointing to registry
    # OR docker load the bootstrap tar (then flag not needed)
    header("Bootstrap Image")
    print("  External registry: either docker-load the bootstrap image locally")
    print("  OR point --kind-cluster-image to your registry.")
    default_kind = cfg("options.kind_cluster_image", "")
    if not default_kind and mirror_url:
        mirror_host = mirror_url.replace("https://", "").replace("http://", "").rstrip("/")
        default_kind = f"{mirror_host}/mesosphere/konvoy-bootstrap"
    kind_image = ask("Bootstrap image (Enter to skip if docker-loaded)", default_kind)
elif dtype == "airgap" and airgap_method == "bundle":
    # Bundle mode: bootstrap image loaded from bundle, no flag needed
    pass
else:
    kind_image = ask("Bootstrap image override (optional, Enter to skip)", cfg("options.kind_cluster_image", ""))


##### Save
# Extract PC host and port from URL
parsed_pc = urllib.parse.urlparse(PC_URL)
pc_host = parsed_pc.hostname or PC_URL
pc_port = parsed_pc.port or 9440

config = {
    "deployment_type": dtype,
    "airgap_method": airgap_method,
    "cluster": {
        "name": cluster_name,
        "hostname": cluster_hostname,
        "extra_sans": extra_sans,
    },
    "nutanix": {
        "endpoint": pc_host,
        "port": pc_port,
        "username": PC_USER,
        "insecure": ntx_insecure,
        "additional_trust_bundle": trust_bundle,
        "prism_element_cluster": pe_name,
        "subnet": subnet_name,
        "storage_container": storage_name,
    },
    "networking": {
        "control_plane_vip": vip,
        "metallb_ip_range": lb_range,
        "dns_server": dns,
        "ntp_server": ntp,
        "pod_cidr": pod_cidr,
        "service_cidr": service_cidr,
    },
    "nodes": {
        "control_plane": {"count": cp_count, "vcpus": cp_vcpus, "memory_gb": cp_mem, "disk_gb": cp_disk},
        "worker": {"count": w_count, "vcpus": w_vcpus, "memory_gb": w_mem, "disk_gb": w_disk},
    },
    "images": {
        "nib_image": nib_image,
        "worker_image": worker_image,
    },
    "registry": {
        "mirror_url": mirror_url,
        "mirror_username": mirror_user,
        "mirror_ca_cert_path": mirror_ca,
        "registry_url": reg_url,
        "registry_username": reg_user,
        "ca_cert_path": reg_ca,
    },
    "proxy": {"http_proxy": proxy_http, "https_proxy": proxy_https, "no_proxy": proxy_no},
    "options": {
        "ssh_username": ssh_user,
        "ssh_public_key_file": ssh_key,
        "self_managed": self_managed,
        "cp_categories": cp_cats,
        "worker_categories": w_cats,
        "csi_hypervisor_attached": csi_hv,
        "csi_file_system": csi_fs,
        "csi_reclaim_policy": csi_reclaim,
        "csi_flash_mode": csi_flash,
        "kind_cluster_image": kind_image,
    },
    "bundle_dir": bundle_dir,
    "license": {"type": license_type},
}

# dump and save
header("Review")
print(json.dumps(config, indent=2))

save = ask("\nSave to config.json? (yes/no)", "yes")
if save.lower() in ("yes", "y"):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"\n  Saved to {CONFIG_FILE}")
    print("  Next: ./1_preflight.sh")
else:
    print("  Not saved.")