"""Minimal App Store Connect API client: signs a JWT with the team key using
openssl (no Python packages needed) and fetches or installs things.

  python3 scripts/asc.py GET /v1/apps
  python3 scripts/asc.py install-profile "Lantern App Store"
  python3 scripts/asc.py POST /v1/profiles body.json
"""
import base64, json, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, tempfile, os
KEY_ID="QLJD26FTGP"; ISSUER="83314295-c12b-4e10-a39d-35bee3e8ffc7"; P8=os.path.expanduser("~/.private_keys/AuthKey_QLJD26FTGP.p8")
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token():
    h=b64(json.dumps({"alg":"ES256","kid":KEY_ID,"typ":"JWT"}).encode()); now=int(time.time())
    p=b64(json.dumps({"iss":ISSUER,"iat":now,"exp":now+900,"aud":"appstoreconnect-v1"}).encode())
    msg=f"{h}.{p}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(msg); mp=f.name
    der=subprocess.check_output(["openssl","dgst","-sha256","-sign",P8,mp]); os.unlink(mp)
    # DER -> raw r||s
    i=2; assert der[0]==0x30
    assert der[i]==2; l=der[i+1]; r=der[i+2:i+2+l]; i=i+2+l
    assert der[i]==2; l=der[i+1]; s=der[i+2:i+2+l]
    r=r[-32:].rjust(32,b"\0"); s=s[-32:].rjust(32,b"\0")
    return f"{h}.{p}.{b64(r+s)}"
def get(path):
    req=urllib.request.Request("https://api.appstoreconnect.apple.com"+path, headers={"Authorization":"Bearer "+token()})
    return json.load(urllib.request.urlopen(req))
def post(path, body):
    req=urllib.request.Request("https://api.appstoreconnect.apple.com"+path, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization":"Bearer "+token(), "Content-Type":"application/json"})
    try: return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e: raise SystemExit(f"{e.code}: {e.read().decode()[:800]}")
def install_profile(name):
    """Download a provisioning profile by name into Xcode's profile folders."""
    d = get("/v1/profiles?filter[name]=" + urllib.parse.quote(name) + "&fields[profiles]=name,uuid,profileContent,profileType")
    if not d.get("data"): raise SystemExit("no profile named " + name)
    a = d["data"][0]["attributes"]; content = base64.b64decode(a["profileContent"])
    # macOS reads .provisionprofile; iOS profiles are .mobileprovision.
    ext = ".provisionprofile" if a.get("profileType", "").startswith("MAC") else ".mobileprovision"
    for folder in ["~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles"]:
        folder = os.path.expanduser(folder); os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, a["uuid"] + ext), "wb").write(content)
    print("installed", a["name"], a["uuid"])
if __name__ == "__main__":
    if sys.argv[1] == "install-profile": install_profile(sys.argv[2])
    elif sys.argv[1] == "GET": print(json.dumps(get(sys.argv[2]), indent=1))
    elif sys.argv[1] == "POST": print(json.dumps(post(sys.argv[2], json.load(open(sys.argv[3]))), indent=1))
    else: print(json.dumps(get(sys.argv[1]), indent=1)[:int(sys.argv[2]) if len(sys.argv) > 2 else 4000])
