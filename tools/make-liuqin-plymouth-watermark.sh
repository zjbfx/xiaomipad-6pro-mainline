#!/bin/sh
# Regenerate the liuqin boot splash's watermark.
#
# The splash uses the Fedora lockup the way the rest of Fedora does -- blue
# badge, white wordmark -- which is what /usr/share/pixmaps/fedora-gdm-logo.png
# and Plymouth's own spinner watermark both look like.  fedora-logos ships that
# lockup only as two single-colour SVGs (fedora_logo.svg is all blue,
# fedora_logo_darkbackground.svg is all white) and never in the two-colour form
# at a usable resolution, so this takes the badge from the blue one and the
# wordmark from the white one.  The two files are the same artwork on the same
# canvas -- their alpha masks come out byte-identical -- so the splice lands
# exactly, and this script checks that before trusting it.
#
# The .svg canvas also carries a lot of padding.  Trim it: without the trim the
# lockup is 400x183, aspect 2.19, against the 3.4 the real Fedora artwork uses,
# and the logo renders noticeably smaller than its width suggests.
#
# Not wired into the build: the result is committed, and this only needs
# re-running when the artwork or the size changes.
#
# Usage: tools/make-liuqin-plymouth-watermark.sh [width]   (default 360)
set -eu

width=${1:-360}
logos=${FEDORA_LOGOS:-/usr/share/fedora-logos}
out="$(dirname "$0")/../device/gnome-overlay/usr/share/plymouth/themes/liuqin/watermark.png"

# Plymouth draws the watermark at its native pixel size, into two-step's
# logical space on this device: 1440x900, because the panel is mounted rotated
# and the cmdline declares panel_orientation=right_side_up (the DRM head is
# 1800x2880 physical at device scale 2).  A number here is therefore twice that
# many physical pixels.  Width 152 puts the lockup at 10.6% of the logical
# width; the theme's .96 vertical alignment sits it near the bottom edge.
case $width in
	''|*[!0-9]*) echo "usage: $0 [width]" >&2; exit 2 ;;
esac

for f in "$logos/fedora_logo.svg" "$logos/fedora_logo_darkbackground.svg"; do
	if [ ! -f "$f" ]; then
		echo "error: $f not found (Fedora host with fedora-logos required)" >&2
		exit 1
	fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for name in fedora_logo fedora_logo_darkbackground; do
	magick -background none -density 400 "$logos/$name.svg" \
		-resize 400x -depth 8 "PNG32:$tmp/$name.png"
	magick "$tmp/$name.png" -alpha extract "$tmp/$name.alpha"
done

# Compare the pixels, not the files: the PNG encoder stamps a tIME chunk, so
# two identical renders can still differ byte for byte.
ae=$(magick compare -metric AE "$tmp/fedora_logo.alpha" \
	"$tmp/fedora_logo_darkbackground.alpha" null: 2>&1)
ae=${ae%% *}   # ImageMagick prints "0 (0)", not "0"

if [ "$ae" != 0 ]; then
	echo "error: fedora_logo.svg and fedora_logo_darkbackground.svg no longer share" >&2
	echo "       a geometry, so the badge/wordmark splice below would be misaligned." >&2
	exit 1
fi

imgw=$(identify -format '%w' "$tmp/fedora_logo.alpha")
imgh=$(identify -format '%h' "$tmp/fedora_logo.alpha")

# Where does the badge end and the wordmark begin?  The badge is the first blob
# of ink; the first all-transparent column after it is the gap between the two.
set -- $(magick "$tmp/fedora_logo.alpha" -resize "${imgw}x1!" -depth 8 txt:- |
	awk '
	NR > 1 {
		v = $0; sub(/.*gray\(/, "", v); sub(/\).*/, "", v)
		col = NR - 2
		if (v + 0 > 0) { if (start == "") start = col }
		else if (start != "" && gap == "") { gap = col; end = col - 1 }
	}
	END { printf "%d %d %d", start, end, gap }
	')
badge_start=$1 badge_end=$2 gap_start=$3

if [ -z "$badge_start" ] || [ -z "$gap_start" ] || [ "$gap_start" -le "$badge_end" ]; then
	echo "error: could not find a badge/wordmark gap in the rendered lockup" >&2
	exit 1
fi

badge_w=$((badge_end - badge_start + 1))

magick "$tmp/fedora_logo.png" -crop "${badge_w}x${imgh}+${badge_start}+0" +repage "$tmp/badge.png"
# Drop the date:create/date:modify/date:timestamp text chunks and the tIME chunk
# they imply.  ImageMagick writes the current time into all four, which would
# make every run produce a file that differs from the last even when the artwork
# has not changed, and leave the tree dirty for no reason.
magick "$tmp/fedora_logo_darkbackground.png" "$tmp/badge.png" \
	-geometry "+${badge_start}+0" -composite \
	-trim +repage -resize "${width}x" -depth 8 \
	+set date:create +set date:modify +set date:timestamp \
	-define png:exclude-chunk=time "PNG32:$out"

echo "wrote $out ($(identify -format '%wx%h' "$out"), badge ${badge_w}px at x=${badge_start})"
