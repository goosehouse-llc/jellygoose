# The made-up album in the App Store's music screenshots: Juniper Gale, "Northbound" (2025).
# Made up so that no real artist's work is on the store page. Eight songs of ordinary length
# (soft tones: the screenshots are silent), the cover drawn in cover.html (render it to
# cover.png first, e.g. with WebKit at 1000 points wide on a 2x screen), and lyrics for
# the title song, timed so the chorus is lit about 50 seconds in.
#
# usage: python3 make.py <a music library folder on a test server>
# then scan that library; the test (StoreShotsUITests.test15Music and
# StoreShotsiOSUITests.test11Music) is given the album's id as MUSIC_ALBUM.
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ARTIST, ALBUM, YEAR, GENRE = "Juniper Gale", "Northbound", 2025, "Indie Pop"
DEST = os.path.join(sys.argv[1], ARTIST, f"{ALBUM} ({YEAR})")
SONGS = [("Northbound", 222), ("Paper Kites", 198), ("Slow Tide", 245), ("Lanterns", 211),
         ("Wide Open Water", 252), ("Golden Hour", 227), ("Late Train Home", 238), ("Quiet Fields", 266)]
LYRICS = {"Northbound": [
    (9, "Packed the car before the light"), (14, "Coffee steaming on the dash"),
    (19, "Every mile a little brighter"), (24, "Every town a little less"),
    (29, "There's a river by the highway"), (34, "Running north the way we go"),
    (39, "Windows down and singing louder"), (44, "Every song we used to know"),
    (50, "We're northbound, northbound"), (55, "Chasing where the summer goes"),
    (60, "Northbound, northbound"), (65, "Following the geese back home"),
    (71, ""), (84, "Little towns with painted signs"), (89, "Diners open all night long"),
    (94, "You're asleep against the window"), (99, "I keep driving, keep it on"),
    (105, "We're northbound, northbound"), (110, "Chasing where the summer goes"),
    (115, "Northbound, northbound"), (120, "Following the geese back home")]}

os.makedirs(DEST, exist_ok=True)
subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", "-Z", "1400",
                os.path.join(HERE, "cover.png"), "--out", os.path.join(DEST, "folder.jpg")], check=True, capture_output=True)
for n, (title, secs) in enumerate(SONGS, 1):
    root = 174.6 * 2 ** ((n * 5 % 12) / 12)
    expr = (f"0.16*sin(2*PI*{root}*t)*(0.75+0.25*sin(2*PI*0.2*t))"
            f"+0.09*sin(2*PI*{root * 1.26}*t)+0.07*sin(2*PI*{root * 1.5}*t)*gt(mod(t,2),1)")
    out = os.path.join(DEST, f"{n:02d} {title}.m4a")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"aevalsrc=exprs='{expr}|{expr}':s=44100:d={secs}",
                    "-c:a", "aac", "-b:a", "64k", "-af", f"afade=t=in:d=1,afade=t=out:st={secs - 2}:d=2",
                    "-metadata", f"title={title}", "-metadata", f"artist={ARTIST}", "-metadata", f"album_artist={ARTIST}",
                    "-metadata", f"album={ALBUM}", "-metadata", f"date={YEAR}", "-metadata", f"genre={GENRE}",
                    "-metadata", f"track={n}/{len(SONGS)}", out], check=True)
    if title in LYRICS:
        with open(out.rsplit(".", 1)[0] + ".lrc", "w") as fh:
            fh.write(f"[ti:{title}]\n[ar:{ARTIST}]\n[al:{ALBUM}]\n")
            for s, line in LYRICS[title]:
                fh.write(f"[{s // 60:02d}:{s % 60:02d}.00]{line}\n")
print("made", DEST)
