"""Resolve an official Windows ISO download URL: msdl.py PAGE LANGUAGE

Uses the same Microsoft software-download API as the download page (and
Fido/Mido/Rufus). PAGE is the page slug, e.g. windows10ISO or windows11;
LANGUAGE is as listed on the page, e.g. "English", "English International",
"German". Prints the (time-limited) x64 ISO URL.
"""
import http.cookiejar
import json
import re
import sys
import urllib.parse
import urllib.request
import uuid

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
API = "https://www.microsoft.com/software-download-connector/api/"
PROFILE = "606624d44113"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    page, language = sys.argv[1], sys.argv[2]
    page_url = "https://www.microsoft.com/en-us/software-download/" + page
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def get(url, referer=None):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-US"})
        if referer:
            req.add_header("Referer", referer)
        with opener.open(req, timeout=60) as r:
            return r.read().decode("utf-8", "replace")

    def api(method, **params):
        params.update(profile=PROFILE, friendlyFileName="undefined", Locale="en-US", sessionID=session)
        body = get(API + method + "?" + urllib.parse.urlencode(params), referer=page_url)
        try:
            data = json.loads(body)
        except ValueError:
            sys.exit("msdl: Microsoft returned an unexpected response (download blocked or API changed)")
        errors = (data.get("ValidationContainer") or {}).get("Errors") or data.get("Errors") or []
        if errors:
            if any("Sentinel" in e.get("Key", "") for e in errors):
                sys.exit("msdl: Microsoft rejected the automated download request (bot protection, "
                         "often temporary or tied to your IP/VPN). Download the ISO manually from "
                         + page_url)
            sys.exit("msdl: " + "; ".join(e.get("Value", str(e)) for e in errors))
        return data

    html = get(page_url)
    editions = re.findall(r'<option value="(\d+)">([^<]*)', html)
    if not editions:
        sys.exit("msdl: no product found on " + page_url)
    edition = editions[0][0]  # the page lists just the x64 multi-edition ISO

    session = str(uuid.uuid4())
    # Registers the session id; the API refuses unknown sessions.
    get("https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=" + session)

    skus = api("getskuinformationbyproductedition", ProductEditionId=edition, SKU="undefined")["Skus"]
    sku = next((s for s in skus if s["Language"] == language), None)
    if sku is None:
        sys.exit("msdl: language %r not offered; choose one of: %s"
                 % (language, ", ".join(sorted(s["Language"] for s in skus))))

    links = api("GetProductDownloadLinksBySku", productEditionId="undefined", SKU=sku["Id"])
    uris = [o["Uri"] for o in links.get("ProductDownloadOptions", []) if "x64" in o["Uri"]]
    if not uris:
        sys.exit("msdl: no x64 download link returned")
    print(uris[0])


if __name__ == "__main__":
    main()
