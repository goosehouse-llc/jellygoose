# Five made-up films for the throwaway server's Films library, for App Store pictures with no
# one's real films in them: artwork from out/, details in an NFO, and a video file of the film's
# length that is one still frame (small). Then the library is scanned and each film is put
# part-way watched for the goose account, Lantern Bay last, so it heads Continue Watching.
import json, os, subprocess, sys, time, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone
HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "..", "..", "..", "build", "uitest", "localjf", "media", "movies")
FILMS = [  # key, title, year, minutes, rating, stars, genres, tagline, plot, watched share
    ("lantern", "Lantern Bay", 2025, 118, "PG-13", 7.9, ["Mystery", "Drama"],
     "Every light on the water is a promise.",
     "Twenty years after the harbour went dark, the lanterns come back to Lantern Bay, one more every night, and the lighthouse keeper's daughter sets out to find who is lighting them.", 0.42),
    ("city", "City of Small Hours", 2024, 101, "PG-13", 7.6, ["Drama"],
     "Everyone is someone else after midnight.",
     "A night-shift taxi driver, a jazz pianist and a sleepless architect cross paths across one long night in a city that never quite goes dark.", 0.63),
    ("planets", "Paper Planets", 2024, 94, "PG", 7.4, ["Animation", "Family", "Adventure"],
     "The universe is bigger when you fold it yourself.",
     "Two sisters build a cardboard rocket in their attic and wake up in a solar system made entirely of paper, where every planet can be unfolded.", 0.25),
    ("glass", "Glasswater", 2023, 106, "R", 7.1, ["Thriller"],
     "The lake keeps everything.",
     "A diver hired to search a still mountain lake finds the water is hiding more than one disappearance, and that the town above it would rather it stayed hidden.", 0.51),
    ("canyon", "Red Canyon Run", 2022, 112, "PG-13", 6.9, ["Adventure", "Action"],
     "Three days. Four hundred miles. One road out.",
     "When a flash flood cuts off the only town for a hundred miles, a former rally driver has three days to get a convoy of strangers across the canyon.", 0.37),
]
BASE = "http://127.0.0.1:8096"
HDR = 'MediaBrowser Client="rig", Device="mac", DeviceId="rig-films-1", Version="1"'


def call(method, path, body=None, token=None, q=None):
    if q: path += "?" + urllib.parse.urlencode(q)
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", "Authorization": HDR + (f', Token="{token}"' if token else "")})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read(); return json.loads(raw) if raw else None


def esc(s): return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


for key, title, year, minutes, rating, stars, genres, tagline, plot, _ in FILMS:
    d = os.path.join(LIB, f"{title} ({year})")
    os.makedirs(d, exist_ok=True)
    video = os.path.join(d, f"{title} ({year}).mp4")
    if not os.path.exists(video):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x101020:s=1280x720:r=0.1",
                        "-t", str(minutes * 60), "-c:v", "libx264", "-preset", "ultrafast", "-tune", "stillimage",
                        "-crf", "40", "-pix_fmt", "yuv420p", video], check=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", f"{HERE}/out/{key}-backdrop.png", "--out", f"{d}/backdrop.jpg"], check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", f"{HERE}/out/{key}-poster.png", "--out", f"{d}/poster.jpg"], check=True, capture_output=True)
    if os.path.exists(f"{HERE}/out/{key}-logo.png"):
        subprocess.run(["cp", f"{HERE}/out/{key}-logo.png", f"{d}/logo.png"], check=True)
    with open(os.path.join(d, "movie.nfo"), "w") as fh:
        fh.write("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n<movie>\n")
        fh.write(f"  <title>{esc(title)}</title>\n  <year>{year}</year>\n  <premiered>{year}-04-18</premiered>\n")
        fh.write(f"  <tagline>{esc(tagline)}</tagline>\n  <plot>{esc(plot)}</plot>\n  <mpaa>{rating}</mpaa>\n")
        fh.write(f"  <rating>{stars}</rating>\n  <runtime>{minutes}</runtime>\n")
        for g in genres: fh.write(f"  <genre>{g}</genre>\n")
        fh.write("</movie>\n")
    print("folder", d)

auth = call("POST", "/Users/AuthenticateByName", {"Username": "goose", "Pw": "goose"})
t, uid = auth["AccessToken"], auth["User"]["Id"]
films_lib = [v for v in call("GET", "/Library/VirtualFolders", token=t) if v["Name"] == "Films"][0]["ItemId"]
call("POST", f"/Items/{films_lib}/Refresh", {}, t, {"Recursive": "true", "ImageRefreshMode": "Default", "MetadataRefreshMode": "Default"})
ids = {}
for _ in range(60):
    time.sleep(3)
    found = call("GET", "/Items", token=t, q={"userId": uid, "parentId": films_lib, "recursive": "true", "includeItemTypes": "Movie",
                                              "fields": "Taglines,OfficialRating,ProductionYear"})["Items"]
    ids = {i["Name"]: i for i in found}
    if all(f[1] in ids and ids[f[1]].get("RunTimeTicks") for f in FILMS): break
now = datetime.now(timezone.utc)
for n, (key, title, year, minutes, rating, stars, genres, tagline, plot, share) in enumerate(FILMS):
    item = ids.get(title)
    if not item: print("MISSING", title); continue
    ticks = int(item["RunTimeTicks"] * share)
    played = (now - timedelta(hours=n + 1)).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
    call("POST", f"/UserItems/{item['Id']}/UserData", {"PlaybackPositionTicks": ticks, "LastPlayedDate": played, "Played": False}, t, {"userId": uid})
    print(item["Id"], title, item.get("ProductionYear"), item.get("OfficialRating"), item.get("CommunityRating"),
          round(item["RunTimeTicks"] / 6e8), "min", (item.get("Taglines") or [""])[0][:40], item.get("ImageTags", {}).keys())
resume = call("GET", "/UserItems/Resume", token=t, q={"userId": uid, "limit": 8})["Items"]
print("Continue Watching:", [i["Name"] for i in resume])
call("POST", "/Sessions/Logout", {}, t)
