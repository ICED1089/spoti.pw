#!/usr/bin/env python3
"""Read-only, standalone reproduction of spoti.pw's Apple artist-logo lookup.

Only tests public Apple Music web/catalog responses; never touches a Spotify IPA.
Do not print or save the Apple Music web-player bearer token.
"""
import base64
import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from io import BytesIO

BROWSER = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
           "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
BROWSE = "https://music.apple.com/us/browse"
SEARCH = "https://amp-api.music.apple.com/v1/catalog/us/search"
ARTISTS = [
    "Taylor Swift", "Michael Jackson", "Billie Eilish", "Beyoncé",
    "The Weeknd", "Ariana Grande", "Sabrina Carpenter", "Bad Bunny",
    "Drake", "Olivia Rodrigo", "Coldplay", "Kendrick Lamar",
]


def request(url, token=None, timeout=18):
    headers = {"User-Agent": BROWSER, "Accept": "*/*"}
    if token:
        headers.update({"Authorization": "Bearer " + token,
                        "Origin": "https://music.apple.com"})
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read(12 * 1024 * 1024), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(2048), exc.headers.get("Content-Type", "")


def plain(name):
    name = unicodedata.normalize("NFD", name.casefold())
    name = "".join(c for c in name if not unicodedata.combining(c))
    return " ".join(re.findall(r"[^\W_]+", name))


def json_data(raw):
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {}


def jwt_issuer(token):
    try:
        part = token.split(".")[1].replace("-", "+").replace("_", "/")
        part += "=" * (-len(part) % 4)
        return json.loads(base64.b64decode(part)).get("iss")
    except Exception:
        return None


def web_token():
    status, html, _ = request(BROWSE)
    if status != 200:
        raise RuntimeError(f"web player HTTP {status}")
    page = html.decode("utf-8", "replace")
    asset = (re.search(r"/assets/index~[^\"']+\.js", page) or
             re.search(r"/assets/index[^\"']*\.js", page))
    if not asset:
        raise RuntimeError("web player missing index JS URL (token bootstrap failed)")
    asset_url = urllib.parse.urljoin(BROWSE, asset.group(0))
    status, data, _ = request(asset_url)
    if status != 200:
        raise RuntimeError(f"web player index JS HTTP {status}")
    code = data.decode("utf-8", "replace")
    candidates = re.findall(r"""["'](eyJ[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]+)["']""", code)
    valid = [item for item in candidates if jwt_issuer(item) == "AMPWebPlay"]
    if not valid:
        raise RuntimeError(f"no AMPWebPlay token in index JS ({len(candidates)} candidates)")
    return valid[0]


def logo_url(attrs):
    editorial = attrs.get("editorialArtwork")
    if not isinstance(editorial, dict):
        return None, "no editorialArtwork"
    rendition = editorial.get("musicContentColorLogoTrimmed") or editorial.get("musicContentColorLogo")
    template = rendition.get("url") if isinstance(rendition, dict) else rendition
    if not isinstance(template, str) or not template:
        return None, "no recognized logo rendition"
    url = template.replace("{w}", "1200").replace("{h}", "480").replace("{f}", "png")
    parts = urllib.parse.urlsplit(url)
    if "{" in url or "}" in url or parts.scheme != "https" or not parts.hostname:
        return None, "unresolved or invalid HTTPS template"
    return url, "recognized rendition"


def matte_result(raw):
    from PIL import Image
    try:
        img = Image.open(BytesIO(raw))
        img.load()
        width, height = img.size
        if not width or not height or width > 2048 or height > 2048:
            return f"REJECTED dimensions={width}x{height}"
        rgba = img.convert("RGBA")
        corners = [rgba.getpixel((x, y)) for x, y in (
            (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1))]
        if any(pixel[3] < 200 for pixel in corners):
            return f"ACCEPTED transparency {width}x{height} ({img.format})"
        if not all(a >= 245 and min(r, g, b) >= 242 for r, g, b, a in corners):
            return f"REJECTED opaque/nonwhite corners {width}x{height} ({img.format})"
        samples = [rgba.getpixel((i % width, i // width)) for i in range(0, width * height, 8)]
        if not any(min(p[:3]) < 235 for p in samples):
            return f"REJECTED no foreground pixels {width}x{height}"
        return f"ACCEPTED removable white matte {width}x{height} ({img.format})"
    except Exception as exc:
        return f"REJECTED image decode: {type(exc).__name__}"


def probe(artist, token):
    url = SEARCH + "?" + urllib.parse.urlencode({
        "term": artist, "types": "artists", "limit": 8, "extend": "editorialArtwork"})
    status, body, _ = request(url, token)
    if status != 200:
        return {"artist": artist, "result": "SEARCH_FAILED", "searchHTTP": status}
    result = json_data(body)
    hits = result.get("results", {}).get("artists", {}).get("data", [])
    exact = [h for h in hits if plain(h.get("attributes", {}).get("name", "")) == plain(artist)]
    if not exact:
        return {"artist": artist, "result": "NO_EXACT_NAME_MATCH", "searchHTTP": status,
                "searchCount": len(hits)}
    chosen = exact[0]
    found_url = None
    reason = ""
    for hit in exact:
        found_url, reason = logo_url(hit.get("attributes", {}))
        if found_url:
            chosen = hit
            break
    detail_status = "not_requested"
    detail_keys = []
    if not found_url and str(chosen.get("id", "")).isdigit():
        detail = ("https://amp-api.music.apple.com/v1/catalog/us/artists/" +
                  urllib.parse.quote(str(chosen["id"])) + "?extend=editorialArtwork")
        detail_status, raw, _ = request(detail, token)
        if detail_status == 200:
            artists = json_data(raw).get("data", [])
            attrs = artists[0].get("attributes", {}) if artists else {}
            detail_keys = list((attrs.get("editorialArtwork") or {}).keys())
            if plain(attrs.get("name", "")) == plain(artist):
                found_url, reason = logo_url(attrs)
            else:
                reason = "detail artist name mismatch"
        else:
            return {"artist": artist, "result": "DETAIL_FAILED",
                    "searchHTTP": status, "detailHTTP": detail_status}
    if not found_url:
        return {"artist": artist, "result": "NO_EXPOSED_LOGO_OR_UNSUPPORTED_KEY",
                "searchHTTP": status, "detailHTTP": detail_status,
                "searchEditorialKeys": list((chosen.get("attributes", {}).get("editorialArtwork") or {}).keys()),
                "detailEditorialKeys": detail_keys, "reason": reason}
    img_status, img, mime = request(found_url, timeout=20)
    if img_status != 200:
        return {"artist": artist, "result": "IMAGE_HTTP_FAILED", "imageHTTP": img_status}
    if len(img) > 6 * 1024 * 1024:
        return {"artist": artist, "result": "IMAGE_TOO_LARGE", "bytes": len(img)}
    outcome = matte_result(img)
    return {"artist": artist, "result": "LOGO_ACCEPTED" if outcome.startswith("ACCEPTED") else "LOGO_REJECTED",
            "imageHTTP": img_status, "imageType": mime.split(";")[0],
            "matte": outcome, "source": "search" if detail_status == "not_requested" else "detail"}


def selftest():
    from PIL import Image
    assert plain("Beyoncé") == "beyonce"
    sample = {"editorialArtwork": {"musicContentColorLogoTrimmed": {"url":
              "https://example.com/{w}x{h}.{f}"}}}
    assert logo_url(sample)[0] == "https://example.com/1200x480.png"
    assert logo_url({"artwork": sample})[0] is None
    for rgba, expected in [((255, 255, 255, 0), "ACCEPTED"),
                           ((0, 0, 0, 255), "REJECTED")]:
        picture = Image.new("RGBA", (40, 20), rgba)
        data = BytesIO()
        picture.save(data, format="PNG")
        assert matte_result(data.getvalue()).startswith(expected)
    print("ISOLATED_PARSER_TESTS=PASS")


if __name__ == "__main__":
    selftest()
    try:
        token = web_token()
        print("APPLE_WEB_PLAYER_TOKEN=AVAILABLE (value withheld)")
    except Exception as exc:
        print("TOKEN_BOOTSTRAP_FAILED=" + str(exc))
        sys.exit(2)
    for artist in ARTISTS:
        try:
            print(json.dumps(probe(artist, token), ensure_ascii=False, sort_keys=True), flush=True)
        except Exception as exc:
            print(json.dumps({"artist": artist, "result": "TEST_ERROR",
                              "errorType": type(exc).__name__, "message": str(exc)[:180]},
                             ensure_ascii=False), flush=True)
        time.sleep(0.4)
